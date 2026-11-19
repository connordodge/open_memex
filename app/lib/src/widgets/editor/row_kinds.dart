// The row-kind seam of the live preview editor (Spec #122 Req 35, rulings
// D2, D3, D5): how one editor row of a kind is shown, measured and pressed.
//
// Frozen contract (WI #124): #123's attachment rows (`attachment_row.dart`)
// and #122's later Work Items build on these members. Later changes are
// additive only.

import 'package:flutter/widgets.dart';

import '../../editor/editor_rows.dart';
import '../../editor/row_geometry.dart';
import 'attachment_row.dart';
import 'editor_row.dart' show markerColumnKind;
import 'line_boxes.dart';
import 'live_preview_controller.dart';
import 'marker_column.dart';
import 'table_grid.dart';
import 'text_segment.dart' show editorBodyStyle;

/// Builds an editor row's text slot (frozen, D2): the row's field under Key
/// `editor-row-<segment>-<index>`, with the row's selection fill and
/// spelling squiggles. With [offstage] the field stays mounted (its
/// controller, focus node and text input connection survive) but is not
/// painted, hit or read by semantics, as a rendered table's field is.
typedef RowTextSlot = Widget Function({required bool offstage});

/// What a [RowKindPresenter] knows of the editor row it presents (frozen,
/// D2).
@immutable
class PresentedRow {
  const PresentedRow({
    required this.segment,
    required this.index,
    required this.kind,
    required this.controller,
    this.geometry,
    this.marker = '',
    this.blockKey,
  });

  /// The text segment's index (`<s>` of `text-segment-<s>`).
  final int segment;

  /// The row's index in its segment.
  final int index;

  /// The row's kind.
  final RowKind kind;

  /// The row field's controller: it holds only the row's text.
  final LivePreviewController controller;

  /// An item row's marker column geometry; null for every other row.
  final ItemGeometry? geometry;

  /// An item row's marker as written, without the row's indentation; empty
  /// for every other row.
  final String marker;

  /// The key of the subtree holding the row's block (a rendered table's
  /// grid, an attachment's image or card) while it shows, so the host finds
  /// it; null for a row pumped alone.
  final GlobalKey? blockKey;
}

/// How editor rows of one [RowKind] are shown, measured and pressed (frozen,
/// D2). [presenterFor] picks the presenter of a row's kind.
abstract class RowKindPresenter {
  const RowKindPresenter();

  /// The row's body: [textSlot] (the row's field, possibly offstage) and any
  /// block the kind shows beside it. The rows host wraps the result in the
  /// row's `LivePreviewFrame`.
  Widget build(BuildContext context, PresentedRow row, RowTextSlot textSlot);

  /// Whether [row]'s text is hidden now: its field is mounted offstage and a
  /// block shows in its place. Find highlights, squiggles, the selection
  /// fill and link hits skip a row whose text is hidden.
  bool textHidden(PresentedRow row);

  /// [row]'s geometry while a block stands in for its text, in the row
  /// field's text offsets (the block's own box coordinates); null while the
  /// text slot answers (D3: `SegmentViewState.rowBoxes`).
  LineBoxSource? blockBoxes(PresentedRow row);

  /// Whether the press at global [position] belongs to [row]'s block (D5):
  /// the segment's pointer layer then ignores it, with no caret move, focus
  /// change, selection or drag, as it does a marker column's press.
  bool ownsPress(PresentedRow row, Offset position);
}

/// The presenter of prose, code and item rows: the row's field, inset and
/// marker-columned by its kind (frozen, D2).
///
/// - A prose row's text slot spans the text column.
/// - A code row's is inset 16.2 px left and 10 px right (A2).
/// - An item row (bullet, numbered, task, quote) puts a [MarkerColumn]
///   (Key `editor-row-marker-<segment>-<index>`) of its
///   [PresentedRow.geometry]'s width at its marker x, then the text slot from
///   the item's text x to the text column's right edge (a quote keeps one
///   column of right padding), so every wrapped line of the item starts at
///   its text x (hanging indent).
class TextRowPresenter extends RowKindPresenter {
  const TextRowPresenter();

  @override
  Widget build(BuildContext context, PresentedRow row, RowTextSlot textSlot) {
    final slot = textSlot(offstage: false);
    return switch ((row.kind, markerColumnKind(row.kind), row.geometry)) {
      (RowKind.code, _, _) => Padding(
        padding: EdgeInsets.only(
          left: codeTextInsetLeft,
          right: codeTextInsetRight,
        ),
        child: slot,
      ),
      (_, final column?, final item?) => Padding(
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
      ),
      _ => slot,
    };
  }

