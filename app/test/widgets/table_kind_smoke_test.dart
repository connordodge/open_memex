// WI #202 (Tables 1, ruling D9): the new table line and row kinds reach every
// switch on main. Until T3/T5/T6/T7 replace them, the fallback arms behave
// exactly like plain lines and prose rows:
// - an editor segment and an excerpt card holding a table pump without an
//   exception (`editor_row.dart` and `card_rows.dart` default arms) and show
//   the table text where a prose row would;
// - table lines get plain lines' inline styles and code pills
//   (`live_preview_controller.dart`, `live_preview_decorations.dart`);
// - a link on a table line is still found by `LinkRegion`
//   (`link_region.dart`).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/markdown_lines.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/widgets/editor/card_rows.dart';
import 'package:open_memex_app/src/widgets/editor/editor_row.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/link_region.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_decorations.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';

import '../support/editor_scope.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/segment_editing_finder.dart';

/// A table with a wikilink, an inline code span, bold text and a URL link in
/// its cells.
const _wi202Table =
    '| a | [[Known]] |\n|---|:-:|\n| `x` | **b** |\n| [docs](https://x.y) | 2 |';

/// [_wi202Table] with its delimiter broken (same length): plain lines only.
final _wi202Plain = _wi202Table.replaceFirst('|---|', '|-x-|');

/// The note titled `Known`.
const _wi202KnownId = 'topic-known';

/// Whether [text] holds every table line kind.
void _wi202ExpectTable(String text) {
  final kinds = [
    for (final l in classifyLines(text, atSegmentStart: true)) l.kind,
  ];
  expect(
    kinds,
    containsAll(const [
      MdLineKind.tableHeader,
      MdLineKind.tableDelimiter,
      MdLineKind.tableBody,
    ]),
    reason: 'the fixture is a table',
  );
}

/// The style of each code unit of [span]'s text (the innermost span's).
List<TextStyle?> _wi202Styles(InlineSpan span) {
  final out = <TextStyle?>[];
  void walk(InlineSpan s, TextStyle? inherited) {
    final style = s.style ?? inherited;
    if (s is TextSpan) {
      final text = s.text;
      if (text != null) out.addAll(List.filled(text.length, style));
      for (final child in s.children ?? const <InlineSpan>[]) {
        walk(child, style);
      }
    }
  }

  walk(span, null);
  return out;
}

/// A [LineBoxSource] over [text] in fixed 8 px columns, one 20 px line per
/// source line.
class _Wi202MonoBoxes implements LineBoxSource {
  _Wi202MonoBoxes(String text) {
    var top = 0.0;
    var start = 0;
    for (final line in text.split('\n')) {
      _lines.add(
        LineBox(
          range: TextRange(start: start, end: start + line.length),
          top: top,
          bottom: top + 20,
        ),
      );
      top += 20;
      start += line.length + 1;
    }
  }

  final List<LineBox> _lines = [];

  double _x(LineBox line, int offset) => (offset - line.range.start) * 8.0;

  @override
  RenderBox get box => throw UnimplementedError('no render box');

  @override
  List<LineBox> get lines => List.unmodifiable(_lines);

  @override
  List<Rect> boxesFor(TextRange range) => [
    for (final l in _lines)
      if (range.start < l.range.end && range.end > l.range.start)
        Rect.fromLTRB(
          _x(l, range.start < l.range.start ? l.range.start : range.start),
          l.top,
          _x(l, range.end > l.range.end ? l.range.end : range.end),
          l.bottom,
        ),
  ];

  @override
  Rect caretRect(int offset) {
    final l = lineHolding(_lines, offset);
    return Rect.fromLTRB(_x(l, offset), l.top, _x(l, offset) + 1, l.bottom);
  }

  @override
  int offsetAt(Offset point) => throw UnimplementedError();
}

Note _wi202Note(String content) => Note(
  id: 'topic-202',
  title: 'Tables',
  contentMd: content,
  frontmatter: '{"role":"topic"}',
  version: 3,
  createdAt: 0,
  updatedAt: 0,
  tags: const [],
);

Finder _wi202Row(int s, int r) => find.byKey(Key('editor-row-$s-$r'));

/// The row's field, also while it is offstage (#204: a rendered table row
/// keeps its field mounted offstage under the grid).
Finder _wi202Field(int s, int r) => find.descendant(
  of: find.byKey(Key('editor-row-$s-$r'), skipOffstage: false),
  matching: find.byType(EditableText, skipOffstage: false),
  skipOffstage: false,
);

