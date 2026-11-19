// WI #128 (Spec #122 Req 30, TD5; rulings D5, D11): the segment's pointer
// layer owns every press, click chain and right-click on an editor row that
// has no field, so a row whose text slot is a `RichText` behaves as main's
// field rows do: a click puts the caret at the pressed offset and makes the
// row the active row; double and triple clicks select a word and a line; a
// drag selects across rows and Shift+click extends, both keeping focus in
// the row the selection started from; a right-click opens the spelling menu
// on a flagged word and the text context menu elsewhere (its Paste through
// `PasteTextIntent`); Cmd+click follows a wikilink and hovering a link shows
// its hover style and the click cursor; a task checkbox toggles once; and
// Check Document Now lands on a misspelling in such a row.
//
// The test-only idle row (never the real one, #132): a row presenter
// (#124's seam, `debugRowKindPresenterOverride`) that builds a row's text
// slot as a `RichText` of the span the row's own `LivePreviewController`
// builds, at the field's style, strut and layout width (#127's slot), joined
// to the editor's spell checks (`SpellCheckField`), with the item marker
// column of an item row. The row has no field and its focus node is
// attached nowhere, as an idle row's is (TD5). Only while the rows host
// reports it as its active row (`SegmentViewState.activeRow`, the host's
// activation request) does the presenter build the row's real text slot,
// its field, in its place, as #132's active row will. Row 5 of [_t128Body]
// always has its field: the row focus starts in.
//
// Every test pumps the real note editor through `pumpSpellingEditor` (a
// FakeSpellingService, a fake macOS pasteboard) under macOS ([macOnly]).
// Row geometry goes through `editor_rows_probe.dart`; glyph points come from
// the idle slot's own `RenderParagraph`, read before the press.
//
// Helpers carry the `_t128` prefix so stacked siblings never collide. Text
// is synthetic (public repo).
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/row_geometry.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/widgets/editor/editor_row.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/marker_column.dart';
import 'package:open_memex_app/src/widgets/editor/row_kinds.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/spell_check_host.dart';
import 'package:open_memex_app/src/widgets/editor/spelling_menu.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';

import '../../support/app_harness.dart';
import '../../support/editor_rows_probe.dart';
import '../../support/fake_spelling_service.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import '../../support/wi438_spelling_menu.dart';

// ------------------------------------------------------------------ text

/// Row 0: a prose row with the misspelling `teh`.
const _t128Prose = 'Alpha prose line with teh typo and plain words';

/// Row 1: a bullet row with the misspelling `wrld`.
const _t128Bullet = '- bullet item wrld here';

/// Row 2: an open task row.
const _t128Task = '- [ ] task item text';

/// Row 3: a quote row.
const _t128Quote = '> quote line text';

/// Row 4: a prose row holding one heading line.
const _t128Heading = '# Heading line text';

/// Row 5: a bullet row that always has its field (where focus starts).
const _t128Anchor = '- field anchor words';

/// Row 6: a prose row with the misspelling `smal` and a wikilink to the
/// fixture vault's `Other note`.
const _t128Omega = 'Omega smal line with [[Other note]] link';

/// Rows: 0 prose, 1 bullet, 2 task, 3 quote, 4 prose (heading), 5 bullet
/// (field), 6 prose.
const _t128Body =
    '$_t128Prose\n'
    '$_t128Bullet\n'
    '$_t128Task\n'
    '$_t128Quote\n'
    '$_t128Heading\n'
    '$_t128Anchor\n'
    '$_t128Omega\n';

/// The row that always has its field.
const _t128FieldRow = 5;

/// The fixture vault's note `Other note` (`seedSegmentedVault`).
const _t128OtherId = 'topic-other';

/// The checker of every test: three misspellings, each with its own
/// guesses.
FakeSpellingService _t128Spelling() => FakeSpellingService()
  ..misspell('teh', corrections: const ['the', 'tea'])
  ..misspell('wrld', corrections: const ['world'])
  ..misspell('smal', corrections: const ['small']);

// ------------------------------------------------------------- idle slot

/// Key of the test-only RichText text slot of row [r] of segment [s].
Key _t128SlotKey(int s, int r) => ValueKey('t128-idle-slot-$s-$r');

/// RenderEditable's caret margin in a `TextField` (cursor width 2 plus its
/// 1 px caret gap): the field lays its text out this much narrower.
const double _t128CaretMargin = 3;

/// The test-only idle text: a `RichText` (Key [slotKey]) of the span
/// [controller] builds for its selection and reveal state, at the editor
/// field's merged style, strut and text scaler, rebuilt when the controller
/// or its reveal gate changes (#127's slot).
class _T128SlotText extends StatelessWidget {
  const _T128SlotText({required this.controller, required this.slotKey});

  final LivePreviewController controller;
  final Key slotKey;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: _t128CaretMargin),
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

/// The test-only idle row presenter: every row but [_t128FieldRow] builds
/// [_T128SlotText] (joined to the spell checks, under the text slot's Key
/// `editor-row-<s>-<r>`) in place of its field, and its marker column when
/// it is an item row; while the rows host's `activeRow` is the row, it
/// builds the row's real text slot (its field) instead. It hides no text,
/// measures no block and owns no press.
class _T128IdlePresenter extends RowKindPresenter {
  const _T128IdlePresenter();

