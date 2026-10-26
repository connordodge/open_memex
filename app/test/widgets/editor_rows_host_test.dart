// WI #167 (C1, Spec #157 R9-R13, R21, R32-R35, R39-R41; rulings D2, D5-D11,
// D17): each text segment of the segmented editor renders as editor rows.
// - Rows come from A1's `splitRows` after every change: one item row per
//   bullet, numbered, task or quote line, one code row per fenced block, one
//   prose row per run of other lines, keyed `editor-row-<s>-<r>`.
// - Item rows: a marker column (`editor-row-marker-<s>-<r>`, A2 widths,
//   marker source text in fg2) then a field holding only the item text, so
//   wrapped lines hang at the item text x; children start at the parent
//   text x; code rows inset 16.2 px left and 10 px right.
// - Lines 22.95 px, no gap between rows, marker on the first line.
// - Write-through (D9): one onContentChanged per keystroke, synchronous;
//   external writes re-derive rows, never echo and reset the segment undo;
//   a composing focused row is left alone.
// - Identity (R40, R41): the focused row keeps its FocusNode, controller and
//   text input connection through text, range and kind changes, polls and
//   rebases.
// - The SegmentEditing handle over rows (D5): select, rectForOffset,
//   focusedRow, replaceText; every row paints its selection slice.
// - Preserved behaviour (R32-R35): gutter across rows, [[ and the kind chip
//   in item rows, launch focus, hint, empty click area, marker column taps.
// - Composition points (D8): keyboard, pointer and selection-ops
//   pass-throughs and the undo recorder, called once per applied edit.
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_frame.dart';
import 'package:open_memex_app/src/widgets/editor/segment_keyboard.dart';
import 'package:open_memex_app/src/widgets/editor/segment_pointer_layer.dart';
import 'package:open_memex_app/src/widgets/editor/segment_selection_ops.dart';
import 'package:open_memex_app/src/widgets/editor/segment_undo.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';

import '../robots/segmented_editor_robot.dart';
import '../robots/today_robot.dart';
import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/footer_cli_fakes.dart';
import '../support/mac_editing.dart';
import '../support/markdown_fixtures.dart';
import '../support/poll_fakes.dart';
import '../support/segment_editing_finder.dart';
import '../support/today_cli_fakes.dart';
import '../support/topics_access_doubles.dart';
import '../support/topics_launch.dart';

/// A paragraph, a two-item list, a blank line and a last paragraph: rows
/// prose `para`, bullet `a`, bullet `b`, prose `\nend` (AC1).
const _wi167List = 'para\n- a\n- b\n\nend';

/// The hint of an empty single text segment.
const _wi167Hint = 'type [[ to link a note · write markdown…';

/// A card token: text segment 0, card 1, text segment 2.
const _wi167Token = '![[2026-09-05#^b7k2m9..^c3d4e5]]';

/// Words long enough to wrap twice in the 744 px test column.
const _wi167Long =
    'wrapped item text that keeps going well past the right edge of the '
    'text column so the field has to lay it out on a second line and a third';

/// One mono column (A2): 8.1 px.
const double _wi167Col = 8.1;

/// A body or item line (R13): 13.5 x 1.7.
const double _wi167Line = 22.95;

Note _wi167Note(String content, {bool daily = false}) => Note(
  id: daily ? 'daily-2026-10-03' : 'topic-167',
  title: daily ? '2026-10-03' : 'Rows',
  contentMd: content,
  frontmatter: daily ? '{"role":"daily"}' : '{"role":"topic"}',
  version: 3,
  createdAt: 0,
  updatedAt: 0,
  tags: const [],
);

/// A pumped [SegmentedBody] whose content the test can rewrite as a server
/// write would, and whose `onContentChanged` reports are recorded (and fed
/// back as the editor's content, as `EditorController` does).
class _Wi167Body {
  _Wi167Body(this.tester, this.content, this.version, this.changes);

  final WidgetTester tester;
  final ValueNotifier<String> content;
  final ValueNotifier<int> version;
  final List<String> changes;

  /// The server's copy of the note changed to [text] (a poll, a merge).
  Future<void> serverWrite(String text) async {
    content.value = text;
    await tester.pump();
    await tester.pump();
  }

  /// A save completed with the text unchanged (the base version moved).
  Future<void> saved() async {
    version.value++;
    await tester.pump();
    await tester.pump();
  }
}

Future<_Wi167Body> _wi167Pump(
  WidgetTester tester,
  String text, {
  bool daily = false,
  FocusNode? primary,
}) async {
  final content = ValueNotifier(text);
  final version = ValueNotifier(3);
  final changes = <String>[];
  addTearDown(content.dispose);
  addTearDown(version.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: ListenableBuilder(
                  listenable: Listenable.merge([content, version]),
                  builder: (context, _) => SegmentedBody(
                    note: _wi167Note(content.value, daily: daily),
                    content: content.value,
                    savedVersion: version.value,
                    primaryFocusNode: primary,
                    onContentChanged: (joined) {
                      changes.add(joined);
                      content.value = joined;
                    },
                  ),
                ),
              ),
              const SizedBox(
                key: Key('wi167-outside'),
                height: 40,
                width: double.infinity,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return _Wi167Body(tester, content, version, changes);
}

Finder _wi167Row(int s, int r) => find.byKey(Key('editor-row-$s-$r'));

Finder _wi167Marker(int s, int r) => find.byKey(Key('editor-row-marker-$s-$r'));

Finder _wi167FieldOf(int s, int r) =>
    find.descendant(of: _wi167Row(s, r), matching: find.byType(EditableText));

/// How many `editor-row-<s>-<r>` Keys segment [s] shows.
int _wi167RowKeys(int s) => find
    .byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey<String> &&
          RegExp('^editor-row-$s-\\d+\$').hasMatch(k.value);
    })
    .evaluate()
    .length;

/// How many `editor-row-marker-<s>-<r>` Keys segment [s] shows.
int _wi167MarkerKeys(int s) => find
    .byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey<String> &&
          RegExp('^editor-row-marker-$s-\\d+\$').hasMatch(k.value);
    })
    .evaluate()
    .length;

LivePreviewController _wi167Ctrl(WidgetTester tester, int s, int r) =>
    tester.widget<EditableText>(_wi167FieldOf(s, r)).controller
        as LivePreviewController;

String _wi167Text(WidgetTester tester, int s, int r) =>
    _wi167Ctrl(tester, s, r).text;

List<String> _wi167Texts(WidgetTester tester, int s) => [
  for (var r = 0; r < _wi167RowKeys(s); r++) _wi167Text(tester, s, r),
];

RenderEditable _wi167Editable(WidgetTester tester, int s, int r) {
  RenderEditable? found;
  void visit(RenderObject node) {
    if (found != null) return;
    if (node is RenderEditable) {
      found = node;
    } else {
      node.visitChildren(visit);
    }
  }

  visit(tester.renderObject(_wi167Row(s, r)));
  if (found == null) throw TestFailure('No RenderEditable in row $s-$r');
  return found!;
}

/// The global rect of row [s]-[r]'s field (its RenderEditable).
Rect _wi167FieldRect(WidgetTester tester, int s, int r) {
  final e = _wi167Editable(tester, s, r);
  return e.localToGlobal(Offset.zero) & e.size;
}

