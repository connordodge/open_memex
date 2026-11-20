// WI #147 (Spec #123 A2: R7, R11; rulings D12, D20): the note editor's drop
// target. Files dropped on the editor body go to A4's attach action
// (`attachControllerProvider`), anchored to the line under the drop point.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
///   open, or while the vault can't be written (R11).
///
/// The seam's local positions are relative to this widget's box.
class AttachmentDropTarget extends ConsumerStatefulWidget {
  const AttachmentDropTarget({super.key, required this.child});

  /// The editor body.
  final Widget child;

  @override
  ConsumerState<AttachmentDropTarget> createState() =>
      _AttachmentDropTargetState();
}

class _AttachmentDropTargetState extends ConsumerState<AttachmentDropTarget> {
  @override
  Widget build(BuildContext context) => widget.child;
}
