// WI #147 (Spec #123 A2: R7, R11; rulings D12, D20): the note editor's drop
// target. Files dropped on the editor body go to A4's attach action
// (`attachControllerProvider`), anchored to the line under the drop point.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/attach_controller.dart';
import '../../state/attachment_drop_source.dart';
import '../../state/vault_access_state.dart';
import '../../theme/colors.dart';
import 'segmented_body.dart' show segmentedBodyDropLine;
import 'source_surface.dart' show sourceFieldLineBoxes;

/// Key of the outline the editor shows while files are dragged over it: a
/// 2 px `OmColors.accent` border, the focus-ring style (R7).
const attachmentDropOutlineKey = Key('editor-drop-outline');

/// Wraps the note editor's body (live preview or Source mode) in A1's drop
/// seam (`attachmentDropSourceProvider`), Spec #123 R7:
/// - a drop hands its paths, in drop order, to
///   `AttachController.attachPaths`, anchored to the body line under the
///   drop point: a text line, an excerpt card's line, or the person
///   section's last line for a drop below the last line;
/// - a drop on the note header, or outside this widget's box, does nothing;
/// - while files are dragged over it, [attachmentDropOutlineKey] shows;
/// - nothing is offered while the Command palette, a dialog or a sheet is
///   open, while the vault can't be written (R11), or while [active] is
///   false (the outgoing editor of a zoom switch).
///
/// The seam's local positions are relative to this widget's box.
class AttachmentDropTarget extends ConsumerStatefulWidget {
  const AttachmentDropTarget({
    super.key,
    required this.child,
    this.active = true,
  });

  /// The editor body.
  final Widget child;

  /// False while the editor is the outgoing one of a zoom switch: one drop
  /// then reaches only the incoming editor's target.
  final bool active;

  @override
  ConsumerState<AttachmentDropTarget> createState() =>
      _AttachmentDropTargetState();
}

class _AttachmentDropTargetState extends ConsumerState<AttachmentDropTarget> {
  /// True while files are dragged over the body (entered, not yet exited
  /// or dropped).
  bool _dragging = false;

  void _setDragging(bool dragging) {
    if (mounted && _dragging != dragging) {
      setState(() => _dragging = dragging);
    }
  }

  void _onDragged(Offset _) => _setDragging(true);

  void _onExited() => _setDragging(false);

  void _onDropped(List<String> paths, Offset localPosition) {
    _setDragging(false);
    if (!mounted) return;
    final box = context.findRenderObject()! as RenderBox;
    if (!(Offset.zero & box.size).contains(localPosition)) return;
    final line = _lineAt(box.localToGlobal(localPosition));
    if (line == null) return;
    ref
        .read(attachControllerProvider)
        .attachPaths(context, paths, anchorLine: line);
  }

  /// The body line under global [position]: Source mode's field line, or
  /// the segmented body's ([segmentedBodyDropLine]). Null over the note
  /// header.
  int? _lineAt(Offset position) {
    final source = _descendant(
      context,
      (e) => e.widget.key == const Key('editor-source-surface'),
    );
    if (source == null) return segmentedBodyDropLine(context, position);
    final body = _descendant(
      source,
      (e) => e.widget.key == const Key('editor-body'),
    );
    final area = body?.findRenderObject();
    final field = body == null
        ? null
        : _descendant(body, (e) => e.widget is EditableText);
    final boxes = sourceFieldLineBoxes(area);
    if (area is! RenderBox || field == null || boxes == null) return null;
    // Above the body field: the note header.
    if (position.dy < area.localToGlobal(Offset.zero).dy) return null;
    final text = (field.widget as EditableText).controller.text;
    final offset = boxes.offsetAt(boxes.box.globalToLocal(position));
    return '\n'
        .allMatches(text.substring(0, offset.clamp(0, text.length)))
        .length;
  }

  @override
  Widget build(BuildContext context) {
    // R11, and no drop under a modal route (the Command palette, a dialog,
    // a sheet): `desktop_drop` reports drags under other widgets too.
    final writable =
        ref.watch(vaultAccessProvider.select((a) => a?.canWrite)) ?? false;
    return ref
        .watch(attachmentDropSourceProvider)
        .buildTarget(
          enabled:
              widget.active &&
              writable &&
              (ModalRoute.isCurrentOf(context) ?? true),
          onEntered: _onDragged,
          onUpdated: _onDragged,
          onExited: _onExited,
          onDropped: _onDropped,
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              widget.child,
              if (_dragging)
                const Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      key: attachmentDropOutlineKey,
                      decoration: BoxDecoration(
                        border: Border.fromBorderSide(
                          BorderSide(color: OmColors.accent, width: 2),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
  }
}

/// The first element under [root] (depth first) that [test] accepts.
Element? _descendant(BuildContext root, bool Function(Element) test) {
  Element? found;
  void visit(Element e) {
    if (found != null) return;
    if (test(e)) {
      found = e;
    } else {
      e.visitChildren(visit);
    }
  }

  root.visitChildElements(visit);
  return found;
}
