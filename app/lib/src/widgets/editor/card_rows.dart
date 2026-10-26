import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../editor/editor_rows.dart';
import '../../editor/row_geometry.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import 'editor_row.dart';
import 'live_preview_controller.dart';
import 'live_preview_decorations.dart';
import 'live_preview_styles.dart';
import 'marker_column.dart';
import 'paragraph_line_boxes.dart';

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
/// - Painted decorations come from B2's `layoutDecorations` measured
///   through `RenderParagraphLineBoxes` (D6), across the row's full width;
///   quote bands are `surface4` (L14).
/// - Display only: no caret, focus, toggling or link clicks.
class CardRows extends StatelessWidget {
  const CardRows({super.key, required this.text});

  /// The card's rendered excerpt text (`RenderedExcerpt.text`).
  final String text;

  /// The card's base text style, as built (pack #172: `fg1`).
  static TextStyle _baseStyle() =>
      OmType.mono(size: monoFontSize, color: OmColors.fg1, height: 1.7);

  @override
  Widget build(BuildContext context) {
    final specs = splitRows(text, atSegmentStart: true);
    final geometries = rowGeometries(specs);
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
          _row(r, specs[r], geometries[r], base, scaler),
      ],
    );
  }

  Widget _row(
    int r,
    RowSpec spec,
    ItemGeometry? geometry,
    TextStyle base,
    TextScaler scaler,
  ) {
    final rowText = text.substring(spec.textStart, spec.textEnd);
    final quote = spec.kind == RowKind.quote;
    final codeRow = spec.kind == RowKind.code;
    final atSegmentStart = spec.textStart == 0;
    final rich = _RowText(
      key: ValueKey('card-row-text-$r'),
      child: RichText(
        textScaler: scaler,
        strutStyle: livePreviewStrut(codeRow: codeRow),
        text: buildLivePreviewSpan(
          rowText,
          style: base,
          forceHidden: true,
          itemText: spec.isItem,
          taskDone: spec.done,
          quote: quote,
          atSegmentStart: atSegmentStart,
          codeRow: codeRow,
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