  @override
  Widget build(BuildContext context, PresentedRow row, RowTextSlot textSlot) {
    if (row.index == _t128FieldRow) {
      return const TextRowPresenter().build(context, row, textSlot);
    }
    final host = context.findAncestorStateOfType<SegmentViewState>();
    Widget idle() => KeyedSubtree(
      key: ValueKey('editor-row-${row.segment}-${row.index}'),
      child: SpellCheckField(
        controller: row.controller,
        child: _T128SlotText(
          controller: row.controller,
          slotKey: _t128SlotKey(row.segment, row.index),
        ),
      ),
    );
    final Widget slot = host == null
        ? idle()
        : ValueListenableBuilder<int?>(
            valueListenable: host.activeRow,
            builder: (context, active, _) =>
                active == row.index ? textSlot(offstage: false) : idle(),
          );
    final item = row.geometry;
    final column = markerColumnKind(row.kind);
    if (item == null || column == null) return slot;
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
              child: slot,
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

/// [_T128IdlePresenter] whose row [owned] owns every press inside its
/// rect (D5: a presenter's `ownsPress` wins).
class _T128OwningPresenter extends _T128IdlePresenter {
  const _T128OwningPresenter(this.owned);

  final int owned;

  @override
  bool ownsPress(PresentedRow row, Offset position) => row.index == owned;
}

// ---------------------------------------------------------------- harness

/// One pumped note editor on [_t128Body] with the idle presenter.
class _T128Editor {
  _T128Editor(this.w);

  final Wi438Editor w;

  WidgetTester get tester => w.tester;
  SegmentViewState get host => rowsHostOf(tester);
  String get body => w.body;

  RowSpec spec(int r) => host.rowSpec(r)!;

  /// The laid-out idle slot of row [r].
  RenderParagraph slot(int r) {
    final finder = find.byKey(_t128SlotKey(0, r));
    if (finder.evaluate().isEmpty) {
      throw TestFailure('row $r shows no idle RichText slot');
    }
    return tester.renderObject<RenderParagraph>(finder);
  }

  /// Row-local offset of [word] in row [r]'s text.
  int local(int r, String word) {
    final text = rowTextOf(tester, 0, r);
    final i = text.indexOf(word);
    if (i < 0) throw TestFailure('"$word" is not in row $r: "$text"');
    return i;
  }

  /// Segment offset of [word] in row [r].
  int at(int r, String word) => spec(r).textStart + local(r, word);

  /// The segment range of [word] in row [r].
  TextRange range(int r, String word) {
    final start = at(r, word);
    return TextRange(start: start, end: start + word.length);
  }

  /// The global rect of row-local [start]..[end] (one line) in row [r]'s
  /// idle slot.
  Rect glyphs(int r, int start, int end) {
    final p = slot(r);
    final boxes = p.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
    );
    if (boxes.isEmpty) throw TestFailure('no glyph boxes for $start..$end');
    final first = boxes.first;
    final right = p
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
      p.localToGlobal(rect.topLeft),
      p.localToGlobal(rect.bottomRight),
    );
  }

  /// A global point in the left quarter of the glyph at row-local [offset]
  /// of row [r]'s idle slot, so the nearest offset is [offset].
  Offset glyphPoint(int r, int offset) {
    final g = glyphs(r, offset, offset + 1);
    return Offset(g.left + math.min(2.0, g.width / 4), g.center.dy);
  }

  /// A point inside [word]'s first glyphs (its second character) in row
  /// [r]'s idle slot.
  Offset wordPoint(int r, String word) => glyphPoint(r, local(r, word) + 1);

  /// The segment offset the row accessor resolves at global [point] in row
  /// [r] now (`offsetAt` of `SegmentViewState.rowBoxes`).
  int offsetAt(int r, Offset point) {
    final boxes = rowBoxesOf(tester, 0, r);
    return spec(r).textStart + boxes.offsetAt(boxes.box.globalToLocal(point));
  }

  /// Focuses the field row ([_t128FieldRow]) with the caret at its row
  /// offset [offset].
  Future<void> focusFieldRow({int offset = 2}) async {
    await activateRow(tester, 0, _t128FieldRow, offset: offset);
    await pumpFrames(tester);
  }

  /// The rows host's active row.
  int? get active => host.activeRow.value;

  /// The row holding focus.
  int? get focused => host.focusedRow;

  TextRange get selected =>
      TextRange(start: host.selection.start, end: host.selection.end);
}

Future<_T128Editor> _t128Pump(
  WidgetTester tester, {
  Wi438Actions? actions,
  RowKindPresenter presenter = const _T128IdlePresenter(),
}) async {
  debugRowKindPresenterOverride = (kind) =>
      kind == RowKind.table ? null : presenter;
  addTearDown(() => debugRowKindPresenterOverride = null);
  final w = await wi438Pump(
    tester,
    body: _t128Body,
    spelling: _t128Spelling(),
    actions: actions,
  );
  final e = _T128Editor(w);
  // Every row but the field row is idle: no field under it.
  for (var r = 0; r < e.host.rowCount; r++) {
    if (r == _t128FieldRow) continue;
    e.slot(r);
  }
  return e;
}

// ------------------------------------------------------------- gestures

/// A primary-button mouse click at [at] (global), then lets any click chain
/// expire.
Future<void> _t128Click(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kPrimaryButton,
  );
  await tester.pump();
  await gesture.up();
  await pumpFrames(tester);
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
}

/// [count] primary-button mouse clicks at [at] (global) inside one click
/// chain, then lets the chain expire.
Future<void> _t128Clicks(WidgetTester tester, Offset at, int count) async {
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
  await pumpFrames(tester);
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
}

/// Two primary-button mouse clicks at [at] (global) in the same frame (no
/// pump between them), then pumps.
Future<void> _t128SameFrameClicks(WidgetTester tester, Offset at) async {
  for (var i = 0; i < 2; i++) {
    final gesture = await tester.startGesture(
      at,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryButton,
    );
    await gesture.up();
  }
  await pumpFrames(tester);
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
}

/// A primary-button mouse drag from [from] to [to] (global) in [steps]
/// moves; [during] runs before the release.
Future<void> _t128Drag(
  WidgetTester tester,
  Offset from,
  Offset to, {
  int steps = 6,
  void Function()? during,
}) async {
  final mouse = await tester.startGesture(
    from,
    kind: PointerDeviceKind.mouse,
    buttons: kPrimaryButton,
  );
  await tester.pump();
  for (var i = 1; i <= steps; i++) {
    await mouse.moveTo(Offset.lerp(from, to, i / steps)!);
    await tester.pump();
  }
  during?.call();
  await mouse.up();
  await pumpFrames(tester);
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
}

