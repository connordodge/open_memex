// WI #145 (Spec #123 R7/R8 seams, D17): fakes for the attachment input
// seams. `FakeAttachmentDropSource` lets a test fire a drag (enter, update,
// exit, drop) on a mounted target; `FakePasteboardReader` answers the
// clipboard from a queue. Neither touches `desktop_drop` or a channel.
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:open_memex_app/src/state/attachment_drop_source.dart';
import 'package:open_memex_app/src/state/pasteboard_reader.dart';

/// An [AttachmentDropSource] whose targets a test drives by hand.
///
/// Like the real `DropTarget`, a target reports nothing while it is
/// disabled (and an exit if it is disabled mid-drag), and nothing once it
/// is unmounted. The fire methods act on the most recently mounted target
/// and, unlike the real one, do not require an `enter` before a drop. A drop
/// during a drag reports an exit first, as the real one does.
class FakeAttachmentDropSource implements AttachmentDropSource {
  _FakeDropTargetState? _target;

  /// How many targets the seam has built (one per `buildTarget` call that
  /// mounted).
  int mounts = 0;

  /// Whether a target is mounted right now.
  bool get isMounted => _target != null;

  /// The mounted target's `enabled` flag; null when nothing is mounted.
  bool? get enabled => _target?.widget.enabled;

  /// A drag enters the target at [localPosition].
  void enter(Offset localPosition) {
    final t = _live;
    if (t == null) return;
    t._dragging = true;
    t.widget.onEntered?.call(localPosition);
  }

  /// A drag moves to [localPosition].
  void update(Offset localPosition) {
    final t = _live;
    if (t == null) return;
    t.widget.onUpdated?.call(localPosition);
  }

  /// A drag leaves the target.
  void exit() {
    final t = _live;
    if (t == null) return;
    t._dragging = false;
    t.widget.onExited?.call();
  }

  /// Files at [paths] are released over the target at [localPosition].
  void drop(List<String> paths, {Offset localPosition = Offset.zero}) {
    final t = _live;
    if (t == null) return;
    // The real `DropTarget` ends the drag (an exit) before it reports the drop.
    if (t._dragging) {
      t._dragging = false;
      t.widget.onExited?.call();
    }
    t.widget.onDropped?.call(List.of(paths), localPosition);
  }

  /// The mounted target when it is also enabled.
  _FakeDropTargetState? get _live {
    final t = _target;
    return (t != null && t.widget.enabled) ? t : null;
  }

  @override
  Widget buildTarget({
    required Widget child,
    required bool enabled,
    AttachmentDragCallback? onEntered,
    AttachmentDragCallback? onUpdated,
    VoidCallback? onExited,
    AttachmentDropCallback? onDropped,
  }) => _FakeDropTarget(
    source: this,
    enabled: enabled,
    onEntered: onEntered,
    onUpdated: onUpdated,
    onExited: onExited,
    onDropped: onDropped,
    child: child,
  );
}

class _FakeDropTarget extends StatefulWidget {
  const _FakeDropTarget({
    required this.source,
    required this.enabled,
    required this.onEntered,
    required this.onUpdated,
    required this.onExited,
    required this.onDropped,
    required this.child,
  });

  final FakeAttachmentDropSource source;
  final bool enabled;
  final AttachmentDragCallback? onEntered;
  final AttachmentDragCallback? onUpdated;
  final VoidCallback? onExited;
  final AttachmentDropCallback? onDropped;
  final Widget child;

  @override
  State<_FakeDropTarget> createState() => _FakeDropTargetState();
}

class _FakeDropTargetState extends State<_FakeDropTarget> {
  /// A drag is over the target (entered, not yet exited or dropped).
  bool _dragging = false;

  @override
  void didUpdateWidget(_FakeDropTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The real `DropTarget` reports an exit when it is disabled mid-drag.
    if (oldWidget.enabled && !widget.enabled && _dragging) {
      _dragging = false;
      widget.onExited?.call();
    }
  }

  @override
  void initState() {
    super.initState();
    widget.source._target = this;
    widget.source.mounts++;
  }

  @override
  void dispose() {
    if (identical(widget.source._target, this)) widget.source._target = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A [PasteboardReader] that answers from [contents].
class FakePasteboardReader implements PasteboardReader {
  FakePasteboardReader([this.contents = const PasteboardContents()]);

  /// What every [read] returns.
  PasteboardContents contents;

  /// How many times [read] was called.
  int reads = 0;

  @override
  Future<PasteboardContents> read() async {
    reads++;
    return contents;
  }
}

/// A run-time (non-const) PNG-looking payload for tests.
Uint8List fakePngBytes([int length = 8]) => Uint8List.fromList([
  0x89,
  0x50,
  0x4e,
  0x47,
  for (var i = 0; i < length; i++) i,
]);
