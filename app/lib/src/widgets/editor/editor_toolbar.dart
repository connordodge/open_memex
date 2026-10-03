import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../../db.dart';
import '../../state/editor_controller.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../atoms.dart';
import 'note_menu.dart';

/// The note editor's top bar (Key `editor-toolbar`): the back-to-canvas pill,
/// the breadcrumb, save-failure chips, share, the note menu and the
/// right-panel toggle.
class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    super.key,
    required this.note,
    required this.vaultPath,
    required this.status,
    required this.rightOpen,
    required this.onToggleRight,
    this.onBackToCanvas,
  });
  final Note? note;
  final String? vaultPath;
  final SaveStatus status;
  final bool rightOpen;
  final VoidCallback onToggleRight;

  /// When non-null, the toolbar shows a "← back to canvas" pill that
  /// invokes this.
  final VoidCallback? onBackToCanvas;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('editor-toolbar'),
      height: 44,
      color: OmColors.surface1,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          if (onBackToCanvas != null) ...[
            _BackToCanvasButton(onTap: onBackToCanvas!),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: _Breadcrumb(note: note, vaultPath: vaultPath),
          ),
          if (status == SaveStatus.conflict)
            const OmChip(label: 'conflict — reload', tone: ChipTone.danger),
          if (status == SaveStatus.error)
            const OmChip(label: 'save failed', tone: ChipTone.danger),
          const SizedBox(width: 8),
          OmButton(
            kind: OmButtonKind.ghost,
            size: 26,
            icon: LucideIcons.share,
            onPressed: null,
            tooltip: 'share',
          ),
          const SizedBox(width: 4),
          NoteMenuButton(note: note),
          const SizedBox(width: 4),
          // Right-panel (agents) toggle — relocated here from the old
          // second-level tab bar, which duplicated the workspace tab row.
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onToggleRight,
              child: Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                child: Icon(
                  LucideIcons.atom,
                  size: 14,
                  color: rightOpen ? OmColors.fg0 : OmColors.fg2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "← back to canvas" pill shown in the toolbar when a note is opened by
/// zooming in from a canvas.
class _BackToCanvasButton extends StatelessWidget {
  const _BackToCanvasButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: OmColors.surface2,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        key: const Key('zoom-out-back-button'),
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Text(
            '← back to canvas',
            style: OmType.mono(size: 11, color: OmColors.fg1),
          ),
        ),
      ),
    );
  }
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.note, required this.vaultPath});
  final Note? note;
  final String? vaultPath;
  @override
  Widget build(BuildContext context) {
    if (note == null || vaultPath == null) {
      return const SizedBox.shrink();
    }
    final vaultName = p.basename(vaultPath!);
    final parts = [vaultName, '${note!.title}.md'];
    return Row(
      children: [
        for (var i = 0; i < parts.length; i++) ...[
          Text(
            parts[i],
            style: OmType.mono(
              size: 11.5,
              color: i == parts.length - 1 ? OmColors.fg1 : OmColors.fg3,
            ),
          ),
          if (i < parts.length - 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                '/',
                style: OmType.mono(size: 11.5, color: OmColors.fg4),
              ),
            ),
        ],
      ],
    );
  }
}
