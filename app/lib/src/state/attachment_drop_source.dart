import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A drag moved over the target: [localPosition] is relative to the target.
typedef AttachmentDragCallback = void Function(Offset localPosition);

/// Files were dropped: their absolute [paths] in the order the system gave
/// them, and where in the target ([localPosition]) they landed.
typedef AttachmentDropCallback =
    void Function(List<String> paths, Offset localPosition);

/// The drop-target seam (Spec #123 R7): wraps a child so files dragged from
/// Finder report as plain callbacks. Tests replace it with a fake that fires
/// the callbacks directly.
abstract interface class AttachmentDropSource {
  /// Wraps [child] in a drop target.
  ///
  /// While [enabled] is false the target reports nothing (a drop target
  /// still gets drags when another widget, such as a modal, covers it).
  /// [onEntered] fires when a drag enters, [onUpdated] while it moves,
  /// [onExited] when it leaves or the target is disabled mid-drag, and
  /// [onDropped] when files are released over the target. A drop ends the
  /// drag, so [onExited] fires just before [onDropped].
  Widget buildTarget({
    required Widget child,
    required bool enabled,
    AttachmentDragCallback? onEntered,
    AttachmentDragCallback? onUpdated,
    VoidCallback? onExited,
    AttachmentDropCallback? onDropped,
  });
}

/// The default [AttachmentDropSource]: `desktop_drop`'s `DropTarget`.
class DesktopAttachmentDropSource implements AttachmentDropSource {
  const DesktopAttachmentDropSource();

  @override
  Widget buildTarget({
    required Widget child,
    required bool enabled,
    AttachmentDragCallback? onEntered,
    AttachmentDragCallback? onUpdated,
    VoidCallback? onExited,
    AttachmentDropCallback? onDropped,
  }) => DropTarget(
    enable: enabled,
    onDragEntered: onEntered == null
        ? null
        : (details) => onEntered(details.localPosition),
    onDragUpdated: onUpdated == null
        ? null
        : (details) => onUpdated(details.localPosition),
    onDragExited: onExited == null ? null : (_) => onExited(),
    onDragDone: onDropped == null
        ? null
        : (details) => onDropped([
            for (final file in details.files) file.path,
          ], details.localPosition),
    child: child,
  );
}

/// The app's [AttachmentDropSource]. Tests override it with a fake.
final attachmentDropSourceProvider = Provider<AttachmentDropSource>(
  (ref) => const DesktopAttachmentDropSource(),
);
