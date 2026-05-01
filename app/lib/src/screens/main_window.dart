import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../state/settings.dart';
import '../state/vault_state.dart';
import '../widgets/note_editor.dart';
import '../widgets/note_list.dart';

class MainWindow extends ConsumerWidget {
  const MainWindow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vaultPath = ref.watch(currentVaultProvider)!;
    final saveStatus = ref.watch(editorControllerProvider).status;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Open Memex'),
            const SizedBox(width: 12),
            Text(
              p.basename(vaultPath),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 12),
            _SaveIndicator(status: saveStatus),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            key: const Key('vault-switcher'),
            tooltip: 'Vault',
            icon: const Icon(Icons.folder_outlined),
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'switch',
                child: Text('Switch vault…'),
              ),
              const PopupMenuItem(
                value: 'create',
                child: Text('Create new vault…'),
              ),
            ],
            onSelected: (v) async {
              if (v == 'switch' || v == 'create') {
                await ref.read(settingsProvider.notifier).clearLastVault();
                ref.read(currentVaultProvider.notifier).state = null;
                ref.read(selectedNoteIdProvider.notifier).state = null;
              }
            },
          ),
          IconButton(
            key: const Key('new-note-button'),
            tooltip: 'New note',
            icon: const Icon(Icons.add),
            onPressed: () => _createNote(context, ref),
          ),
        ],
      ),
      body: Row(
        children: const [
          SizedBox(width: 320, child: NoteList()),
          VerticalDivider(width: 1),
          Expanded(child: NoteEditor()),
        ],
      ),
    );
  }

  Future<void> _createNote(BuildContext context, WidgetRef ref) async {
    final cli = ref.read(memexCliProvider);
    final vaultPath = ref.read(currentVaultProvider);
    if (cli == null || vaultPath == null) return;
    try {
      final id = await cli.addNote(
        vaultPath: vaultPath,
        title: 'Untitled',
        contentMd: '# Untitled\n\n',
      );
      ref.read(vaultRevisionProvider.notifier).state++;
      ref.read(selectedNoteIdProvider.notifier).state = id;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not create note: $e')));
      }
    }
  }
}

class _SaveIndicator extends StatelessWidget {
  const _SaveIndicator({required this.status});
  final SaveStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      SaveStatus.idle => ('', Theme.of(context).colorScheme.onSurfaceVariant),
      SaveStatus.dirty => ('• unsaved', Theme.of(context).colorScheme.tertiary),
      SaveStatus.saving => ('saving…', Theme.of(context).colorScheme.tertiary),
      SaveStatus.clean => (
        'saved',
        Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      SaveStatus.error => ('save failed', Theme.of(context).colorScheme.error),
      SaveStatus.conflict => (
        'conflict — reload',
        Theme.of(context).colorScheme.error,
      ),
    };
    return Text(
      label,
      key: const Key('save-indicator'),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
    );
  }
}
