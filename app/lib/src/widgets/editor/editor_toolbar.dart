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
    this.sourceMode = false,
    this.onToggleSource,
  });
  final Note? note;
  final String? vaultPath;
  final SaveStatus status;
  final bool rightOpen;
  final VoidCallback onToggleRight;

  /// When non-null, the toolbar shows a "← back to canvas" pill that
  /// invokes this.
  final VoidCallback? onBackToCanvas;

  /// True while the body shows the single Source field.
  final bool sourceMode;

  /// Switches the body between the segmented view and Source; the `Source`
  /// toggle (Key `editor-source-toggle`) shows only when non-null.
  final VoidCallback? onToggleSource;

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
          if (onToggleSource != null) ...[
            _SourceToggle(active: sourceMode, onTap: onToggleSource!),
            const SizedBox(width: 4),
          ],
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

/// The `Source` toggle (Key `editor-source-toggle`): highlighted while the
/// body shows the plain Source field.
class _SourceToggle extends StatelessWidget {
  const _SourceToggle({required this.active, required this.onTap});
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: active ? 'show segments' : 'show markdown source',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: const Key('editor-source-toggle'),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? OmColors.surface3 : null,
              border: Border.all(
                color: active ? OmColors.line2 : OmColors.line1,
                width: 1,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.code,
                  size: 12,
                  color: active ? OmColors.accent : OmColors.fg2,
                ),
                const SizedBox(width: 5),
                Text(
                  'Source',
                  style: OmType.mono(
                    size: 11,
                    color: active ? OmColors.fg0 : OmColors.fg2,
                  ),
                ),
              ],
            ),
          ),
        ),
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
