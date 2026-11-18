// WI #82 (Spec #61 F2): the Find bar, design B's floating box over the note
// body. F6 mounts it in the note editor's `_bodyOverlays` slot.
//
// Skeleton (test author, red mode): the public API only. It shows nothing.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../editor/find_in_note.dart';

/// The Find bar: a `Positioned` box 10 px below the body top and 12 px from
/// its right edge, `findBoxWidth(bodyWidth)` wide and 38 px tall, shown only
/// while `findInNoteProvider.open` is true. It must be a direct child of the
/// body's `Stack`.
///
/// Stepping (Enter, Shift+Enter, the up and down buttons) calls [onStep]
/// with the new current match; closing (Esc in the field, the close button)
/// calls [onClose] with the current match, or null when there is none. The
/// bar never touches the editor's caret or selection itself (Req 20).
class FindBarOverlay extends ConsumerStatefulWidget {
  const FindBarOverlay({
    super.key,
    required this.bodyWidth,
    required this.onStep,
    required this.onClose,
  });

  /// The note body's width; the box is `findBoxWidth(bodyWidth)` wide.
  final double bodyWidth;

  /// Called with the new current match after each step from the bar.
  final ValueChanged<FindMatch> onStep;

  /// Called with the current match (null when there is none) after the bar
  /// closes from Esc in the field or the close button.
  final ValueChanged<FindMatch?> onClose;

  @override
  ConsumerState<FindBarOverlay> createState() => _FindBarOverlayState();
}

class _FindBarOverlayState extends ConsumerState<FindBarOverlay> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