LivePreviewController _wi202Ctrl(WidgetTester tester, int s, int r) =>
    tester.widget<EditableText>(_wi202Field(s, r)).controller
        as LivePreviewController;

/// The global left of row [s]-[r]'s field.
double _wi202FieldLeft(WidgetTester tester, int s, int r) =>
    tester.getTopLeft(_wi202Field(s, r)).dx;

void main() {
  holdFontFetches();

  group('table row kind fallback arms (D9)', () {
    test('a table row has no marker column and no item geometry', () {
      expect(markerColumnKind(RowKind.table), isNull);
      final rows = splitRows('- a\n$_wi202Table', atSegmentStart: true);
      expect([for (final r in rows) r.kind], [RowKind.bullet, RowKind.table]);
      final geometries = rowGeometries(rows);
      expect(geometries[0], isNotNull);
      expect(geometries[1], isNull);
    });

    test('table lines get the same inline styles as plain lines', () {
      _wi202ExpectTable(_wi202Table);
      expect(_wi202Plain.length, _wi202Table.length);
      // #206: a revealed table styles its pipes and header (table_reveal_style_test).
      for (final forceHidden in [true]) {
        final table = _wi202Styles(
          buildLivePreviewSpan(
            _wi202Table,
            style: const TextStyle(fontSize: 13.5),
            forceHidden: forceHidden,
            selection: const TextSelection.collapsed(offset: 0),
          ),
        );
        final plain = _wi202Styles(
          buildLivePreviewSpan(
            _wi202Plain,
            style: const TextStyle(fontSize: 13.5),
            forceHidden: forceHidden,
            selection: const TextSelection.collapsed(offset: 0),
          ),
        );
        expect(table, hasLength(_wi202Table.length));
        // The bold cell is styled at all (a dropped arm leaves it plain).
        final bold = _wi202Table.indexOf('**b**') + 2;
        expect(table[bold]?.fontWeight, plain[bold]?.fontWeight);
        expect(table[bold], isNot(table[0]));
        for (var i = 0; i < table.length; i++) {
          expect(table[i], plain[i], reason: 'unit $i hidden $forceHidden');
        }
      }
    });

    test('table lines get the same code pills as plain lines', () {
      _wi202ExpectTable(_wi202Table);
      List<(DecorationKind, Rect)> of(String text) => [
        for (final d in layoutDecorations(
          text: text,
          boxes: _Wi202MonoBoxes(text),
          columnLeft: 0,
          columnRight: 600,
          // #206: a table's pills are painted only while it is revealed.
          reveal: const TextSelection.collapsed(offset: 0),
        ))
          (d.kind, d.rect),
      ];
      final table = of(_wi202Table);
      expect(
        table.where((d) => d.$1 == DecorationKind.codePill),
        hasLength(1),
        reason: 'the code span in a cell gets its pill',
      );
      expect(table, of(_wi202Plain));
    });

    testWidgets(
      'an editor segment holding a table pumps and shows the table as a prose row would',
      (tester) async {
        const content = 'Intro line\n$_wi202Table\nOutro line\n';
        final changes = <String>[];
        await pumpEditorScoped(
          tester,
          MaterialApp(
            theme: buildOmTheme(),
            home: Scaffold(
              body: SegmentedBody(
                note: _wi202Note(content),
                content: content,
                savedVersion: 3,
                onContentChanged: changes.add,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);

        final handle = segmentEditingAt(tester, 0);
        expect(handle.text, content);
        expect(handle.rowCount, 3);
        for (var r = 0; r < 3; r++) {
          expect(_wi202Row(0, r), findsOneWidget, reason: 'editor-row-0-$r');
        }
        expect(find.byKey(const Key('editor-row-marker-0-1')), findsNothing);
        expect(_wi202Ctrl(tester, 0, 1).text, _wi202Table);
        expect(_wi202Ctrl(tester, 0, 1).itemText, isFalse);
        expect(_wi202Ctrl(tester, 0, 1).codeRow, isFalse);
        expect(
          _wi202FieldLeft(tester, 0, 1),
          moreOrLessEquals(_wi202FieldLeft(tester, 0, 0), epsilon: 0.01),
          reason: 'at the text column, as a prose row',
        );
        expect(changes, isEmpty, reason: 'pumping reports no content');

        // A caret in the table reveals and edits it like a prose row.
        final end = content.indexOf(' 2 |') + 4;
        // The field is offstage under the grid while rendered (#204), so the
        // all-fields-onstage focusSegmentAt cannot be used.
        await tester.showKeyboard(_wi202Field(0, 1));
        await tester.pump();
        handle.select(TextSelection.collapsed(offset: end));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(handle.focusedRow, 1);
        await tester.enterText(_wi202Field(0, 1), '${_wi202Table}z');
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(
          segmentEditingAt(tester, 0).text,
          'Intro line\n${_wi202Table}z\nOutro line\n',
        );
        expect(segmentEditingAt(tester, 0).rowCount, 3);
        expect(changes.last, 'Intro line\n${_wi202Table}z\nOutro line\n');
      },
      variant: macOnly,
    );

    testWidgets(
      'an excerpt card holding a table pumps and shows the table text as a prose row would',
      (tester) async {
        const text = 'Intro\n$_wi202Table';
        await tester.pumpWidget(
          MaterialApp(
            theme: buildOmTheme(),
            home: const Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 700, child: CardRows(text: text)),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('card-row-0')), findsOneWidget);
        expect(find.byKey(const Key('card-row-1')), findsOneWidget);
        expect(find.byKey(const Key('card-row-2')), findsNothing);
        expect(find.byKey(const Key('card-row-marker-1')), findsNothing);
        RichText rich(int r) => tester.widget<RichText>(
          find.descendant(
            of: find.byKey(Key('card-row-text-$r')),
            matching: find.byType(RichText),
          ),
        );
        expect(rich(1).text.toPlainText(), _wi202Table);
        expect(
          tester.getTopLeft(find.byKey(const Key('card-row-text-1'))).dx,
          moreOrLessEquals(
            tester.getTopLeft(find.byKey(const Key('card-row-text-0'))).dx,
            epsilon: 0.01,
          ),
          reason: 'at the inner left, as a prose row',
        );
        // Inline styles as on plain lines, every marker hidden.
        expect(
          _wi202Styles(rich(1).text),
          _wi202Styles(
            buildLivePreviewSpan(
              _wi202Plain,
              style: rich(1).text.style,
              forceHidden: true,
              atSegmentStart: false,
            ),
          ),
        );
      },
    );

    testWidgets('a wikilink inside a table line is still found by LinkRegion', (
      tester,
    ) async {
      _wi202ExpectTable(_wi202Table);
      final controller = LivePreviewController(text: _wi202Table);
      addTearDown(controller.dispose);
      final opener = RecordingUrlOpener();
      final fieldKey = GlobalKey();
      LineBoxSource? lookup() {
        final editable = findRenderEditable(
          fieldKey.currentContext?.findRenderObject(),
        );
        return editable == null ? null : RenderEditableLineBoxes(editable);
      }

      await pumpEditorScoped(
        tester,
        MaterialApp(
          home: Material(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 700,
                child: LinkRegion(
                  controller: controller,
                  boxes: lookup,
                  child: TextField(
                    key: fieldKey,
                    controller: controller,
                    maxLines: null,
                  ),
                ),
              ),
            ),
          ),
        ),
        opener: opener,
        titles: [NoteTitle(id: _wi202KnownId, title: 'Known', updatedAt: 1)],
      );
      await tester.pump();
      await tester.pump();

      /// A global point in the middle of [needle] in the field.
      Offset pointOn(String needle) {
        final boxes = lookup()!;
        final start = _wi202Table.indexOf(needle);
        final a = boxes.caretRect(start);
        final z = boxes.caretRect(start + needle.length);
        return boxes.box.localToGlobal(
          Offset((a.left + z.left) / 2, a.center.dy),
        );
      }

      final link = _wi202Table.indexOf('[[Known]]');
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.metaLeft,
        platform: 'macos',
      );
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: pointOn('Known'));
      await tester.pump();
      await mouse.moveTo(pointOn('Known'));
      await tester.pump();
      try {
        expect(
          controller.cmdHover,
          TextRange(start: link, end: link + '[[Known]]'.length),
        );
      } finally {
        await mouse.removePointer();
        await tester.pump();
        await tester.sendKeyUpEvent(
          LogicalKeyboardKey.metaLeft,
          platform: 'macos',
        );
        await tester.pump();
      }

      // A URL link in a body cell opens on Cmd+click.
      await tester.macCmdClick(pointOn('docs'));
      await tester.pump();
      expect(opener.opened, ['https://x.y']);
    }, variant: macOnly);
  });
}
