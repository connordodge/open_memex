import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../db.dart';
import '../../state/tabs_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../atoms.dart';

/// The sidebar's note list (Key `notes-rail`, one `note-list-item-<id>` row
/// per note), or its empty state with a "new note" button when [notes] is
/// empty. Tapping a row opens or focuses that note's tab.
///
/// Fills the bounded height its parent gives it.
class NotesPane extends ConsumerWidget {
  const NotesPane({
    super.key,
    required this.notes,
    this.activeNoteId,
    required this.onNewNote,
  });
  final List<NoteListItem> notes;

  /// The note whose row is highlighted, if any.
  final String? activeNoteId;
  final VoidCallback onNewNote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (notes.isEmpty) return _EmptyTree(onCreate: onNewNote);
    return ListView.builder(
      key: const Key('notes-rail'),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      itemCount: notes.length,
      itemBuilder: (_, i) {
        final n = notes[i];
        return _TreeItem(
          note: n,
          active: n.id == activeNoteId,
          onTap: () =>
              ref.read(tabsProvider.notifier).openOrFocus(NoteTab(n.id)),
        );
      },
    );
  }
}

class _TreeItem extends StatefulWidget {
  const _TreeItem({
    required this.note,
    required this.active,
    required this.onTap,
  });
  final NoteListItem note;
  final bool active;
  final VoidCallback onTap;
  @override
  State<_TreeItem> createState() => _TreeItemState();
}

class _TreeItemState extends State<_TreeItem> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    const tint = OmColors.fg1;
    final row = Container(
      key: Key('note-list-item-${widget.note.id}'),
      padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
      decoration: BoxDecoration(
        color: widget.active
            ? OmColors.surface4
            : (_hover ? OmColors.surface3 : Colors.transparent),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        children: [
          const SizedBox(width: 11),
          const Icon(LucideIcons.fileText, size: 13, color: tint),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              widget.note.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OmType.sans(
                size: 13,
                color: widget.active ? OmColors.fg0 : OmColors.fg1,
              ),
            ),
          ),
        ],
      ),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Draggable<String>(
        data: widget.note.id,
        feedback: Material(
          color: Colors.transparent,
          child: SizedBox(
            width: 200,
            child: Opacity(opacity: 0.85, child: row),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.4, child: row),
        child: GestureDetector(onTap: widget.onTap, child: row),
      ),
    );
  }
}

class _EmptyTree extends StatelessWidget {
  const _EmptyTree({required this.onCreate});
  final VoidCallback onCreate;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'no notes yet.',
            style: OmType.mono(size: 11.5, color: OmColors.fg3),
          ),
          const SizedBox(height: 12),
          OmButton(
            kind: OmButtonKind.secondary,
            icon: LucideIcons.plus,
            label: 'new note',
            kbd: '⌘N',
            onPressed: onCreate,
          ),
        ],
      ),
    );
  }
}
