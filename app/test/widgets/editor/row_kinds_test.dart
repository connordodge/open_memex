// WI #124 (Spec #122 Req 35, TD5, TD12; rulings D2, D3, D5, D12, D17): the
// row-kind seam.
// - `presenterFor` picks the table, attachment or text presenter by kind.
// - The table presenter shows the grid (field offstage) until revealed, and
//   its block geometry is the grid's; `LivePreviewController.textHidden` is
//   `tableRow && !tableRevealed`.
// - The attachment stub renders and edits like a prose row.
// - `SegmentViewState.rowBoxes(i)` is the presenter's `blockBoxes` when
//   non-null, else the row's text line boxes.
// - `BlockLineBoxes`: one line over its block.
// - A press a presenter owns is ignored by the pointer layer (D5).
// - `SegmentEditing.applyEdit` and `offsetAtGlobal` (D12).
// - `editor_rows_probe.dart` (D17) works on prose, item, table and
//   attachment rows.
//
// Test presenters are injected through `debugRowKindPresenterOverride`;
// helpers carry the `_t124` prefix so stacked siblings never collide.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/editor/spell_issues.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/widgets/editor/attachment_row.dart';
import 'package:open_memex_app/src/widgets/editor/editor_row.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/paragraph_line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/row_kinds.dart';
import 'package:open_memex_app/src/widgets/editor/segment_editing.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/spell_issue_scope.dart';
import 'package:open_memex_app/src/widgets/editor/table_grid.dart';
import 'package:open_memex_app/src/widgets/find/find_highlights.dart';
import 'package:open_memex_app/src/widgets/find/find_keys.dart';

import '../../support/editor_rows_probe.dart';
import '../../support/editor_scope.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/segment_editing_finder.dart';
import '../../support/spelling_editor_pump.dart';
import '../../support/table_harness.dart';
import '../../support/wi83_find_paint.dart';

/// A small table (header, delimiter, one body line).
const _t124Table = '| Step | Notes |\n|---|---|\n| Alpha | one |';

/// A prose row, a table row and a prose row.
const _t124ProseTable = 'Intro line\n$_t124Table\nBelow line';

/// A prose row, a bullet row, a table row and a prose row.
const _t124Mixed = 'Intro line\n- item one\n$_t124Table\nOutro line';

/// Every line of [source] as (range, top, bottom), for comparing two
/// sources line by line.
List<(TextRange, double, double)> _t124Lines(LineBoxSource source) => [
  for (final l in source.lines) (l.range, l.top, l.bottom),
];

/// The render box of editor row [r]'s field in text segment [s] (also while
/// offstage).
RenderBox _t124FieldEditable(WidgetTester tester, int s, int r) =>
    segmentRowTextBox(tester, s, r);

/// The line boxes of the text box [box] of an editor row: its field's, or
/// (WI #132, an idle row) its paragraph's.
LineBoxSource _t124BoxesOf(RenderBox box) => switch (box) {
  final RenderEditable e => RenderEditableLineBoxes(e),
  final RenderParagraph p => RenderParagraphLineBoxes(p),
  _ => throw TestFailure('$box lays out no text'),
};

/// A primary-button mouse click at [at] (global), held [move] away before
/// release when given; then lets any click chain expire.
Future<void> _t124Click(
  WidgetTester tester,
  Offset at, {
  Offset move = Offset.zero,
}) async {
  final gesture = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kPrimaryButton,
  );
  await tester.pump();
  if (move != Offset.zero) {
    await gesture.moveBy(move);
    await tester.pump();
  }
  await gesture.up();
  await tester.pump();
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
}

/// A presenter that shows the row's field, then a [height] px block under
/// [PresentedRow.blockKey]. It owns presses inside the block when
/// [ownsBlock]; its block geometry is a [BlockLineBoxes] over the block
/// when [measuresBlock]. It hides the row's text (field offstage, so the
/// block stands in) when [hidesText].
class _T124BlockPresenter extends RowKindPresenter {
  const _T124BlockPresenter({
    this.height = 40,
    this.ownsBlock = false,
    this.measuresBlock = false,
    this.hidesText = false,
  });

  final double height;
  final bool ownsBlock;
  final bool measuresBlock;
  final bool hidesText;

  @override
  Widget build(BuildContext context, PresentedRow row, RowTextSlot textSlot) =>
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          textSlot(offstage: hidesText),
          KeyedSubtree(
            key: row.blockKey,
            child: SizedBox(
              key: ValueKey('t124-block-${row.segment}-${row.index}'),
              height: height,
            ),
          ),
        ],
      );

  @override
  bool textHidden(PresentedRow row) => hidesText;

  RenderBox? _block(PresentedRow row) {
    final box = row.blockKey?.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize ? box : null;
  }

  @override
  LineBoxSource? blockBoxes(PresentedRow row) {
    if (!measuresBlock) return null;
    final box = _block(row);
    return box == null
        ? null
        : BlockLineBoxes(box, textLength: row.controller.text.length);
  }

  @override
  bool ownsPress(PresentedRow row, Offset position) {
    if (!ownsBlock) return false;
    final box = _block(row);
    return box != null &&
        (box.localToGlobal(Offset.zero) & box.size).contains(position);
  }
}

