// WI #127 (Spec #122 Req 25, Req 38, TD5 "idle-row contract"; rulings D3,
// D17): every consumer of editor-row geometry reads it through the rows
// host's row-geometry accessor (`SegmentViewState.rowBoxes`) or the host,
// never through a `RenderEditable` or `EditableTextState` per row. The
// change is behaviour-neutral on main's rows, and every consumer also works
// when a row's text slot is a `RichText` (`RenderParagraph`).
//
// The test-only text slot (never the real idle row, #132): a `RichText` of
// the span the row's own `LivePreviewController` builds, at the field's
// style, strut and layout width. It comes in two shapes:
// - a row presenter (#124's seam, `debugRowKindPresenterOverride`) that
//   builds it in place of the row's text slot, under the text slot's Key
//   `editor-row-<s>-<r>` ([_T127RichTextPresenter]);
// - a `SegmentView` field builder that builds it in place of the row's
//   field, inside the text slot's selection fill and squiggle layers, as an
//   idle row will sit (#132) ([_t127PumpView]).
//
// Expected geometry comes from the slot's own `RenderParagraph` (or the
// `RenderParagraphLineBoxes` adapter over it), never from the accessor under
// test. Row geometry in these tests goes through `editor_rows_probe.dart`:
// no text field finder and no render-editable lookup.
//
// Helpers carry the `_t127` prefix so stacked siblings never collide. Text
// is synthetic (public repo).
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/editor/row_geometry.dart';
import 'package:open_memex_app/src/editor/spell_issues.dart';
import 'package:open_memex_app/src/state/daily_state.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';
import 'package:open_memex_app/src/state/note_reveal.dart';
import 'package:open_memex_app/src/state/spell_check_controller.dart';
import 'package:open_memex_app/src/state/spell_session_state.dart';
import 'package:open_memex_app/src/state/spelling_service.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';
import 'package:open_memex_app/src/widgets/editor/echo_arrival_highlight.dart';
import 'package:open_memex_app/src/widgets/editor/editor_row.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/marker_column.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_decorations.dart';
import 'package:open_memex_app/src/widgets/editor/paragraph_line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/row_kinds.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/spell_check_host.dart';
import 'package:open_memex_app/src/widgets/editor/spell_issue_scope.dart';
import 'package:open_memex_app/src/widgets/editor/spell_squiggles.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';
import 'package:open_memex_app/src/widgets/find/find_in_note_host.dart'
    show findRevealInset;
import 'package:open_memex_app/src/widgets/find/find_keys.dart';

import '../../support/editor_rows_probe.dart';
import '../../support/editor_scope.dart';
import '../../support/fake_spelling_service.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import '../../support/note_reveal_pump.dart';
import '../../support/segment_editing_finder.dart';
import '../../support/table_harness.dart';
import '../../support/wi83_find_paint.dart';
import '../../support/wi85_find_editor.dart';

// ------------------------------------------------------------------ text

/// Row 2's two source lines: a plain line, then one with a link and code.
const _t127Middle1 = 'Middle first line with needle';
const _t127Middle2 =
    'Middle second [guide](https://example.com/guide) has `code` here';

/// Rows: 0 prose, 1 bullet, 2 prose (two lines: [_t127Middle1],
/// [_t127Middle2]), 3 bullet, 4 prose.
const _t127Text =
    'Intro paragraph line\n'
    '- first item\n'
    '$_t127Middle1\n'
    '$_t127Middle2\n'
    '- second item\n'
    'Outro line';

/// The row whose text slot the tests replace in [_t127Text].
const _t127Rich = 2;

/// Where row [_t127Rich]'s text starts in [_t127Text].
final int _t127RichStart = _t127Text.indexOf(_t127Middle1);

/// Where [_t127Middle2] starts in row [_t127Rich]'s text.
const int _t127Line2 = _t127Middle1.length + 1;

/// Row-local offset of `needle` in row [_t127Rich].
final int _t127Needle = _t127Middle1.indexOf('needle');

/// A prose row, a table row and a prose row (row 1 renders its grid).
const _t127GridText =
    'Intro prose line\n'
    '| Step | Notes |\n'
    '|---|---|\n'
    '| Alpha | one |\n'
    'Outro prose line';

// ------------------------------------------------------------- text slot

/// Key of the test-only RichText text slot of row [r] of segment [s].
Key _t127SlotKey(int s, int r) => ValueKey('t127-rich-slot-$s-$r');

/// RenderEditable's caret margin in a `TextField` (cursor width 2 plus its
/// 1 px caret gap): the field lays its text out this much narrower than
/// its box.
const double _t127CaretMargin = 3;

/// The test-only text slot: a `RichText` (Key [slotKey]) of the span
/// [controller] builds for its selection and reveal state, at the editor
/// field's merged style, strut (as `EditableText` resolves it), text scaler
/// and layout width. Rebuilt when the controller or its reveal gate changes.
class _T127SlotText extends StatelessWidget {
  const _T127SlotText({required this.controller, required this.slotKey});

  final LivePreviewController controller;
  final Key slotKey;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: _t127CaretMargin),
    child: ListenableBuilder(
      listenable: Listenable.merge([controller, controller.revealGate]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final style = (theme.textTheme.bodyLarge ?? const TextStyle()).merge(
          editorBodyStyle(),
        );
        final strut = controller.strutStyle;
        return RichText(
          key: slotKey,
          text: controller.buildTextSpan(
            context: context,
            style: style,
            withComposing: false,
          ),
          strutStyle: strut == null
              ? StrutStyle.fromTextStyle(style, forceStrutHeight: true)
              : strut.inheritFromTextStyle(style),
          textScaler: MediaQuery.textScalerOf(context),
          textHeightBehavior: DefaultTextHeightBehavior.maybeOf(context),
        );
      },
    ),
  );
}

/// A presenter that builds prose row [only] (every prose row when null) as
/// [_T127SlotText] in place of its text slot, under the slot's Key
/// `editor-row-<s>-<r>`; any other row as the built-in text presenter does.
/// It hides no text, measures no block and owns no press.
class _T127RichTextPresenter extends RowKindPresenter {
  const _T127RichTextPresenter({this.only});

  final int? only;

  bool _replaces(PresentedRow row) => only == null || row.index == only;

  @override
  Widget build(BuildContext context, PresentedRow row, RowTextSlot textSlot) {
    if (!_replaces(row)) {
      return const TextRowPresenter().build(context, row, textSlot);
    }
    return KeyedSubtree(
      key: ValueKey('editor-row-${row.segment}-${row.index}'),
      child: _T127SlotText(
        controller: row.controller,
        slotKey: _t127SlotKey(row.segment, row.index),
      ),
    );
  }

  @override
  bool textHidden(PresentedRow row) => false;

  @override
  LineBoxSource? blockBoxes(PresentedRow row) => null;

  @override
  bool ownsPress(PresentedRow row, Offset position) => false;
}

/// Presents prose row [only] (every prose row when null) as a RichText
/// text slot until the test ends.
void _t127PresentRichText({int? only}) {
  final presenter = _T127RichTextPresenter(only: only);
  debugRowKindPresenterOverride = (kind) =>
      kind == RowKind.prose ? presenter : null;
  addTearDown(() => debugRowKindPresenterOverride = null);
}

/// The laid-out test slot of row [r] of segment [s].
RenderParagraph _t127Slot(WidgetTester tester, int s, int r) {
  final finder = find.byKey(_t127SlotKey(s, r));
  if (finder.evaluate().isEmpty) {
    throw TestFailure('row $s-$r has no RichText test slot');
  }
  return tester.renderObject<RenderParagraph>(finder);
}

/// The global rect of row-local [start]..[end] in [slot], a range on one
/// line.
Rect _t127GlyphsGlobal(RenderParagraph slot, int start, int end) {
  final boxes = slot.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: end),
  );
  if (boxes.isEmpty) throw TestFailure('no glyph boxes for $start..$end');
  // One line: from the first glyph box's left to the caret x after [end]
  // (a selection's box list may run on past the range's last glyph).
  final first = boxes.first;
  final right = slot
      .getOffsetForCaret(
        TextPosition(offset: end, affinity: TextAffinity.upstream),
        Rect.zero,
      )
      .dx;
  final rect = Rect.fromLTRB(
    first.left,
    first.top,
    math.max(first.left, right),
    first.bottom,
  );
  return Rect.fromPoints(
    slot.localToGlobal(rect.topLeft),
    slot.localToGlobal(rect.bottomRight),
  );
}

/// A global point in the left quarter of the glyph at row-local [offset] of
/// [slot], so the nearest offset is [offset].
Offset _t127GlyphPoint(RenderParagraph slot, int offset) {
  final r = _t127GlyphsGlobal(slot, offset, offset + 1);
  return Offset(r.left + math.min(2.0, r.width / 4), r.center.dy);
}

/// Every line of [source] as (range, top, bottom), for comparing two
/// sources line by line.
List<(TextRange, double, double)> _t127Lines(LineBoxSource source) => [
  for (final l in source.lines) (l.range, l.top, l.bottom),
];