  @override
  bool textHidden(PresentedRow row) => false;

  @override
  LineBoxSource? blockBoxes(PresentedRow row) => null;

  @override
  bool ownsPress(PresentedRow row, Offset position) => false;
}

/// The presenter of table rows (Spec #197 R12, TD4, rulings D12, D14): the
/// grid (Key `editor-table-<segment>-<index>`, under [PresentedRow.blockKey])
/// while the row's controller is not `tableRevealed`, its field offstage;
/// revealed, the field shows and the grid is gone. The pointer layer owns
/// grid presses (D14), so it owns none.
///
/// While the grid shows, [blockBoxes] is the grid's line boxes
/// (`TableGridState.lineBoxes`) once it is built and laid out; null before
/// (the row's field, mounted offstage and still laid out, answers) and
/// while revealed.
class TableRowPresenter extends RowKindPresenter {
  const TableRowPresenter();

  @override
  Widget build(BuildContext context, PresentedRow row, RowTextSlot textSlot) {
    final controller = row.controller;
    return ListenableBuilder(
      listenable: Listenable.merge([controller, controller.revealGate]),
      builder: (context, _) {
        final revealed = controller.tableRevealed;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            textSlot(offstage: !revealed),
            if (!revealed)
              KeyedSubtree(
                key: row.blockKey,
                child: TableGrid(
                  key: ValueKey('editor-table-${row.segment}-${row.index}'),
                  text: controller.text,
                  style: editorBodyStyle(),
                  links: controller,
                  fenced: controller.fenced,
                ),
              ),
          ],
        );
      },
    );
  }

  @override
  bool textHidden(PresentedRow row) => row.controller.textHidden;

  @override
  LineBoxSource? blockBoxes(PresentedRow row) {
    if (!textHidden(row)) return null;
    TableGridState? grid;
    void visit(Element element) {
      if (grid != null) return;
      if (element is StatefulElement && element.state is TableGridState) {
        grid = element.state as TableGridState;
      } else {
        element.visitChildren(visit);
      }
    }

    row.blockKey?.currentContext?.visitChildElements(visit);
    return grid?.lineBoxes();
  }

  @override
  bool ownsPress(PresentedRow row, Offset position) => false;
}

/// Test seam: while set, [presenterFor] returns what it returns for a kind,
/// and the built-in presenter where it returns null. Tests reset it.
@visibleForTesting
RowKindPresenter? Function(RowKind kind)? debugRowKindPresenterOverride;

/// The presenter of editor rows of [kind] (frozen, D2): [TableRowPresenter]
/// for tables, [AttachmentRowPresenter] for attachments, [TextRowPresenter]
/// for every other kind.
RowKindPresenter presenterFor(RowKind kind) =>
    debugRowKindPresenterOverride?.call(kind) ??
    switch (kind) {
      RowKind.table => const TableRowPresenter(),
      RowKind.attachment => const AttachmentRowPresenter(),
      RowKind.prose ||
      RowKind.code ||
      RowKind.bullet ||
      RowKind.numbered ||
      RowKind.task ||
      RowKind.quote => const TextRowPresenter(),
    };

/// [LineBoxSource] over a block [box] (an image, a card, frozen D2, D4): one
/// line spanning the whole box, holding row offsets 0 to [textLength].
///
/// Its caret rect sits at the box's top-left, as tall as the box;
/// [offsetAt] is 0 everywhere; [boxesFor] a non-empty range is the box's
/// rect. Read when asked, so a relaid-out box reports its new size.
class BlockLineBoxes implements LineBoxSource {
  BlockLineBoxes(this.box, {this.textLength = 0});

  @override
  final RenderBox box;

  /// The row text length the block's one line holds.
  final int textLength;

  @override
  List<LineBox> get lines => [
    LineBox(
      range: TextRange(start: 0, end: textLength),
      top: 0,
      bottom: box.size.height,
    ),
  ];

  @override
  List<Rect> boxesFor(TextRange range) =>
      range.isCollapsed ? const [] : [Offset.zero & box.size];

  @override
  Rect caretRect(int offset) => Rect.fromLTWH(0, 0, 0, box.size.height);

  @override
  int offsetAt(Offset point) => 0;
}
