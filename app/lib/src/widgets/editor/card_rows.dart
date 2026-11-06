import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../editor/editor_rows.dart';
import '../../editor/markdown_inline.dart';
import '../../editor/markdown_lines.dart';
import '../../editor/markdown_table.dart' show splitTableLine;
import '../../editor/row_geometry.dart';
import '../../editor/tag_grammar.dart' show fencedRowLines, normalizeTagName;
import '../../state/tags_browse_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import 'editor_row.dart';
import 'line_boxes.dart';
import 'live_preview_controller.dart';
import 'live_preview_decorations.dart';
import 'live_preview_styles.dart';
import 'marker_column.dart';
import 'paragraph_line_boxes.dart';
import 'table_grid.dart';

/// An excerpt card's body (WI #172, B4; Spec R7, D4, D7, D12, D17): the
/// card's rendered excerpt [text] split into rows with A1's `splitRows`, each
/// rendered read-only with live preview's styling and every marker hidden.
///
/// - Row `r` sits under Key `card-row-<r>`; its text (one `RichText` of
///   B1's `buildLivePreviewSpan` with `forceHidden: true`) under Key
///   `card-row-text-<r>`; an item row's `MarkerColumn` (C1b, read-only)
///   under Key `card-row-marker-<r>`. Leading and trailing empty prose rows
///   (empty [text], a trailing line break) are left out; an interior empty
///   prose row renders as one blank body line, as in the editor.
/// - Item rows hang their text at the item's text x (A2 geometry), as the
///   editor's rows do; prose rows start at the left edge; code rows keep
///   the editor's code insets and lay out with the code row strut (D18), so
///   hidden fence lines are 8 px tall. Rows stack with no gap.
/// - Row text lays out with the body field's even leading, so its glyphs
///   sit where the editor body row's do; an empty row is one body line.
/// - Painted decorations come from B2's `layoutDecorations` measured
///   through `RenderParagraphLineBoxes` (D6), across the row's full width;
///   quote bands are `surface4` (L14).
/// - A table row (WI #208; Spec #197 R25, D12, D16, D23) renders as the
///   editor's [TableGrid] under Key `card-table-<r>` inside `card-row-<r>`:
///   the row's text in the card text style, header band `surface4`, no link
///   controller unless the row holds a tag (markers always hidden, never
///   revealed). Its text is painted by the grid only. Several tables in one
///   excerpt are separate rows, so each is its own grid, stacked with no gap.
/// - A row holding a live `#tag` (WI #247, ruling D51) adds [_CardTagRegion]:
///   a click on the tag opens Tags mode. Every other row, a table row
///   included, adds no listener, gesture detector or mouse region (D14).
/// - Otherwise display only: no caret, focus, toggling or link clicks.
class CardRows extends StatelessWidget {
  const CardRows({super.key, required this.text});

  /// The card's rendered excerpt text (`RenderedExcerpt.text`).
  final String text;

  /// The card's base text style, as built (pack #172: `fg1`).
  static TextStyle _baseStyle() =>
      OmType.mono(size: monoFontSize, color: OmColors.fg1, height: 1.7);

  /// The style row text [rowText] lays out in: [base] with even leading, as
  /// the editor body's field lays its text out (its `TextField` merges the
  /// Material 3 body style, whose leading is even), so a card row's glyphs
  /// sit where the body row's do. An empty row keeps [base]'s proportional
  /// leading: it has no glyphs to place, and an empty paragraph with even
  /// leading lays out 32 px tall, not one 22.95 px line (review-r2).
  static TextStyle _rowStyle(TextStyle base, String rowText) => rowText.isEmpty
      ? base
      : base.copyWith(leadingDistribution: TextLeadingDistribution.even);