/// A presenter that hides its text for the row at [hiddenAt] only.
class _T124IndexPresenter extends TextRowPresenter {
  const _T124IndexPresenter(this.hiddenAt);

  final int hiddenAt;

  @override
  bool textHidden(PresentedRow row) => row.index == hiddenAt;
}

/// Presents every prose row with [presenter] until the test ends.
void _t124PresentProseWith(RowKindPresenter presenter) {
  debugRowKindPresenterOverride = (kind) =>
      kind == RowKind.prose ? presenter : null;
  addTearDown(() => debugRowKindPresenterOverride = null);
}

/// A lone EditableText over [controller] and [node].
Widget _t124Field(LivePreviewController controller, FocusNode node) =>
    EditableText(
      controller: controller,
      focusNode: node,
      style: const TextStyle(fontSize: 13.5),
      cursorColor: const Color(0xFF000000),
      backgroundCursorColor: const Color(0xFF000000),
      maxLines: null,
    );

/// The painted state of one prose row a presenter shows (WI #124, D2): the
/// find ranges its highlight layer got, whether its squiggle layer paints
/// and whether the segment paints a selection fill.
typedef _T124Paint = ({
  List<FindPaintRange> find,
  bool squiggle,
  bool selectionFill,
});

/// Pumps the whole editor on a prose row `Alpha beta gamma` presented by
/// [presenter], finds `beta`, flags it as misspelled, selects `beta` in the
/// segment and returns what the row paints.
Future<_T124Paint> _t124PaintedWith(
  WidgetTester tester,
  RowKindPresenter presenter,
) async {
  _t124PresentProseWith(presenter);
  final e = await pumpSpellingEditor(tester, body: 'Alpha beta gamma');
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  final row = find.byKey(const ValueKey('editor-row-0-0'), skipOffstage: false);
  expect(row, findsOneWidget, reason: 'fixture: the prose row');
  final field = find.descendant(
    of: row,
    matching: find.byType(EditableText, skipOffstage: false),
    skipOffstage: false,
  );
  final text = e.robot.segmentText(0);
  final beta = text.indexOf('beta');

  // Find highlights.
  wi83Open(e.container, [
    FindSource(segment: 0, kind: FindSourceKind.body, text: text),
  ], 'beta');
  await tester.pump();
  await tester.pump();
  final highlights = tester.widget<FindHighlights>(
    find.byKey(findHighlightsKey(0, 0), skipOffstage: false),
  );

  // Squiggles.
  final registry = SpellIssueScope.maybeOf(tester.element(field));
  expect(registry, isNotNull, reason: 'fixture: the field has a registry');
  registry!.setIssues(tester.widget<EditableText>(field).controller, [
    SpellIssue(kind: SpellIssueKind.spelling, start: beta, length: 4),
  ]);
  await tester.pump();
  final layer = find.descendant(
    of: row,
    matching: find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_SquiggleLayer',
      description: 'squiggle layer',
      skipOffstage: false,
    ),
    skipOffstage: false,
  );
  expect(layer, findsOneWidget, reason: 'fixture: the squiggle layer');
  final squiggle = _t124Paints(tester.renderObject(layer), (i) {
    return i.memberName == #drawPath;
  });

  // Selection fill: `beta` selected in the segment.
  segmentEditingAt(
    tester,
    0,
  ).select(TextSelection(baseOffset: beta, extentOffset: beta + 4));
  await tester.pump();
  final fill = _t124Paints(
    tester.renderObject(find.byKey(textSegmentKey(0))),
    (i) =>
        i.memberName == #drawRect &&
        (i.positionalArguments[1] as Paint).color.toARGB32() ==
            OmColors.selection.toARGB32(),
  );
  return (
    find: List.of(highlights.ranges),
    squiggle: squiggle,
    selectionFill: fill,
  );
}

/// Whether painting [root] makes a canvas call [match] accepts.
bool _t124Paints(RenderObject root, bool Function(Invocation call) match) {
  final canvas = TestRecordingCanvas();
  (root as RenderBox).paint(TestRecordingPaintingContext(canvas), Offset.zero);
  return canvas.invocations.any((c) => match(c.invocation));
}

