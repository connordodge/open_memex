import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/vault_state.dart';

class NoteList extends ConsumerWidget {
  const NoteList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(notesListProvider);
    final selectedId = ref.watch(selectedNoteIdProvider);

    if (notes.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No notes yet.\nClick + to create your first note.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: notes.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final n = notes[i];
        final selected = n.id == selectedId;
        return ListTile(
          key: Key('note-list-item-${n.id}'),
          selected: selected,
          title: Text(
            n.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
          subtitle: Text(
            n.snippet,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => ref.read(selectedNoteIdProvider.notifier).state = n.id,
        );
      },
    );
  }
}
