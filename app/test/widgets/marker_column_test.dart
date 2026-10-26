// WI #168 (C1b, Spec #157 R2, R4, R11, R12, R22, R24; TD9-TD11; D8, D11,
// D12; TS2, TS3): an item row's marker column paints its marker, reveals
// the marker source while the caret or selection touches the line, and a
// task's column is a checkbox.
// - Pure geometry (TD10): bullet dots, the task circle and the check.
// - Painted markers (pixels): filled dot at level 1, hollow ring at level
//   2+, right-aligned numbers, 14 px task circle with a 1.5 px fg2 ring, done
//   tasks filled accentSoft with an accentFg check. No bullet characters.
// - Reveal: only while the segment has focus and the caret or selection
//   touches the line; source text in fg2; a task widens 4 -> 6 columns and
//   its children keep their x; a selected marker is fg1 over a full-height
//   OmColors.selection fill.
// - Display only (R22): a click on revealed marker text moves no caret.
// - Checkbox (`task-checkbox-<s>-<r>`): the whole column is the hit area;
//   a click applies toggleTask through the host as one edit, never moving
//   focus or caret; the toggled bytes are saved.
// - Read-only mode (B4's cards): never reveals, never toggles.
// Design pack design/156-live-preview/packs/168.md wins over WI numbers.
//
// Note for the implementer: tests run in the 13.5 px-advance test font, so
// a 2-digit number is wider than its column. Place each painted number at
// A2's `numberedMarkerLeft` from its measured width (TD10); a right-aligned
// Text in a box clamps an overflowing line to the box's left edge.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/row_geometry.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/editor_row.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/marker_column.dart';
import 'package:open_memex_app/src/widgets/editor/segment_undo.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/segment_editing_finder.dart';

// ------------------------------------------------------------------ harness

/// A card token: text segment 0, card 1, text segment 2.
const _wi168Token = '![[2026-09-05#^b7k2m9..^c3d4e5]]';

/// One mono column (A2).
const double _wi168Col = 8.1;

/// An item line (R13).
const double _wi168Line = 22.95;

const _wi168BoundaryKey = Key('wi168-boundary');

/// An opaque surface behind every pixel probe (the editor's panel colour),
/// so captured pixels are not premultiplied over transparency.
const _wi168Surface = OmColors.surface2;
const _wi168OutsideKey = Key('wi168-outside');

Note _wi168Note(String content) => Note(
  id: 'topic-168',
  title: 'Markers',
  contentMd: content,
  frontmatter: '{"role":"topic"}',
  version: 3,
  createdAt: 0,
  updatedAt: 0,
  tags: const [],
);