void main() {
  holdFontFetches();

  tearDown(() => debugRowKindPresenterOverride = null);

  group('presenterFor (AC1)', () {
    test(
      'presenterFor returns the table, attachment and text presenters by row kind',
      () {
        for (final kind in RowKind.values) {
          final presenter = presenterFor(kind);
          switch (kind) {
            case RowKind.table:
              expect(presenter, isA<TableRowPresenter>(), reason: kind.name);
            case RowKind.attachment:
              expect(
                presenter,
                isA<AttachmentRowPresenter>(),
                reason: kind.name,
              );
            case _:
              expect(presenter, isA<TextRowPresenter>(), reason: kind.name);
              expect(
                presenter,
                isNot(isA<TableRowPresenter>()),
                reason: kind.name,
              );
              expect(
                presenter,
                isNot(isA<AttachmentRowPresenter>()),
                reason: kind.name,
              );
          }
        }
        // The test seam: an override answers the kinds it returns a
        // presenter for, the built-in presenters the rest.
        const custom = _T124BlockPresenter();
        debugRowKindPresenterOverride = (kind) =>
            kind == RowKind.prose ? custom : null;
        expect(presenterFor(RowKind.prose), same(custom));
        expect(presenterFor(RowKind.table), isA<TableRowPresenter>());
        expect(presenterFor(RowKind.bullet), isA<TextRowPresenter>());
        debugRowKindPresenterOverride = null;
        expect(presenterFor(RowKind.prose), isA<TextRowPresenter>());
      },
    );
  });

  group('BlockLineBoxes (AC6)', () {
    testWidgets(
      'BlockLineBoxes reports one line over its block, its caret at the top-left, offset 0 and the block rect',
      (tester) async {
        final key = GlobalKey();
        var height = 48.0;
        late StateSetter setOuter;
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 30, top: 70),
                child: StatefulBuilder(
                  builder: (context, setState) {
                    setOuter = setState;
                    return SizedBox(key: key, width: 120, height: height);
                  },
                ),
              ),
            ),
          ),
        );
        final box = key.currentContext!.findRenderObject()! as RenderBox;
        // Built from run-time values.
        final length = '![chart](objects/ab/chart.png)'.length;
        final boxes = BlockLineBoxes(box, textLength: length);
        expect(boxes.box, same(box));
        expect(boxes.textLength, length);

        // One line spanning the block, holding the row's text.
        expect(boxes.lines, hasLength(1));
        final line = boxes.lines.single;
        expect(line.range, TextRange(start: 0, end: length));
        expect(line.top, 0);
        expect(line.bottom, 48);

        // The caret at the block's top-left, as tall as the block, at any
        // offset.
        for (final offset in [0, 5, length]) {
          final caret = boxes.caretRect(offset);
          expect(caret.topLeft, Offset.zero, reason: 'caret at $offset');
          expect(caret.height, 48, reason: 'caret at $offset');
        }

        // Every point resolves to offset 0.
        for (final point in const [
          Offset.zero,
          Offset(60, 24),
          Offset(119, 47),
          Offset(-10, -10),
          Offset(500, 500),
        ]) {
          expect(boxes.offsetAt(point), 0, reason: '$point');
        }

        // A non-empty range is the block's rect (local); an empty one is
        // nothing.
        const rect = Rect.fromLTWH(0, 0, 120, 48);
        expect(boxes.boxesFor(const TextRange(start: 0, end: 1)), [rect]);
        expect(boxes.boxesFor(TextRange(start: 0, end: length)), [rect]);
        expect(boxes.boxesFor(const TextRange.collapsed(0)), isEmpty);
        expect(boxes.boxesFor(const TextRange.collapsed(4)), isEmpty);

        // Read when asked: a relaid-out block reports its new size.
        setOuter(() => height = 64);
        await tester.pump();
        expect(boxes.lines.single.bottom, 64);
        expect(boxes.caretRect(0).height, 64);
        expect(boxes.boxesFor(const TextRange(start: 0, end: 2)), [
          const Rect.fromLTWH(0, 0, 120, 64),
        ]);

        // Without a text length the one line is empty.
        expect(
          BlockLineBoxes(box).lines.single.range,
          const TextRange(start: 0, end: 0),
        );
      },
    );
  });

  group('LivePreviewController.textHidden (AC3)', () {
    test('textHidden is true exactly when a table row shows its grid', () {
      final gate = ValueNotifier(false);
      addTearDown(gate.dispose);
      for (final tableRow in [false, true]) {
        for (final open in [false, true]) {
          for (final valid in [false, true]) {
            final c = LivePreviewController(text: '| a |\n|---|\n| 1 |');
            addTearDown(c.dispose);
            c
              ..tableRow = tableRow
              ..revealGate = gate
              ..selection = valid
                  ? const TextSelection.collapsed(offset: 1)
                  : const TextSelection.collapsed(offset: -1);
            gate.value = open;
            final shown = tableRow && !(open && valid);
            expect(
              c.textHidden,
              shown,
              reason: 'tableRow=$tableRow gate=$open selection valid=$valid',
            );
            expect(c.textHidden, c.tableRow && !c.tableRevealed);
          }
        }
      }
    });

    testWidgets(
      'textHidden follows a pumped table row and stays false on its prose rows',
      (tester) async {
        final body = await pumpTable(tester, _t124ProseTable);
        final prose = tableRowController(tester, 0, 0);
        final table = tableRowController(tester, 0, 1);
        expectTableRendered(0, 1);
        expect(table.textHidden, isTrue, reason: 'grid shows');
        expect(prose.textHidden, isFalse);

        // Caret in the table with the segment focused: revealed.
        await body.placeCaret(_t124ProseTable.indexOf('Alpha'));
        expectTableRevealed(0, 1);
        expect(table.textHidden, isFalse, reason: 'revealed');
        expect(prose.textHidden, isFalse);

        // Caret on the prose row: the grid shows again.
        await body.placeCaret(2);
        expectTableRendered(0, 1);
        expect(table.textHidden, isTrue);
        expect(prose.textHidden, isFalse, reason: 'focused prose row');

        // Focus out of the segment: still the grid.
        await body.focusOutside();
        expect(table.textHidden, isTrue);
        expect(prose.textHidden, isFalse);
      },
    );

    testWidgets(
      'a presenter that shows its text lets find, squiggles and the selection fill paint',
      (tester) async {
        final painted = await _t124PaintedWith(
          tester,
          const _T124BlockPresenter(),
        );
        expect(painted.find, isNotEmpty, reason: 'find highlights');
        expect(painted.squiggle, isTrue, reason: 'squiggle');
        expect(painted.selectionFill, isTrue, reason: 'selection fill');
      },
    );

    testWidgets(
      'a presenter that hides its text suppresses find highlights, squiggles and the selection fill',
      (tester) async {
        final painted = await _t124PaintedWith(
          tester,
          const _T124BlockPresenter(hidesText: true),
        );
        expect(painted.find, isEmpty, reason: 'find highlights');
        expect(painted.squiggle, isFalse, reason: 'squiggle');
        expect(painted.selectionFill, isFalse, reason: 'selection fill');
      },
    );

    test(
      'textHidden asks the presenter hook first and falls back to the table rule',
      () {
        final c = LivePreviewController(text: 'x');
        addTearDown(c.dispose);
        expect(c.presenterTextHidden, isNull, reason: 'no host: no hook');
        expect(c.textHidden, isFalse, reason: 'bare prose controller');
        c.tableRow = true;
        expect(c.textHidden, isTrue, reason: 'bare table: the fallback');

        // The hook wins over the table rule, both ways.
        c.presenterTextHidden = () => false;
        expect(c.textHidden, isFalse, reason: 'hook says shown on a table');
        c.tableRow = false;
        c.presenterTextHidden = () => true;
        expect(c.textHidden, isTrue, reason: 'hook says hidden on prose');

        // Cleared: the fallback again.
        c.presenterTextHidden = null;
        expect(c.textHidden, isFalse);
      },
    );

    testWidgets(
      'a row that moves answers textHidden for its current index at once',
      (tester) async {
        _t124PresentProseWith(const _T124IndexPresenter(1));
        await pumpTable(tester, 'Alpha line\n- item one');
        final prose = tableRowController(tester, 0, 0);
        expect(prose.textHidden, isFalse, reason: 'prose row at index 0');

        // A bullet row goes in above it: the prose row is row 1 now.
        segmentEditingAt(tester, 0).applyEdit(
          const SegmentEdit(start: 0, end: 0, replacement: '- new\n'),
        );
        expect(prose.textHidden, isTrue, reason: 'the presenter sees index 1');
        await tester.pump();
        expect(
          tableRowController(tester, 0, 1),
          same(prose),
          reason: 'fixture: the prose row is kept, now row 1',
        );
      },
    );

    testWidgets(
      'a row that changes kind answers textHidden from its new presenter at once',
      (tester) async {
        // Prose rows are presented by a presenter that hides its text.
        _t124PresentProseWith(const _T124BlockPresenter(hidesText: true));
        final body = await pumpTable(tester, _t124Table);
        await body.placeCaret(_t124Table.indexOf('Alpha'));
        expectTableRevealed(0, 0);
        final row = tableRowController(tester, 0, 0);
        expect(row.textHidden, isFalse, reason: 'a revealed table row');

        // The focused row becomes prose; rows re-derive in the call, before
        // the next frame builds them.
        segmentEditingAt(tester, 0).replaceText('Alpha line');
        expect(
          tableRowController(tester, 0, 0),
          same(row),
          reason: 'fixture: the focused row is kept across the kind change',
        );
        expect(row.tableRow, isFalse, reason: 'fixture: now a prose row');
        expect(row.textHidden, isTrue, reason: 'the prose presenter answers');
        await tester.pump();
        expect(row.textHidden, isTrue);
      },
    );
  });

  group('table presenter (AC2)', () {
    testWidgets(
      'the table presenter shows the grid with its field offstage until revealed',
      (tester) async {
        final controller = LivePreviewController(text: _t124Table)
          ..tableRow = true;
        final node = FocusNode();
        final gate = ValueNotifier(false);
        addTearDown(controller.dispose);
        addTearDown(node.dispose);
        addTearDown(gate.dispose);
        controller
          ..revealGate = gate
          ..selection = const TextSelection.collapsed(offset: 2);
        final blockKey = GlobalKey(debugLabel: 't124-block');
        // Built from run-time values.
        final segment = int.parse('3');
        final row = PresentedRow(
          segment: segment,
          index: segment - 2,
          kind: RowKind.table,
          controller: controller,
          blockKey: blockKey,
        );
        expect(row.segment, 3);
        expect(row.index, 1);
        expect(row.kind, RowKind.table);
        expect(row.controller, same(controller));
        expect(row.blockKey, same(blockKey));
        expect(row.geometry, isNull);
        expect(row.marker, '');
        final presenter = presenterFor(RowKind.table);
        final slots = <bool>[];
        await pumpEditorScoped(
          tester,
          MaterialApp(
            theme: buildOmTheme(),
            home: Material(
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 600,
                  child: Builder(
                    builder: (context) => presenter.build(context, row, ({
                      required bool offstage,
                    }) {
                      slots.add(offstage);
                      return KeyedSubtree(
                        key: const ValueKey('t124-slot'),
                        child: Offstage(
                          offstage: offstage,
                          child: _t124Field(controller, node),
                        ),
                      );
                    }),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final grid = find.byKey(const ValueKey('editor-table-3-1'));
        // Rendered: the grid under the block key, the field offstage.
        expect(grid, findsOneWidget, reason: 'the grid shows');
        expect(
          find.descendant(of: find.byKey(blockKey), matching: grid),
          findsOneWidget,
          reason: 'the grid sits under the block key',
        );
        expect(slots, isNotEmpty);
        expect(slots.last, isTrue, reason: 'the text slot is offstage');
        expect(find.byType(EditableText), findsNothing);
        expect(
          find.byType(EditableText, skipOffstage: false),
          findsOneWidget,
          reason: 'the field stays mounted',
        );
        expect(presenter.textHidden(row), isTrue);
        final gridBoxes = tester.state<TableGridState>(grid).lineBoxes()!;
        final block = presenter.blockBoxes(row);
        expect(block, isNotNull, reason: 'the grid measures the row');
        expect(block!.box, same(gridBoxes.box));
        expect(_t124Lines(block), _t124Lines(gridBoxes));
        expect(
          presenter.ownsPress(row, tester.getCenter(grid)),
          isFalse,
          reason: 'the pointer layer owns grid presses (D14)',
        );

        // Revealed (the gate opens with a valid selection): the field shows,
        // the grid is gone and the text slot answers.
        gate.value = true;
        await tester.pump();
        expect(grid, findsNothing, reason: 'revealed');
        expect(find.byType(EditableText), findsOneWidget);
        expect(slots.last, isFalse);
        expect(presenter.textHidden(row), isFalse);
        expect(presenter.blockBoxes(row), isNull);

        // No valid selection: the grid again.
        controller.selection = const TextSelection.collapsed(offset: -1);
        await tester.pump();
        expect(grid, findsOneWidget);
        expect(slots.last, isTrue);
        expect(presenter.textHidden(row), isTrue);

        // The gate closes with a valid selection: still the grid.
        controller.selection = const TextSelection.collapsed(offset: 0);
        gate.value = false;
        await tester.pump();
        expect(grid, findsOneWidget);
        expect(presenter.textHidden(row), isTrue);
      },
    );
  });

  group('attachment stub (AC4)', () {
    testWidgets(
      'an attachment row built through presenterFor renders and edits like a prose row with the same text',
      (tester) async {
        const text = 'A synthetic attachment line ![chart](objects/ab/c.png)';
        final prose = LivePreviewController(text: text);
        final attachment = LivePreviewController(text: text);
        final proseNode = FocusNode();
        final attachmentNode = FocusNode();
        for (final d in [prose, attachment, proseNode, attachmentNode]) {
          addTearDown(d.dispose);
        }
        final presenter = presenterFor(RowKind.attachment);
        final row = PresentedRow(
          segment: 1,
          index: 0,
          kind: RowKind.attachment,
          controller: attachment,
          blockKey: GlobalKey(),
        );
        // The stub's frozen contract: no hidden text, no block geometry, no
        // press of its own; its body is the text slot, on stage.
        expect(presenter.textHidden(row), isFalse);
        expect(presenter.blockBoxes(row), isNull);
        expect(presenter.ownsPress(row, const Offset(10, 10)), isFalse);
        final slots = <bool>[];
        await pumpEditorScoped(
          tester,
          MaterialApp(
            home: Material(
              child: Builder(
                builder: (context) =>
                    presenter.build(context, row, ({required bool offstage}) {
                      slots.add(offstage);
                      return KeyedSubtree(
                        key: const ValueKey('t124-attachment-slot'),
                        child: Text(text, textDirection: TextDirection.ltr),
                      );
                    }),
              ),
            ),
          ),
        );
        expect(slots, [false], reason: 'the text slot, once, on stage');
        expect(find.byKey(const ValueKey('t124-attachment-slot')), findsOne);

        // As EditorRows of the same text: the attachment row lays out and
        // edits as the prose row does.
        Widget lone(
          int segment,
          RowKind kind,
          LivePreviewController c,
          FocusNode n,
        ) => SizedBox(
          width: 360,
          child: EditorRow(
            segment: segment,
            index: 0,
            kind: kind,
            geometry: null,
            marker: '',
            controller: c,
            focusNode: n,
            boxes: () => null,
            field: _t124Field(c, n),
          ),
        );
        await pumpEditorScoped(
          tester,
          MaterialApp(
            theme: buildOmTheme(),
            home: Material(
              child: Align(
                alignment: Alignment.topLeft,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    lone(0, RowKind.prose, prose, proseNode),
                    lone(1, RowKind.attachment, attachment, attachmentNode),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final proseRow = find.byKey(const ValueKey('editor-row-0-0'));
        final attachmentRow = find.byKey(const ValueKey('editor-row-1-0'));
        expect(attachmentRow, findsOneWidget);
        final attachmentField = find.descendant(
          of: attachmentRow,
          matching: find.byType(EditableText),
        );
        expect(attachmentField, findsOneWidget, reason: 'field on stage');
        expect(tester.getSize(attachmentRow), tester.getSize(proseRow));
        expect(
          tester.getSize(find.byType(EditorRow).last),
          tester.getSize(find.byType(EditorRow).first),
        );
        expect(
          tester.getTopLeft(attachmentRow).dx,
          tester.getTopLeft(proseRow).dx,
          reason: 'no inset or marker column',
        );
        expect(
          _t124Lines(
            RenderEditableLineBoxes(
              findRenderEditable(tester.renderObject(attachmentRow))!,
            ),
          ),
          _t124Lines(
            RenderEditableLineBoxes(
              findRenderEditable(tester.renderObject(proseRow))!,
            ),
          ),
        );

        // It edits like a prose row: typing reaches its controller.
        await tester.showKeyboard(attachmentField);
        await tester.pump();
        expect(attachmentNode.hasFocus, isTrue);
        await tester.enterText(attachmentField, '$text more');
        await tester.pump();
        expect(attachment.text, '$text more');
        expect(prose.text, text);
      },
    );
  });

  group('row geometry accessor (AC5)', () {
    testWidgets(
      'rowBoxes returns a prose row field line boxes and null past the last row',
      (tester) async {
        await pumpTable(tester, 'Alpha line\n- item one\nBeta');
        final host = tableView(tester);
        expect(host.rowCount, 3);
        for (var r = 0; r < host.rowCount; r++) {
          final boxes = host.rowBoxes(r);
          expect(boxes, isNotNull, reason: 'row $r is laid out');
          final editable = _t124FieldEditable(tester, 0, r);
          expect(boxes!.box, same(editable), reason: 'row $r: its field');
          expect(
            _t124Lines(boxes),
            _t124Lines(_t124BoxesOf(editable)),
            reason: 'row $r',
          );
        }
        expect(host.rowBoxes(-1), isNull);
        expect(host.rowBoxes(host.rowCount), isNull);
      },
    );

    testWidgets(
      'rowBoxes returns a rendered table grid geometry and its field once revealed',
      (tester) async {
        final body = await pumpTable(tester, _t124ProseTable);
        final host = tableView(tester);
        expectTableRendered(0, 1);
        final grid = tableGridState(tester, 0, 1).lineBoxes()!;
        final rendered = host.rowBoxes(1);
        expect(rendered, isNotNull);
        expect(rendered!.box, same(grid.box), reason: 'the grid answers');
        expect(_t124Lines(rendered), _t124Lines(grid));
        expect(host.rowBoxes(0)!.box, same(_t124FieldEditable(tester, 0, 0)));

        await body.placeCaret(_t124ProseTable.indexOf('Alpha'));
        expectTableRevealed(0, 1);
        final editable = _t124FieldEditable(tester, 0, 1);
        final revealed = host.rowBoxes(1);
        expect(revealed!.box, same(editable), reason: 'the field answers');
        expect(_t124Lines(revealed), _t124Lines(_t124BoxesOf(editable)));
      },
    );

    testWidgets('rowBoxes returns the presenter block boxes when non-null', (
      tester,
    ) async {
      _t124PresentProseWith(
        const _T124BlockPresenter(height: 52, measuresBlock: true),
      );
      await pumpTable(tester, 'Alpha line\n- item one');
      final host = tableView(tester);
      final block = find.byKey(const ValueKey('t124-block-0-0'));
      expect(block, findsOneWidget, reason: 'the prose row uses the seam');
      final boxes = host.rowBoxes(0);
      expect(boxes, isA<BlockLineBoxes>());
      expect(boxes!.box, same(tester.renderObject(block)));
      expect(boxes.lines.single.bottom, 52);
      expect(boxes.lines.single.range, const TextRange(start: 0, end: 10));
      // The item row (text presenter) still answers from its field.
      expect(host.rowBoxes(1)!.box, same(_t124FieldEditable(tester, 0, 1)));
    });
  });

  group('press ownership (AC7)', () {
    testWidgets(
      'a press a presenter owns places no caret and starts no selection',
      (tester) async {
        _t124PresentProseWith(
          const _T124BlockPresenter(height: 60, ownsBlock: true),
        );
        const text = 'Alpha beta gamma';
        await pumpTable(tester, text);
        final handle = segmentEditingAt(tester, 0);
        final block = find.byKey(const ValueKey('t124-block-0-0'));
        expect(block, findsOneWidget, reason: 'the prose row uses the seam');
        final before = handle.selection;
        expect(handle.focusedRow, isNull);
        final center = tester.getCenter(block);

        // A plain click on the block.
        await _t124Click(tester, center);
        expect(handle.selection, before, reason: 'no caret move');
        expect(handle.focusedRow, isNull, reason: 'no focus change');

        // A drag from the block up over the text.
        final text0 = tableView(tester).lineBoxes()!;
        final textTop = text0.box.localToGlobal(
          Offset(2, text0.lines.first.top + 4),
        );
        await _t124Click(tester, center, move: textTop - center);
        expect(handle.selection, before, reason: 'no drag selection');
        expect(handle.focusedRow, isNull);

        // A Shift+click on the block.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await _t124Click(tester, center);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(handle.selection, before, reason: 'no Shift selection');
        expect(handle.focusedRow, isNull);

        // A press the presenter does not own (on the text) keeps today's
        // behaviour: the caret goes to the pressed offset, with focus.
        final at = text.indexOf('beta');
        final boxes = tableView(tester).lineBoxes()!;
        final char = boxes.boxesFor(TextRange(start: at, end: at + 1)).single;
        await _t124Click(
          tester,
          boxes.box.localToGlobal(Offset(char.left + 1, char.center.dy)),
        );
        expect(handle.selection, TextSelection.collapsed(offset: at));
        expect(handle.focusedRow, 0);
      },
    );
  });

  group('SegmentEditing additions (AC8)', () {
    testWidgets(
      'offsetAtGlobal returns the segment offset under a global point over text',
      (tester) async {
        const text = 'alpha beta\n- item gamma\nlast words';
        await pumpTable(tester, text);
        final SegmentEditing handle = segmentEditingAt(tester, 0);
        expect(handle.rowCount, 3);
        final boxes = tableView(tester).lineBoxes()!;
        for (final needle in ['alpha', 'beta', 'item', 'gamma', 'words']) {
          final at = text.indexOf(needle) + 1;
          final char = boxes.boxesFor(TextRange(start: at, end: at + 1)).single;
          final global = boxes.box.localToGlobal(
            Offset(char.left + 1, char.center.dy),
          );
          expect(handle.offsetAtGlobal(global), at, reason: needle);
          expect(
            handle.offsetAtGlobal(global),
            boxes.offsetAt(boxes.box.globalToLocal(global)),
            reason: '$needle: as the line boxes resolve it',
          );
        }
      },
    );

    testWidgets('offsetAtGlobal is null while the segment has no line boxes', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'abc\ndef');
      final focus = FocusNode();
      final gate = ValueNotifier(false);
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      addTearDown(gate.dispose);
      final viewKey = GlobalKey<SegmentViewState>();
      final duringBuild = <int?>[];
      var withField = true;
      late StateSetter setOuter;
      await pumpEditorScoped(
        tester,
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setOuter = setState;
                return SegmentView(
                  key: viewKey,
                  index: 0,
                  controller: controller,
                  focusNode: focus,
                  revealGate: gate,
                  minLines: 1,
                  hintText: null,
                  onChanged: () {},
                  onRowRemoved: (_) {},
                  fieldBuilder: (context, row) => withField
                      ? TextField(
                          controller: row.controller,
                          focusNode: row.focusNode,
                          maxLines: null,
                        )
                      : const SizedBox(width: 10, height: 10),
                  builder: (context, rows, b) {
                    duringBuild.add(
                      viewKey.currentState?.offsetAtGlobal(const Offset(4, 4)),
                    );
                    return rows;
                  },
                );
              },
            ),
          ),
        ),
      );
      final SegmentEditing handle = viewKey.currentState!;
      expect(duringBuild, [null], reason: 'first build: no layout yet');

      // Laid out: a point over `def` resolves to its offset.
      final boxes = viewKey.currentState!.lineBoxes()!;
      final char = boxes.boxesFor(const TextRange(start: 5, end: 6)).single;
      final global = boxes.box.localToGlobal(
        Offset(char.left + 1, char.center.dy),
      );
      expect(handle.offsetAtGlobal(global), 5);

      // Rows that render no field have no line boxes.
      setOuter(() => withField = false);
      await tester.pump();
      expect(viewKey.currentState!.lineBoxes(), isNull);
      expect(handle.offsetAtGlobal(global), isNull);
    });

    testWidgets(
      'applyEdit through the SegmentEditing handle applies one edit as SegmentViewState applyEdit does',
      (tester) async {
        const text = 'alpha beta\n- item gamma';
        const edit = SegmentEdit(
          start: 6,
          end: 10,
          replacement: 'delta',
          selection: SegmentSelection.collapsed(11),
        );
        // Through the host itself.
        var body = await pumpTable(tester, text);
        tableView(tester).applyEdit(edit);
        await tester.pump();
        final viaHost = (
          text: body.text(),
          selection: body.selection(),
          reports: body.reportCount,
          records: body.undoRecordCount,
          focused: body.segment().focusedRow,
        );

        // Through the frozen handle.
        await tester.pumpWidget(const SizedBox());
        body = await pumpTable(tester, text);
        final SegmentEditing handle = segmentEditingAt(tester, 0);
        handle.applyEdit(edit);
        await tester.pump();
        expect(body.text(), 'alpha delta\n- item gamma');
        expect(body.text(), viaHost.text);
        expect(body.selection(), const TextSelection.collapsed(offset: 11));
        expect(body.selection(), viaHost.selection);
        expect(body.reportCount, 1, reason: 'reported once');
        expect(body.reportCount, viaHost.reports);
        expect(body.undoRecordCount, 1, reason: 'one undo record');
        expect(body.undoRecordCount, viaHost.records);
        expect(handle.focusedRow, isNull, reason: 'focus unchanged');
        expect(handle.focusedRow, viaHost.focused);
        expect(handle.rowCount, 2);

        // Without a selection the selection is kept, clamped to the text.
        body.resetCounts();
        handle.select(const TextSelection.collapsed(offset: 20));
        handle.applyEdit(
          const SegmentEdit(start: 12, end: 24, replacement: ''),
        );
        await tester.pump();
        expect(handle.text, 'alpha delta\n');
        expect(handle.selection, const TextSelection.collapsed(offset: 12));
        expect(body.reportCount, 1);
        await body.settleTyping();
      },
    );
  });

  group('editor_rows_probe (AC9)', () {
    testWidgets(
      'editor_rows_probe reads and activates prose, item, table and attachment rows through the accessor',
      (tester) async {
        // The probe never reaches into a row's field widgets.
        final probe = File(
          'test/support/editor_rows_probe.dart',
        ).readAsStringSync();
        expect(probe, contains('rowBoxes('), reason: 'the probe was read');
        for (final banned in [
          'find.byType(TextField)',
          'findRenderEditable',
          'EditableText',
          'RenderEditable',
        ]) {
          expect(probe, isNot(contains(banned)), reason: banned);
        }

        final specs = splitRows(_t124Mixed, atSegmentStart: true);
        expect(
          [for (final s in specs) s.kind],
          const [RowKind.prose, RowKind.bullet, RowKind.table, RowKind.prose],
        );
        await pumpTable(tester, _t124Mixed);
        String expected(int r) =>
            _t124Mixed.substring(specs[r].textStart, specs[r].textEnd);

        // Read: text and geometry of every kind.
        expect(rowTextOf(tester, 0, 0), 'Intro line');
        expect(rowTextOf(tester, 0, 1), 'item one');
        expect(rowTextOf(tester, 0, 2), _t124Table);
        expect(rowTextOf(tester, 0, 3), expected(3));
        for (var r = 0; r < specs.length; r++) {
          final boxes = rowBoxesOf(tester, 0, r);
          expect(boxes.lines, isNotEmpty, reason: 'row $r');
          final rect = rowRectOf(tester, 0, r);
          expect(rect.height, greaterThan(0), reason: 'row $r');
        }
        expect(
          rowBoxesOf(tester, 0, 2).box,
          same(tableGridState(tester, 0, 2).lineBoxes()!.box),
          reason: 'a rendered table measures through its grid',
        );
        expect(
          rowRectOf(tester, 0, 1).top,
          greaterThanOrEqualTo(rowRectOf(tester, 0, 0).bottom - 0.5),
        );

        // Activate: the row gets focus and the caret at the row offset.
        for (final r in [0, 1, 2]) {
          await activateRow(tester, 0, r, offset: 1);
          final handle = segmentEditingAt(tester, 0);
          expect(handle.focusedRow, r);
          expect(
            handle.selection,
            TextSelection.collapsed(offset: specs[r].textStart + 1),
          );
        }
        expectTableRevealed(0, 2);
        expect(
          rowBoxesOf(tester, 0, 2).box,
          same(_t124FieldEditable(tester, 0, 2)),
          reason: 'a revealed table measures through its field',
        );

        // An attachment row (the attachment presenter shows a prose row).
        await tester.pumpWidget(const SizedBox());
        debugRowKindPresenterOverride = (kind) =>
            kind == RowKind.prose ? presenterFor(RowKind.attachment) : null;
        const attached = 'See ![chart](objects/ab/chart.png)\n- item two';
        await pumpTable(tester, attached);
        expect(rowTextOf(tester, 0, 0), 'See ![chart](objects/ab/chart.png)');
        expect(rowBoxesOf(tester, 0, 0).lines, isNotEmpty);
        expect(rowRectOf(tester, 0, 0).height, greaterThan(0));
        await activateRow(tester, 0, 0, offset: 4);
        expect(segmentEditingAt(tester, 0).focusedRow, 0);
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(offset: 4),
        );
        await activateRow(tester, 0, 1);
        expect(segmentEditingAt(tester, 0).focusedRow, 1);
        expect(rowTextOf(tester, 0, 1), 'item two');
      },
    );
  });

  group('row field wrapper (verify pins)', () {
    // The Offstage widgets inside editor row [r]'s keyed slot, also while
    // the field is offstage.
    Finder wrappers(int r) => find.descendant(
      of: find.byKey(ValueKey('editor-row-0-$r'), skipOffstage: false),
      matching: find.byType(Offstage, skipOffstage: false),
    );

    testWidgets(
      'only a table row keeps its field under an Offstage, off while revealed',
      (tester) async {
        final body = await pumpTable(tester, _t124Mixed);
        // Prose and item rows: the field sits bare, as on main.
        for (final r in [0, 1, 3]) {
          expect(wrappers(r), findsNothing, reason: 'row $r has no wrapper');
        }
        // A rendered table: one wrapper, offstage.
        expectTableRendered(0, 2);
        expect(wrappers(2), findsOneWidget);
        expect(tester.widget<Offstage>(wrappers(2)).offstage, isTrue);

        // Revealed: the same wrapper, on screen (the field never reparents).
        await body.placeCaret(_t124Mixed.indexOf('Alpha'));
        expectTableRevealed(0, 2);
        expect(wrappers(2), findsOneWidget, reason: 'still wrapped');
        expect(tester.widget<Offstage>(wrappers(2)).offstage, isFalse);
        for (final r in [0, 1, 3]) {
          expect(wrappers(r), findsNothing, reason: 'row $r has no wrapper');
        }
      },
    );

    test('an attachment row has no marker column and no item geometry', () {
      expect(markerColumnKind(RowKind.attachment), isNull);
      const text = '![chart](objects/ab/c.png)';
      final spec = RowSpec(
        kind: RowKind.attachment,
        start: 0,
        textStart: 0,
        textEnd: text.length,
        end: text.length,
      );
      expect(rowGeometries([spec]), [isNull]);
      expect(markerColumnKind(RowKind.table), isNull);
    });
  });
}