  @override
  Widget build(BuildContext context) {
    final specs = splitRows(text, atSegmentStart: true);
    final geometries = rowGeometries(specs);
    final fenced = fencedRowLines(text, specs);
    final scaler = MediaQuery.textScalerOf(context);
    final base = _baseStyle();
    bool blank(RowSpec spec) =>
        spec.kind == RowKind.prose && spec.textLength == 0;
    // The rows between the leading and the trailing empty prose rows.
    var first = 0;
    while (first < specs.length && blank(specs[first])) {
      first++;
    }
    var last = specs.length - 1;
    while (last >= first && blank(specs[last])) {
      last--;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var r = first; r <= last; r++)
          _row(r, specs[r], geometries[r], fenced[r], base, scaler),
      ],
    );
  }

  Widget _row(
    int r,
    RowSpec spec,
    ItemGeometry? geometry,
    List<bool> fenced,
    TextStyle base,
    TextScaler scaler,
  ) {
    final rowText = text.substring(spec.textStart, spec.textEnd);
    final quote = spec.kind == RowKind.quote;
    final codeRow = spec.kind == RowKind.code;
    final atSegmentStart = spec.textStart == 0;
    final style = _rowStyle(base, rowText);
    final tags = _liveTags(
      rowText,
      itemText: spec.isItem,
      atSegmentStart: atSegmentStart,
      fenced: fenced,
    );
    Widget tagged(_TagRowBuilder build) =>
        tags.isEmpty ? build(null) : _CardTagRegion(tags: tags, builder: build);
    if (spec.kind == RowKind.table) {
      return KeyedSubtree(
        key: ValueKey('card-row-$r'),
        child: tagged(
          (links) => TableGrid(
            key: ValueKey('card-table-$r'),
            text: rowText,
            style: style,
            links: links,
            headerBand: OmColors.surface4,
            fenced: fenced,
          ),
        ),
      );
    }
    final rich = tagged(
      (links) => _RowText(
        key: ValueKey('card-row-text-$r'),
        child: RichText(
          textScaler: scaler,
          // As the body field's EditableText does with its strut.
          strutStyle: livePreviewStrut(
            codeRow: codeRow,
          ).inheritFromTextStyle(style),
          text: buildLivePreviewSpan(
            rowText,
            style: style,
            forceHidden: true,
            itemText: spec.isItem,
            taskDone: spec.done,
            quote: quote,
            atSegmentStart: atSegmentStart,
            cmdHover: links?.cmdHover,
            codeRow: codeRow,
            fenced: fenced,
          ),
        ),
      ),
    );
    final Widget row = switch (spec.kind) {
      RowKind.prose => rich,
      RowKind.code => Padding(
        padding: EdgeInsets.only(
          left: codeTextInsetLeft,
          right: codeTextInsetRight,
        ),
        child: rich,
      ),
      _ => Padding(
        padding: EdgeInsets.only(left: geometry!.markerX),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            KeyedSubtree(
              key: ValueKey('card-row-marker-$r'),
              child: MarkerColumn(
                // The marker as written, without the row's indentation.
                marker: text.substring(spec.start, spec.textStart).trimLeft(),
                width: geometry.columnWidth,
                readOnly: true,
              ),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                  right: itemTextRightInset(markerColumnKind(spec.kind)!),
                ),
                child: rich,
              ),
            ),
          ],
        ),
      ),
    };
    return _RowDecorations(
      key: ValueKey('card-row-$r'),
      text: rowText,
      quote: quote,
      atSegmentStart: atSegmentStart,
      child: row,
    );
  }
}

/// A tag a click on a card row opens: its [span] in the row's text and its
/// normalized [name].
final class _CardTag {
  const _CardTag(this.span, this.name);

  final TextRange span;
  final String name;
}