/// The global left of the glyph at local [offset] of [e].
double _wi167GlyphLeft(RenderEditable e, int offset) {
  final boxes = e.getBoxesForSelection(
    TextSelection(baseOffset: offset, extentOffset: offset + 1),
  );
  if (boxes.isEmpty) throw TestFailure('No glyph box at $offset');
  return e.localToGlobal(Offset(boxes.first.left, boxes.first.top)).dx;
}

/// Row [s]-[r]'s laid-out lines in global coordinates (top, bottom, range).
List<({double top, double bottom, TextRange range})> _wi167Lines(
  WidgetTester tester,
  int s,
  int r,
) {
  final e = _wi167Editable(tester, s, r);
  return [
    for (final line in RenderEditableLineBoxes(e).lines)
      (
        top: e.localToGlobal(Offset(0, line.top)).dy,
        bottom: e.localToGlobal(Offset(0, line.bottom)).dy,
        range: line.range,
      ),
  ];
}

/// The text the marker column of row [s]-[r] shows.
String _wi167MarkerText(WidgetTester tester, int s, int r) => [
  for (final w in tester.widgetList<RichText>(
    find.descendant(of: _wi167Marker(s, r), matching: find.byType(RichText)),
  ))
    w.text.toPlainText(),
].join();

/// The colours of every visible glyph run of the marker column [s]-[r].
Set<Color?> _wi167MarkerColors(WidgetTester tester, int s, int r) {
  final out = <Color?>{};
  void visit(InlineSpan span, Color? inherited) {
    final color = span.style?.color ?? inherited;
    if (span is TextSpan) {
      if ((span.text ?? '').trim().isNotEmpty) out.add(color);
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child, color);
      }
    }
  }

  for (final w in tester.widgetList<RichText>(
    find.descendant(of: _wi167Marker(s, r), matching: find.byType(RichText)),
  )) {
    visit(w.text, null);
  }
  return out;
}

Rect _wi167SegmentRect(WidgetTester tester, int s) =>
    tester.getRect(find.byKey(textSegmentKey(s)));

SegmentViewState _wi167View(WidgetTester tester, int s) =>
    tester.state<SegmentViewState>(
      find.descendant(
        of: find.byKey(textSegmentKey(s)),
        matching: find.byType(SegmentView),
      ),
    );

/// Focus row [s]-[r]'s field and put its caret at local [local] (default:
/// the row text's end).
Future<void> _wi167FocusRow(
  WidgetTester tester,
  int s,
  int r, {
  int? local,
}) async {
  await tester.showKeyboard(_wi167Row(s, r));
  await tester.pump();
  final ctrl = _wi167Ctrl(tester, s, r);
  ctrl.selection = TextSelection.collapsed(offset: local ?? ctrl.text.length);
  await tester.pump();
}

/// Every text input client change logged since [log] was cleared.
Iterable<MethodCall> _wi167ClientChanges(List<MethodCall> log) => log.where(
  (c) =>
      c.method == 'TextInput.setClient' || c.method == 'TextInput.clearClient',
);

/// A segment undo recorder that remembers what the host told it.
class _Wi167Recorder extends SegmentUndoRecorder {
  final records = <({String before, SegmentEdit edit})>[];
  int resets = 0;

  @override
  void record(SegmentEdit edit, {required String before}) =>
      records.add((before: before, edit: edit));

  @override
  void reset() => resets++;
}

/// Every recorder the host makes from now on (one per text segment) lands in
/// the returned list. Restored at teardown.
List<_Wi167Recorder> _wi167Recorders() {
  final made = <_Wi167Recorder>[];
  final previous = segmentUndoRecorderFactory;
  segmentUndoRecorderFactory = () {
    final r = _Wi167Recorder();
    made.add(r);
    return r;
  };
  addTearDown(() => segmentUndoRecorderFactory = previous);
  return made;
}

int _wi167RecordCount(List<_Wi167Recorder> made) =>
    made.fold(0, (n, r) => n + r.records.length);

int _wi167ResetCount(List<_Wi167Recorder> made) =>
    made.fold(0, (n, r) => n + r.resets);

