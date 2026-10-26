import 'package:flutter/widgets.dart';

/// An excerpt card's body (WI #172, B4; Spec R7, D4, D7, D12, D17): the
/// card's rendered excerpt [text] split into rows with A1's `splitRows`, each
/// rendered read-only with live preview's styling and every marker hidden.
///
/// - Row `r` sits under Key `card-row-<r>`; its text (one `RichText` of
///   B1's `buildLivePreviewSpan` with `forceHidden: true`) under Key
///   `card-row-text-<r>`; an item row's `MarkerColumn` (C1b, read-only)
///   under Key `card-row-marker-<r>`.
/// - Item rows hang their text at the item's text x (A2 geometry).
/// - Painted decorations come from B2's `layoutDecorations` measured
///   through `RenderParagraphLineBoxes` (D6); quote bands are `surface4`
///   (L14).
/// - Display only: no caret, focus, toggling or link clicks.
class CardRows extends StatelessWidget {
  const CardRows({super.key, required this.text});

  /// The card's rendered excerpt text (`RenderedExcerpt.text`).
  final String text;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}
