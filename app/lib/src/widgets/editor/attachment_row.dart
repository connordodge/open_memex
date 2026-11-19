// The attachment row presenter (Spec #123, rulings D1, D5, D6): #123-V3
// fills it. Until then an attachment row renders and edits like a prose row
// with the same text (WI #124 stub, frozen contract of `row_kinds.dart`).

import 'package:flutter/widgets.dart';

import 'line_boxes.dart';
import 'row_kinds.dart';

/// The presenter of `RowKind.attachment` rows. Stub (WI #124): shows the
/// row's field like a prose row, hides no text, has no block geometry and
/// owns no press.
class AttachmentRowPresenter extends RowKindPresenter {
  const AttachmentRowPresenter();

  @override
  Widget build(BuildContext context, PresentedRow row, RowTextSlot textSlot) =>
      const SizedBox.shrink();

  @override
  bool textHidden(PresentedRow row) => false;

  @override
  LineBoxSource? blockBoxes(PresentedRow row) => null;

  @override
  bool ownsPress(PresentedRow row, Offset position) => false;
}