void main() {
  holdFontFetches();

  // -------------------------------------------------------------------------
  // AC1: row shapes and keys
  // -------------------------------------------------------------------------
  group('rows from the segment text (AC1)', () {
    testWidgets(
      'a segment with a paragraph a two item list and a trailing paragraph renders four rows keyed by segment and row index',
      (tester) async {
        await _wi167Pump(tester, _wi167List);

        expect(_wi167RowKeys(0), 4);
        for (var r = 0; r < 4; r++) {
          expect(_wi167Row(0, r), findsOneWidget, reason: 'editor-row-0-$r');
          // The index Key wraps exactly one field.
          expect(_wi167FieldOf(0, r), findsOneWidget);
        }
        expect(_wi167Row(0, 4), findsNothing);
        expect(_wi167Texts(tester, 0), ['para', 'a', 'b', '\nend']);
        // Only the two item rows have a marker column.
        expect(_wi167Marker(0, 1), findsOneWidget);
        expect(_wi167Marker(0, 2), findsOneWidget);
        expect(_wi167MarkerKeys(0), 2);
        final handle = segmentEditingAt(tester, 0);
        expect(handle.rowCount, 4);
        expect(handle.text, _wi167List);
        // The row fields sit inside the segment's Key.
        expect(
          find.descendant(
            of: find.byKey(textSegmentKey(0)),
            matching: _wi167Row(0, 3),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a segment with no item lines renders exactly one prose row holding the whole segment text',
      (tester) async {
        const text = '# Title\nplain text\n\n---\nmore words\n';
        await _wi167Pump(tester, text);

        expect(_wi167RowKeys(0), 1);
        expect(_wi167Texts(tester, 0), [text]);
        expect(_wi167MarkerKeys(0), 0);
        expect(segmentEditingAt(tester, 0).rowCount, 1);
        expect(_wi167Ctrl(tester, 0, 0).itemText, isFalse);
      },
    );

    testWidgets('a list like line inside a fence is not an item row', (
      tester,
    ) async {
      const fence = '```\n- not a list\n1. not numbered\n> not a quote\n```';
      await _wi167Pump(tester, 'intro\n$fence\n');

      expect(_wi167Texts(tester, 0), ['intro', fence, '']);
      expect(_wi167MarkerKeys(0), 0);
      for (var r = 0; r < 3; r++) {
        expect(_wi167Ctrl(tester, 0, r).itemText, isFalse, reason: 'row $r');
      }
    });

    testWidgets(
      'rows of a second text segment after a card are keyed with that segment index',
      (tester) async {
        await _wi167Pump(tester, 'Intro\n$_wi167Token\n- one\n- two\nOutro\n');

        expect(_wi167Texts(tester, 0), ['Intro\n']);
        expect(_wi167Texts(tester, 2), ['one', 'two', 'Outro\n']);
        expect(_wi167Marker(2, 0), findsOneWidget);
        expect(_wi167Marker(2, 1), findsOneWidget);
        expect(segmentEditingAt(tester, 2).rowCount, 3);
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC2: code rows
  // -------------------------------------------------------------------------
  group('code rows (AC2)', () {
    testWidgets(
      'a fenced block renders one code row whose text starts 16.2 px right of the text column and ends 10 px before the box right edge',
      (tester) async {
        const fence = '```\nlet a = 1;\n- b stays code\n```';
        await _wi167Pump(tester, 'Before\n$fence\nAfter');

        expect(_wi167Texts(tester, 0), ['Before', fence, 'After']);
        expect(_wi167MarkerKeys(0), 0);
        final column = _wi167SegmentRect(tester, 0);
        final code = _wi167FieldRect(tester, 0, 1);
        expect(code.left, moreOrLessEquals(column.left + 16.2, epsilon: 0.01));
        expect(code.right, moreOrLessEquals(column.right - 10, epsilon: 0.01));
        expect(
          _wi167GlyphLeft(_wi167Editable(tester, 0, 1), 0),
          moreOrLessEquals(column.left + 16.2, epsilon: 0.01),
        );
        // Prose rows span the text column.
        for (final r in [0, 2]) {
          final prose = _wi167FieldRect(tester, 0, r);
          expect(prose.left, moreOrLessEquals(column.left, epsilon: 0.01));
          expect(prose.right, moreOrLessEquals(column.right, epsilon: 0.01));
        }
        expect(_wi167Ctrl(tester, 0, 1).itemText, isFalse);
        expect(_wi167Ctrl(tester, 0, 1).quote, isFalse);
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC3: quote prop
  // -------------------------------------------------------------------------
  group('quote rows (AC3)', () {
    testWidgets(
      'quote rows set the controller quote prop and every other row leaves it false',
      (tester) async {
        await _wi167Pump(
          tester,
          '> first quote\n>\nplain\n- bullet\n- [ ] task\n1. num\n',
        );

        expect(_wi167Texts(tester, 0), [
          'first quote',
          '',
          'plain',
          'bullet',
          'task',
          'num',
          '',
        ]);
        final quotes = [
          for (var r = 0; r < 7; r++) _wi167Ctrl(tester, 0, r).quote,
        ];
        expect(quotes, [true, true, false, false, false, false, false]);
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC4: item text and marker source
  // -------------------------------------------------------------------------
  group('item rows (AC4)', () {
    testWidgets(
      'each item row field holds only the item text and its marker column shows the marker source text in fg2',
      (tester) async {
        await _wi167Pump(
          tester,
          'intro\n- dash item\n* star item\n12. twelve\n- [ ] open task\n'
          '- [x] done task\n> quoted\n- \nend',
        );

        expect(_wi167Texts(tester, 0), [
          'intro',
          'dash item',
          'star item',
          'twelve',
          'open task',
          'done task',
          'quoted',
          '',
          'end',
        ]);
        const markers = {
          1: '- ',
          2: '* ',
          3: '12. ',
          4: '- [ ] ',
          5: '- [x] ',
          6: '> ',
          7: '- ',
        };
        for (final MapEntry(key: r, value: marker) in markers.entries) {
          expect(_wi167MarkerText(tester, 0, r), marker, reason: 'row $r');
          expect(_wi167MarkerColors(tester, 0, r), {
            OmColors.fg2,
          }, reason: 'row $r marker colour');
        }
        expect(_wi167Marker(0, 0), findsNothing);
        expect(_wi167Marker(0, 8), findsNothing);
      },
    );

    testWidgets(
      'every row field is wrapped in a LivePreviewFrame of its own LivePreviewController and the host sets itemText taskDone atSegmentStart and revealGate',
      (tester) async {
        await _wi167Pump(tester, 'intro\n- [x] done\n- [ ] open\n> q');

        final controllers = [
          for (var r = 0; r < 4; r++) _wi167Ctrl(tester, 0, r),
        ];
        for (var r = 0; r < 4; r++) {
          final frame = tester.widget<LivePreviewFrame>(
            find
                .ancestor(
                  of: _wi167FieldOf(0, r),
                  matching: find.byType(LivePreviewFrame),
                )
                .first,
          );
          expect(frame.controller, same(controllers[r]), reason: 'row $r');
        }
        expect(controllers.toSet(), hasLength(4));
        expect(
          [for (final c in controllers) c.itemText],
          [false, true, true, true],
        );
        expect(
          [for (final c in controllers) c.taskDone],
          [false, true, false, false],
        );
        expect(
          [for (final c in controllers) c.atSegmentStart],
          [true, false, false, false],
        );
        expect(
          [for (final c in controllers) c.revealGate.value],
          [false, false, false, false],
        );

        // Markers may reveal in every row while any row of the segment has
        // focus.
        await _wi167FocusRow(tester, 0, 2);
        expect(
          [for (final c in controllers) c.revealGate.value],
          [true, true, true, true],
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        expect(
          [for (final c in controllers) c.revealGate.value],
          [false, false, false, false],
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC5: hanging indent
  // -------------------------------------------------------------------------
  group('hanging indent (AC5)', () {
    for (final (name, line, column) in [
      (
        'a wrapped bullet row starts its second line at the item text x',
        '- $_wi167Long',
        2 * _wi167Col,
      ),
      (
        'a wrapped numbered row starts its second line at the item text x',
        '7. $_wi167Long',
        3 * _wi167Col,
      ),
      (
        'a wrapped task row starts its second line at the item text x',
        '- [ ] $_wi167Long',
        4 * _wi167Col,
      ),
      (
        'a wrapped quote row starts its second line at the item text x',
        '> $_wi167Long',
        2 * _wi167Col,
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _wi167Pump(tester, 'intro\n$line');

        expect(_wi167Text(tester, 0, 1), _wi167Long);
        final textX = _wi167SegmentRect(tester, 0).left + column;
        final editable = _wi167Editable(tester, 0, 1);
        final lines = _wi167Lines(tester, 0, 1);
        expect(lines.length, greaterThanOrEqualTo(2), reason: 'the item wraps');
        expect(
          _wi167GlyphLeft(editable, 0),
          moreOrLessEquals(textX, epsilon: 0.01),
          reason: 'first line text x',
        );
        expect(
          _wi167GlyphLeft(editable, lines[1].range.start),
          moreOrLessEquals(textX, epsilon: 0.01),
          reason: 'the second line hangs at the item text x',
        );
      });
    }

    testWidgets(
      'item text reaches the text column right edge and a quote row keeps one column of right padding',
      (tester) async {
        await _wi167Pump(tester, '- bullet\n> quote\n1. one');

        final right = _wi167SegmentRect(tester, 0).right;
        expect(
          _wi167FieldRect(tester, 0, 0).right,
          moreOrLessEquals(right, epsilon: 0.01),
        );
        expect(
          _wi167FieldRect(tester, 0, 1).right,
          moreOrLessEquals(right - _wi167Col, epsilon: 0.01),
        );
        expect(
          _wi167FieldRect(tester, 0, 2).right,
          moreOrLessEquals(right, epsilon: 0.01),
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC6: marker widths and nesting
  // -------------------------------------------------------------------------
  group('marker columns and nesting (AC6)', () {
    testWidgets(
      'marker columns have the A2 widths for bullet numbered quote and task rows and a nested child starts at its parent text x',
      (tester) async {
        await _wi167Pump(
          tester,
          '- a\n  - child of bullet\n1. one\n2. two\n> quote\n- [ ] task\n'
          '  - child of task\n10. ten\n11. eleven\n',
        );
        final t = _wi167SegmentRect(tester, 0).left;
        // Row: (marker left, marker width).
        final expected = <int, (double, double)>{
          0: (t, 16.2),
          1: (t + 16.2, 16.2),
          2: (t, 24.3),
          3: (t, 24.3),
          4: (t, 16.2),
          5: (t, 32.4),
          6: (t + 32.4, 16.2),
          7: (t, 32.4),
          8: (t, 32.4),
        };
        for (final MapEntry(key: r, value: (left, width)) in expected.entries) {
          final marker = tester.getRect(_wi167Marker(0, r));
          expect(
            marker.left,
            moreOrLessEquals(left, epsilon: 0.01),
            reason: 'row $r marker x',
          );
          expect(
            marker.width,
            moreOrLessEquals(width, epsilon: 0.01),
            reason: 'row $r marker width',
          );
          expect(
            _wi167FieldRect(tester, 0, r).left,
            moreOrLessEquals(left + width, epsilon: 0.01),
            reason: 'row $r text x',
          );
        }
      },
    );

    testWidgets(
      'when a numbered run grows from nine to ten items every row in the run widens together',
      (tester) async {
        final nine = [for (var i = 1; i <= 9; i++) '$i. item $i'].join('\n');
        await _wi167Pump(tester, nine);
        final t = _wi167SegmentRect(tester, 0).left;
        for (var r = 0; r < 9; r++) {
          expect(
            tester.getRect(_wi167Marker(0, r)).width,
            moreOrLessEquals(24.3, epsilon: 0.01),
            reason: 'row $r before',
          );
        }

        segmentEditingAt(tester, 0).replaceText('$nine\n10. item 10');
        await tester.pump();
        await tester.pump();

        expect(_wi167RowKeys(0), 10);
        for (var r = 0; r < 10; r++) {
          expect(
            tester.getRect(_wi167Marker(0, r)).width,
            moreOrLessEquals(32.4, epsilon: 0.01),
            reason: 'row $r after',
          );
          expect(
            _wi167FieldRect(tester, 0, r).left,
            moreOrLessEquals(t + 32.4, epsilon: 0.01),
            reason: 'row $r text x after',
          );
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC7: line heights and row gaps
  // -------------------------------------------------------------------------
  group('line heights (AC7)', () {
    testWidgets(
      'body and item lines are 22.95 px tall and consecutive rows touch with no vertical gap',
      (tester) async {
        await _wi167Pump(
          tester,
          'para line\nsecond para line\n- item one\n- $_wi167Long\n> quote\n'
          'last para',
        );

        expect(_wi167RowKeys(0), 5);
        for (var r = 0; r < 5; r++) {
          final lines = _wi167Lines(tester, 0, r);
          for (final line in lines) {
            expect(
              line.bottom - line.top,
              moreOrLessEquals(_wi167Line, epsilon: 0.1),
              reason: 'row $r line ${line.range}',
            );
          }
          expect(
            _wi167FieldRect(tester, 0, r).height,
            // The test font rounds each 22.95 line to 23.
            moreOrLessEquals(lines.length * _wi167Line, epsilon: 0.5),
            reason: 'row $r has no padding',
          );
          if (r > 0) {
            expect(
              _wi167FieldRect(tester, 0, r).top,
              moreOrLessEquals(
                _wi167FieldRect(tester, 0, r - 1).bottom,
                epsilon: 0.1,
              ),
              reason: 'no gap above row $r',
            );
          }
        }
        // The wrapped item: the marker sits on its first line only.
        expect(_wi167Lines(tester, 0, 2).length, greaterThanOrEqualTo(2));
        for (final r in [1, 2, 3]) {
          final marker = tester.getRect(_wi167Marker(0, r));
          final field = _wi167FieldRect(tester, 0, r);
          expect(
            marker.top,
            moreOrLessEquals(field.top, epsilon: 0.1),
            reason: 'row $r',
          );
          expect(
            marker.height,
            moreOrLessEquals(_wi167Line, epsilon: 0.1),
            reason: 'row $r marker is one line tall',
          );
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC8: focus and input connection while typing
  // -------------------------------------------------------------------------
  group('typing keeps the row (AC8)', () {
    testWidgets(
      'typing in a focused row keeps its FocusNode and text input connection',
      (tester) async {
        final body = await _wi167Pump(tester, _wi167List);
        await _wi167FocusRow(tester, 0, 2);
        final node = FocusManager.instance.primaryFocus;
        final state = tester.state<EditableTextState>(_wi167FieldOf(0, 2));
        final ctrl = _wi167Ctrl(tester, 0, 2);
        expect(node, isNotNull);
        expect(segmentEditingAt(tester, 0).focusedRow, 2);
        tester.testTextInput.log.clear();

        await tester.macEditingValue('bx');
        await tester.macEditingValue('bxy');

        expect(FocusManager.instance.primaryFocus, same(node));
        expect(
          tester.state<EditableTextState>(_wi167FieldOf(0, 2)),
          same(state),
        );
        expect(_wi167Ctrl(tester, 0, 2), same(ctrl));
        expect(_wi167ClientChanges(tester.testTextInput.log), isEmpty);
        expect(segmentEditingAt(tester, 0).focusedRow, 2);
        expect(body.changes.last, 'para\n- a\n- bxy\n\nend');
      },
    );

    testWidgets(
      'typing a bullet prefix at the start of a plain line turns it into an item row that keeps focus with the caret before the same text',
      (tester) async {
        final body = await _wi167Pump(tester, 'hello\nworld');
        expect(_wi167RowKeys(0), 1);
        await _wi167FocusRow(tester, 0, 0, local: 6);
        final node = FocusManager.instance.primaryFocus;
        final state = tester.state<EditableTextState>(_wi167FieldOf(0, 0));
        final ctrl = _wi167Ctrl(tester, 0, 0);
        tester.testTextInput.log.clear();

        await tester.macEditingValue(
          'hello\n-world',
          selection: const TextSelection.collapsed(offset: 7),
        );
        expect(_wi167RowKeys(0), 1, reason: 'a bare - is text');
        await tester.macEditingValue(
          'hello\n- world',
          selection: const TextSelection.collapsed(offset: 8),
        );
        await tester.pump();

        expect(_wi167Texts(tester, 0), ['hello', 'world']);
        expect(_wi167MarkerText(tester, 0, 1), '- ');
        final handle = segmentEditingAt(tester, 0);
        expect(handle.focusedRow, 1);
        expect(handle.selection, const TextSelection.collapsed(offset: 8));
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(_wi167Ctrl(tester, 0, 1), same(ctrl));
        expect(
          _wi167Ctrl(tester, 0, 1).selection,
          const TextSelection.collapsed(offset: 0),
        );
        expect(
          tester.state<EditableTextState>(_wi167FieldOf(0, 1)),
          same(state),
        );
        expect(_wi167ClientChanges(tester.testTextInput.log), isEmpty);
        expect(body.changes, ['hello\n-world', 'hello\n- world']);
      },
    );

    testWidgets(
      'typing a task box after a bullet marker turns the bullet into a task row that keeps focus',
      (tester) async {
        final body = await _wi167Pump(tester, 'intro\n- milk');
        await _wi167FocusRow(tester, 0, 1, local: 0);
        final node = FocusManager.instance.primaryFocus;
        final ctrl = _wi167Ctrl(tester, 0, 1);
        tester.testTextInput.log.clear();

        for (final (typed, caret) in [
          ('[milk', 1),
          ('[ milk', 2),
          ('[ ]milk', 3),
          ('[ ] milk', 4),
        ]) {
          await tester.macEditingValue(
            typed,
            selection: TextSelection.collapsed(offset: caret),
          );
        }
        await tester.pump();

        expect(_wi167Texts(tester, 0), ['intro', 'milk']);
        expect(_wi167MarkerText(tester, 0, 1), '- [ ] ');
        expect(_wi167Ctrl(tester, 0, 1), same(ctrl));
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(offset: 12),
        );
        expect(
          _wi167Ctrl(tester, 0, 1).selection,
          const TextSelection.collapsed(offset: 0),
        );
        expect(_wi167ClientChanges(tester.testTextInput.log), isEmpty);
        expect(body.changes.last, 'intro\n- [ ] milk');
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC9: write-through and echo suppression
  // -------------------------------------------------------------------------
  group('write-through (AC9)', () {
    testWidgets(
      'each keystroke in a row reports exactly one onContentChanged with the joined body bytes',
      (tester) async {
        final body = await _wi167Pump(tester, 'a\r\n- b\r\n- c\r\nd');
        expect(_wi167Texts(tester, 0), ['a', 'b', 'c', 'd']);

        await _wi167FocusRow(tester, 0, 2);
        expect(body.changes, isEmpty, reason: 'focusing is not an edit');
        await tester.macEditingValue('cx');
        expect(body.changes, ['a\r\n- b\r\n- cx\r\nd']);

        await _wi167FocusRow(tester, 0, 0);
        await tester.macEditingValue('ay');
        expect(body.changes, [
          'a\r\n- b\r\n- cx\r\nd',
          'ay\r\n- b\r\n- cx\r\nd',
        ]);
        expect(segmentEditingAt(tester, 0).text, 'ay\r\n- b\r\n- cx\r\nd');
      },
    );

    testWidgets(
      'replaceText reports the joined body once synchronously and re-derives the rows',
      (tester) async {
        final body = await _wi167Pump(tester, _wi167List);

        segmentEditingAt(tester, 0).replaceText('x\n- y');
        // Synchronous: reported before any frame (B3 flushes on it).
        expect(body.changes, ['x\n- y']);
        await tester.pump();
        await tester.pump();

        expect(body.changes, ['x\n- y']);
        expect(_wi167Texts(tester, 0), ['x', 'y']);
        expect(segmentEditingAt(tester, 0).rowCount, 2);
      },
    );

    testWidgets(
      'an external write re-derives the rows without echoing an edit back and resets the segment undo',
      (tester) async {
        final recorders = _wi167Recorders();
        final body = await _wi167Pump(tester, _wi167List);
        final resets = _wi167ResetCount(recorders);

        await body.serverWrite('para\n- a\n- b\n- c\n\nend');

        expect(body.changes, isEmpty);
        expect(_wi167Texts(tester, 0), ['para', 'a', 'b', 'c', '\nend']);
        expect(segmentEditingAt(tester, 0).text, 'para\n- a\n- b\n- c\n\nend');
        expect(_wi167RecordCount(recorders), 0);
        expect(_wi167ResetCount(recorders), resets + 1);
      },
    );

    testWidgets(
      'a server write that keeps a composing focused row leaves its composing range alone',
      (tester) async {
        final body = await _wi167Pump(tester, '- a\nend');
        await _wi167FocusRow(tester, 0, 0);

        await tester.macCompose('aé', const TextRange(start: 1, end: 2));
        expect(body.changes, ['- aé\nend']);
        expect(
          _wi167Ctrl(tester, 0, 0).value.composing,
          const TextRange(start: 1, end: 2),
          reason: 'the keystroke write-through keeps the marked text',
        );

        await body.serverWrite('- aé\nend\nmore');

        expect(_wi167Texts(tester, 0), ['aé', 'end\nmore']);
        expect(_wi167Ctrl(tester, 0, 0).text, 'aé');
        expect(
          _wi167Ctrl(tester, 0, 0).value.composing,
          const TextRange(start: 1, end: 2),
        );
        expect(body.changes, ['- aé\nend']);
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC10: polls and rebases keep the focused row
  // -------------------------------------------------------------------------
  group('server writes keep the focused row (AC10)', () {
    testWidgets(
      'a polled capture appended to the focused row keeps its focus controller and caret at the same segment offset',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedLiveDaily(
            blocks: const [
              SeedBlock('p-intro', 'Intro.'),
              SeedBlock('p-list', '- one\n- two'),
              SeedBlock('p-tail', 'Tail words here.'),
            ],
          );
        final clock = FakeClock(DateTime(2026, 10, 3, 9));
        final cli = FakeMemexCli()..onUpdateServer(db, clock: clock);
        final r = await pumpLiveWorkspace(
          tester,
          db: db,
          cli: cli,
          clock: clock,
        );
        expect(_wi167Texts(tester, 0), [
          'Intro.\n',
          'one',
          'two',
          '\nTail words here.\n',
        ]);
        final caret = r.bodyText.indexOf(' words here');
        await r.placeCaret(caret);
        expect(r.bodySegment.focusedRow, 3);
        final node = FocusManager.instance.primaryFocus;
        final ctrl = _wi167Ctrl(tester, 0, 3);
        final state = tester.state<EditableTextState>(_wi167FieldOf(0, 3));

        r.db.serverAppend(
          liveDailyId,
          'Agent added.',
          blockId: 'a-added',
          at: DateTime(2026, 10, 3, 9, 0, 1),
        );
        await r.poll();

        expect(r.bodyText.trimRight().endsWith('Agent added.'), isTrue);
        expect(_wi167RowKeys(0), 4);
        expect(_wi167Text(tester, 0, 3), endsWith('Agent added.\n'));
        expect(r.bodySegment.focusedRow, 3);
        expect(r.bodySelection, TextSelection.collapsed(offset: caret));
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(_wi167Ctrl(tester, 0, 3), same(ctrl));
        expect(
          tester.state<EditableTextState>(_wi167FieldOf(0, 3)),
          same(state),
        );
        expect(r.updates, isEmpty);
      },
    );

    testWidgets(
      'the footer rebase after an autocomplete create keeps the focused row and its caret at the same segment offset',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedDailyNote('2026-10-03', id: 'daily-2026-10-03')
          ..seedDailyNote('2026-09-30', id: 'daily-2026-09-30');
        final cli = FakeMemexCli()
          ..onUpdateWrites(db)
          ..onAddCreates(db)
          ..onFooterAdd(db);
        final r = await launchTopics(
          tester,
          AccessDoubles(),
          db: db,
          cli: cli,
          topicsMode: false,
        );
        r.h
            .read(tabsProvider.notifier)
            .openOrFocus(const NoteTab('daily-2026-09-30'));
        await pumpFrames(tester);
        final bodyField = find.byKey(editorBodyKey);
        await focusSegmentAt(tester, bodyField);
        tester.testTextInput.enterText('- first\nSlept badly [[Sleep');
        await pumpFrames(tester);

        expect(_wi167Texts(tester, 0), ['first', 'Slept badly [[Sleep']);
        expect(editorBodySegment(tester).focusedRow, 1);
        final node = FocusManager.instance.primaryFocus;
        final ctrl = _wi167Ctrl(tester, 0, 1);
        final popoverCreate = find.byKey(const Key('wikilink-popover-create'));
        expect(popoverCreate, findsOneWidget);

        await tester.tap(popoverCreate);
        await pumpFrames(tester);

        const typed = '- first\nSlept badly [[Sleep]]';
        expect(
          r.h.read(editorControllerProvider).lastSavedVersion,
          2,
          reason: 'the editor rebased onto the footer add version',
        );
        final handle = editorBodySegment(tester);
        expect(handle.text, typed);
        expect(handle.focusedRow, 1);
        expect(
          handle.selection,
          const TextSelection.collapsed(offset: typed.length),
        );
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(_wi167Ctrl(tester, 0, 1), same(ctrl));
      },
    );

    testWidgets(
      'a completed save that keeps the text keeps every row controller and the focused caret',
      (tester) async {
        final body = await _wi167Pump(tester, _wi167List);
        await _wi167FocusRow(tester, 0, 1, local: 1);
        final before = [for (var r = 0; r < 4; r++) _wi167Ctrl(tester, 0, r)];
        final node = FocusManager.instance.primaryFocus;

        await body.saved();

        for (var r = 0; r < 4; r++) {
          expect(_wi167Ctrl(tester, 0, r), same(before[r]), reason: 'row $r');
        }
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(offset: 8),
        );
        expect(body.changes, isEmpty);
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC11: opening a note saves nothing (D17)
  // -------------------------------------------------------------------------
  group('open without edit (AC11)', () {
    testWidgets(
      'opening each markdown fixture note and waiting past the save debounce sends no update and shows its rows',
      (tester) async {
        final vault = seedSegmentedVault();
        final ids = <String, String>{};
        var i = 0;
        for (final MapEntry(key: name, value: text)
            in markdownFixtures.entries) {
          final id = 'topic-wi167-fixture-${i++}';
          ids[name] = id;
          vault.db.seedNote(
            id: id,
            title: 'Fixture $name',
            role: 'topic',
            content: text,
            version: 1,
          );
        }
        final r = await launchSegmented(tester, vault: vault);

        for (final MapEntry(key: name, value: text)
            in markdownFixtures.entries) {
          await r.open(ids[name]!);
          expect(r.segmentText(0), text, reason: name);
          expect(
            r.segment(0).rowCount,
            splitRows(text, atSegmentStart: true).length,
            reason: '$name rows',
          );
          await r.waitForSave();
          expect(r.updates, isEmpty, reason: '$name was saved');
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC12: the handle over rows
  // -------------------------------------------------------------------------
  group('SegmentEditing over rows (AC12)', () {
    testWidgets(
      'select over three rows sets each row selection to its slice and each unfocused row paints it in the selection colour with tight boxes',
      (tester) async {
        await _wi167Pump(tester, _wi167List);
        expect(segmentEditingAt(tester, 0).focusedRow, isNull);

        const range = TextSelection(baseOffset: 2, extentOffset: 12);
        segmentEditingAt(tester, 0).select(range);
        await tester.pump();

        expect(segmentEditingAt(tester, 0).selection, range);
        expect(segmentEditingAt(tester, 0).focusedRow, isNull);
        final slices = {
          0: const TextSelection(baseOffset: 2, extentOffset: 4),
          1: const TextSelection(baseOffset: 0, extentOffset: 1),
          2: const TextSelection(baseOffset: 0, extentOffset: 1),
        };
        for (final MapEntry(key: r, value: slice) in slices.entries) {
          expect(_wi167Ctrl(tester, 0, r).selection, slice, reason: 'row $r');
          expect(
            _wi167Editable(tester, 0, r).selection,
            slice,
            reason: 'row $r renders it',
          );
          // The slice's x extent on its line, as the field lays it out. The
          // painted slice is as wide as the slice and tight: the 13.5 px
          // font's content height, not its 22.95 line or the line spacing.
          final line = RenderEditableLineBoxes(
            _wi167Editable(tester, 0, r),
          ).boxesFor(TextRange(start: slice.start, end: slice.end)).single;
          expect(
            tester.renderObject(_wi167Row(0, r)),
            paints..something((method, args) {
              if (method != #drawRect) return false;
              final rect = args[0] as Rect;
              final paint = args[1] as Paint;
              // Paint stores its colour as float32 components, so compare
              // the 8-bit ARGB value (an exact == never matches).
              return paint.color.toARGB32() == OmColors.selection.toARGB32() &&
                  rect.height > 5 &&
                  rect.height < 13.5 + 1 &&
                  (rect.width - line.width).abs() < 0.5;
            }),
            reason:
                'row $r paints its slice while unfocused in OmColors.selection '
                'with a tight box inside its line',
          );
        }
        expect(
          tester.renderObject(_wi167Row(0, 3)),
          isNot(
            paints..something(
              (method, args) =>
                  method == #drawRect &&
                  (args[1] as Paint).color.toARGB32() ==
                      OmColors.selection.toARGB32(),
            ),
          ),
          reason: 'the untouched row paints no selection',
        );

        // A backwards selection keeps its direction.
        const back = TextSelection(baseOffset: 12, extentOffset: 2);
        segmentEditingAt(tester, 0).select(back);
        await tester.pump();
        expect(segmentEditingAt(tester, 0).selection, back);
      },
    );

    testWidgets(
      'rectForOffset returns the caret rect of the row holding the offset for an offset in any row',
      (tester) async {
        await _wi167Pump(tester, _wi167List);
        final handle = segmentEditingAt(tester, 0);

        // Segment offset: (row, local offset).
        const cases = {2: (0, 2), 8: (1, 1), 11: (2, 0), 16: (3, 3)};
        for (final MapEntry(key: offset, value: (r, local)) in cases.entries) {
          final editable = _wi167Editable(tester, 0, r);
          final caret = RenderEditableLineBoxes(editable).caretRect(local);
          final expected = Rect.fromPoints(
            editable.localToGlobal(caret.topLeft),
            editable.localToGlobal(caret.bottomRight),
          );
          final actual = handle.rectForOffset(offset);
          expect(
            actual.left,
            moreOrLessEquals(expected.left, epsilon: 0.01),
            reason: 'offset $offset x',
          );
          expect(
            actual.top,
            moreOrLessEquals(expected.top, epsilon: 0.01),
            reason: 'offset $offset top',
          );
          expect(
            actual.bottom,
            moreOrLessEquals(expected.bottom, epsilon: 0.01),
            reason: 'offset $offset bottom',
          );
          expect(actual.height, greaterThan(0));
        }
      },
    );

    testWidgets(
      'focusedRow reports the index of the focused row and null when no row has focus',
      (tester) async {
        await _wi167Pump(tester, _wi167List);
        final handle = segmentEditingAt(tester, 0);
        expect(handle.focusedRow, isNull);

        await _wi167FocusRow(tester, 0, 3);
        expect(segmentEditingAt(tester, 0).focusedRow, 3);
        expect(
          segmentEditingAt(tester, 0).selection,
          TextSelection.collapsed(offset: _wi167List.length),
        );

        await _wi167FocusRow(tester, 0, 1, local: 0);
        expect(segmentEditingAt(tester, 0).focusedRow, 1);
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(offset: 7),
        );

        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        expect(segmentEditingAt(tester, 0).focusedRow, isNull);
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC13: capture gutter across rows
  // -------------------------------------------------------------------------
  group('capture gutter across rows (AC13)', () {
    testWidgets(
      'a captured block spanning a prose row and two item rows gets one gutter rule from its first line top to its last line bottom',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedLiveDaily(
            blocks: [
              const SeedBlock('p-intro', 'Intro para.'),
              SeedBlock(
                'a-cap',
                'Captured heading.\n- first captured\n- second captured',
                source: 'agent',
                createdVersion: 2,
                createdAt: DateTime(2026, 10, 3, 14, 32),
              ),
              const SeedBlock('p-tail', 'Tail.'),
            ],
          );
        final clock = FakeClock(DateTime(2026, 10, 3, 15));
        final cli = FakeMemexCli()..onUpdateServer(db, clock: clock);
        await pumpLiveWorkspace(tester, db: db, cli: cli, clock: clock);
        await tester.pump();

        expect(_wi167Texts(tester, 0), [
          'Intro para.\n\nCaptured heading.',
          'first captured',
          'second captured',
          '\nTail.\n',
        ]);
        final rule = find.byKey(const Key('capture-gutter-rule-a-cap'));
        expect(rule, findsOneWidget);
        final rect = tester.getRect(rule);
        final heading = 'Intro para.\n\n'.length;
        final first = _wi167Lines(
          tester,
          0,
          0,
        ).lastWhere((l) => l.range.start <= heading);
        final last = _wi167Lines(tester, 0, 2).last;
        expect(rect.top, moreOrLessEquals(first.top, epsilon: 0.5));
        expect(rect.bottom, moreOrLessEquals(last.bottom, epsilon: 0.5));
        // It spans the item rows between.
        expect(rect.top, lessThan(_wi167FieldRect(tester, 0, 1).top));
        expect(
          rect.bottom,
          greaterThanOrEqualTo(_wi167FieldRect(tester, 0, 2).bottom - 0.5),
        );
        expect(
          rect.bottom,
          lessThanOrEqualTo(_wi167FieldRect(tester, 0, 3).top + 0.5),
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC14: autocomplete and kind chip in item rows
  // -------------------------------------------------------------------------
  group('autocomplete in item rows (AC14)', () {
    const body = 'Intro line\n- see \nOutro line\n';

    Future<SegmentedEditorRobot> openWithPopover(WidgetTester tester) async {
      final r = await launchSegmented(
        tester,
        vault: seedSegmentedVault(topicBody: body),
      );
      await r.open(fixtureTopicId);
      expect(_wi167Texts(tester, 0), ['Intro line', 'see ', 'Outro line\n']);
      await _wi167FocusRow(tester, 0, 1);
      for (final typed in ['see [', 'see [[', 'see [[Other']) {
        await tester.macEditingValue(typed);
      }
      await tester.pump();
      return r;
    }

    testWidgets(
      'typing [[ in an item row opens the popover under that row caret line and accepting inserts the wikilink in that row with the kind chip',
      (tester) async {
        final r = await openWithPopover(tester);

        expect(r.popover, findsOneWidget);
        expect(r.segment(0).focusedRow, 1);
        final editable = _wi167Editable(tester, 0, 1);
        final caret = RenderEditableLineBoxes(
          editable,
        ).caretRect('see [[Other'.length);
        final caretBottom = editable.localToGlobal(caret.bottomLeft);
        expect(
          tester.getTopLeft(r.popover).dy,
          moreOrLessEquals(caretBottom.dy + 6, epsilon: 0.5),
        );
        // The popover's x is the row's caret x when the overlay last
        // rebuilt. WikilinkAutocomplete rebuilds it in the build phase, before
        // the field lays out the newest keystroke, so it trails the caret by
        // that keystroke (unchanged behaviour, not this WI). It sits on this
        // row's text between the `[[` and the caret.
        final triggerX = editable
            .localToGlobal(
              RenderEditableLineBoxes(
                editable,
              ).caretRect('see '.length).bottomLeft,
            )
            .dx;
        expect(
          tester.getTopLeft(r.popover).dx,
          inInclusiveRange(triggerX - 0.5, caretBottom.dx + 0.5),
        );

        await r.pressKey(LogicalKeyboardKey.enter);

        expect(r.popover, findsNothing);
        expect(_wi167Texts(tester, 0), [
          'Intro line',
          'see [[Other note]]',
          'Outro line\n',
        ]);
        expect(
          r.segmentText(0),
          'Intro line\n- see [[Other note]]\nOutro line\n',
        );
        expect(r.kindChip, findsOneWidget);
        await r.waitForSave();
        expect(
          r.updates.last.stdinBody,
          'Intro line\n- see [[Other note]]\nOutro line\n',
        );
      },
    );

    testWidgets(
      'removing the row whose controller the kind chip targets clears the chip',
      (tester) async {
        final r = await openWithPopover(tester);
        await r.pressKey(LogicalKeyboardKey.enter);
        expect(r.kindChip, findsOneWidget);

        // Focus moves to another row: the chip stays.
        await _wi167FocusRow(tester, 0, 0, local: 2);
        expect(r.kindChip, findsOneWidget);

        r.segment(0).replaceText('Intro line\nOutro line\n');
        await pumpFrames(tester);

        expect(r.segment(0).rowCount, 1);
        expect(r.kindChip, findsNothing);
        await r.waitForSave();
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC15: launch focus, hint, empty click area
  // -------------------------------------------------------------------------
  group('launch focus, hint and empty area (AC15)', () {
    testWidgets(
      'launch focuses the row holding the end of the first text segment with the caret at the end',
      (tester) async {
        const person = 'Morning pages\n- first item\n- last item\n';
        final db = FakeVaultDb.v5()
          ..seedNote(
            id: 'daily-2026-10-03',
            title: '2026-10-03',
            content: person,
            role: 'daily',
            version: 4,
          );
        final r = TodayRobot(tester);
        await r.launch(
          db: db,
          cli: FakeMemexCli()..onUpdateWrites(db),
          clock: FakeClock(DateTime(2026, 10, 3, 9)),
        );

        expect(r.bodyText, person);
        expect(_wi167Texts(tester, 0), [
          'Morning pages',
          'first item',
          'last item',
          '',
        ]);
        expect(r.bodySegment.focusedRow, 3);
        expect(
          r.bodySelection,
          const TextSelection.collapsed(offset: person.length),
        );
        // A text field has focus (not a node above the rows).
        final focused = FocusManager.instance.primaryFocus!.context!;
        expect(
          find.descendant(
            of: _wi167Row(0, 3),
            matching: find.byWidget(focused.widget),
          ),
          findsOneWidget,
        );
        expect(tester.testTextInput.hasAnyClients, isTrue);
      },
    );

    testWidgets(
      'the hint shows in the only text segment only while it is empty',
      (tester) async {
        final body = await _wi167Pump(tester, '');
        expect(_wi167RowKeys(0), 1);
        expect(
          find.descendant(of: _wi167Row(0, 0), matching: find.text(_wi167Hint)),
          findsOneWidget,
        );

        await body.serverWrite('a\n- b');
        expect(find.text(_wi167Hint), findsNothing);
        expect(_wi167RowKeys(0), 2);

        await body.serverWrite('\n$_wi167Token\n');
        expect(find.text(_wi167Hint), findsNothing);
      },
    );

    testWidgets(
      'a click in the empty area below the last row puts the caret at the segment end in the last row',
      (tester) async {
        await _wi167Pump(tester, 'a\n- b');
        final segment = _wi167SegmentRect(tester, 0);
        // 12 lines when it is the only text segment (as built).
        expect(segment.height, moreOrLessEquals(12 * _wi167Line, epsilon: 1));
        final last = _wi167FieldRect(tester, 0, 1);
        expect(segment.bottom, greaterThan(last.bottom + 100));

        await tester.tapAt(
          Offset(segment.left + 200, segment.bottom - 20),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();

        final handle = segmentEditingAt(tester, 0);
        expect(handle.focusedRow, 1);
        expect(handle.selection, const TextSelection.collapsed(offset: 5));
      },
      variant: macOnly,
    );

    testWidgets(
      'the last of several text segments keeps a four line empty area and the others none',
      (tester) async {
        await _wi167Pump(tester, '- a\n$_wi167Token\n- b');

        // Segment 0 is `- a\n`: a bullet row and an empty prose row, with
        // no empty area below them.
        expect(_wi167Texts(tester, 0), ['a', '']);
        final first = _wi167SegmentRect(tester, 0);
        expect(
          first.height,
          moreOrLessEquals(
            _wi167FieldRect(tester, 0, 1).bottom -
                _wi167FieldRect(tester, 0, 0).top,
            epsilon: 1,
          ),
        );
        final last = _wi167SegmentRect(tester, 2);
        expect(last.height, moreOrLessEquals(4 * _wi167Line, epsilon: 1));

        await tester.tapAt(
          Offset(last.left + 200, last.bottom - 10),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        expect(segmentEditingAt(tester, 2).focusedRow, 0);
        expect(
          segmentEditingAt(tester, 2).selection,
          const TextSelection.collapsed(offset: 3),
        );
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC16: marker column taps
  // -------------------------------------------------------------------------
  group('marker column tap region (AC16)', () {
    testWidgets('a click on the marker column keeps focus in the row field', (
      tester,
    ) async {
      await _wi167Pump(tester, _wi167List);
      await _wi167FocusRow(tester, 0, 1);
      final node = FocusManager.instance.primaryFocus;
      expect(segmentEditingAt(tester, 0).focusedRow, 1);

      await tester.tapAt(
        tester.getCenter(_wi167Marker(0, 1)),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();

      expect(FocusManager.instance.primaryFocus, same(node));
      expect(segmentEditingAt(tester, 0).focusedRow, 1);

      // Control: a click outside every tap region does unfocus the row.
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('wi167-outside'))),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(segmentEditingAt(tester, 0).focusedRow, isNull);
    }, variant: macOnly);
  });

  // -------------------------------------------------------------------------
  // AC17: composition points
  // -------------------------------------------------------------------------
  group('composition points (AC17)', () {
    testWidgets(
      'the segment rows are wrapped in the keyboard pointer and selection ops pass-throughs',
      (tester) async {
        await _wi167Pump(tester, '- a\n- b\n$_wi167Token\nplain\n- c');

        for (final (s, rows) in [(0, 2), (2, 2)]) {
          for (final type in [
            SegmentKeyboard,
            SegmentPointerLayer,
            SegmentSelectionOps,
          ]) {
            final wrappers = find.descendant(
              of: find.byKey(textSegmentKey(s)),
              matching: find.byType(type),
            );
            expect(wrappers, findsOneWidget, reason: '$type in segment $s');
            for (var r = 0; r < rows; r++) {
              expect(
                find.descendant(of: wrappers, matching: _wi167Row(s, r)),
                findsOneWidget,
                reason: '$type wraps row $s-$r',
              );
            }
          }
        }
        // The card is outside every segment's wrappers.
        expect(
          find.ancestor(
            of: find.byKey(const Key('excerpt-card-1')),
            matching: find.byType(SegmentKeyboard),
          ),
          findsNothing,
        );
      },
    );

    testWidgets(
      'the host records each applied SegmentEdit once in the segment undo recorder',
      (tester) async {
        final recorders = _wi167Recorders();
        await _wi167Pump(tester, _wi167List);
        expect(_wi167RecordCount(recorders), 0);

        await _wi167FocusRow(tester, 0, 2);
        await tester.macEditingValue('bx');

        final typed = [for (final r in recorders) ...r.records];
        expect(typed, hasLength(1));
        expect(typed.single.before, _wi167List);
        expect(
          typed.single.edit,
          const SegmentEdit(
            start: 12,
            end: 12,
            replacement: 'x',
            selection: SegmentSelection.collapsed(13),
          ),
        );

        const replaced = 'para\n- a\n- bx\n- c\n\nend';
        segmentEditingAt(tester, 0).replaceText(replaced);
        await tester.pump();

        final all = [for (final r in recorders) ...r.records];
        expect(all, hasLength(2));
        expect(all.last.before, 'para\n- a\n- bx\n\nend');
        expect(all.last.edit.apply(all.last.before), replaced);
      },
    );

    testWidgets(
      'applyEdit applies a task toggle as one reported and recorded edit and re-derives the rows',
      (tester) async {
        final recorders = _wi167Recorders();
        const text = 'intro\n- [ ] milk\nend';
        final body = await _wi167Pump(tester, text);
        expect(_wi167Ctrl(tester, 0, 1).taskDone, isFalse);
        final ctrl = _wi167Ctrl(tester, 0, 1);

        final toggle = toggleTask(
          text,
          splitRows(text, atSegmentStart: true)[1],
        )!;
        _wi167View(tester, 0).applyEdit(toggle);

        expect(body.changes, ['intro\n- [x] milk\nend']);
        await tester.pump();
        await tester.pump();

        expect(body.changes, hasLength(1));
        expect(segmentEditingAt(tester, 0).text, 'intro\n- [x] milk\nend');
        expect(_wi167Texts(tester, 0), ['intro', 'milk', 'end']);
        expect(_wi167Ctrl(tester, 0, 1), same(ctrl));
        expect(_wi167Ctrl(tester, 0, 1).taskDone, isTrue);
        expect(_wi167MarkerText(tester, 0, 1), '- [x] ');
        final records = [for (final r in recorders) ...r.records];
        expect(records, hasLength(1));
        expect(records.single.before, text);
        expect(records.single.edit, toggle);
      },
    );
  });
}