/// Pumps a [SegmentedBody] of [text] inside a repaint boundary (for pixel
/// probes) above an empty box outside every tap region. Returns the joined
/// bodies its `onContentChanged` reported (fed back as its content, as
/// `EditorController` does).
Future<List<String>> _wi168Pump(WidgetTester tester, String text) async {
  final content = ValueNotifier(text);
  final changes = <String>[];
  addTearDown(content.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: RepaintBoundary(
                  key: _wi168BoundaryKey,
                  child: ColoredBox(
                    color: _wi168Surface,
                    child: ValueListenableBuilder<String>(
                      valueListenable: content,
                      builder: (context, value, _) => SegmentedBody(
                        note: _wi168Note(value),
                        content: value,
                        savedVersion: 3,
                        onContentChanged: (joined) {
                          changes.add(joined);
                          content.value = joined;
                        },
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(
                key: _wi168OutsideKey,
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
  return changes;
}

Finder _wi168Row(int s, int r) => find.byKey(Key('editor-row-$s-$r'));

Finder _wi168Marker(int s, int r) => find.byKey(Key('editor-row-marker-$s-$r'));

Finder _wi168Checkbox(int s, int r) => find.byKey(Key('task-checkbox-$s-$r'));

TextEditingController _wi168Ctrl(WidgetTester tester, int s, int r) => tester
    .widget<EditableText>(
      find.descendant(of: _wi168Row(s, r), matching: find.byType(EditableText)),
    )
    .controller;

/// The global rect of row [s]-[r]'s field (its RenderEditable).
Rect _wi168FieldRect(WidgetTester tester, int s, int r) {
  RenderEditable? found;
  void visit(RenderObject node) {
    if (found != null) return;
    if (node is RenderEditable) {
      found = node;
    } else {
      node.visitChildren(visit);
    }
  }

  visit(tester.renderObject(_wi168Row(s, r)));
  if (found == null) throw TestFailure('No RenderEditable in row $s-$r');
  return found!.localToGlobal(Offset.zero) & found!.size;
}

/// Focus row [s]-[r]'s field and put its caret at local [local] (default:
/// the row text's end).
Future<void> _wi168FocusRow(
  WidgetTester tester,
  int s,
  int r, {
  int? local,
}) async {
  await tester.showKeyboard(_wi168Row(s, r));
  await tester.pump();
  final ctrl = _wi168Ctrl(tester, s, r);
  ctrl.selection = TextSelection.collapsed(offset: local ?? ctrl.text.length);
  await tester.pump();
}

/// The segment-offset rows of [text] (A1).
List<RowSpec> _wi168Specs(String text) => splitRows(text, atSegmentStart: true);

/// Every visible text run under [column]: spans with a non-transparent
/// colour, outside any zero [Opacity] and outside offstage subtrees.
List<(String, Color?)> _wi168Runs(WidgetTester tester, Finder column) {
  final out = <(String, Color?)>[];
  void visit(InlineSpan span, Color? inherited) {
    final color = span.style?.color ?? inherited;
    if (span is TextSpan) {
      final text = span.text ?? '';
      if (text.isNotEmpty && (color == null || color.a > 0)) {
        out.add((text, color));
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child, color);
      }
    }
  }

  final texts = find.descendant(of: column, matching: find.byType(RichText));
  for (final element in texts.evaluate()) {
    final hidden = find
        .ancestor(
          of: find.byElementPredicate((e) => identical(e, element)),
          matching: find.byWidgetPredicate(
            (w) => w is Opacity && w.opacity == 0,
          ),
        )
        .evaluate()
        .isNotEmpty;
    if (hidden) continue;
    visit((element.widget as RichText).text, null);
  }
  return out;
}

/// The visible text of marker column [s]-[r] ('' when it shows none).
String _wi168Shown(WidgetTester tester, int s, int r) => [
  for (final (text, _) in _wi168Runs(tester, _wi168Marker(s, r))) text,
].join();

/// The colours of the visible non-blank glyph runs of marker column [s]-[r].
Set<Color?> _wi168ShownColors(WidgetTester tester, int s, int r) => {
  for (final (text, color) in _wi168Runs(tester, _wi168Marker(s, r)))
    if (text.trim().isNotEmpty) color,
};

/// Every string the segmented body renders as text: RichText spans and
/// field contents.
List<String> _wi168AllRenderedText(WidgetTester tester) => [
  for (final w in tester.widgetList<RichText>(find.byType(RichText)))
    w.text.toPlainText(),
  for (final w in tester.widgetList<EditableText>(find.byType(EditableText)))
    w.controller.text,
];

/// A segment undo recorder that remembers what the host told it.
class _Wi168Recorder extends SegmentUndoRecorder {
  final records = <({String before, SegmentEdit edit})>[];

  @override
  void record(SegmentEdit edit, {required String before}) =>
      records.add((before: before, edit: edit));

  @override
  void reset() {}
}

/// Every recorder the host makes from now on lands in the returned list.
List<_Wi168Recorder> _wi168Recorders() {
  final made = <_Wi168Recorder>[];
  final previous = segmentUndoRecorderFactory;
  segmentUndoRecorderFactory = () {
    final r = _Wi168Recorder();
    made.add(r);
    return r;
  };
  addTearDown(() => segmentUndoRecorderFactory = previous);
  return made;
}

// ------------------------------------------------------------------- pixels

/// Pixels of a region of the repaint boundary, captured at [ratio] image
/// pixels per logical pixel.
class _Wi168Pixels {
  _Wi168Pixels(this._bytes, this.width, this.height, this.rect, this.ratio);

  final ByteData _bytes;
  final int width;
  final int height;

  /// The captured region in global coordinates.
  final Rect rect;
  final double ratio;

  /// The pixel at global [point].
  Color at(Offset point) {
    final x = ((point.dx - rect.left) * ratio).floor();
    final y = ((point.dy - rect.top) * ratio).floor();
    expect(x, inInclusiveRange(0, width - 1), reason: 'x of $point');
    expect(y, inInclusiveRange(0, height - 1), reason: 'y of $point');
    return atPixel(x, y);
  }

  Color atPixel(int x, int y) {
    final i = (y * width + x) * 4;
    return Color.fromARGB(
      _bytes.getUint8(i + 3),
      _bytes.getUint8(i),
      _bytes.getUint8(i + 1),
      _bytes.getUint8(i + 2),
    );
  }

  /// The global x just right of the rightmost pixel near [ink] on the
  /// image row through global [y], or null when there is none.
  double? rightEdgeOf(Color ink, double y) {
    final row = ((y - rect.top) * ratio).floor();
    for (var x = width - 1; x >= 0; x--) {
      if (_wi168Near(atPixel(x, row), ink, 12)) {
        return rect.left + (x + 1) / ratio;
      }
    }
    return null;
  }
}

/// Captures the boundary's pixels inside global [region].
Future<_Wi168Pixels> _wi168Capture(
  WidgetTester tester,
  Rect region, {
  double ratio = 8,
}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_wi168BoundaryKey),
  );
  final origin = boundary.localToGlobal(Offset.zero);
  final bounds = (Offset.zero & boundary.size);
  final local = region.shift(-origin).intersect(bounds);
  final layer = boundary.debugLayer! as OffsetLayer;
  final image = (await tester.runAsync(
    () => layer.toImage(local, pixelRatio: ratio),
  ))!;
  final bytes = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final pixels = _Wi168Pixels(
    bytes,
    image.width,
    image.height,
    local.shift(origin),
    ratio,
  );
  image.dispose();
  return pixels;
}

int _wi168Channel(double c) => (c * 255).round();

List<int> _wi168Channels(Color c) => [
  _wi168Channel(c.r),
  _wi168Channel(c.g),
  _wi168Channel(c.b),
  _wi168Channel(c.a),
];

/// Whether every RGBA channel of [a] is within [tolerance] of [b]'s.
bool _wi168Near(Color a, Color b, int tolerance) {
  final x = _wi168Channels(a);
  final y = _wi168Channels(b);
  for (var i = 0; i < 4; i++) {
    if ((x[i] - y[i]).abs() > tolerance) return false;
  }
  return true;
}

/// Matches a [Color] whose RGBA channels are each within 6 of [expected].
class _Wi168Near extends Matcher {
  const _Wi168Near(this.expected);

  static const tolerance = 6;

  final Color expected;

  static String _hex(Color c) =>
      '0x${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

  @override
  bool matches(Object? item, Map<dynamic, dynamic> matchState) =>
      item is Color && _wi168Near(item, expected, tolerance);

  @override
  Description describe(Description description) =>
      description.add('a colour near ${_hex(expected)} (±$tolerance)');

  @override
  Description describeMismatch(
    Object? item,
    Description mismatchDescription,
    Map<dynamic, dynamic> matchState,
    bool verbose,
  ) => item is Color
      ? mismatchDescription.add('was ${_hex(item)}')
      : mismatchDescription.add('was not a Color');
}

Matcher _wi168IsColor(Color c) => _Wi168Near(c);

const _wi168Directions = [
  Offset(-1, 0),
  Offset(1, 0),
  Offset(0, -1),
  Offset(0, 1),
];

/// The background of [px] in a column region nothing paints: the column's
/// top-right corner area.
Color _wi168Background(_Wi168Pixels px, Rect column) =>
    px.at(Offset(column.right - 2, column.top + 1.5));

/// Expects a level-1 bullet's filled fg2 dot (pack #168: diameter 3.5 at
/// column left + 4.05, line top + 11.47) in [column].
void _wi168ExpectFilledDot(_Wi168Pixels px, Rect column, {String why = ''}) {
  final c = column.topLeft + const Offset(4.05, 11.475);
  final bg = _wi168Background(px, column);
  expect(px.at(c), _wi168IsColor(OmColors.fg2), reason: '$why dot centre');
  for (final d in _wi168Directions) {
    expect(
      px.at(c + d * 1.0),
      _wi168IsColor(OmColors.fg2),
      reason: '$why inside the dot at $d',
    );
    expect(
      px.at(c + d * 2.7),
      _wi168IsColor(bg),
      reason: '$why outside the dot at $d',
    );
  }
}

/// Expects a level-2+ bullet's hollow fg2 ring (outer diameter 4, stroke 1)
/// with an unpainted centre in [column].
void _wi168ExpectHollowDot(_Wi168Pixels px, Rect column, {String why = ''}) {
  final c = column.topLeft + const Offset(4.05, 11.475);
  final bg = _wi168Background(px, column);
  expect(px.at(c), _wi168IsColor(bg), reason: '$why ring centre is unpainted');
  for (final d in _wi168Directions) {
    expect(
      px.at(c + d * 1.5),
      _wi168IsColor(OmColors.fg2),
      reason: '$why on the ring at $d',
    );
    expect(
      px.at(c + d * 2.7),
      _wi168IsColor(bg),
      reason: '$why outside the ring at $d',
    );
  }
}

/// The centre of the 14 px task circle of [column] (pack #168: circle at
/// column left, top + 4.47).
Offset _wi168CircleCentre(Rect column) =>
    column.topLeft + const Offset(7, 4.475 + 7);

/// Expects an open task's 14 px circle: a 1.5 px fg2 ring inside the
/// circle, nothing painted inside or outside it.
void _wi168ExpectOpenCircle(_Wi168Pixels px, Rect column, {String why = ''}) {
  final c = _wi168CircleCentre(column);
  final bg = _wi168Background(px, column);
  expect(px.at(c), _wi168IsColor(bg), reason: '$why open circle has no fill');
  for (final d in _wi168Directions) {
    for (final r in [5.75, 6.25, 6.75]) {
      expect(
        px.at(c + d * r),
        _wi168IsColor(OmColors.fg2),
        reason: '$why ring at radius $r towards $d',
      );
    }
    expect(
      px.at(c + d * 4.9),
      _wi168IsColor(bg),
      reason: '$why inside the 1.5 px ring towards $d',
    );
    if (d.dx >= 0) {
      expect(
        px.at(c + d * 7.7),
        _wi168IsColor(bg),
        reason: '$why outside the 14 px circle towards $d',
      );
    }
  }
}

/// Expects a done task's circle filled accentSoft with an accentFg check
/// (pack #168: the Lucide check in a 9 px box at circle + 2.5).
void _wi168ExpectDoneCircle(_Wi168Pixels px, Rect column, {String why = ''}) {
  final c = _wi168CircleCentre(column);
  final circle = column.topLeft + const Offset(0, 4.475);
  final bg = _wi168Background(px, column);
  for (final p in [
    c + const Offset(0, -4.5),
    c + const Offset(-3.5, 3.5),
    c + const Offset(3.5, 3.5),
    c + const Offset(-6.25, 0),
    c + const Offset(6.25, 0),
  ]) {
    expect(
      px.at(p),
      _wi168IsColor(OmColors.accentSoft),
      reason: '$why accentSoft fill at ${p - column.topLeft}',
    );
  }
  for (final p in [
    const Offset(7.9375, 6.8125),
    const Offset(4.9375, 7.9375),
    const Offset(5.875, 8.875),
  ]) {
    expect(
      px.at(circle + p),
      _wi168IsColor(OmColors.accentFg),
      reason: '$why accentFg check at circle $p',
    );
  }
  expect(
    px.at(c + const Offset(7.7, 0)),
    _wi168IsColor(bg),
    reason: '$why outside the 14 px circle',
  );
}

// --------------------------------------------------------- read-only hosts

/// A [SegmentView] of [text] whose field builder puts a read-only
/// [MarkerColumn] (Key `wi168-read-only`) for [marker] before every row
/// field: inside an editor row of a real segment, where the row's own
/// column reveals and toggles.
Future<
  ({
    TextEditingController ctrl,
    FocusNode focus,
    ValueNotifier<bool> gate,
    List<String> changes,
  })
>
_wi168ReadOnlyHost(WidgetTester tester, String text, String marker) async {
  final ctrl = TextEditingController(text: text);
  final focus = FocusNode(debugLabel: 'wi168-segment');
  final gate = ValueNotifier(false);
  final changes = <String>[];
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: _wi168BoundaryKey,
              child: Container(
                color: _wi168Surface,
                width: 600,
                child: SegmentView(
                  index: 0,
                  controller: ctrl,
                  focusNode: focus,
                  revealGate: gate,
                  minLines: 1,
                  hintText: null,
                  onChanged: () => changes.add(ctrl.text),
                  onRowRemoved: (_) {},
                  fieldBuilder: (context, row) => Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MarkerColumn(
                        key: const Key('wi168-read-only'),
                        marker: marker,
                        width: 4 * _wi168Col,
                        readOnly: true,
                      ),
                      Expanded(
                        child: TextField(
                          controller: row.controller,
                          focusNode: row.focusNode,
                          maxLines: null,
                        ),
                      ),
                    ],
                  ),
                  builder: (context, rows, boxes) => rows,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return (ctrl: ctrl, focus: focus, gate: gate, changes: changes);
}

void main() {
  holdFontFetches();

  // -------------------------------------------------------------------------
  // TD10: pure marker geometry
  // -------------------------------------------------------------------------
  group('marker geometry (TD10)', () {
    test(
      'a level 1 bullet dot is a filled disc of diameter 3.5 centred half a column in and half a line down',
      () {
        for (final level in [1]) {
          final dot = markerBulletDot(level: level);
          expect(dot.filled, isTrue);
          expect(dot.radius, moreOrLessEquals(1.75, epsilon: 0.06));
          expect(dot.strokeWidth, 0);
          expect(dot.center.dx, moreOrLessEquals(4.05, epsilon: 0.06));
          expect(dot.center.dy, moreOrLessEquals(11.475, epsilon: 0.06));
        }
      },
    );

    test(
      'a level 2 or deeper bullet dot is a hollow ring of outer diameter 4 stroked 1 px at the same centre',
      () {
        for (final level in [2, 3, 7]) {
          final dot = markerBulletDot(level: level);
          expect(dot.filled, isFalse, reason: 'level $level');
          expect(
            dot.radius,
            moreOrLessEquals(1.5, epsilon: 0.06),
            reason: 'level $level stroke centre radius',
          );
          expect(dot.strokeWidth, 1.0, reason: 'level $level');
          expect(
            dot.radius + dot.strokeWidth / 2,
            moreOrLessEquals(2.0, epsilon: 0.06),
            reason: 'level $level outer radius',
          );
          expect(dot.center.dx, moreOrLessEquals(4.05, epsilon: 0.06));
          expect(dot.center.dy, moreOrLessEquals(11.475, epsilon: 0.06));
        }
      },
    );

    test(
      'a task circle is 14 px at the column left centred on the item line with a 1.5 px ring',
      () {
        final circle = markerTaskCircle();
        expect(circle.bounds.left, 0);
        expect(circle.bounds.width, moreOrLessEquals(14, epsilon: 0.01));
        expect(circle.bounds.height, moreOrLessEquals(14, epsilon: 0.01));
        expect(
          circle.bounds.top,
          moreOrLessEquals((_wi168Line - 14) / 2, epsilon: 0.01),
        );
        expect(circle.ringWidth, 1.5);
      },
    );

    test(
      'a done task check is the Lucide check scaled into a 9 px box 2.5 px inside the circle with a 1.5 px stroke',
      () {
        final circle = markerTaskCircle().bounds;
        final check = markerTaskCheck();
        expect(check.strokeWidth, 1.5);
        final box = circle.topLeft + const Offset(2.5, 2.5);
        const lucide = [Offset(20, 6), Offset(9, 17), Offset(4, 12)];
        expect(check.points, hasLength(lucide.length));
        for (final (i, p) in lucide.indexed) {
          final want = box + p * (9 / 24);
          expect(
            check.points[i].dx,
            moreOrLessEquals(want.dx, epsilon: 0.01),
            reason: 'point $i x',
          );
          expect(
            check.points[i].dy,
            moreOrLessEquals(want.dy, epsilon: 0.01),
            reason: 'point $i y',
          );
          expect(circle.contains(check.points[i]), isTrue);
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC1: bullets
  // -------------------------------------------------------------------------
  group('painted bullets (AC1)', () {
    testWidgets(
      'a level 1 bullet paints a filled dot and level 2 and 3 bullets a hollow dot with no bullet characters in the rendered text',
      (tester) async {
        await _wi168Pump(
          tester,
          'intro\n- top\n  - child\n    - grandchild\n* star top\nend',
        );

        for (final r in [1, 2, 3, 4]) {
          expect(_wi168Shown(tester, 0, r), '', reason: 'row $r shows text');
          final column = tester.getRect(_wi168Marker(0, r));
          final px = await _wi168Capture(tester, column);
          if (r == 2 || r == 3) {
            _wi168ExpectHollowDot(px, column, why: 'row $r');
          } else {
            _wi168ExpectFilledDot(px, column, why: 'row $r');
          }
        }
        for (final text in _wi168AllRenderedText(tester)) {
          expect(text, isNot(contains('•')));
          expect(text, isNot(contains('◦')));
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC2: numbers
  // -------------------------------------------------------------------------
  group('painted numbers (AC2)', () {
    testWidgets(
      'a numbered run of 9 and 10 right aligns its painted numbers so the dots share an x',
      (tester) async {
        await _wi168Pump(tester, '9. nine\n10. ten');

        expect(_wi168Shown(tester, 0, 0).trimRight(), '9.');
        expect(_wi168Shown(tester, 0, 1).trimRight(), '10.');
        final edges = <double>[];
        for (final r in [0, 1]) {
          expect(_wi168ShownColors(tester, 0, r), {OmColors.fg2});
          final column = tester.getRect(_wi168Marker(0, r));
          expect(column.width, moreOrLessEquals(4 * _wi168Col, epsilon: 0.01));
          final px = await _wi168Capture(
            tester,
            Rect.fromLTRB(
              column.left - 48,
              column.top,
              column.right,
              column.bottom,
            ),
            ratio: 4,
          );
          final edge = px.rightEdgeOf(OmColors.fg2, column.top + 14);
          expect(edge, isNotNull, reason: 'row $r paints its number in fg2');
          expect(
            edge!,
            moreOrLessEquals(column.right - _wi168Col, epsilon: 0.5),
            reason: 'row $r number ends one column before the column end',
          );
          edges.add(edge);
        }
        expect(edges[0], moreOrLessEquals(edges[1], epsilon: 0.3));
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC3: task circles
  // -------------------------------------------------------------------------
  group('painted task circles (AC3)', () {
    testWidgets(
      'an unchecked task paints a 14 px circle with a 1.5 px fg2 ring and no fill',
      (tester) async {
        await _wi168Pump(tester, 'intro\n- [ ] open\n* [ ] star open\nend');

        for (final r in [1, 2]) {
          expect(_wi168Shown(tester, 0, r), '', reason: 'row $r shows text');
          final column = tester.getRect(_wi168Marker(0, r));
          expect(column.width, moreOrLessEquals(4 * _wi168Col, epsilon: 0.01));
          final px = await _wi168Capture(tester, column.inflate(2));
          _wi168ExpectOpenCircle(px, column, why: 'row $r');
        }
      },
    );

    testWidgets(
      'a done task with a lower or upper case x paints an accentSoft fill with an accentFg check',
      (tester) async {
        await _wi168Pump(tester, 'intro\n- [x] lower\n- [X] upper\nend');

        for (final r in [1, 2]) {
          expect(_wi168Shown(tester, 0, r), '', reason: 'row $r shows text');
          final column = tester.getRect(_wi168Marker(0, r));
          final px = await _wi168Capture(tester, column.inflate(2));
          _wi168ExpectDoneCircle(px, column, why: 'row $r');
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC4: reveal
  // -------------------------------------------------------------------------
  group('marker reveal (AC4)', () {
    const text =
        'intro\n- dash\n* star\n12. twelve\n> quoted\n- [ ] task\n- [x] done\n'
        'end';
    const markers = {
      1: '- ',
      2: '* ',
      3: '12. ',
      4: '> ',
      5: '- [ ] ',
      6: '- [x] ',
    };

    /// What item row [r] shows while it isn't revealed.
    String hidden(int r) => r == 3 ? '12.' : '';

    void expectHidden(WidgetTester tester, int r, {String why = ''}) => expect(
      _wi168Shown(tester, 0, r).trimRight(),
      hidden(r),
      reason: '$why row $r is not revealed',
    );

    testWidgets(
      'with the segment focused and the caret on an item line its column shows the marker source in fg2 and every other item column only its painted marker',
      (tester) async {
        await _wi168Pump(tester, text);

        for (final r in markers.keys) {
          await _wi168FocusRow(tester, 0, r);
          expect(segmentEditingAt(tester, 0).focusedRow, r);
          for (final k in markers.keys) {
            if (k == r) {
              expect(
                _wi168Shown(tester, 0, k),
                markers[k],
                reason: 'caret on row $r reveals it',
              );
              expect(_wi168ShownColors(tester, 0, k), {
                OmColors.fg2,
              }, reason: 'row $k revealed colour');
            } else {
              expectHidden(tester, k, why: 'caret on row $r:');
            }
          }
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'with the caret on a prose line or with focus outside the segment every item column shows its painted marker only',
      (tester) async {
        await _wi168Pump(tester, text);

        await _wi168FocusRow(tester, 0, 0, local: 2);
        for (final r in markers.keys) {
          expectHidden(tester, r, why: 'caret on prose:');
        }

        await _wi168FocusRow(tester, 0, 1);
        expect(_wi168Shown(tester, 0, 1), '- ');

        await tester.macClick(tester.getCenter(find.byKey(_wi168OutsideKey)));
        await tester.pump();
        expect(segmentEditingAt(tester, 0).focusedRow, isNull);
        for (final r in markers.keys) {
          expectHidden(tester, r, why: 'focus outside:');
        }
        final column = tester.getRect(_wi168Marker(0, 1));
        _wi168ExpectFilledDot(
          await _wi168Capture(tester, column),
          column,
          why: 'after focus left',
        );

        // The caret moves onto an item line while the segment has no focus.
        final specs = _wi168Specs(text);
        segmentEditingAt(
          tester,
          0,
        ).select(TextSelection.collapsed(offset: specs[5].textStart + 1));
        await tester.pump();
        expect(segmentEditingAt(tester, 0).focusedRow, isNull);
        for (final r in markers.keys) {
          expectHidden(tester, r, why: 'unfocused caret on row 5:');
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'a selection that touches several item lines reveals each of their markers and an unselected revealed marker stays fg2',
      (tester) async {
        await _wi168Pump(tester, text);
        final specs = _wi168Specs(text);

        await _wi168FocusRow(tester, 0, 1);
        segmentEditingAt(tester, 0).select(
          TextSelection(
            baseOffset: specs[1].textStart + 1,
            extentOffset: specs[2].textStart + 2,
          ),
        );
        await tester.pump();

        expect(_wi168Shown(tester, 0, 1), '- ');
        expect(_wi168ShownColors(tester, 0, 1), {OmColors.fg2});
        expect(_wi168Shown(tester, 0, 2), '* ');
        for (final r in [3, 4, 5, 6]) {
          expectHidden(tester, r, why: 'selection over rows 1-2:');
        }
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC5: task widening
  // -------------------------------------------------------------------------
  group('task widening (AC5)', () {
    testWidgets(
      'revealing a task widens its column from 4 to 6 columns and moves its text 2 columns right while its child marker column keeps its x',
      (tester) async {
        await _wi168Pump(tester, 'intro\n- [ ] parent\n  - child\nend');
        final t = tester.getRect(find.byKey(textSegmentKey(0))).left;

        void expectGeometry({required double taskWidth, required String why}) {
          final task = tester.getRect(_wi168Marker(0, 1));
          expect(task.left, moreOrLessEquals(t, epsilon: 0.01), reason: why);
          expect(
            task.width,
            moreOrLessEquals(taskWidth, epsilon: 0.01),
            reason: '$why task column width',
          );
          expect(
            _wi168FieldRect(tester, 0, 1).left,
            moreOrLessEquals(t + taskWidth, epsilon: 0.01),
            reason: '$why task text x',
          );
          final child = tester.getRect(_wi168Marker(0, 2));
          expect(
            child.left,
            moreOrLessEquals(t + 4 * _wi168Col, epsilon: 0.01),
            reason: '$why child marker x',
          );
          expect(
            child.width,
            moreOrLessEquals(2 * _wi168Col, epsilon: 0.01),
            reason: '$why child marker width',
          );
          expect(
            _wi168FieldRect(tester, 0, 2).left,
            moreOrLessEquals(t + 6 * _wi168Col, epsilon: 0.01),
            reason: '$why child text x',
          );
        }

        await _wi168FocusRow(tester, 0, 0);
        expectGeometry(taskWidth: 4 * _wi168Col, why: 'caret on prose:');

        await _wi168FocusRow(tester, 0, 1, local: 2);
        expect(_wi168Shown(tester, 0, 1), '- [ ] ');
        expectGeometry(taskWidth: 6 * _wi168Col, why: 'task revealed:');

        await _wi168FocusRow(tester, 0, 2);
        expect(_wi168Shown(tester, 0, 2), '- ');
        expectGeometry(taskWidth: 4 * _wi168Col, why: 'child revealed:');
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC6: selected markers
  // -------------------------------------------------------------------------
  group('selected markers (AC6)', () {
    const text = 'intro\n- a\n- bb\n- c\nend';

    /// Points of a 16.2 x 22.95 bullet column clear of the revealed `-`
    /// glyph: the corners and the right of the column at mid line.
    List<Offset> clearPoints(Rect column) => [
      column.topLeft + const Offset(0.6, 0.6),
      column.topLeft + const Offset(15.6, 0.6),
      column.topLeft + const Offset(0.6, 22.35),
      column.topLeft + const Offset(15.6, 22.35),
      column.topLeft + const Offset(15.2, 11.5),
    ];

    testWidgets(
      'a marker inside a selection that spans its line renders in fg1 over a full line height selection fill of its column',
      (tester) async {
        await _wi168Pump(tester, text);
        final specs = _wi168Specs(text);

        await _wi168FocusRow(tester, 0, 0);
        segmentEditingAt(
          tester,
          0,
        ).select(TextSelection(baseOffset: 2, extentOffset: specs[1].textEnd));
        await tester.pump();

        expect(_wi168Shown(tester, 0, 1), '- ');
        expect(_wi168ShownColors(tester, 0, 1), {OmColors.fg1});
        final selected = tester.getRect(_wi168Marker(0, 1));
        final untouched = tester.getRect(_wi168Marker(0, 3));
        expect(selected.height, moreOrLessEquals(_wi168Line, epsilon: 0.01));
        final px = await _wi168Capture(
          tester,
          selected.expandToInclude(untouched),
        );
        final bg = px.at(untouched.topLeft + const Offset(13, 1.5));
        final fill = Color.alphaBlend(OmColors.selection, bg);
        for (final p in clearPoints(selected)) {
          expect(
            px.at(p),
            _wi168IsColor(fill),
            reason: 'selection fill at ${p - selected.topLeft}',
          );
        }
        // Row 2 is outside the selection: no fill.
        final row2 = tester.getRect(_wi168Marker(0, 2));
        expect(
          px.at(row2.topLeft + const Offset(15.6, 0.6)),
          _wi168IsColor(bg),
          reason: 'row 2 is not selected',
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'a revealed marker before the selection start stays fg2 with no fill while a spanned marker after it is fg1 over the fill',
      (tester) async {
        await _wi168Pump(tester, text);
        final specs = _wi168Specs(text);

        await _wi168FocusRow(tester, 0, 2);
        segmentEditingAt(tester, 0).select(
          TextSelection(
            baseOffset: specs[2].textStart + 1,
            extentOffset: text.length,
          ),
        );
        await tester.pump();

        expect(_wi168Shown(tester, 0, 2), '- ');
        expect(_wi168ShownColors(tester, 0, 2), {OmColors.fg2});
        expect(_wi168Shown(tester, 0, 3), '- ');
        expect(_wi168ShownColors(tester, 0, 3), {OmColors.fg1});
        final untouched = tester.getRect(_wi168Marker(0, 1));
        final partial = tester.getRect(_wi168Marker(0, 2));
        final spanned = tester.getRect(_wi168Marker(0, 3));
        final px = await _wi168Capture(
          tester,
          untouched.expandToInclude(spanned),
        );
        final bg = px.at(untouched.topLeft + const Offset(13, 1.5));
        final fill = Color.alphaBlend(OmColors.selection, bg);
        for (final p in clearPoints(partial)) {
          expect(
            px.at(p),
            _wi168IsColor(bg),
            reason: 'no fill on row 2 at ${p - partial.topLeft}',
          );
        }
        for (final p in clearPoints(spanned)) {
          expect(
            px.at(p),
            _wi168IsColor(fill),
            reason: 'fill on row 3 at ${p - spanned.topLeft}',
          );
        }
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC7: display only
  // -------------------------------------------------------------------------
  group('display only markers (AC7)', () {
    testWidgets(
      'tapping the revealed marker text keeps focus and leaves the caret in the item text field',
      (tester) async {
        const text = 'intro\n- dash\n12. num\n> quoted\nend';
        final changes = await _wi168Pump(tester, text);

        for (final (r, marker) in [(1, '- '), (2, '12. '), (3, '> ')]) {
          await _wi168FocusRow(tester, 0, r, local: 2);
          expect(_wi168Shown(tester, 0, r), marker);
          final node = FocusManager.instance.primaryFocus;
          final before = segmentEditingAt(tester, 0).selection;
          final column = tester.getRect(_wi168Marker(0, r));

          for (final dx in [4.0, column.width - 3]) {
            await tester.macClick(column.topLeft + Offset(dx, 11.5));
            await tester.pump();

            expect(
              FocusManager.instance.primaryFocus,
              same(node),
              reason: 'row $r focus after a click at +$dx',
            );
            expect(segmentEditingAt(tester, 0).focusedRow, r);
            expect(
              segmentEditingAt(tester, 0).selection,
              before,
              reason: 'row $r caret after a click at +$dx',
            );
            expect(
              _wi168Ctrl(tester, 0, r).selection,
              const TextSelection.collapsed(offset: 2),
              reason: 'row $r field caret',
            );
            expect(_wi168Shown(tester, 0, r), marker);
          }
        }
        expect(changes, isEmpty);
        expect(segmentEditingAt(tester, 0).text, text);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC8: checkbox hit area
  // -------------------------------------------------------------------------
  group('checkbox hit area (AC8)', () {
    testWidgets(
      'task-checkbox covers the whole marker column and a click near its edge outside the circle toggles it',
      (tester) async {
        final changes = await _wi168Pump(tester, 'intro\n- [ ] a\nend');

        expect(_wi168Checkbox(0, 1), findsOneWidget);
        final column = tester.getRect(_wi168Marker(0, 1));
        final box = tester.getRect(_wi168Checkbox(0, 1));
        for (final (name, got, want) in [
          ('left', box.left, column.left),
          ('top', box.top, column.top),
          ('right', box.right, column.right),
          ('bottom', box.bottom, column.bottom),
        ]) {
          expect(got, moreOrLessEquals(want, epsilon: 0.01), reason: name);
        }
        expect(column.width, moreOrLessEquals(4 * _wi168Col, epsilon: 0.01));
        expect(column.height, moreOrLessEquals(_wi168Line, epsilon: 0.01));

        // Top-right corner: outside the 14 px circle.
        await tester.macClick(column.topLeft + const Offset(31, 1));
        await tester.pump();
        expect(changes, ['intro\n- [x] a\nend']);

        // Bottom edge right of the circle.
        await tester.macClick(column.topLeft + const Offset(20, 21.5));
        await tester.pump();
        expect(changes, ['intro\n- [x] a\nend', 'intro\n- [ ] a\nend']);
      },
      variant: macOnly,
    );

    testWidgets('no checkbox key on bullet numbered and quote rows', (
      tester,
    ) async {
      await _wi168Pump(tester, '- a\n1. b\n> c\n- [ ] d');

      for (final r in [0, 1, 2]) {
        expect(_wi168Checkbox(0, r), findsNothing, reason: 'row $r');
      }
      expect(_wi168Checkbox(0, 3), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // AC9: toggling
  // -------------------------------------------------------------------------
  group('checkbox toggle (AC9)', () {
    testWidgets(
      'clicking the checkbox of the focused task toggles it with focus and caret unchanged and saves the exact toggled bytes',
      (tester) async {
        final vault = seedSegmentedVault(topicBody: '- [ ] a');
        final r = await launchSegmented(tester, vault: vault);
        await r.open(fixtureTopicId);
        expect(r.segmentText(0), '- [ ] a');
        await r.focusSegment(0, offset: 7);
        final node = FocusManager.instance.primaryFocus;
        expect(r.segment(0).focusedRow, 0);
        expect(_wi168Checkbox(0, 0), findsOneWidget);

        await tester.macClick(tester.getCenter(_wi168Checkbox(0, 0)));
        await tester.pump();

        expect(r.segmentText(0), '- [x] a');
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(r.segment(0).focusedRow, 0);
        expect(r.segmentSelection(0), const TextSelection.collapsed(offset: 7));
        await r.waitForSave();
        expect(r.updates, hasLength(1));
        expect(r.updates.last.stdinBody, '- [x] a');

        await tester.macClick(tester.getCenter(_wi168Checkbox(0, 0)));
        await tester.pump();

        expect(r.segmentText(0), '- [ ] a');
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(r.segmentSelection(0), const TextSelection.collapsed(offset: 7));
        await r.waitForSave();
        expect(r.updates, hasLength(2));
        expect(r.updates.last.stdinBody, '- [ ] a');
      },
      variant: macOnly,
    );

    testWidgets(
      'a checkbox click applies toggleTask through the host as one reported and recorded edit and leaves the caret on another row in place',
      (tester) async {
        final recorders = _wi168Recorders();
        const text = 'intro\n* [X] caps\nend';
        final changes = await _wi168Pump(tester, text);
        await _wi168FocusRow(tester, 0, 0, local: 3);
        final node = FocusManager.instance.primaryFocus;

        await tester.macClick(tester.getCenter(_wi168Checkbox(0, 1)));
        await tester.pump();

        expect(changes, ['intro\n* [ ] caps\nend']);
        final records = [for (final r in recorders) ...r.records];
        expect(records, hasLength(1));
        expect(records.single.before, text);
        final want = toggleTask(text, _wi168Specs(text)[1])!;
        expect(
          (
            records.single.edit.start,
            records.single.edit.end,
            records.single.edit.replacement,
          ),
          (want.start, want.end, want.replacement),
        );
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(segmentEditingAt(tester, 0).focusedRow, 0);
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(offset: 3),
        );
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC10: unfocused segment
  // -------------------------------------------------------------------------
  group('checkbox of an unfocused segment (AC10)', () {
    testWidgets(
      'clicking the checkbox of an unfocused segment toggles it without moving focus into it',
      (tester) async {
        final changes = await _wi168Pump(
          tester,
          'intro\n$_wi168Token\n- [ ] b',
        );
        expect(segmentEditingAt(tester, 2).text, '- [ ] b');
        await _wi168FocusRow(tester, 0, 0, local: 2);
        final node = FocusManager.instance.primaryFocus;

        await tester.macClick(tester.getCenter(_wi168Checkbox(2, 0)));
        await tester.pump();

        expect(segmentEditingAt(tester, 2).text, '- [x] b');
        expect(changes, ['intro\n$_wi168Token\n- [x] b']);
        expect(FocusManager.instance.primaryFocus, same(node));
        expect(segmentEditingAt(tester, 0).focusedRow, 0);
        expect(segmentEditingAt(tester, 2).focusedRow, isNull);
        expect(_wi168Shown(tester, 2, 0), '', reason: 'no reveal');
      },
      variant: macOnly,
    );

    testWidgets(
      'clicking a checkbox while no segment has focus leaves every segment unfocused',
      (tester) async {
        final changes = await _wi168Pump(
          tester,
          'intro\n$_wi168Token\n- [x] b',
        );
        expect(segmentEditingAt(tester, 0).focusedRow, isNull);
        expect(segmentEditingAt(tester, 2).focusedRow, isNull);

        await tester.macClick(tester.getCenter(_wi168Checkbox(2, 0)));
        await tester.pump();

        expect(changes, ['intro\n$_wi168Token\n- [ ] b']);
        expect(segmentEditingAt(tester, 0).focusedRow, isNull);
        expect(segmentEditingAt(tester, 2).focusedRow, isNull);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC11: read-only mode
  // -------------------------------------------------------------------------
  group('read-only mode (AC11)', () {
    test('the read only flag defaults to interactive', () {
      final marker = ['- ', '[ ] '].join();
      final column = MarkerColumn(marker: marker, width: 4 * _wi168Col);
      expect(column.readOnly, isFalse);
      expect(
        MarkerColumn(
          marker: marker,
          width: 4 * _wi168Col,
          readOnly: true,
        ).readOnly,
        isTrue,
      );
    });

    testWidgets(
      'in read only mode a task column inside a focused segment row never reveals and a click on it changes nothing',
      (tester) async {
        final host = await _wi168ReadOnlyHost(tester, '- [ ] a', '- [ ] ');
        final readOnly = find.byKey(const Key('wi168-read-only'));
        expect(readOnly, findsOneWidget);

        await tester.showKeyboard(_wi168Row(0, 0));
        host.gate.value = true;
        await tester.pump();
        _wi168Ctrl(tester, 0, 0).selection = const TextSelection.collapsed(
          offset: 1,
        );
        await tester.pump();

        // Control: the row's own (interactive) column reveals here.
        expect(_wi168Shown(tester, 0, 0), '- [ ] ');
        expect(
          [for (final (t, _) in _wi168Runs(tester, readOnly)) t].join(),
          '',
          reason: 'the read-only column never reveals',
        );
        final column = tester.getRect(readOnly);
        final px = await _wi168Capture(tester, column.inflate(2));
        _wi168ExpectOpenCircle(px, column, why: 'read-only');

        for (final p in [
          tester.getCenter(readOnly),
          column.topLeft + const Offset(31, 1),
        ]) {
          await tester.macClick(p);
          await tester.pump();
        }
        expect(host.ctrl.text, '- [ ] a');
        expect(host.changes, isEmpty);

        await tester.pumpWidget(const SizedBox());
        host.ctrl.dispose();
        host.focus.dispose();
        host.gate.dispose();
      },
      variant: macOnly,
    );

    testWidgets(
      'a read only marker column on its own paints its marker with no marker text and ignores clicks',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: buildOmTheme(),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: RepaintBoundary(
                    key: _wi168BoundaryKey,
                    child: Container(
                      color: _wi168Surface,
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          MarkerColumn(
                            key: const Key('wi168-ro-done'),
                            marker: '- [x] ',
                            width: 4 * _wi168Col,
                            readOnly: true,
                          ),
                          MarkerColumn(
                            key: const Key('wi168-ro-bullet'),
                            marker: '- ',
                            width: 2 * _wi168Col,
                            readOnly: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final done = find.byKey(const Key('wi168-ro-done'));
        final bullet = find.byKey(const Key('wi168-ro-bullet'));
        for (final f in [done, bullet]) {
          expect(
            [for (final (t, _) in _wi168Runs(tester, f)) t].join(),
            '',
            reason: '$f shows marker text',
          );
        }
        final doneRect = tester.getRect(done);
        _wi168ExpectDoneCircle(
          await _wi168Capture(tester, doneRect.inflate(2)),
          doneRect,
          why: 'read-only done task',
        );
        final bulletRect = tester.getRect(bullet);
        _wi168ExpectFilledDot(
          await _wi168Capture(tester, bulletRect),
          bulletRect,
          why: 'read-only bullet',
        );

        await tester.macClick(tester.getCenter(done));
        await tester.pump();
        expect(tester.takeException(), isNull);
        _wi168ExpectDoneCircle(
          await _wi168Capture(tester, doneRect.inflate(2)),
          doneRect,
          why: 'read-only done task after a click',
        );
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // Verify: contracts of MarkerColumn's API docs the ACs leave open
  // -------------------------------------------------------------------------
  group('marker column contracts (verify)', () {
    /// Points of a bullet column clear of the revealed `-` glyph.
    List<Offset> clearPoints(Rect column) => [
      column.topLeft + const Offset(0.6, 0.6),
      column.topLeft + const Offset(15.6, 0.6),
      column.topLeft + const Offset(0.6, 22.35),
      column.topLeft + const Offset(15.6, 22.35),
    ];

    testWidgets(
      'a selection from exactly the line start to exactly the text end selects the marker and one ending inside the text does not',
      (tester) async {
        const text = 'intro\n- ab\n- cd\nend';
        await _wi168Pump(tester, text);
        final specs = _wi168Specs(text);
        await _wi168FocusRow(tester, 0, 0);

        Future<void> expectSelected(bool selected, String why) async {
          expect(_wi168Shown(tester, 0, 1), '- ', reason: why);
          expect(_wi168ShownColors(tester, 0, 1), {
            selected ? OmColors.fg1 : OmColors.fg2,
          }, reason: why);
          final column = tester.getRect(_wi168Marker(0, 1));
          final untouched = tester.getRect(_wi168Marker(0, 2));
          final px = await _wi168Capture(
            tester,
            column.expandToInclude(untouched),
          );
          final bg = px.at(untouched.topLeft + const Offset(13, 1.5));
          final want = selected ? Color.alphaBlend(OmColors.selection, bg) : bg;
          for (final p in clearPoints(column)) {
            expect(
              px.at(p),
              _wi168IsColor(want),
              reason: '$why: column at ${p - column.topLeft}',
            );
          }
        }

        segmentEditingAt(tester, 0).select(
          TextSelection(
            baseOffset: specs[1].start,
            extentOffset: specs[1].textEnd,
          ),
        );
        await tester.pump();
        expect(
          segmentEditingAt(tester, 0).selection,
          TextSelection(
            baseOffset: specs[1].start,
            extentOffset: specs[1].textEnd,
          ),
        );
        await expectSelected(true, 'line start to text end');

        segmentEditingAt(tester, 0).select(
          TextSelection(
            baseOffset: specs[1].start,
            extentOffset: specs[1].textEnd - 1,
          ),
        );
        await tester.pump();
        await expectSelected(false, 'line start to inside the text');

        segmentEditingAt(
          tester,
          0,
        ).select(TextSelection(baseOffset: specs[1].textEnd, extentOffset: 2));
        await tester.pump();
        await expectSelected(true, 'a backward selection over the line');
      },
      variant: macOnly,
    );

    testWidgets(
      'toggling the task of an unfocused segment repaints its circle done and then open again',
      (tester) async {
        await _wi168Pump(tester, 'intro\n$_wi168Token\n- [ ] b');
        await _wi168FocusRow(tester, 0, 0, local: 2);
        final column = tester.getRect(_wi168Marker(2, 0));
        _wi168ExpectOpenCircle(
          await _wi168Capture(tester, column.inflate(2)),
          column,
          why: 'before',
        );

        await tester.macClick(tester.getCenter(_wi168Checkbox(2, 0)));
        await tester.pump();
        expect(segmentEditingAt(tester, 2).text, '- [x] b');
        _wi168ExpectDoneCircle(
          await _wi168Capture(tester, column.inflate(2)),
          column,
          why: 'after one click',
        );

        await tester.macClick(tester.getCenter(_wi168Checkbox(2, 0)));
        await tester.pump();
        expect(segmentEditingAt(tester, 2).text, '- [ ] b');
        _wi168ExpectOpenCircle(
          await _wi168Capture(tester, column.inflate(2)),
          column,
          why: 'after two clicks',
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'an interactive marker column outside any editor row paints its marker as a level 1 item with no checkbox and ignores clicks',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: buildOmTheme(),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: RepaintBoundary(
                    key: _wi168BoundaryKey,
                    child: Container(
                      color: _wi168Surface,
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          MarkerColumn(
                            key: const Key('wi168-free-task'),
                            marker: ['- ', '[ ] '].join(),
                            width: 4 * _wi168Col,
                          ),
                          MarkerColumn(
                            key: const Key('wi168-free-bullet'),
                            marker: ['  ', '- '].join(),
                            width: 2 * _wi168Col,
                          ),
                          const MarkerColumn(
                            key: Key('wi168-free-number'),
                            marker: '7. ',
                            width: 3 * _wi168Col,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final task = find.byKey(const Key('wi168-free-task'));
        final bullet = find.byKey(const Key('wi168-free-bullet'));
        final number = find.byKey(const Key('wi168-free-number'));
        expect(
          find.byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('task-checkbox'),
          ),
          findsNothing,
        );
        expect([for (final (t, _) in _wi168Runs(tester, task)) t].join(), '');
        expect([for (final (t, _) in _wi168Runs(tester, bullet)) t].join(), '');
        expect(
          [for (final (t, _) in _wi168Runs(tester, number)) t].join(),
          '7.',
        );
        final taskRect = tester.getRect(task);
        _wi168ExpectOpenCircle(
          await _wi168Capture(tester, taskRect.inflate(2)),
          taskRect,
          why: 'free task',
        );
        final bulletRect = tester.getRect(bullet);
        _wi168ExpectFilledDot(
          await _wi168Capture(tester, bulletRect),
          bulletRect,
          why: 'free bullet is level 1',
        );

        await tester.macClick(tester.getCenter(task));
        await tester.pump();
        expect(tester.takeException(), isNull);
        _wi168ExpectOpenCircle(
          await _wi168Capture(tester, taskRect.inflate(2)),
          taskRect,
          why: 'free task after a click',
        );
      },
      variant: macOnly,
    );

    /// Pumps a one-row segment (`- [x] a`) whose rows builder adds a stray
    /// task [EditorRow] of index [strayIndex] (at or past the segment's row
    /// count), and expects that row's column to paint its own open marker
    /// with no checkbox, with clicks changing nothing.
    Future<void> expectStrayRowPaintsItsOwnMarker(
      WidgetTester tester,
      int strayIndex,
    ) async {
      final ctrl = TextEditingController(text: '- [x] a');
      final focus = FocusNode(debugLabel: 'wi168-stray');
      final gate = ValueNotifier(true);
      final strayCtrl = LivePreviewController(text: 'stray');
      final strayFocus = FocusNode(debugLabel: 'wi168-stray-row');
      addTearDown(() {
        ctrl.dispose();
        focus.dispose();
        gate.dispose();
        strayCtrl.dispose();
        strayFocus.dispose();
      });
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: buildOmTheme(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: RepaintBoundary(
                  key: _wi168BoundaryKey,
                  child: Container(
                    color: _wi168Surface,
                    width: 600,
                    child: SegmentView(
                      index: 0,
                      controller: ctrl,
                      focusNode: focus,
                      revealGate: gate,
                      minLines: 1,
                      hintText: null,
                      onChanged: () {},
                      onRowRemoved: (_) {},
                      fieldBuilder: (context, row) => TextField(
                        controller: row.controller,
                        focusNode: row.focusNode,
                        maxLines: null,
                      ),
                      builder: (context, rows, boxes) => Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          rows,
                          EditorRow(
                            segment: 0,
                            index: strayIndex,
                            kind: RowKind.task,
                            geometry: itemGeometry(
                              markerX: 0,
                              kind: MarkerColumnKind.task,
                            ),
                            marker: ['- ', '[ ] '].join(),
                            controller: strayCtrl,
                            focusNode: strayFocus,
                            boxes: () => null,
                            field: TextField(
                              controller: strayCtrl,
                              focusNode: strayFocus,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      expect(_wi168Checkbox(0, 0), findsOneWidget);
      expect(_wi168Checkbox(0, strayIndex), findsNothing);
      final stray = tester.getRect(_wi168Marker(0, strayIndex));
      _wi168ExpectOpenCircle(
        await _wi168Capture(tester, stray.inflate(2)),
        stray,
        why: 'stray row paints its own open marker',
      );

      await tester.macClick(tester.getCenter(_wi168Marker(0, strayIndex)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(ctrl.text, '- [x] a');
    }

    testWidgets(
      'a marker column whose editor row index is past its segment rows paints its own marker with no checkbox',
      (tester) => expectStrayRowPaintsItsOwnMarker(tester, 5),
      variant: macOnly,
    );

    testWidgets(
      'a marker column whose editor row index equals its segment row count paints its own marker with no checkbox',
      (tester) async {
        expect(_wi168Specs('- [x] a'), hasLength(1));
        await expectStrayRowPaintsItsOwnMarker(tester, 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'a done task check is an open polyline with no stroke from its last point back to its first',
      (tester) async {
        await _wi168Pump(tester, 'intro\n- [x] done\nend');
        final column = tester.getRect(_wi168Marker(0, 1));
        final px = await _wi168Capture(tester, column.inflate(2));
        _wi168ExpectDoneCircle(px, column, why: 'control');

        // A closed path would stroke the segment from the check's last
        // point back to its first; it crosses the fill clear of both strokes.
        final check = markerTaskCheck();
        for (final t in [0.25, 0.4, 0.5]) {
          final p = Offset.lerp(check.points.last, check.points.first, t)!;
          expect(
            px.at(column.topLeft + p),
            _wi168IsColor(OmColors.accentSoft),
            reason: 'unstroked fill at $t of last to first point $p',
          );
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'the marker painter repaints when only its selection fill or only its dot or only its task state changes and not when nothing changes',
      (tester) async {
        const text = '- one\n- two\n  - three\n- [ ] four\n- [x] five';
        final specs = _wi168Specs(text);
        final ctrl = TextEditingController(text: text);
        final focus = FocusNode(debugLabel: 'wi168-repaint');
        final gate = ValueNotifier(false);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: buildOmTheme(),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 600,
                    child: SegmentView(
                      index: 0,
                      controller: ctrl,
                      focusNode: focus,
                      revealGate: gate,
                      minLines: 1,
                      hintText: null,
                      onChanged: () {},
                      onRowRemoved: (_) {},
                      fieldBuilder: (context, row) => TextField(
                        controller: row.controller,
                        focusNode: row.focusNode,
                        maxLines: null,
                      ),
                      builder: (context, rows, boxes) => rows,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        CustomPainter painter(int r) => tester
            .widgetList<CustomPaint>(
              find.descendant(
                of: _wi168Marker(0, r),
                matching: find.byType(CustomPaint),
              ),
            )
            .map((w) => w.painter)
            .whereType<CustomPainter>()
            .single;

        final before = [for (var r = 0; r < specs.length; r++) painter(r)];
        expect(
          before[1].shouldRepaint(before[0]),
          isFalse,
          reason: 'two unselected level 1 bullets paint the same',
        );
        expect(
          before[2].shouldRepaint(before[1]),
          isTrue,
          reason: 'only the dot differs: level 2 vs level 1',
        );
        expect(
          before[4].shouldRepaint(before[3]),
          isTrue,
          reason: 'only the task state differs: done vs open',
        );

        // Select row 0 from its line start to its text end with the reveal
        // gate shut: only the column's fill changes.
        ctrl.selection = TextSelection(
          baseOffset: specs[0].start,
          extentOffset: specs[0].textEnd,
        );
        await tester.pump();
        expect(_wi168Shown(tester, 0, 0), '', reason: 'row 0 is not revealed');
        final selected = painter(0);
        expect(identical(selected, before[0]), isFalse);
        expect(
          selected.shouldRepaint(before[0]),
          isTrue,
          reason: 'only the selection fill changed',
        );
        expect(
          painter(1).shouldRepaint(before[1]),
          isFalse,
          reason: 'nothing changed on row 1',
        );

        // Reveal row 1 with a collapsed caret: only its dot goes away.
        ctrl.selection = const TextSelection.collapsed(offset: 0);
        await tester.showKeyboard(_wi168Row(0, 1));
        gate.value = true;
        await tester.pump();
        _wi168Ctrl(tester, 0, 1).selection = const TextSelection.collapsed(
          offset: 1,
        );
        await tester.pump();
        expect(_wi168Shown(tester, 0, 1), '- ', reason: 'row 1 is revealed');
        expect(
          painter(1).shouldRepaint(before[1]),
          isTrue,
          reason: 'only the dot changed: revealed',
        );

        await tester.pumpWidget(const SizedBox());
        ctrl.dispose();
        focus.dispose();
        gate.dispose();
      },
      variant: macOnly,
    );
  });
}
