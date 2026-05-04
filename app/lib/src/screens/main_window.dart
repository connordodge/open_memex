import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../widgets/note_editor.dart';
import '../widgets/right_panel.dart';
import '../widgets/sidebar.dart';

final rightPanelOpenProvider = StateProvider<bool>((_) => true);

class MainWindow extends ConsumerWidget {
  const MainWindow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rightOpen = ref.watch(rightPanelOpenProvider);
    return Scaffold(
      backgroundColor: OmColors.surface1,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Sidebar(onNewNote: () => _createNote(context, ref)),
          NoteEditor(
            rightPanelOpen: rightOpen,
            onToggleRightPanel: () =>
                ref.read(rightPanelOpenProvider.notifier).state = !rightOpen,
          ),
          if (rightOpen)
            RightPanel(
              onClose: () =>
                  ref.read(rightPanelOpenProvider.notifier).state = false,
            ),
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