/// The texts of the text context menu (the field default menu on macOS),
/// top to bottom.
List<String> _t128DefaultMenuLabels(WidgetTester tester) {
  final entries = <(Offset, String)>[];
  for (final e
      in find
          .descendant(of: wi438DefaultMenu, matching: find.byType(RichText))
          .evaluate()) {
    final box = e.renderObject! as RenderBox;
    entries.add((
      box.localToGlobal(Offset.zero),
      (e.widget as RichText).text.toPlainText(),
    ));
  }
  entries.sort((a, b) {
    final dy = a.$1.dy.compareTo(b.$1.dy);
    return dy != 0 ? dy : a.$1.dx.compareTo(b.$1.dx);
  });
  return [for (final e in entries) e.$2];
}

/// The mouse cursor the mouse device shows now.
MouseCursor? _t128Cursor() =>
    RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);

// ------------------------------------------------------------------ tests

void main() {
  holdFontFetches();

  tearDown(() => debugRowKindPresenterOverride = null);

  // -------------------------------------------------------------------------
  // AC1: a click places the caret at offsetAt(point) and activates the row
  // -------------------------------------------------------------------------
  group('a click on a row without a field (AC1)', () {
    for (final (name, row, word) in [
      (
        'a click on a prose row without a field puts the caret at offsetAt and makes it the focused active row',
        0,
        'typo',
      ),
      (
        'a click on an item row without a field puts the caret at offsetAt and makes it the focused active row',
        1,
        'item',
      ),
      (
        'a click on a task row without a field puts the caret at offsetAt and makes it the focused active row',
        2,
        'item',
      ),
      (
        'a click on a quote row without a field puts the caret at offsetAt and makes it the focused active row',
        3,
        'line',
      ),
      (
        'a click on a heading row without a field puts the caret at offsetAt and makes it the focused active row',
        4,
        'line',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        expect(e.focused, _t128FieldRow, reason: 'focus starts in the field');
        final point = e.glyphPoint(row, e.local(row, word) + 2);
        final expected = e.offsetAt(row, point);
        expect(
          expected,
          e.at(row, word) + 2,
          reason: 'fixture: the point lies on that glyph',
        );

        await _t128Click(tester, point);

        expect(
          e.host.selection,
          TextSelection.collapsed(offset: expected),
          reason: 'the caret goes to offsetAt(point)',
        );
        expect(e.focused, row, reason: 'focus moved to the clicked row');
        expect(e.active, row, reason: 'the clicked row is the active row');
        expect(
          e.host.widget.focusNode.hasFocus,
          isTrue,
          reason: 'the segment keeps focus',
        );
      }, variant: macOnly);
    }

    testWidgets(
      'a click on a row without a field while nothing has focus focuses that row with the caret at the click',
      (tester) async {
        final e = await _t128Pump(tester);
        expect(e.focused, isNull, reason: 'fixture: nothing focused');
        final point = e.wordPoint(6, 'line');
        final expected = e.offsetAt(6, point);

        await _t128Click(tester, point);

        expect(e.host.selection, TextSelection.collapsed(offset: expected));
        expect(e.focused, 6);
        expect(e.active, 6);
      },
      variant: macOnly,
    );

    testWidgets(
      'two clicks in the same frame on a row without a field select the word once and make the row active',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();

        await _t128SameFrameClicks(tester, e.wordPoint(0, 'plain'));

        expect(e.selected, e.range(0, 'plain'));
        expect(e.focused, 0);
        expect(e.active, 0);
      },
      variant: macOnly,
    );

    testWidgets(
      'a click on a row without a field leaves the other rows without a field idle',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();

        await _t128Click(tester, e.wordPoint(3, 'quote'));
        expect(e.focused, 3);
        // Then another row: it becomes the active row in turn.
        await _t128Click(tester, e.wordPoint(0, 'prose'));

        expect(e.focused, 0);
        expect(e.active, 0);
        expect(
          find.byKey(_t128SlotKey(0, 3)),
          findsOneWidget,
          reason: 'the quote row is idle again',
        );
      },
      variant: macOnly,
    );
    testWidgets(
      'a Cmd+click on plain text of a row without a field puts the caret there and makes it the focused active row as on a field',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        // On the field row: a Cmd+click off a link is a plain click there.
        final fieldAt = e.w.at('field anchor', 'words') + 1;
        await tester.macHolding([
          LogicalKeyboardKey.metaLeft,
        ], () => _t128Click(tester, e.w.caretPoint('field anchor', fieldAt)));
        expect(
          e.host.selection,
          TextSelection.collapsed(
            offset: e.spec(_t128FieldRow).textStart + fieldAt,
          ),
          reason: 'fixture: main field moves its caret on a Cmd+click',
        );
        final point = e.wordPoint(0, 'plain');
        final expected = e.offsetAt(0, point);

        await tester.macHolding([
          LogicalKeyboardKey.metaLeft,
        ], () => _t128Click(tester, point));

        expect(e.host.selection, TextSelection.collapsed(offset: expected));
        expect(e.focused, 0);
        expect(e.active, 0);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC2: double and triple clicks select a word and a line
  // -------------------------------------------------------------------------
  group('double and triple clicks on a row without a field (AC2)', () {
    /// Focus in the field row with a selection from inside it back to the
    /// heading row's start, so the heading row's line is revealed while the
    /// row has no field.
    Future<_T128Editor> revealedHeading(WidgetTester tester) async {
      final e = await _t128Pump(tester);
      await e.focusFieldRow();
      e.host.select(
        TextSelection(
          baseOffset: e.spec(_t128FieldRow).textStart + 2,
          extentOffset: e.spec(4).start,
        ),
      );
      await pumpFrames(tester);
      expect(e.focused, _t128FieldRow, reason: 'fixture: focus stays');
      expect(
        rowTextOf(tester, 0, 4),
        _t128Heading,
        reason: 'fixture: the heading row',
      );
      // Collapse the selection onto the heading row's line, keeping it
      // revealed, without moving focus.
      e.host.select(TextSelection.collapsed(offset: e.spec(4).textStart + 3));
      await pumpFrames(tester);
      return e;
    }

    testWidgets(
      'a double click on a revealed line of a row without a field selects the word under the pointer',
      (tester) async {
        final e = await revealedHeading(tester);

        await _t128Clicks(tester, e.wordPoint(4, 'line'), 2);

        expect(e.selected, e.range(4, 'line'));
        expect(e.focused, 4);
        expect(e.active, 4);
      },
      variant: macOnly,
    );

    testWidgets(
      'a triple click on a revealed line of a row without a field selects its line',
      (tester) async {
        final e = await revealedHeading(tester);

        await _t128Clicks(tester, e.wordPoint(4, 'line'), 3);

        expect(
          e.selected,
          TextRange(start: e.spec(4).textStart, end: e.spec(4).textEnd),
          reason: 'the whole line, as the field selects its paragraph',
        );
        expect(e.focused, 4);
        expect(e.active, 4);
      },
      variant: macOnly,
    );

    testWidgets(
      'a double click on the line holding the caret in a row without a field selects the word under the pointer',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        // A row without a field whose line holds the caret (placed by code,
        // focus still in the field row), so its markup shows.
        e.host.select(TextSelection.collapsed(offset: e.at(3, 'line')));
        await pumpFrames(tester);

        await _t128Clicks(tester, e.wordPoint(3, 'quote'), 2);

        expect(e.selected, e.range(3, 'quote'));
        expect(e.focused, 3);
        expect(e.active, 3);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC3: a drag selects across rows; focus stays in the starting row
  // -------------------------------------------------------------------------
  group('a drag from a row without a field (AC3)', () {
    testWidgets(
      'a drag from a row without a field into another selects the range between and focus stays in the starting row',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        final from = e.wordPoint(0, 'prose');
        final to = e.wordPoint(3, 'line');
        final base = e.offsetAt(0, from);
        final extent = e.offsetAt(3, to);
        int? focusedMidDrag;

        await _t128Drag(
          tester,
          from,
          to,
          during: () => focusedMidDrag = e.focused,
        );

        expect(
          e.host.selection,
          TextSelection(baseOffset: base, extentOffset: extent),
        );
        expect(focusedMidDrag, 0, reason: 'focus is in the starting row');
        expect(e.focused, 0, reason: 'and stays there');
        expect(e.active, 0);
      },
      variant: macOnly,
    );

    testWidgets(
      'a drag upward from a row without a field selects backward and focus stays in the starting row',
      (tester) async {
        final e = await _t128Pump(tester);
        final from = e.wordPoint(6, 'line');
        final to = e.wordPoint(1, 'item');
        final base = e.offsetAt(6, from);
        final extent = e.offsetAt(1, to);

        await _t128Drag(tester, from, to);

        expect(
          e.host.selection,
          TextSelection(baseOffset: base, extentOffset: extent),
        );
        expect(e.focused, 6);
        expect(e.active, 6);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC4: Shift+click extends; focus stays where it was
  // -------------------------------------------------------------------------
  group('Shift+click (AC4)', () {
    testWidgets(
      'Shift+click on a row without a field extends the selection to the clicked offset and focus stays in the row it started from',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        final start = e.wordPoint(0, 'typo');
        final base = e.offsetAt(0, start);
        await _t128Click(tester, start);
        expect(e.focused, 0, reason: 'the first click focused row 0');
        final end = e.wordPoint(3, 'text');
        final extent = e.offsetAt(3, end);

        await tester.macHolding([
          LogicalKeyboardKey.shiftLeft,
        ], () => _t128Click(tester, end));

        expect(
          e.host.selection,
          TextSelection(baseOffset: base, extentOffset: extent),
        );
        expect(e.focused, 0, reason: 'focus stays in row 0');
        expect(e.active, 0);
        expect(
          find.byKey(_t128SlotKey(0, 3)),
          findsOneWidget,
          reason: 'the Shift+clicked row stays idle',
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'Shift+click on the field row after a click on a row without a field extends the selection backward and focus stays in the clicked row',
      (tester) async {
        final e = await _t128Pump(tester);
        final start = e.wordPoint(6, 'line');
        final base = e.offsetAt(6, start);
        await _t128Click(tester, start);
        expect(e.focused, 6, reason: 'the first click focused row 6');
        final end = e.w.glyphPoint(
          'field anchor',
          e.w.at('field anchor', 'anchor') + 1,
        );
        final extent =
            e.spec(_t128FieldRow).textStart +
            e.w.at('field anchor', 'anchor') +
            1;

        await tester.macHolding([
          LogicalKeyboardKey.shiftLeft,
        ], () => _t128Click(tester, end));

        expect(
          e.host.selection,
          TextSelection(baseOffset: base, extentOffset: extent),
        );
        expect(e.focused, 6, reason: 'focus stays where it was');
        expect(e.active, 6);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC5: right-click on a flagged word opens the spelling menu
  // -------------------------------------------------------------------------
  group('right-click on a flagged word of a row without a field (AC5)', () {
    testWidgets(
      'a right click on a flagged word of a row without a field opens the spelling menu with its guesses Learn and Ignore',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();

        await wi438RightClick(tester, e.wordPoint(0, 'teh'));

        expect(wi438Menu, findsOneWidget, reason: 'the spelling menu opens');
        expect(wi438Labels(tester).take(4), [
          'the',
          'tea',
          'Learn Spelling',
          'Ignore Spelling',
        ]);
        expect(e.active, 0, reason: 'the row the menu acts on is active');
      },
      variant: macOnly,
    );

    testWidgets(
      'choosing a guess in the spelling menu of a row without a field replaces that word',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        final before = e.body;
        final teh = e.at(0, 'teh');

        await wi438RightClick(tester, e.wordPoint(0, 'teh'));
        expect(wi438Menu, findsOneWidget, reason: 'the spelling menu opens');
        await e.w.choose('the');

        expect(e.body, before.replaceRange(teh, teh + 3, 'the'));
        expect(wi438Menu, findsNothing, reason: 'the menu closed');
        expect(
          e.host.selection,
          TextSelection.collapsed(offset: teh + 3),
          reason: 'the caret goes after the replacement',
        );
        expect(e.active, 0);
        expect(e.focused, 0, reason: 'focus returns to the row');
      },
      variant: macOnly,
    );

    testWidgets(
      'a right click on a flagged word of an item row without a field opens its menu and Learn Spelling learns that word',
      (tester) async {
        final actions = Wi438Actions(result: true);
        final e = await _t128Pump(tester, actions: actions);
        await e.focusFieldRow();

        await wi438RightClick(tester, e.wordPoint(1, 'wrld'));
        expect(wi438Menu, findsOneWidget, reason: 'the spelling menu opens');
        expect(wi438Labels(tester).take(3), [
          'world',
          'Learn Spelling',
          'Ignore Spelling',
        ]);
        expect(e.active, 1);
        await e.w.choose('Learn Spelling');

        expect(actions.learned, ['wrld']);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC6: right-click on plain text opens the standard text context menu
  // -------------------------------------------------------------------------
  group('right-click on plain text of a row without a field (AC6)', () {
    testWidgets(
      'a right click on plain text of a row without a field opens the field text context menu with the same items',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        // Main's field menu for a right click on a plain word.
        final fieldWord = e.w.glyphPoint(
          'field anchor',
          e.w.at('field anchor', 'anchor') + 1,
        );
        await wi438RightClick(tester, fieldWord);
        expect(wi438DefaultMenu, findsOneWidget, reason: 'fixture: main menu');
        expect(
          e.selected,
          e.range(_t128FieldRow, 'anchor'),
          reason: 'fixture: main selects the right-clicked word',
        );
        final expected = _t128DefaultMenuLabels(tester);
        expect(expected, contains('Paste'), reason: 'fixture: main menu');
        ContextMenuController.removeAny();
        await pumpFrames(tester);

        await wi438RightClick(tester, e.wordPoint(0, 'plain'));

        expect(wi438DefaultMenu, findsOneWidget);
        expect(wi438Menu, findsNothing, reason: 'not the spelling menu');
        expect(_t128DefaultMenuLabels(tester), expected);
        expect(
          e.selected,
          e.range(0, 'plain'),
          reason: 'the right-clicked word is selected, as in a field',
        );
        expect(e.active, 0, reason: 'the row the menu acts on is active');
      },
      variant: macOnly,
    );

    testWidgets(
      'Paste in the text context menu of a row without a field pastes the text clipboard once',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        final before = e.body;

        await wi438RightClick(tester, e.wordPoint(0, 'plain'));
        expect(wi438DefaultMenu, findsOneWidget);
        final selection = e.host.selection;
        expect(
          selection.start,
          inInclusiveRange(e.at(0, 'plain'), e.at(0, 'plain') + 5),
          reason: 'the menu acts on the clicked word',
        );
        await tester.tap(
          find.descendant(
            of: wi438DefaultMenu,
            matching: wi438AnyText('Paste'),
          ),
        );
        await pumpFrames(tester);

        expect(
          e.body,
          before.replaceRange(selection.start, selection.end, wi438Clip),
          reason: 'one text paste over the selection the menu acted on',
        );
        expect(
          wi438Clip.allMatches(e.body).length,
          1,
          reason: 'exactly one paste',
        );
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC7: Cmd+click on a wikilink opens it; hover style and cursor
  // -------------------------------------------------------------------------
  group('links in a row without a field (AC7)', () {
    testWidgets(
      'a Cmd+click on a wikilink in a row without a field opens its note',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        final link = e.local(6, 'Other note');
        final at = e.glyphs(6, link, link + 5).center;

        await tester.macHolding([LogicalKeyboardKey.metaLeft], () async {
          final g = await tester.startGesture(
            at,
            kind: PointerDeviceKind.mouse,
            buttons: kPrimaryButton,
          );
          await tester.pump();
          await g.up();
          await tester.pump();
        });
        await pumpFrames(tester);

        expect(
          e.w.e.container.read(tabsProvider).activeTab,
          const NoteTab(_t128OtherId),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'hovering a wikilink in a row without a field shows its hover style and the click cursor and moving out clears both',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        final link = e.local(6, 'Other note');
        final at = e.glyphs(6, link, link + 5).center;
        final controller = e.host.rowController(6)!;
        final token = e.local(6, '[[Other note]]');

        final mouse = await wi438MouseIn(tester, at);
        expect(_t128Cursor(), SystemMouseCursors.click);
        expect(
          controller.cmdHover,
          TextRange(start: token, end: token + '[[Other note]]'.length),
          reason: 'the hover style covers the whole token',
        );

        // Out onto plain text of the same row: the text cursor, no hover.
        await mouse.moveTo(e.wordPoint(6, 'Omega'));
        await pumpFrames(tester);
        expect(_t128Cursor(), SystemMouseCursors.text);
        expect(controller.cmdHover, isNull);

        await wi438MouseOut(tester, mouse);
        expect(controller.cmdHover, isNull);
      },
      variant: macOnly,
    );

    testWidgets(
      'the text cursor shows over the text of a row without a field',
      (tester) async {
        final e = await _t128Pump(tester);
        final mouse = await wi438MouseIn(tester, e.wordPoint(0, 'plain'));
        expect(_t128Cursor(), SystemMouseCursors.text);
        await mouse.moveTo(e.wordPoint(3, 'quote'));
        await pumpFrames(tester);
        expect(_t128Cursor(), SystemMouseCursors.text);
        await wi438MouseOut(tester, mouse);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC8: a task checkbox click toggles the task exactly once
  // -------------------------------------------------------------------------
  group('the task checkbox of a row without a field (AC8)', () {
    Finder checkbox() => find.byKey(const ValueKey('task-checkbox-0-2'));

    testWidgets(
      'a click on the task checkbox of a row without a field toggles the task once and moves neither focus nor caret',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        final before = e.body;
        final selection = e.host.selection;

        await _t128Click(tester, tester.getCenter(checkbox()));

        expect(e.body, before.replaceFirst('- [ ] task', '- [x] task'));
        expect(e.focused, _t128FieldRow, reason: 'focus does not move');
        expect(e.host.selection, selection, reason: 'nor does the caret');
      },
      variant: macOnly,
    );

    testWidgets(
      'two presses in the same frame on the task checkbox of a row without a field toggle the task exactly once',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        final before = e.body;

        await _t128SameFrameClicks(tester, tester.getCenter(checkbox()));

        expect(e.body, before.replaceFirst('- [ ] task', '- [x] task'));
        expect(e.focused, _t128FieldRow);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC9: Check Document Now lands in a row without a field
  // -------------------------------------------------------------------------
  group('Check Document Now (AC9)', () {
    testWidgets(
      'Check Document Now moves to a misspelling in a row without a field and makes that row active with the word selected',
      (tester) async {
        final e = await _t128Pump(tester);
        // From the field row: the next issue is `smal` in row 6.
        await e.focusFieldRow();

        e.w.spelling.emitCheckDocumentNow();
        await pumpFrames(tester, frames: 10);

        expect(e.selected, e.range(6, 'smal'));
        expect(e.active, 6, reason: 'the row is the active row');
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // Verify pins: contracts the doc comments promise
  // -------------------------------------------------------------------------
  group('right-click places the layer does not own (verify pins)', () {
    testWidgets(
      'a right click on the marker column of an item row without a field opens no menu and moves nothing',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        final selection = e.host.selection;
        final marker = find.byKey(const ValueKey('editor-row-marker-0-1'));
        expect(marker, findsOneWidget, reason: 'fixture: row 1 is an item');

        await wi438RightClick(tester, tester.getCenter(marker));

        expect(wi438Menu, findsNothing);
        expect(wi438DefaultMenu, findsNothing);
        expect(e.host.selection, selection, reason: 'the selection stays');
        expect(e.active, isNull, reason: 'no row became active');
      },
      variant: macOnly,
    );

    testWidgets(
      'a right click on a row whose presenter owns the press opens no row menu and moves nothing',
      (tester) async {
        final e = await _t128Pump(
          tester,
          presenter: const _T128OwningPresenter(0),
        );
        await e.focusFieldRow();
        final selection = e.host.selection;

        await wi438RightClick(tester, e.wordPoint(0, 'teh'));

        expect(wi438Menu, findsNothing, reason: 'no spelling menu');
        expect(wi438DefaultMenu, findsNothing, reason: 'no text menu');
        expect(e.host.selection, selection, reason: 'the selection stays');
        expect(e.active, isNull, reason: 'row 0 did not activate');
      },
      variant: macOnly,
    );

    testWidgets(
      'a right click below the rows of the segment opens no row menu and moves nothing',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        final selection = e.host.selection;
        final segment = e.host.context.findRenderObject()! as RenderBox;
        final rows = e.host.lineBoxes()!.box;
        final below = Offset(
          rows.localToGlobal(Offset.zero).dx + 200,
          rows.localToGlobal(Offset(0, rows.size.height)).dy + 4,
        );
        expect(
          below.dy,
          lessThan(segment.localToGlobal(Offset(0, segment.size.height)).dy),
          reason: 'fixture: the point lies on the empty area of the segment',
        );

        await wi438RightClick(tester, below);

        expect(wi438Menu, findsNothing);
        expect(wi438DefaultMenu, findsNothing);
        expect(e.host.selection, selection);
        expect(e.active, isNull);
      },
      variant: macOnly,
    );

    testWidgets(
      'a right click inside the selection of a field row keeps that selection and opens the field menu',
      (tester) async {
        final e = await _t128Pump(tester);
        const text = 'field anchor words';
        final start = e.spec(_t128FieldRow).textStart;
        await e.w.select(
          'field anchor',
          const TextSelection(baseOffset: 0, extentOffset: text.length),
        );
        final inside = e.w.glyphPoint(
          'field anchor',
          e.w.at('field anchor', 'anchor') + 1,
        );

        await wi438RightClick(tester, inside);

        expect(wi438DefaultMenu, findsOneWidget);
        expect(
          e.selected,
          TextRange(start: start, end: start + text.length),
          reason: 'a field keeps a selection the right click lands on',
        );
        expect(e.active, isNull);
      },
      variant: macOnly,
    );
  });

  group('the text menu of a row without a field (verify pins)', () {
    testWidgets(
      'the text menu over a selection lists Cut Copy and Paste and Copy puts the word on the clipboard and closes the menu',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();

        await wi438RightClick(tester, e.wordPoint(0, 'plain'));
        expect(_t128DefaultMenuLabels(tester), ['Cut', 'Copy', 'Paste']);
        await tester.tap(
          find.descendant(of: wi438DefaultMenu, matching: wi438AnyText('Copy')),
        );
        await pumpFrames(tester);

        expect(e.w.clip.text, 'plain', reason: 'Copy copies the word');
        expect(wi438DefaultMenu, findsNothing, reason: 'the item closed it');
      },
      variant: macOnly,
    );

    testWidgets(
      'Cut in the text menu of a row without a field removes the word and puts it on the clipboard',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        final before = e.body;
        final plain = e.at(0, 'plain');

        await wi438RightClick(tester, e.wordPoint(0, 'plain'));
        await tester.tap(
          find.descendant(of: wi438DefaultMenu, matching: wi438AnyText('Cut')),
        );
        await pumpFrames(tester);

        expect(e.body, before.replaceRange(plain, plain + 5, ''));
        expect(e.w.clip.text, 'plain');
        expect(wi438DefaultMenu, findsNothing);
      },
      variant: macOnly,
    );

    testWidgets('the text menu over a caret lists only Paste', (tester) async {
      final e = await _t128Pump(tester);
      await _t128Click(tester, e.wordPoint(0, 'plain'));
      expect(e.host.selection.isCollapsed, isTrue, reason: 'fixture: caret');

      await showRowTextMenu(e.host, 0, anchor: const Offset(100, 100));
      await pumpFrames(tester);

      expect(_t128DefaultMenuLabels(tester), ['Paste']);
    }, variant: macOnly);

    testWidgets(
      'the text menu lists no Paste while the clipboard holds no text',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        e.w.clip.text = null;

        await wi438RightClick(tester, e.wordPoint(0, 'plain'));

        expect(_t128DefaultMenuLabels(tester), ['Cut', 'Copy']);
      },
      variant: macOnly,
    );

    testWidgets(
      'no text menu opens over a caret while the clipboard holds no text',
      (tester) async {
        final e = await _t128Pump(tester);
        await _t128Click(tester, e.wordPoint(0, 'plain'));
        e.w.clip.text = null;

        await showRowTextMenu(e.host, 0, anchor: const Offset(100, 100));
        await pumpFrames(tester);

        expect(wi438DefaultMenu, findsNothing, reason: 'it has no items');
      },
      variant: macOnly,
    );

    testWidgets('the text menu of a row past the last row opens nothing', (
      tester,
    ) async {
      final e = await _t128Pump(tester);
      await e.focusFieldRow();

      await showRowTextMenu(e.host, 99, anchor: const Offset(100, 100));
      await showRowTextMenu(e.host, -1, anchor: const Offset(100, 100));
      await pumpFrames(tester);

      expect(wi438DefaultMenu, findsNothing);
    }, variant: macOnly);

    testWidgets(
      'a press on a row closes the text menu of a row without a field',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        await wi438RightClick(tester, e.wordPoint(0, 'plain'));
        expect(wi438DefaultMenu, findsOneWidget, reason: 'fixture: it is open');

        final point = e.w.glyphPoint(
          'field anchor',
          e.w.at('field anchor', 'anchor') + 1,
        );
        final press = await tester.startGesture(
          point,
          kind: PointerDeviceKind.mouse,
          buttons: kPrimaryButton,
        );
        await tester.pump();

        expect(wi438DefaultMenu, findsNothing, reason: 'the press closed it');
        await press.up();
        await pumpFrames(tester);
      },
      variant: macOnly,
    );

    testWidgets(
      'a tap outside the editor closes the text menu of a row without a field',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        await wi438RightClick(tester, e.wordPoint(0, 'plain'));
        expect(wi438DefaultMenu, findsOneWidget, reason: 'fixture: it is open');

        await tester.tapAt(const Offset(2, 2));
        await pumpFrames(tester);

        expect(wi438DefaultMenu, findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'a change of the segment text closes the text menu of a row without a field',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        await wi438RightClick(tester, e.wordPoint(0, 'plain'));
        expect(wi438DefaultMenu, findsOneWidget, reason: 'fixture: it is open');

        e.host.applyEdit(
          const SegmentEdit(start: 0, end: 0, replacement: 'Zed '),
        );
        await pumpFrames(tester);

        expect(wi438DefaultMenu, findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'a change of the segment selection closes the text menu of a row without a field',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        await wi438RightClick(tester, e.wordPoint(0, 'plain'));
        expect(wi438DefaultMenu, findsOneWidget, reason: 'fixture: it is open');

        e.host.select(const TextSelection.collapsed(offset: 1));
        await pumpFrames(tester);

        expect(wi438DefaultMenu, findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'a second right click replaces the text menu with one for the new word',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        await wi438RightClick(tester, e.wordPoint(3, 'quote'));
        expect(wi438DefaultMenu, findsOneWidget, reason: 'fixture: it is open');

        await wi438RightClick(tester, e.wordPoint(0, 'plain'));

        expect(wi438DefaultMenu, findsOneWidget, reason: 'one menu only');
        expect(e.selected, e.range(0, 'plain'));
        expect(e.active, 0);
      },
      variant: macOnly,
    );
  });

  group('the spelling menu of a row without a field (verify pins)', () {
    testWidgets(
      'a second right click on another flagged word opens that menu after the first',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        await wi438RightClick(tester, e.wordPoint(0, 'teh'));
        expect(wi438Labels(tester).first, 'the', reason: 'fixture: first menu');

        await wi438RightClick(tester, e.wordPoint(1, 'wrld'));

        expect(wi438Menu, findsOneWidget);
        expect(wi438Labels(tester).first, 'world');
        expect(e.active, 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'closing the spelling menu of a row without a field makes that row the active row again with its selection',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        final teh = e.range(0, 'teh');
        e.host.select(
          TextSelection(baseOffset: teh.start, extentOffset: teh.end),
        );
        final issue = rowSpellingIssue(e.host, 0);
        expect(issue, isNotNull, reason: 'fixture: the selection is on teh');
        expect(e.active, isNull, reason: 'fixture: row 0 is idle');

        final opened = await showRowSpellingMenu(
          e.host,
          0,
          issue: issue!,
          anchor: e.wordPoint(0, 'teh'),
        );
        await pumpFrames(tester);
        expect(opened, isTrue);
        expect(wi438Menu, findsOneWidget);
        await wi438Key(tester, wi438Esc);
        await pumpFrames(tester);

        expect(wi438Menu, findsNothing, reason: 'Esc closed the menu');
        expect(e.active, 0, reason: 'the row is the active row again');
        expect(e.focused, 0, reason: 'and has focus');
        expect(e.selected, teh, reason: 'with the selection as it was');
      },
      variant: macOnly,
    );

    testWidgets('the spelling menu of a row past the last row opens nothing', (
      tester,
    ) async {
      final e = await _t128Pump(tester);
      await e.focusFieldRow();
      final teh = e.range(0, 'teh');
      e.host.select(
        TextSelection(baseOffset: teh.start, extentOffset: teh.end),
      );
      final real = rowSpellingIssue(e.host, 0)!;

      final opened = await showRowSpellingMenu(
        e.host,
        99,
        issue: real,
        anchor: const Offset(100, 100),
      );
      await pumpFrames(tester);

      expect(opened, isFalse);
      expect(wi438Menu, findsNothing);
      expect(rowSpellingIssue(e.host, 99), isNull);
    }, variant: macOnly);

    testWidgets(
      'Check Document Now opens the spelling menu of a row without a field below the misspelling',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();

        e.w.spelling.emitCheckDocumentNow();
        await pumpFrames(tester, frames: 10);

        expect(wi438Menu, findsOneWidget, reason: 'the menu opens');
        expect(wi438Labels(tester).take(3), [
          'small',
          'Learn Spelling',
          'Ignore Spelling',
        ]);
        // The row has its field by now: read the word from its own boxes.
        final smal = e.local(6, 'smal');
        final boxes = rowBoxesOf(tester, 0, 6);
        final rects = boxes.boxesFor(TextRange(start: smal, end: smal + 4));
        final bottom = boxes.box.localToGlobal(rects.first.bottomLeft).dy;
        expect(
          tester.getRect(wi438Item('small')).top,
          greaterThanOrEqualTo(bottom - 1),
          reason: 'the menu hangs below the word',
        );
      },
      variant: macOnly,
    );
  });

  group('Cmd+press on a row without a field (verify pins)', () {
    testWidgets(
      'a Cmd+click on a wikilink in a row without a field opens its note and puts the caret at the link',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        // The note the link opens takes the editor's place: keep this host.
        final host = e.host;
        final link = e.local(6, 'Other note');
        final at = e.glyphs(6, link, link + 5).center;
        final expected = e.offsetAt(6, at);

        await tester.macHolding([LogicalKeyboardKey.metaLeft], () async {
          final g = await tester.startGesture(
            at,
            kind: PointerDeviceKind.mouse,
            buttons: kPrimaryButton,
          );
          await tester.pump();
          expect(
            host.selection,
            isNot(TextSelection.collapsed(offset: expected)),
            reason: 'the caret waits for the release',
          );
          await g.up();
          await tester.pump();
        });
        await pumpFrames(tester);

        expect(
          e.w.e.container.read(tabsProvider).activeTab,
          const NoteTab(_t128OtherId),
        );
        expect(host.selection, TextSelection.collapsed(offset: expected));
        expect(host.activeRow.value, 6);
      },
      variant: macOnly,
    );

    testWidgets(
      'a Cmd+drag from a row without a field to another row selects from the press and keeps focus in the first row',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        final start = e.wordPoint(0, 'typo');
        final base = e.offsetAt(0, start);
        final end = e.wordPoint(3, 'text');
        final extent = e.offsetAt(3, end);

        await tester.macHolding([
          LogicalKeyboardKey.metaLeft,
        ], () => _t128Drag(tester, start, end));

        expect(
          e.host.selection,
          TextSelection(baseOffset: base, extentOffset: extent),
        );
        expect(e.focused, 0, reason: 'focus is in the row the press began in');
        expect(e.active, 0);
      },
      variant: macOnly,
    );
  });

  group('the active row of the rows host (verify pins)', () {
    testWidgets(
      'the active row follows its row when a row is inserted above it',
      (tester) async {
        final e = await _t128Pump(tester);
        await _t128Click(tester, e.wordPoint(6, 'line'));
        expect(e.active, 6, reason: 'fixture');
        final rows = e.host.rowCount;

        e.host.applyEdit(
          const SegmentEdit(start: 0, end: 0, replacement: '- first\n'),
        );
        await pumpFrames(tester);

        expect(e.host.rowCount, rows + 1, reason: 'fixture: a row was added');
        expect(e.active, 7, reason: 'the row moved down by one');
        expect(rowTextOf(tester, 0, 7), startsWith('Omega'));
      },
      variant: macOnly,
    );

    testWidgets('the active row becomes null when its row is retired', (
      tester,
    ) async {
      final e = await _t128Pump(tester);
      await _t128Click(tester, e.wordPoint(6, 'line'));
      expect(e.active, 6, reason: 'fixture');
      // Focus leaves the row: a focused row keeps its identity, another
      // row whose kind changes has no continuation.
      await e.focusFieldRow();
      final start = e.spec(6).textStart;

      // The prose row turns into a bullet row.
      e.host.applyEdit(
        SegmentEdit(start: start, end: start, replacement: '- '),
      );
      await pumpFrames(tester);

      expect(e.active, isNull);
    }, variant: macOnly);

    testWidgets(
      'a click on a row without a field after one on an earlier row without a field makes the later row the active row',
      (tester) async {
        final e = await _t128Pump(tester);
        await e.focusFieldRow();
        await _t128Click(tester, e.wordPoint(0, 'plain'));
        expect(e.active, 0, reason: 'fixture: row 0 is active');

        await _t128Click(tester, e.wordPoint(3, 'quote'));

        expect(e.active, 3);
        expect(e.focused, 3);
        expect(
          find.byKey(_t128SlotKey(0, 0)),
          findsOneWidget,
          reason: 'row 0 is idle again',
        );
      },
      variant: macOnly,
    );
  });
}