/// The tags of the card row text [text] that get tag ink, as
/// `buildLivePreviewSpan` finds them with the same props: tokenized line by
/// line (a table line cell by cell), each stretch knowing the code unit before
/// it, and none on a line [fenced] says is fenced code.
List<_CardTag> _liveTags(
  String text, {
  required bool itemText,
  required bool atSegmentStart,
  required List<bool> fenced,
}) {
  final tags = <_CardTag>[];
  void tokenize(int start, int end) {
    final stretch = text.substring(start, end);
    for (final t in tokenizeInline(
      stretch,
      before: unitBeforeInLine(text, start),
    )) {
      if (t.kind != InlineTokenKind.tag) continue;
      tags.add(
        _CardTag(
          TextRange(start: start + t.start, end: start + t.end),
          normalizeTagName(stretch.substring(t.start + 1, t.end))!,
        ),
      );
    }
  }

  final lines = classifyLines(text, atSegmentStart: atSegmentStart);
  for (final (i, line) in lines.indexed) {
    if (fenced.elementAtOrNull(i) ?? false) continue;
    switch (itemText ? MdLineKind.plain : line.kind) {
      case MdLineKind.heading ||
          MdLineKind.bullet ||
          MdLineKind.numbered ||
          MdLineKind.task ||
          MdLineKind.quote:
        tokenize(line.textStart, line.contentEnd);
      case MdLineKind.plain:
        tokenize(line.start, line.contentEnd);
      case MdLineKind.tableHeader || MdLineKind.tableBody:
        final split = splitTableLine(
          text,
          start: line.start,
          end: line.contentEnd,
        );
        for (final cell in split.cells) {
          tokenize(cell.start, cell.end);
        }
      default:
        break;
    }
  }
  return tags;
}

/// Builds a card row's content; [links] holds its Cmd hover, null on a row with
/// no [_CardTagRegion].
typedef _TagRowBuilder = Widget Function(LivePreviewController? links);

/// The pointer path of one card row holding [tags] (WI #247, ruling D51): a
/// card has no `LinkRegion`, and wikilinks in a card stay inert.
///
/// - A primary press and release on the same tag calls `revealTag`, with or
///   without Cmd. A card's markup is always hidden, so every plain click
///   follows.
/// - Over a tag the cursor is [SystemMouseCursors.click]; with Cmd held the tag
///   also renders hovered, through the private controller [builder] gets.
///
/// Hit-tests through the row's own line boxes: the row text's paragraph, or a
/// table row's `TableGridState.lineBoxes` (row-local offsets either way).
class _CardTagRegion extends ConsumerStatefulWidget {
  const _CardTagRegion({required this.tags, required this.builder});

  final List<_CardTag> tags;
  final _TagRowBuilder builder;

  @override
  ConsumerState<_CardTagRegion> createState() => _CardTagRegionState();
}

class _CardTagRegionState extends ConsumerState<_CardTagRegion> {
  /// Holds the row's Cmd hover in `cmdHover`, which a table's grid reads.
  final _links = LivePreviewController();

  /// The mouse's global position while it is over the row, else null.
  Offset? _pointer;

  /// The span of the tag under the mouse, or null.
  TextRange? _hover;

  /// The span of the tag a primary press went down on, or null.
  TextRange? _pressed;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _links.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (_pointer != null) _refresh();
    return false;
  }

  void _pointerAt(Offset? global) {
    _pointer = global;
    _refresh();
  }

  /// Recomputes the hovered tag under the pointer.
  void _refresh() {
    final at = _pointer;
    final hover = at == null ? null : _tagAt(at)?.span;
    final lit = HardwareKeyboard.instance.isMetaPressed ? hover : null;
    if (hover == _hover && lit == _links.cmdHover) return;
    setState(() {
      _hover = hover;
      _links.cmdHover = lit;
    });
  }

  void _onPointerDown(PointerDownEvent event) {
    _pressed = event.buttons == kPrimaryButton
        ? _tagAt(event.position)?.span
        : null;
  }

  void _onPointerUp(PointerUpEvent event) {
    final pressed = _pressed;
    _pressed = null;
    if (pressed == null) return;
    final up = _tagAt(event.position);
    if (up == null || up.span != pressed) return;
    revealTag(ref, up.name);
  }

  /// The tag whose glyphs are under global [at], or null.
  _CardTag? _tagAt(Offset at) {
    final source = _lineBoxes();
    if (source == null) return null;
    final local = source.box.globalToLocal(at);
    final offset = source.offsetAt(local);
    for (final tag in widget.tags) {
      if (offset < tag.span.start || offset > tag.span.end) continue;
      if (source.boxesFor(tag.span).any((r) => r.contains(local))) return tag;
    }
    return null;
  }

  /// The line boxes of the row under this region, once laid out.
  LineBoxSource? _lineBoxes() {
    LineBoxSource? found;
    void visit(Element element) {
      switch (element) {
        case StatefulElement(state: final TableGridState grid):
          found = grid.lineBoxes();
        case RenderObjectElement(renderObject: final _RenderRowText row):
          if (row.paragraph case final paragraph?) {
            found = RenderParagraphLineBoxes(paragraph);
          }
        default:
          element.visitChildren(visit);
      }
    }

    context.visitChildElements(visit);
    return found;
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _onPointerDown,
    onPointerUp: _onPointerUp,
    onPointerCancel: (_) => _pressed = null,
    child: MouseRegion(
      cursor: _hover == null ? MouseCursor.defer : SystemMouseCursors.click,
      onHover: (event) => _pointerAt(event.position),
      onExit: (_) => _pointerAt(null),
      child: widget.builder(_links),
    ),
  );
}