/// A presenter that builds every item row (bullet, numbered, task, quote)
/// as the built-in item layout does (the marker column, then the text
/// column) but with [_T127SlotText] as its text, and no text slot of its
/// own: the row's marker text sits before the slot in the row's render tree.
class _T127ItemRichPresenter extends RowKindPresenter {
  const _T127ItemRichPresenter();

  @override
  Widget build(BuildContext context, PresentedRow row, RowTextSlot textSlot) {
    final item = row.geometry!;
    final column = markerColumnKind(row.kind)!;
    return Padding(
      padding: EdgeInsets.only(left: item.markerX),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KeyedSubtree(
            key: ValueKey('editor-row-marker-${row.segment}-${row.index}'),
            child: MarkerColumn(marker: row.marker, width: item.columnWidth),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: itemTextRightInset(column)),
              child: KeyedSubtree(
                key: ValueKey('editor-row-${row.segment}-${row.index}'),
                child: _T127SlotText(
                  controller: row.controller,
                  slotKey: _t127SlotKey(row.segment, row.index),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool textHidden(PresentedRow row) => false;

  @override
  LineBoxSource? blockBoxes(PresentedRow row) => null;

  @override
  bool ownsPress(PresentedRow row, Offset position) => false;
}

/// A span that counts the plain-text copies and child walks asked of it.
class _T127CountingSpan extends TextSpan {
  const _T127CountingSpan({super.text, super.children, super.style});

  static int copies = 0;
  static int walks = 0;

  @override
  String toPlainText({
    bool includeSemanticsLabels = true,
    bool includePlaceholders = true,
  }) {
    copies++;
    return super.toPlainText(
      includeSemanticsLabels: includeSemanticsLabels,
      includePlaceholders: includePlaceholders,
    );
  }

  @override
  bool visitChildren(InlineSpanVisitor visitor) {
    walks++;
    return super.visitChildren(visitor);
  }
}

// ------------------------------------------------------------- gestures

/// A primary-button mouse click at [at] (global), then lets any click chain
/// expire.
Future<void> _t127Click(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kPrimaryButton,
  );
  await tester.pump();
  await gesture.up();
  await tester.pump();
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
}

/// [count] primary-button mouse clicks at [at] (global) inside one click
/// chain, then lets the chain expire.
Future<void> _t127Clicks(WidgetTester tester, Offset at, int count) async {
  for (var i = 0; i < count; i++) {
    final gesture = await tester.startGesture(
      at,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryButton,
    );
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
}

/// The [EditorRow] of row [r] of segment [s].
Finder _t127EditorRow(int s, int r) => find.byWidgetPredicate(
  (w) => w is EditorRow && w.segment == s && w.index == r,
  description: 'EditorRow $s-$r',
);

// ------------------------------------------------------- SegmentView pump

/// A bare text segment of [text] whose row of text [richRowText] has a
/// [_T127SlotText] (Key `t127-field-slot`) as its field, inside the text
/// slot's selection fill and squiggles; every other row has a real field.
/// [registry] is the spelling issue scope's registry.
Future<SegmentViewState> _t127PumpView(
  WidgetTester tester, {
  required String text,
  required String richRowText,
  SpellIssueRegistry? registry,
  String? staleSlotText,
}) async {
  final controller = TextEditingController(text: text);
  final focus = FocusNode();
  final gate = ValueNotifier(false);
  addTearDown(controller.dispose);
  addTearDown(focus.dispose);
  addTearDown(gate.dispose);
  Widget view = SegmentView(
    index: 0,
    controller: controller,
    focusNode: focus,
    revealGate: gate,
    minLines: 1,
    hintText: null,
    onChanged: () {},
    onRowRemoved: (_) {},
    fieldBuilder: (context, row) => row.controller.text == richRowText
        ? staleSlotText != null
              // A slot still showing another text than its row's (a stale
              // layout).
              ? RichText(
                  key: const ValueKey('t127-field-slot'),
                  text: TextSpan(text: staleSlotText, style: editorBodyStyle()),
                )
              : _T127SlotText(
                  controller: row.controller,
                  slotKey: const ValueKey('t127-field-slot'),
                )
        : TextField(
            controller: row.controller,
            focusNode: row.focusNode,
            maxLines: null,
            style: editorBodyStyle(),
          ),
    builder: (context, rows, boxes) => rows,
  );
  if (registry != null) {
    view = SpellIssueScope(registry: registry, child: view);
  }
  await pumpEditorScoped(
    tester,
    MaterialApp(
      theme: buildOmTheme(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 640, child: view),
        ),
      ),
    ),
  );
  await tester.pump();
  return tester.state<SegmentViewState>(find.byType(SegmentView));
}

/// The field-slot RichText of [_t127PumpView].
RenderParagraph _t127FieldSlot(WidgetTester tester) =>
    tester.renderObject<RenderParagraph>(
      find.byKey(const ValueKey('t127-field-slot')),
    );

// ---------------------------------------------------------- spelling fakes

/// A spelling field host that answers only the geometry-free seam (Spec
/// #122 Req 25) from [extentAtOf]: no render object at all.
class _T127ValueHost implements SpellFieldHost {
  _T127ValueHost({
    required this.extentAtOf,
    required this.window,
    this.laidOut = true,
    this.base = 0,
    this.placesOffsets = true,
  });

  /// The global top and bottom of the line holding a field offset.
  final ({double top, double bottom}) Function(int offset) extentAtOf;

  /// The viewport's global top and bottom, null without one.
  final ({double top, double bottom})? window;

  /// Whether the field is laid out ([extent] answers).
  final bool laidOut;

  /// Where the field's text starts in its line (a block marker before it).
  final int base;

  /// Whether [extentAt] places an offset (else it answers null).
  final bool placesOffsets;

  /// Every field offset [extentAt] was asked for.
  final asked = <int>[];

  @override
  SpellFieldLine line(TextEditingController field) => (
    line: '${'-' * base}${field.text}',
    base: base,
    atSegmentStart: base == 0,
  );

  @override
  ({double top, double bottom})? extent() => laidOut
      ? (top: extentAtOf(0).top, bottom: extentAtOf(1 << 20).bottom)
      : null;

  @override
  ({double top, double bottom})? extentAt(int offset) {
    asked.add(offset);
    return placesOffsets ? extentAtOf(offset) : null;
  }

  @override
  ({double top, double bottom})? viewport() => window;

  @override
  bool revealed(TextEditingController field) => true;

  @override
  ValueListenable<bool>? revealGate(TextEditingController field) => null;

  @override
  bool hasFocus(TextEditingController field) => false;

  /// Every render-object member (the seam before WI #127) answers null.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A [SpellIssueSink] over a map.
class _T127MapSink implements SpellIssueSink {
  final issues = <TextEditingController, List<SpellIssue>>{};

  @override
  List<SpellIssue> issuesOf(TextEditingController field) =>
      issues[field] ?? const [];

  @override
  void setIssues(TextEditingController field, List<SpellIssue> value) =>
      issues[field] = value;

  @override
  void forget(TextEditingController field) => issues.remove(field);
}

// ------------------------------------------------------------ source scan

/// The Dart files under `lib/` (paths relative to the app package).
List<File> _t127LibFiles() =>
    Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

/// [source] without `//` comment lines, so a doc comment may still name a
/// symbol.
String _t127Code(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  holdFontFetches();

  tearDown(() => debugRowKindPresenterOverride = null);

  // -------------------------------------------------------------------------
  // AC1: lineBoxes and every lineBoxes consumer over a RichText text slot
  // -------------------------------------------------------------------------
  group('lineBoxes over a RichText text slot (AC1)', () {
    testWidgets(
      'with one row text slot a RichText lineBoxes is non-null and reports that row lines in segment offsets at the slot place',
      (tester) async {
        _t127PresentRichText(only: _t127Rich);
        await pumpTable(tester, _t127Text);
        final host = rowsHostOf(tester);
        final spec = host.rowSpec(_t127Rich)!;
        expect(spec.textStart, _t127RichStart, reason: 'fixture row');
        final slot = _t127Slot(tester, 0, _t127Rich);

        // The accessor answers the slot's paragraph.
        final row = host.rowBoxes(_t127Rich);
        expect(row, isNotNull, reason: 'the RichText row reports geometry');
        expect(row!.box, same(slot), reason: 'measured on the slot itself');
        expect(
          _t127Lines(row),
          _t127Lines(RenderParagraphLineBoxes(slot)),
          reason: 'the slot paragraph lines, row-local',
        );

        // The segment's line boxes hold the slot's two lines at its place.
        final boxes = host.lineBoxes();
        expect(boxes, isNotNull, reason: 'one RichText row disables nothing');
        final shift = MatrixUtils.transformPoint(
          slot.getTransformTo(boxes!.box),
          Offset.zero,
        );
        final own = RenderParagraphLineBoxes(slot).lines;
        expect(own, hasLength(2), reason: 'two source lines, no wrap');
        final inSegment = [
          for (final l in boxes.lines)
            if (l.range.start >= spec.start && l.range.end <= spec.textEnd) l,
        ];
        expect(inSegment, hasLength(2));
        for (final (i, line) in own.indexed) {
          final got = inSegment[i];
          expect(
            got.range,
            TextRange(
              start: i == 0 ? spec.start : spec.toSegment(line.range.start),
              end: spec.toSegment(line.range.end),
            ),
            reason: 'line $i in segment offsets',
          );
          expect(got.top, moreOrLessEquals(line.top + shift.dy), reason: '$i');
          expect(
            got.bottom,
            moreOrLessEquals(line.bottom + shift.dy),
            reason: 'line $i bottom',
          );
        }
        // Every other row still answers through its field.
        expect(boxes.lines.length, greaterThanOrEqualTo(6));
        for (final r in [0, 1, 3, 4]) {
          expect(rowBoxesOf(tester, 0, r).lines, hasLength(1), reason: '$r');
        }
      },
    );

    testWidgets(
      'a RichText text slot of the same span gives the same segment line boxes as the row field',
      (tester) async {
        // The field first.
        await pumpTable(tester, _t127Text);
        final field = rowsHostOf(tester).lineBoxes()!;
        final fieldLines = [
          for (final l in field.lines) (l.range, l.top, l.bottom, l.baseline),
        ];
        final fieldCaret = field.caretRect(_t127RichStart + _t127Needle);
        final fieldGlyphs = field.boxesFor(
          TextRange(
            start: _t127RichStart + _t127Needle,
            end: _t127RichStart + _t127Needle + 'needle'.length,
          ),
        );

        await tester.pumpWidget(const SizedBox());
        _t127PresentRichText(only: _t127Rich);
        await pumpTable(tester, _t127Text);
        final boxes = rowsHostOf(tester).lineBoxes();
        expect(boxes, isNotNull);
        final lines = [
          for (final l in boxes!.lines) (l.range, l.top, l.bottom, l.baseline),
        ];
        expect(lines.length, fieldLines.length);
        for (final (i, l) in lines.indexed) {
          final f = fieldLines[i];
          expect(l.$1, f.$1, reason: 'line $i range');
          expect(l.$2, moreOrLessEquals(f.$2, epsilon: 0.01), reason: '$i top');
          expect(l.$3, moreOrLessEquals(f.$3, epsilon: 0.01), reason: '$i');
          expect(l.$4, moreOrLessEquals(f.$4, epsilon: 0.01), reason: '$i');
        }
        // The glyphs sit where the field's do.
        final range = TextRange(
          start: _t127RichStart + _t127Needle,
          end: _t127RichStart + _t127Needle + 'needle'.length,
        );
        final glyphs = boxes.boxesFor(range);
        expect(glyphs, isNotEmpty);
        expect(glyphs.first.left, moreOrLessEquals(fieldGlyphs.first.left));
        expect(glyphs.first.top, moreOrLessEquals(fieldGlyphs.first.top));
        expect(glyphs.first.bottom, moreOrLessEquals(fieldGlyphs.first.bottom));
        // The caret's line is the field's; its x may differ by the field's
        // half-pixel caret offset (the two adapters, not this WI's).
        final caret = boxes.caretRect(range.start);
        expect(caret.top, moreOrLessEquals(fieldCaret.top, epsilon: 0.01));
        expect(
          caret.bottom,
          moreOrLessEquals(fieldCaret.bottom, epsilon: 0.01),
        );
        expect(caret.left, moreOrLessEquals(fieldCaret.left, epsilon: 0.51));
      },
    );

    testWidgets(
      'rectForOffset in a RichText text slot is the slot caret rect',
      (tester) async {
        _t127PresentRichText(only: _t127Rich);
        await pumpTable(tester, _t127Text);
        final slot = _t127Slot(tester, 0, _t127Rich);
        final local = _t127Line2 + 7;
        final caret = RenderParagraphLineBoxes(slot).caretRect(local);
        final expected = Rect.fromPoints(
          slot.localToGlobal(caret.topLeft),
          slot.localToGlobal(caret.bottomRight),
        );

        final rect = segmentEditingAt(
          tester,
          0,
        ).rectForOffset(_t127RichStart + local);

        expect(rect.left, moreOrLessEquals(expected.left));
        expect(rect.top, moreOrLessEquals(expected.top));
        expect(rect.bottom, moreOrLessEquals(expected.bottom));
      },
    );

    testWidgets(
      'a click on a RichText text slot puts the caret at the offset under the pointer',
      (tester) async {
        _t127PresentRichText(only: _t127Rich);
        final b = await pumpTable(tester, _t127Text);
        final slot = _t127Slot(tester, 0, _t127Rich);
        final local = _t127Needle + 2;

        await _t127Click(tester, _t127GlyphPoint(slot, local));

        expect(
          b.selection(),
          TextSelection.collapsed(offset: _t127RichStart + local),
        );
        // On the second line too.
        final second = _t127Line2 + 3;
        await _t127Click(tester, _t127GlyphPoint(slot, second));
        expect(
          b.selection(),
          TextSelection.collapsed(offset: _t127RichStart + second),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'Arrow Down from the row above lands in a RichText text slot at the nearest x and Arrow Up from the row below lands on its last line',
      (tester) async {
        _t127PresentRichText(only: _t127Rich);
        final b = await pumpTable(tester, _t127Text);
        final slot = _t127Slot(tester, 0, _t127Rich);
        final lines = RenderParagraphLineBoxes(slot).lines;

        int expectedAt(int row, int rowOffset, int line) {
          final above = rowBoxesOf(tester, 0, row);
          final caret = above.caretRect(rowOffset);
          final x = above.box.localToGlobal(caret.topLeft).dx;
          final l = lines[line];
          final local = slot.globalToLocal(Offset(x, 0));
          final position = slot.getPositionForOffset(
            Offset(local.dx, (l.top + l.bottom) / 2),
          );
          return _t127RichStart + position.offset;
        }

        // Down from `first item` (row 1) at row offset 4.
        final down = expectedAt(1, 4, 0);
        await activateRow(tester, 0, 1, offset: 4);
        await b.press(LogicalKeyboardKey.arrowDown);
        expect(
          b.selection(),
          TextSelection.collapsed(offset: down),
          reason: 'Down lands on the slot first line at the nearest x',
        );

        // Up from `second item` (row 3) at row offset 3.
        final up = expectedAt(3, 3, lines.length - 1);
        await activateRow(tester, 0, 3, offset: 3);
        await b.press(LogicalKeyboardKey.arrowUp);
        expect(
          b.selection(),
          TextSelection.collapsed(offset: up),
          reason: 'Up lands on the slot last line at the nearest x',
        );
      },
      variant: macOnly,
    );

    testWidgets('a Cmd+click on a link in a RichText text slot follows it', (
      tester,
    ) async {
      _t127PresentRichText(only: _t127Rich);
      final opener = RecordingUrlOpener();
      await pumpTable(tester, _t127Text, opener: opener);
      await tester.pump();
      final slot = _t127Slot(tester, 0, _t127Rich);
      final guide = _t127Line2 + _t127Middle2.indexOf('guide');
      final at = _t127GlyphsGlobal(slot, guide, guide + 5).center;

      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.metaLeft,
        platform: 'macos',
      );
      await tester.pump();
      final gesture = await tester.startGesture(
        at,
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryButton,
      );
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.metaLeft,
        platform: 'macos',
      );
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));

      expect(opener.opened, ['https://example.com/guide']);
    }, variant: macOnly);

    testWidgets(
      'the live preview decorations paint the code pill behind code in a RichText text slot',
      (tester) async {
        _t127PresentRichText(only: _t127Rich);
        await pumpTable(tester, _t127Text);
        final slot = _t127Slot(tester, 0, _t127Rich);
        final code = _t127Line2 + _t127Middle2.indexOf('code');
        final glyphs = _t127GlyphsGlobal(slot, code, code + 4);
        final decorations = tester.renderObject<RenderBox>(
          find.descendant(
            of: _t127EditorRow(0, _t127Rich),
            matching: find.byType(LivePreviewDecorations),
          ),
        );
        final centre = decorations.globalToLocal(glyphs.center);

        expect(
          decorations,
          paints..something((method, args) {
            if (method != #drawRRect) return false;
            final rrect = args[0] as RRect;
            final paint = args[1] as Paint;
            return paint.color.toARGB32() == OmColors.surface4.toARGB32() &&
                rrect.outerRect.contains(centre) &&
                rrect.outerRect.width >= glyphs.width - 0.5;
          }),
          reason: 'a surface4 pill around `code`',
        );
      },
    );

    testWidgets(
      'Find in note paints a match in a RichText text slot over the slot glyphs',
      (tester) async {
        _t127PresentRichText(only: _t127Rich);
        await pumpTable(tester, _t127Text);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(SegmentView)),
        );
        container.read(findInNoteProvider.notifier).setSources([
          const FindSource(
            segment: 0,
            kind: FindSourceKind.body,
            text: _t127Text,
          ),
        ]);
        container.read(findInNoteProvider.notifier).setQuery('needle');
        container.read(findInNoteProvider.notifier).show();
        await tester.pump();
        await tester.pump();
        expect(
          container.read(findInNoteProvider).matches,
          hasLength(1),
          reason: 'one match, in row $_t127Rich',
        );

        final slot = _t127Slot(tester, 0, _t127Rich);
        final glyphs = _t127GlyphsGlobal(
          slot,
          _t127Needle,
          _t127Needle + 'needle'.length,
        );
        final key = findHighlightsKey(0, _t127Rich);
        final layer = wi83Layer(tester, key);
        final centre = layer.globalToLocal(glyphs.center);
        final ops = wi83LayerOps(tester, key);
        expect(ops, isNotEmpty, reason: 'the row layer paints the match');
        expect(
          ops.any((op) => op.outer.contains(centre)),
          isTrue,
          reason: 'over the slot glyphs of `needle`: $ops',
        );
      },
    );

    testWidgets(
      'the capture gutter rule spans a captured block lines in a RichText text slot',
      (tester) async {
        _t127PresentRichText(only: _t127Rich);
        final start = _t127Text.indexOf(_t127Middle2);
        final block = BlockRow(
          blockId: 't127-agent',
          ord: 0,
          text: _t127Middle2,
          source: 'agent',
          createdVersion: 2,
          createdAt: DateTime(2026, 10, 3, 14, 32).millisecondsSinceEpoch,
          startByte: start,
          endByte: start + _t127Middle2.length,
        );
        await pumpTable(
          tester,
          _t127Text,
          daily: true,
          overrides: [
            blocksForNoteAsyncProvider.overrideWith(
              (ref, noteId) async => VaultScoped(null, [block]),
            ),
          ],
        );
        await tester.pump();
        await tester.pump();

        final rule = find.byKey(const Key('capture-gutter-rule-t127-agent'));
        expect(rule, findsOneWidget, reason: 'the rule is measured');
        final slot = _t127Slot(tester, 0, _t127Rich);
        final line = RenderParagraphLineBoxes(slot).lines[1];
        final rect = tester.getRect(rule);
        expect(
          rect.top,
          moreOrLessEquals(slot.localToGlobal(Offset(0, line.top)).dy),
        );
        expect(
          rect.bottom,
          moreOrLessEquals(slot.localToGlobal(Offset(0, line.bottom)).dy),
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC2: the pointer layer's word, line and grid paths over the accessor
  // -------------------------------------------------------------------------
  group('pointer paths over a RichText text slot (AC2)', () {
    testWidgets(
      'a double click on a RichText text slot selects the word under the pointer',
      (tester) async {
        _t127PresentRichText(only: _t127Rich);
        final b = await pumpTable(tester, _t127Text);
        final slot = _t127Slot(tester, 0, _t127Rich);

        await _t127Clicks(tester, _t127GlyphPoint(slot, _t127Needle + 2), 2);

        expect(
          b.selection(),
          TextSelection(
            baseOffset: _t127RichStart + _t127Needle,
            extentOffset: _t127RichStart + _t127Needle + 'needle'.length,
          ),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'a triple click on a RichText text slot selects its source line with the line break',
      (tester) async {
        _t127PresentRichText(only: _t127Rich);
        final b = await pumpTable(tester, _t127Text);
        final slot = _t127Slot(tester, 0, _t127Rich);

        await _t127Clicks(tester, _t127GlyphPoint(slot, 3), 3);

        expect(
          b.selection(),
          TextSelection(
            baseOffset: _t127RichStart,
            extentOffset: _t127RichStart + _t127Line2,
          ),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'a click on a rendered grid in a segment with a RichText text slot reveals the table with the caret at the pressed cell offset',
      (tester) async {
        _t127PresentRichText(only: 0);
        final b = await pumpTable(tester, _t127GridText);
        expect(
          [for (final r in b.rows()) r.kind],
          [RowKind.prose, RowKind.table, RowKind.prose],
          reason: 'fixture',
        );
        expectTableRendered(0, 1, reason: 'the table starts rendered');
        _t127Slot(tester, 0, 0);

        // `Al|pha`: a point on the grid's `l`, mapped by the grid's own
        // geometry at press time.
        final spec = b.rows()[1];
        final alpha = _t127GridText.indexOf('Alpha') - spec.textStart;
        final grid = rowBoxesOf(tester, 0, 1);
        final glyph = grid.boxesFor(
          TextRange(start: alpha + 1, end: alpha + 2),
        );
        expect(glyph, isNotEmpty, reason: 'the grid measures `Alpha`');
        final local = Offset(glyph.first.left + 1, glyph.first.center.dy);
        final mapped = spec.textStart + grid.offsetAt(local);

        await _t127Click(tester, grid.box.localToGlobal(local));

        expectTableRevealed(0, 1, reason: 'the press reveals the table');
        expect(b.selection(), TextSelection.collapsed(offset: mapped));
        expect(b.view().focusedRow, 1, reason: 'the table row has focus');
      },
      variant: macOnly,
    );

    test(
      'the pointer layer guards no path on row fields matching rows and reads no row field geometry',
      () {
        final code = _t127Code(
          File(
            'lib/src/widgets/editor/segment_pointer_layer.dart',
          ).readAsStringSync(),
        );
        for (final banned in [
          'fields.length != rows.length',
          'nodes.length != rows.length',
          'EditableTextState',
          'renderEditable',
          'findRenderEditable',
        ]) {
          expect(
            code.contains(banned),
            isFalse,
            reason:
                'segment_pointer_layer.dart reads rows through the host and '
                'the row-geometry accessor, not `$banned`',
          );
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC3: selection fill, squiggles, echo arrival and revealAnchorRect
  // -------------------------------------------------------------------------
  group('row-slot consumers read the accessor (AC3)', () {
    testWidgets(
      'the selection fill paints the selected glyphs of a RichText text slot as one full-height line',
      (tester) async {
        final host = await _t127PumpView(
          tester,
          text: _t127Text,
          richRowText: '$_t127Middle1\n$_t127Middle2',
        );
        final slot = _t127FieldSlot(tester);
        // `first line` of row 2, unfocused.
        final from = _t127Middle1.indexOf('first');
        final to = from + 'first line'.length;
        host.select(
          TextSelection(
            baseOffset: _t127RichStart + from,
            extentOffset: _t127RichStart + to,
          ),
        );
        await tester.pump();

        final glyphs = _t127GlyphsGlobal(slot, from, to);
        final line = RenderParagraphLineBoxes(slot).lines.first;
        final row = tester.renderObject<RenderBox>(
          find.byKey(ValueKey('editor-row-0-$_t127Rich')),
        );
        final left = row.globalToLocal(glyphs.topLeft).dx;
        expect(
          row,
          paints..something((method, args) {
            if (method != #drawRect) return false;
            final rect = args[0] as Rect;
            final paint = args[1] as Paint;
            return paint.color.toARGB32() == OmColors.selection.toARGB32() &&
                (rect.left - left).abs() < 0.5 &&
                (rect.width - glyphs.width).abs() < 0.5 &&
                (rect.height - (line.bottom - line.top)).abs() < 0.5;
          }),
          reason: 'the slot selected glyphs fill in OmColors.selection',
        );
      },
    );

    testWidgets(
      'the spelling squiggle paints under a flagged word of a RichText text slot',
      (tester) async {
        final registry = SpellIssueRegistry();
        await _t127PumpView(
          tester,
          text: _t127Text,
          richRowText: '$_t127Middle1\n$_t127Middle2',
          registry: registry,
        );
        final controller = tester
            .widget<EditorRow>(_t127EditorRow(0, _t127Rich))
            .controller;
        registry.setIssues(controller, [
          SpellIssue(
            kind: SpellIssueKind.spelling,
            start: _t127Needle,
            length: 'needle'.length,
            corrections: ['noodle'],
          ),
        ]);
        await tester.pump();

        final slot = _t127FieldSlot(tester);
        final glyphs = _t127GlyphsGlobal(
          slot,
          _t127Needle,
          _t127Needle + 'needle'.length,
        );
        final layer = tester.renderObject<RenderBox>(
          find.descendant(
            of: find.byKey(ValueKey('editor-row-0-$_t127Rich')),
            matching: find.byType(SpellSquiggles),
          ),
        );
        final left = layer.globalToLocal(glyphs.bottomLeft).dx;
        expect(
          layer,
          paints..something((method, args) {
            if (method != #drawPath) return false;
            final bounds = (args[0] as Path).getBounds();
            final paint = args[1] as Paint;
            return paint.color.toARGB32() == OmColors.danger.toARGB32() &&
                (bounds.left - left).abs() < 0.5 &&
                (bounds.width - glyphs.width).abs() < 0.5;
          }),
          reason: 'a danger squiggle under exactly `needle`',
        );
      },
    );

    testWidgets(
      'the echo arrival band in a RichText prose row starts at the arrival passage line',
      (tester) async {
        _t127PresentRichText();
        final h = await pumpNoteReveal(tester);
        final at = h.offsetOf('line 300\n');

        h.request(
          NoteRevealRequest(
            revealLongId,
            h.textAt(at),
            const RevealTop(16),
            flash: true,
          ),
        );
        for (var i = 0; i < 20 && h.highlight.evaluate().isEmpty; i++) {
          await tester.pump();
        }
        expect(h.highlight, findsOneWidget, reason: 'the arrival flashes');

        final highlight = tester.widget<EchoArrivalHighlight>(h.highlight);
        final target = highlight.target;
        final line = h.lineBoxOf(0, at);
        final top = target.globalToLocal(line.topLeft).dy;
        expect(top, greaterThan(0), reason: 'line 300 is not the row top');
        expect(
          highlight.band.top,
          moreOrLessEquals(top, epsilon: 0.5),
          reason: 'the band starts on the passage line, not the whole row',
        );
      },
    );

    testWidgets(
      'a reveal of a line in a RichText prose row lands that line at the placement',
      (tester) async {
        _t127PresentRichText();
        final h = await pumpNoteReveal(tester);
        final at = h.offsetOf('line 300\n');

        h.request(
          NoteRevealRequest(revealLongId, h.textAt(at), const RevealTop(16)),
        );
        await pumpFrames(tester);

        expect(h.pixels(), greaterThan(0), reason: 'the page scrolled');
        expect(
          h.lineTopOf(0, at) - h.viewport().top,
          moreOrLessEquals(16, epsilon: 0.5),
          reason: 'the anchor is the line, not the whole row',
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC4: the spelling seam (Req 25)
  // -------------------------------------------------------------------------
  group('spelling near-viewport seam (AC4)', () {
    test(
      'the spelling controller holds no RenderEditable and imports no widget file',
      () {
        final source = File(
          'lib/src/state/spell_check_controller.dart',
        ).readAsStringSync();
        expect(
          _t127Code(source).contains('RenderEditable'),
          isFalse,
          reason: 'the host answers tops and bottoms (Req 25)',
        );
        final imports = RegExp(
          r'''^import\s+['"]([^'"]+)['"]''',
          multiLine: true,
        ).allMatches(source).map((m) => m.group(1)!).toList();
        expect(imports, isNotEmpty);
        for (final path in imports) {
          expect(
            path.contains('widgets/'),
            isFalse,
            reason: 'state/ imports no widget file: $path',
          );
        }
      },
    );

    testWidgets(
      'the spelling controller checks only paragraphs whose host tops and bottoms lie within a screen of the viewport',
      (tester) async {
        final service = FakeSpellingService();
        final container = ProviderContainer(
          overrides: [spellingServiceProvider.overrideWithValue(service)],
        );
        addTearDown(container.dispose);
        final checker = SpellCheckController(
          noteId: 't127-note',
          sink: _T127MapSink(),
          session: () => container.read(spellSessionProvider),
          service: () => service,
          flags: (spelling: true, grammar: false),
        );
        addTearDown(checker.dispose);
        const window = (top: 0.0, bottom: 600.0);

        // A near field with a near and a far paragraph, and a far field.
        const nearPara = 'Near paragraph text.';
        const farPara = 'Far paragraph text.';
        final mixed = TextEditingController(text: '$nearPara\n\n$farPara');
        addTearDown(mixed.dispose);
        final far = TextEditingController(text: 'Distant field text.');
        addTearDown(far.dispose);
        checker.addField(
          mixed,
          _T127ValueHost(
            window: window,
            extentAtOf: (offset) => offset <= nearPara.length
                ? (top: 100.0, bottom: 123.0)
                : (top: 5000.0, bottom: 5023.0),
          ),
        );
        checker.addField(
          far,
          _T127ValueHost(
            window: window,
            extentAtOf: (_) => (top: 9000.0, bottom: 9023.0),
          ),
        );
        for (var i = 0; i < 6; i++) {
          await tester.pump();
        }

        final checked = [
          for (final c in service.callsFor('check')) c.args['text'],
        ];
        expect(checked, [nearPara], reason: 'only within one screen');
      },
    );

    testWidgets(
      'a row field spelling host answers its top and bottom and an offset line top and bottom from the row geometry',
      (tester) async {
        await pumpTable(tester, _t127Text);
        for (final r in [0, _t127Rich]) {
          final rowBoxes = rowBoxesOf(tester, 0, r);
          final box = rowBoxes.box;
          final controller = tester
              .widget<EditorRow>(_t127EditorRow(0, r))
              .controller;
          final field = find.byWidgetPredicate(
            (w) => w is SpellCheckField && identical(w.controller, controller),
          );
          expect(field, findsOneWidget, reason: 'row $r joins spelling');
          final host = tester.state(field) as SpellFieldHost;

          // The row's laid-out text: its box or its lines' span (they
          // differ by the strut's fraction of a pixel).
          final rect = rowRectOf(tester, 0, r);
          final extent = host.extent();
          expect(extent, isNotNull, reason: 'row $r is laid out');
          expect(
            extent!.top,
            moreOrLessEquals(rect.top, epsilon: 0.1),
            reason: 'row $r top',
          );
          expect(
            extent.bottom,
            moreOrLessEquals(rect.bottom, epsilon: 0.1),
            reason: 'row $r bottom',
          );

          // An offset's top and bottom lie on the line holding it (row 2's
          // offset is on its second line).
          final offset = r == _t127Rich ? _t127Line2 + 4 : 3;
          final line = lineHolding(rowBoxes.lines, offset);
          final lineTop = box.localToGlobal(Offset(0, line.top)).dy;
          final lineBottom = box.localToGlobal(Offset(0, line.bottom)).dy;
          final at = host.extentAt(offset);
          expect(at, isNotNull, reason: 'row $r offset $offset');
          expect(
            at!.top,
            greaterThanOrEqualTo(lineTop - 0.1),
            reason: 'row $r offset $offset top on its line',
          );
          expect(
            at.bottom,
            lessThanOrEqualTo(lineBottom + 0.1),
            reason: 'row $r offset $offset bottom on its line',
          );
          expect(at.bottom, greaterThan(at.top), reason: 'row $r: a band');

          // The viewport: the editor page's vertical Scrollable.
          final scrollable = Scrollable.maybeOf(
            tester.element(field),
            axis: Axis.vertical,
          );
          expect(scrollable, isNotNull, reason: 'the body scrolls');
          final page = scrollable!.context.findRenderObject()! as RenderBox;
          final pageTop = page.localToGlobal(Offset.zero).dy;
          final viewport = host.viewport();
          expect(viewport, isNotNull, reason: 'row $r sees the viewport');
          expect(viewport!.top, moreOrLessEquals(pageTop), reason: 'top');
          expect(
            viewport.bottom,
            moreOrLessEquals(pageTop + page.size.height),
            reason: 'bottom',
          );
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC5: Find in note's geometry
  // -------------------------------------------------------------------------
  group('Find in note over a RichText row (AC5)', () {
    testWidgets(
      'Find current match in a RichText prose row reveals the match line within the viewport',
      (tester) async {
        _t127PresentRichText();
        final w = await pumpWi85(tester, open: wi85LongId);
        final h = w.h;
        await w.openOn(wi85LongQuery);
        final second = h.offsetOf('second marker line') + 'second '.length;
        final match = await w.stepUntil((m) => m.start == second);
        await pumpFrames(tester);

        expect(h.pixels(), greaterThan(0), reason: 'the page scrolled');
        final line = h.lineBoxOf(0, match.start);
        final viewport = h.viewport();
        expect(
          line.top,
          greaterThanOrEqualTo(viewport.top + findRevealInset - 0.5),
          reason: 'below the Find bar inset',
        );
        expect(
          line.bottom,
          lessThanOrEqualTo(viewport.bottom + 0.5),
          reason: 'on screen',
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC6: no production file calls findRenderEditable on an editor row
  // -------------------------------------------------------------------------
  group('findRenderEditable guard (AC6)', () {
    test(
      'no production file outside the active field, the line-box adapter and the Source surface calls findRenderEditable',
      () {
        // The files that may call it, and why:
        const allowed = {
          // The active row's own field: its autocomplete caret anchor.
          'lib/src/widgets/editor/text_segment.dart',
          // Its definition, beside the RenderEditableLineBoxes adapter.
          'lib/src/widgets/editor/line_boxes.dart',
          // Source mode's one field: no editor row.
          'lib/src/widgets/editor/source_surface.dart',
        };
        final callers = <String>[];
        for (final file in _t127LibFiles()) {
          final path = file.path.replaceAll(r'\', '/');
          final code = _t127Code(file.readAsStringSync());
          if (code.contains('findRenderEditable(') && !allowed.contains(path)) {
            callers.add(path);
          }
        }
        expect(
          callers,
          isEmpty,
          reason:
              'row geometry goes through SegmentViewState.rowBoxes (D3); '
              'these files still call findRenderEditable: $callers',
        );
        // The allowed files exist (a rename must update this guard).
        for (final path in allowed) {
          expect(File(path).existsSync(), isTrue, reason: path);
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // Accessor contracts the AC tests above leave open (verify)
  // -------------------------------------------------------------------------
  group('text slot lookup (verify)', () {
    Future<RenderObject> pumpRoot(
      WidgetTester tester,
      List<Widget> kids,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(key: const ValueKey('t127-root'), children: kids),
          ),
        ),
      );
      return tester.renderObject(find.byKey(const ValueKey('t127-root')));
    }

    final hint = RichText(text: const TextSpan(text: 'hint'));

    testWidgets(
      'the text slot of a root is its field before a RichText whichever comes first, else its RichText, else nothing',
      (tester) async {
        final controller = TextEditingController(text: 'field text');
        addTearDown(controller.dispose);
        final field = TextField(controller: controller);

        var root = await pumpRoot(tester, [hint, field]);
        expect(
          textSlotBox(root),
          isA<RenderEditable>(),
          reason: 'RichText first',
        );
        expect(textSlotBoxes(root), isA<RenderEditableLineBoxes>());

        root = await pumpRoot(tester, [field, hint]);
        expect(textSlotBox(root), isA<RenderEditable>(), reason: 'field first');

        root = await pumpRoot(tester, [hint]);
        expect(textSlotBox(root), isA<RenderParagraph>());
        expect(textSlotBoxes(root), isA<RenderParagraphLineBoxes>());

        root = await pumpRoot(tester, [const SizedBox(width: 10, height: 10)]);
        expect(textSlotBox(root), isNull, reason: 'no text under the root');
        expect(textSlotBoxes(root), isNull);
        expect(textSlotLines(root, 'x'), isNull);
        expect(textSlotBox(null), isNull, reason: 'no root');
        expect(textSlotBoxes(null), isNull);
        expect(textSlotLines(null, 'x'), isNull);
      },
    );

    testWidgets(
      'the text slot lines are answered only while the laid out text has the length of the given text',
      (tester) async {
        final root = await pumpRoot(tester, [
          RichText(text: const TextSpan(text: 'hello world')),
        ]);
        final lines = textSlotLines(root, 'hello world');
        expect(lines, isNotNull, reason: 'the same length');
        expect(lines!.lines, hasLength(1));
        expect(lines.lines.last.range.end, 'hello world'.length);
        expect(
          _t127Lines(lines.boxes),
          _t127Lines(textSlotBoxes(root)!),
          reason: 'the boxes measure the same slot',
        );
        expect(textSlotLines(root, 'hello world!'), isNull, reason: 'longer');
        expect(textSlotLines(root, 'hello'), isNull, reason: 'shorter');
        expect(textSlotLines(root, ''), isNull, reason: 'empty');
      },
    );
  });

  group('rows host accessor edges (verify)', () {
    testWidgets(
      'the host answers nothing for a row before the first or past the last and something for each row in range',
      (tester) async {
        await pumpTable(tester, _t127Text);
        final host = rowsHostOf(tester);
        final n = host.rowCount;
        expect(n, 5, reason: 'fixture rows');
        for (final i in [-1, n]) {
          expect(host.rowController(i), isNull, reason: 'controller $i');
          expect(host.rowFocusNode(i), isNull, reason: 'focus node $i');
          expect(host.rowBoxes(i), isNull, reason: 'boxes $i');
          expect(
            host.rowPositionAt(i, const Offset(30, 30)),
            isNull,
            reason: 'position $i',
          );
          expect(
            host.rowWordBoundary(i, const TextPosition(offset: 0)),
            isNull,
            reason: 'word $i',
          );
          host.rowPressed(i, 0);
        }
        for (final i in [0, n - 1]) {
          final controller = tester
              .widget<EditorRow>(_t127EditorRow(0, i))
              .controller;
          expect(host.rowController(i), same(controller), reason: 'row $i');
          expect(host.rowFocusNode(i), isNotNull, reason: 'row $i');
          expect(host.rowBoxes(i), isNotNull, reason: 'row $i');
          expect(
            host.rowWordBoundary(i, const TextPosition(offset: 1)),
            isNotNull,
            reason: 'row $i has a laid out slot',
          );
        }
        expect(
          host.rowFocusNode(0),
          isNot(same(host.rowFocusNode(1))),
          reason: 'one node per row',
        );
      },
    );

    testWidgets(
      'a row position and word are resolved by the slot itself for a field row and for a RichText row',
      (tester) async {
        _t127PresentRichText(only: _t127Rich);
        await pumpTable(tester, _t127Text);
        final host = rowsHostOf(tester);

        // The RichText row.
        final slot = _t127Slot(tester, 0, _t127Rich);
        final at = host.rowPositionAt(
          _t127Rich,
          _t127GlyphPoint(slot, _t127Needle + 1),
        );
        expect(at, isNotNull);
        expect(
          at!.offset,
          _t127Needle + 1,
          reason: 'the glyph under the point',
        );
        expect(
          host.rowWordBoundary(
            _t127Rich,
            TextPosition(offset: _t127Needle + 2),
          ),
          TextRange(start: _t127Needle, end: _t127Needle + 'needle'.length),
          reason: 'the word holding the offset',
        );
        expect(
          host.rowWordBoundary(_t127Rich, const TextPosition(offset: 2)),
          const TextRange(start: 0, end: 'Middle'.length),
        );

        // A field row.
        final field = rowBoxesOf(tester, 0, 0).box as RenderEditable;
        final caret = field.getLocalRectForCaret(const TextPosition(offset: 8));
        final point = field.localToGlobal(
          Offset(caret.left + 1, caret.center.dy),
        );
        expect(host.rowPositionAt(0, point)!.offset, 8, reason: 'a field row');
        expect(
          host.rowWordBoundary(0, const TextPosition(offset: 8)),
          TextRange(start: 'Intro '.length, end: 'Intro paragraph'.length),
        );
      },
    );

    testWidgets(
      'a press on a row without a field changes nothing and a press on a field row hides its open toolbar',
      (tester) async {
        _t127PresentRichText(only: _t127Rich);
        final b = await pumpTable(tester, _t127Text);
        final host = rowsHostOf(tester);
        host.rowPressed(_t127Rich, 3);
        await tester.pump();
        expect(
          host.rowController(_t127Rich)!.text,
          '$_t127Middle1\n$_t127Middle2',
        );

        // A field row's toolbar is open; a press the pointer layer took on
        // the row closes it, as the row field's own tap would.
        await b.select(const TextSelection(baseOffset: 0, extentOffset: 5));
        final field = b.focusedField();
        expect(field.showToolbar(), isTrue, reason: 'the toolbar can open');
        await tester.pump();
        expect(field.selectionOverlay?.toolbarIsVisible, isTrue);

        host.rowPressed(0, 2);
        await tester.pump();

        expect(field.selectionOverlay?.toolbarIsVisible ?? false, isFalse);
      },
    );
  });

  group('spelling host over a RichText slot (verify)', () {
    Future<SpellFieldHost> pumpHost(
      WidgetTester tester,
      String text, {
      Key? scroll,
    }) async {
      final controller = TextEditingController(text: text);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                height: 300,
                child: SingleChildScrollView(
                  key: scroll,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 40),
                    child: SpellCheckField(
                      controller: controller,
                      child: RichText(
                        key: const ValueKey('t127-host-slot'),
                        text: TextSpan(
                          text: text,
                          style: const TextStyle(fontSize: 16, height: 1.5),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      return tester.state(find.byType(SpellCheckField)) as SpellFieldHost;
    }

    testWidgets(
      'the host of a RichText slot answers its extent, the band of the line holding an offset clamped to its text, and the scroll viewport',
      (tester) async {
        const text = 'first line\nsecond line\nthird line';
        const scroll = ValueKey('t127-host-scroll');
        final host = await pumpHost(tester, text, scroll: scroll);
        final slot = tester.renderObject<RenderParagraph>(
          find.byKey(const ValueKey('t127-host-slot')),
        );
        final top = slot.localToGlobal(Offset.zero).dy;
        final lines = RenderParagraphLineBoxes(slot).lines;
        expect(lines, hasLength(3), reason: 'three source lines');

        final extent = host.extent();
        expect(extent, isNotNull);
        expect(extent!.top, moreOrLessEquals(top), reason: 'extent top');
        expect(
          extent.bottom,
          moreOrLessEquals(top + slot.size.height),
          reason: 'extent bottom',
        );

        // Each offset's band lies on its own line.
        for (final (i, offset) in [(0, 2), (1, 14), (2, 26)]) {
          final band = host.extentAt(offset);
          expect(band, isNotNull, reason: 'offset $offset');
          expect(band!.top, moreOrLessEquals(top + lines[i].top, epsilon: 1.5));
          expect(
            band.bottom,
            moreOrLessEquals(top + lines[i].bottom, epsilon: 1.5),
          );
          expect(band.bottom, greaterThan(band.top));
        }

        // Clamped to the laid out text, both ways.
        final end = host.extentAt(text.length)!;
        final past = host.extentAt(text.length + 500)!;
        expect((past.top, past.bottom), (end.top, end.bottom), reason: 'past');
        final start = host.extentAt(0)!;
        final before = host.extentAt(-9)!;
        expect(
          (before.top, before.bottom),
          (start.top, start.bottom),
          reason: 'before',
        );
        expect(
          end.top,
          greaterThan(start.top),
          reason: 'end is on a later line',
        );

        // The viewport is the page's scrollable.
        final page = tester.renderObject<RenderBox>(find.byKey(scroll));
        final view = host.viewport();
        expect(view, isNotNull);
        final pageTop = page.localToGlobal(Offset.zero).dy;
        expect(view!.top, moreOrLessEquals(pageTop));
        expect(view.bottom, moreOrLessEquals(pageTop + page.size.height));
        expect(view.bottom - view.top, 300);
      },
    );

    testWidgets(
      'the host answers nothing once its field has left the tree and no viewport without a scrollable',
      (tester) async {
        final host = await pumpHost(tester, 'some text');
        expect(host.extent(), isNotNull);
        await tester.pumpWidget(const SizedBox());
        expect(host.extent(), isNull, reason: 'unmounted extent');
        expect(host.extentAt(2), isNull, reason: 'unmounted extentAt');

        final controller = TextEditingController(text: 'x');
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: SpellCheckField(
              controller: controller,
              child: const SizedBox(width: 20, height: 20),
            ),
          ),
        );
        final bare =
            tester.state(find.byType(SpellCheckField)) as SpellFieldHost;
        expect(bare.extent(), isNull, reason: 'no text slot');
        expect(bare.extentAt(0), isNull, reason: 'no text slot');
        expect(bare.viewport(), isNull, reason: 'no scrollable');
      },
    );

    testWidgets('the host of a field row clamps an offset to the field text', (
      tester,
    ) async {
      await pumpTable(tester, _t127Text);
      final controller = tester
          .widget<EditorRow>(_t127EditorRow(0, 0))
          .controller;
      final host =
          tester.state(
                find.byWidgetPredicate(
                  (w) =>
                      w is SpellCheckField &&
                      identical(w.controller, controller),
                ),
              )
              as SpellFieldHost;
      final end = host.extentAt(controller.text.length)!;
      final past = host.extentAt(controller.text.length + 500)!;
      expect((past.top, past.bottom), (end.top, end.bottom), reason: 'past');
      final start = host.extentAt(0)!;
      final before = host.extentAt(-9)!;
      expect(
        (before.top, before.bottom),
        (start.top, start.bottom),
        reason: 'before',
      );
    });
  });

  group('selection fill over a stale RichText slot (verify)', () {
    for (final (name, stale) in [
      (
        'the selection fill paints nothing while a RichText text slot still shows a shorter text than its row',
        'first',
      ),
      (
        'the selection fill paints nothing while a RichText text slot already shows a longer text than its row',
        '$_t127Middle1\n$_t127Middle2 and more words',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final host = await _t127PumpView(
          tester,
          text: _t127Text,
          richRowText: '$_t127Middle1\n$_t127Middle2',
          staleSlotText: stale,
        );
        final from = _t127Middle1.indexOf('first');
        host.select(
          TextSelection(
            baseOffset: _t127RichStart + from,
            extentOffset: _t127RichStart + from + 'first line'.length,
          ),
        );
        await tester.pump();

        final row = tester.renderObject<RenderBox>(
          find.byKey(ValueKey('editor-row-0-$_t127Rich')),
        );
        expect(
          row,
          isNot(
            paints..something((method, args) {
              if (method != #drawRect) return false;
              final paint = args[1] as Paint;
              return paint.color.toARGB32() == OmColors.selection.toARGB32();
            }),
          ),
          reason: 'a stale layout gets no selection fill',
        );
      });
    }
  });

  group('spelling controller geometry bounds (verify)', () {
    /// Registers one single-paragraph field per [fields] entry (its text
    /// and global extent), checks, and returns the checked paragraph texts.
    Future<List<Object?>> checkedOf(
      WidgetTester tester,
      Map<String, ({double top, double bottom})?> fields, {
      ({double top, double bottom})? window = (top: 0.0, bottom: 600.0),
    }) async {
      final service = FakeSpellingService();
      final container = ProviderContainer(
        overrides: [spellingServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      final checker = SpellCheckController(
        noteId: 't127-bounds',
        sink: _T127MapSink(),
        session: () => container.read(spellSessionProvider),
        service: () => service,
        flags: (spelling: true, grammar: false),
      );
      addTearDown(checker.dispose);
      for (final entry in fields.entries) {
        final controller = TextEditingController(text: entry.key);
        addTearDown(controller.dispose);
        final extent = entry.value;
        checker.addField(
          controller,
          _T127ValueHost(
            window: window,
            laidOut: extent != null,
            extentAtOf: (_) => extent ?? (top: 0.0, bottom: 0.0),
          ),
        );
      }
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 400));
      }
      return [for (final c in service.callsFor('check')) c.args['text']];
    }

    testWidgets(
      'a field is checked while its extent overlaps the band one screen around the viewport and not when it only touches it',
      (tester) async {
        // The viewport is 0..600, so the band is -600..1200.
        final checked = await checkedOf(tester, {
          'Touching the band end.': (top: 1200.0, bottom: 1223.0),
          'Inside the band end.': (top: 1199.0, bottom: 1210.0),
          'Touching the band start.': (top: -623.0, bottom: -600.0),
          'Inside the band start.': (top: -623.0, bottom: -599.0),
          'Never laid out.': null,
        });
        expect(checked.toSet(), {
          'Inside the band end.',
          'Inside the band start.',
        });
      },
    );

    testWidgets('a field is checked everywhere while no host has a viewport', (
      tester,
    ) async {
      final checked = await checkedOf(tester, {
        'Far below the screen.': (top: 9000.0, bottom: 9023.0),
      }, window: null);
      expect(checked, ['Far below the screen.']);
    });

    testWidgets(
      'a paragraph is checked while its host top and bottom overlap the band and not when it only touches it',
      (tester) async {
        const paras = [
          'Zero paragraph text.',
          'One paragraph text.',
          'Two paragraph text.',
          'Three paragraph text.',
        ];
        final text = paras.join('\n\n');
        final starts = <int>[];
        var at = 0;
        for (final p in paras) {
          starts.add(at);
          at += p.length + 2;
        }
        // (top, bottom) of each paragraph; the band is -600..1200.
        const bands = [
          (top: -700.0, bottom: -600.0), // ends where the band starts
          (top: -610.0, bottom: -599.0), // ends inside it
          (top: 1199.0, bottom: 1300.0), // starts inside it
          (top: 1200.0, bottom: 1300.0), // starts where it ends
        ];
        ({double top, double bottom}) bandOf(int offset) {
          var i = 0;
          for (var k = 0; k < starts.length; k++) {
            if (starts[k] <= offset) i = k;
          }
          return bands[i];
        }

        final service = FakeSpellingService();
        final container = ProviderContainer(
          overrides: [spellingServiceProvider.overrideWithValue(service)],
        );
        addTearDown(container.dispose);
        final checker = SpellCheckController(
          noteId: 't127-paras',
          sink: _T127MapSink(),
          session: () => container.read(spellSessionProvider),
          service: () => service,
          flags: (spelling: true, grammar: false),
        );
        addTearDown(checker.dispose);
        final controller = TextEditingController(text: text);
        addTearDown(controller.dispose);
        checker.addField(
          controller,
          _T127ValueHost(
            window: (top: 0.0, bottom: 600.0),
            extentAtOf: (o) => o > text.length ? bands.last : bandOf(o),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 400));
        }
        expect(
          {for (final c in service.callsFor('check')) c.args['text']},
          {paras[1], paras[2]},
        );
      },
    );

    testWidgets(
      'a host that cannot place an offset has every paragraph of a near field checked and none of a far field',
      (tester) async {
        final service = FakeSpellingService();
        final container = ProviderContainer(
          overrides: [spellingServiceProvider.overrideWithValue(service)],
        );
        addTearDown(container.dispose);
        final checker = SpellCheckController(
          noteId: 't127-unplaced',
          sink: _T127MapSink(),
          session: () => container.read(spellSessionProvider),
          service: () => service,
          flags: (spelling: true, grammar: false),
        );
        addTearDown(checker.dispose);
        const window = (top: 0.0, bottom: 600.0);
        final near = TextEditingController(
          text: 'Near first paragraph.\n\nNear second paragraph.',
        );
        final far = TextEditingController(text: 'Far unplaced paragraph.');
        addTearDown(near.dispose);
        addTearDown(far.dispose);
        checker.addField(
          near,
          _T127ValueHost(
            window: window,
            placesOffsets: false,
            extentAtOf: (o) => o == 0
                ? (top: 100.0, bottom: 110.0)
                : (top: 100.0, bottom: 300.0),
          ),
        );
        checker.addField(
          far,
          _T127ValueHost(
            window: window,
            placesOffsets: false,
            extentAtOf: (_) => (top: 5000.0, bottom: 5100.0),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 400));
        }
        expect(
          {for (final c in service.callsFor('check')) c.args['text']},
          {'Near first paragraph.', 'Near second paragraph.'},
        );
      },
    );

    testWidgets(
      'the controller asks a host only for offsets inside the field text, also for a field text after a block marker',
      (tester) async {
        final service = FakeSpellingService();
        final container = ProviderContainer(
          overrides: [spellingServiceProvider.overrideWithValue(service)],
        );
        addTearDown(container.dispose);
        final checker = SpellCheckController(
          noteId: 't127-clamp',
          sink: _T127MapSink(),
          session: () => container.read(spellSessionProvider),
          service: () => service,
          flags: (spelling: true, grammar: false),
        );
        addTearDown(checker.dispose);
        const body = 'Item paragraph text.';
        final controller = TextEditingController(text: body);
        addTearDown(controller.dispose);
        final host = _T127ValueHost(
          window: (top: 0.0, bottom: 600.0),
          base: 2,
          extentAtOf: (_) => (top: 100.0, bottom: 120.0),
        );
        checker.addField(controller, host);
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 400));
        }
        expect(host.asked, isNotEmpty, reason: 'the near field was measured');
        for (final offset in host.asked) {
          expect(offset, inInclusiveRange(0, body.length));
        }
        expect(host.asked, contains(0), reason: 'the marker clamps to 0');
        expect(
          [for (final c in service.callsFor('check')) c.args['text']],
          ['--$body'],
          reason: 'the paragraph holds the block marker',
        );
      },
    );

    testWidgets(
      'the next issue starts from the field with the smallest top, a field not laid out comes last and equal tops keep the joining order',
      (tester) async {
        Future<List<String>> firstIssueField(
          List<(String, ({double top, double bottom})?)> joined,
        ) async {
          final service = FakeSpellingService()
            ..misspell('teh', corrections: const ['the']);
          final container = ProviderContainer(
            overrides: [spellingServiceProvider.overrideWithValue(service)],
          );
          final checker = SpellCheckController(
            noteId: 't127-order',
            sink: _T127MapSink(),
            session: () => container.read(spellSessionProvider),
            service: () => service,
            flags: (spelling: true, grammar: false),
          );
          final controllers = <String, TextEditingController>{};
          for (final (name, extent) in joined) {
            final c = TextEditingController(text: '$name has a teh typo.');
            controllers[name] = c;
            checker.addField(
              c,
              _T127ValueHost(
                window: null,
                laidOut: extent != null,
                extentAtOf: (_) => extent ?? (top: 0.0, bottom: 0.0),
              ),
            );
          }
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 400));
          }
          final next = checker.nextIssue();
          final names = [
            for (final e in controllers.entries)
              if (identical(e.value, next?.field)) e.key,
          ];
          checker.dispose();
          container.dispose();
          for (final c in controllers.values) {
            c.dispose();
          }
          return names;
        }

        expect(
          await firstIssueField([
            ('low', (top: 300.0, bottom: 320.0)),
            ('high', (top: 100.0, bottom: 120.0)),
            ('mid', (top: 200.0, bottom: 220.0)),
          ]),
          ['high'],
          reason: 'the smallest top first, whatever the joining order',
        );
        expect(
          await firstIssueField([
            ('unlaid first', null),
            ('laid', (top: 500.0, bottom: 520.0)),
          ]),
          ['laid'],
          reason: 'a field not laid out goes after a laid out one',
        );
        expect(
          await firstIssueField([
            ('laid', (top: 500.0, bottom: 520.0)),
            ('unlaid last', null),
          ]),
          ['laid'],
          reason: 'a laid out field is first, whichever side it is on',
        );
        expect(
          await firstIssueField([
            ('first joined', (top: 100.0, bottom: 120.0)),
            ('second joined', (top: 100.0, bottom: 120.0)),
          ]),
          ['first joined'],
          reason: 'equal tops keep the joining order',
        );
        expect(
          await firstIssueField([('unlaid a', null), ('unlaid b', null)]),
          ['unlaid a'],
          reason: 'fields not laid out keep the joining order',
        );
      },
    );
  });

  group('item rows and long slots (verify r1)', () {
    testWidgets(
      'a numbered item row with a RichText text slot measures its text and not its marker',
      (tester) async {
        debugRowKindPresenterOverride = (kind) => markerColumnKind(kind) != null
            ? const _T127ItemRichPresenter()
            : null;
        const text = '1. first item\n2. second item\nOutro line';
        final b = await pumpTable(tester, text);
        final host = rowsHostOf(tester);
        for (final r in [0, 1]) {
          final spec = host.rowSpec(r)!;
          expect(spec.textStart, greaterThan(spec.start), reason: 'marker $r');
          final slot = _t127Slot(tester, 0, r);
          final row = host.rowBoxes(r);
          expect(row, isNotNull, reason: 'row $r reports geometry');
          expect(row!.box, same(slot), reason: 'row $r measures its slot');
          expect(
            row.lines.last.range.end,
            spec.textLength,
            reason: 'row $r lines span its text, not the marker',
          );
          expect(
            _t127Lines(row),
            _t127Lines(RenderParagraphLineBoxes(slot)),
            reason: 'row $r',
          );
        }
        expect(host.lineBoxes(), isNotNull, reason: 'no row disables it');

        // A click on the item's text lands in it, at the glyph's offset.
        final slot = _t127Slot(tester, 0, 1);
        final spec = host.rowSpec(1)!;
        await _t127Click(tester, _t127GlyphPoint(slot, 4));
        expect(
          b.selection(),
          TextSelection.collapsed(offset: spec.toSegment(4)),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'the text slot lookup skips a marker column text and finds the text after it',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Row(
                key: const ValueKey('t127-root'),
                children: [
                  const MarkerColumn(marker: '1. ', width: 30),
                  Expanded(
                    child: RichText(
                      key: const ValueKey('t127-after'),
                      text: const TextSpan(text: 'item text'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        final root = tester.renderObject(
          find.byKey(const ValueKey('t127-root')),
        );
        expect(
          textSlotBox(root),
          same(tester.renderObject(find.byKey(const ValueKey('t127-after')))),
        );
        expect(
          find.descendant(
            of: find.byType(MarkerColumn),
            matching: find.byType(RichText),
          ),
          findsOneWidget,
          reason: 'the marker column shows its number as text',
        );
        final marker = tester.renderObject(find.byType(MarkerColumn));
        expect(
          textSlotBox(marker),
          isNull,
          reason: 'a marker column holds no row text',
        );
      },
    );

    Future<SpellFieldHost> pumpSpan(
      WidgetTester tester,
      TextEditingController controller,
      InlineSpan span,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                child: SingleChildScrollView(
                  child: SpellCheckField(
                    controller: controller,
                    child: RichText(text: span),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      return tester.state(find.byType(SpellCheckField)) as SpellFieldHost;
    }

    testWidgets(
      'extentAt over a long RichText slot copies no plain text and walks its span once however many probes',
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        final span = _T127CountingSpan(
          text: List.filled(400, 'long prose line of the row').join(' '),
          children: [const TextSpan(text: ' tail')],
          style: const TextStyle(fontSize: 14),
        );
        final host = await pumpSpan(tester, controller, span);
        expect(host.extent(), isNotNull);
        final length = span.toPlainText().length;
        _T127CountingSpan.copies = 0;
        _T127CountingSpan.walks = 0;
        final bands = <({double top, double bottom})>[];
        for (var i = 0; i < 40; i++) {
          bands.add(host.extentAt(i * length ~/ 39)!);
        }
        // The text painter copies the text once itself (end-of-text caret
        // metrics, cached per layout); a copy per probe would be 40.
        expect(
          _T127CountingSpan.copies,
          lessThanOrEqualTo(1),
          reason: 'no copy of the text per probe',
        );
        expect(
          _T127CountingSpan.walks,
          lessThanOrEqualTo(1),
          reason: 'the span is measured once, not per probe',
        );
        for (var i = 1; i < bands.length; i++) {
          expect(
            bands[i].top,
            greaterThanOrEqualTo(bands[i - 1].top),
            reason: 'probe $i is not above the previous',
          );
        }
        expect(bands.last.top, greaterThan(bands.first.top));
        final past = host.extentAt(length + 9999)!;
        expect((past.top, past.bottom), (bands.last.top, bands.last.bottom));
      },
    );

    testWidgets(
      'the clamp of a RichText slot counts a placeholder as one character and measures a replaced span anew',
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        // a b [] c \n: five characters, then an empty last line.
        var host = await pumpSpan(
          tester,
          controller,
          const TextSpan(
            style: TextStyle(fontSize: 14, height: 1.5),
            children: [
              TextSpan(text: 'ab'),
              WidgetSpan(child: SizedBox(width: 10, height: 10)),
              TextSpan(text: 'c\n'),
            ],
          ),
        );
        final first = host.extentAt(0)!;
        final end = host.extentAt(5)!;
        expect(end.top, greaterThan(first.top), reason: 'end is on line 2');
        final past = host.extentAt(500)!;
        expect((past.top, past.bottom), (end.top, end.bottom));

        // The same host over another span: its own length, not the cached.
        host = await pumpSpan(
          tester,
          controller,
          const TextSpan(
            text: 'x\ny\nz\n',
            style: TextStyle(fontSize: 14, height: 1.5),
          ),
        );
        final lastText = host.extentAt(4)!;
        final lastLine = host.extentAt(6)!;
        expect(lastLine.top, greaterThan(lastText.top), reason: 'line 4');
        expect(host.extentAt(600)!.top, lastLine.top);
      },
    );
  });
}