/// Marks the render box holding a row's text paragraph, so the row's
/// decorations measure that paragraph (not a painted number's).
class _RowText extends SingleChildRenderObjectWidget {
  const _RowText({super.key, required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderRowText();
}

class _RenderRowText extends RenderProxyBox {
  /// The row text's paragraph, once laid out.
  RenderParagraph? get paragraph => switch (child) {
    final RenderParagraph p when p.hasSize => p,
    _ => null,
  };
}

/// Paints B2's decorations of one card row's [text] behind its [child],
/// across the row's full width (marker column included).
class _RowDecorations extends SingleChildRenderObjectWidget {
  const _RowDecorations({
    super.key,
    required this.text,
    required this.quote,
    required this.atSegmentStart,
    required Widget super.child,
  });

  final String text;
  final bool quote;
  final bool atSegmentStart;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderRowDecorations(text, quote, atSegmentStart);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderRowDecorations renderObject,
  ) => renderObject.update(text, quote, atSegmentStart);
}

class _RenderRowDecorations extends RenderProxyBox {
  _RenderRowDecorations(this._text, this._quote, this._atSegmentStart);

  String _text;
  bool _quote;
  bool _atSegmentStart;

  void update(String text, bool quote, bool atSegmentStart) {
    if (text == _text && quote == _quote && atSegmentStart == _atSegmentStart) {
      return;
    }
    _text = text;
    _quote = quote;
    _atSegmentStart = atSegmentStart;
    markNeedsPaint();
  }

  /// The row text's anchor under this row.
  _RenderRowText? _anchor() {
    _RenderRowText? found;
    void visit(RenderObject node) {
      if (found != null) return;
      if (node is _RenderRowText) {
        found = node;
      } else {
        node.visitChildren(visit);
      }
    }

    visitChildren(visit);
    return found;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final paragraph = _anchor()?.paragraph;
    if (paragraph != null) {
      // The paragraph's origin in this row's coordinates.
      final origin = MatrixUtils.transformPoint(
        paragraph.getTransformTo(this),
        Offset.zero,
      );
      final decorations = layoutDecorations(
        text: _text,
        boxes: RenderParagraphLineBoxes(paragraph),
        columnLeft: -origin.dx,
        columnRight: size.width - origin.dx,
        atSegmentStart: _atSegmentStart,
        quote: _quote,
        quoteBandColor: OmColors.surface4,
      );
      final shift = offset + origin;
      for (final d in decorations) {
        final rrect = RRect.fromRectAndRadius(
          d.rect.shift(shift),
          Radius.circular(d.radius),
        );
        context.canvas.drawRRect(rrect, Paint()..color = d.fill);
        if (d.border case final border?) {
          // 1 px inside the rect.
          context.canvas.drawRRect(
            rrect.deflate(0.5),
            Paint()
              ..color = border
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1,
          );
        }
      }
    }
    super.paint(context, offset);
  }
}
