import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../db.dart';
import '../state/settings.dart';
import '../state/vault_state.dart';

class VaultPickerScreen extends ConsumerWidget {
  const VaultPickerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final cli = ref.watch(memexCliProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Open Memex')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            shrinkWrap: true,
            children: [
              Text(
                'Choose a vault',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                'A vault is a folder containing your notes (manifest.json + memex.db). '
                'Pick one you already have, create a new one, or open from disk.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              if (cli == null)
                _MemexBinaryNotFoundCard()
              else
                _MemexBinaryFoundLine(path: cli.binaryPath),
              const SizedBox(height: 24),
              if (settings.recentVaults.isNotEmpty) ...[
                Text('Recent', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final v in settings.recentVaults)
                  _RecentVaultTile(path: v),
                const SizedBox(height: 16),
              ],
              FilledButton.icon(
                key: const Key('vault-picker-create'),
                onPressed: cli == null
                    ? null
                    : () => _createVault(context, ref),
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Create new vault…'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('vault-picker-open'),
                onPressed: () => _openExistingVault(context, ref),
                icon: const Icon(Icons.folder_open),
                label: const Text('Open existing vault…'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _createVault(BuildContext context, WidgetRef ref) async {
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose an empty folder for your new vault',
    );
    if (selected == null) return;
    final cli = ref.read(memexCliProvider);
    if (cli == null) return;
    try {
      await cli.initVault(selected);
      await ref.read(settingsProvider.notifier).rememberVault(selected);
      ref.read(currentVaultProvider.notifier).state = selected;
    } catch (e) {
      if (context.mounted) {
        _showError(context, 'Could not create vault: $e');
      }
    }
  }

  Future<void> _openExistingVault(BuildContext context, WidgetRef ref) async {
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose a vault folder',
    );
    if (selected == null) return;
    if (!VaultDb.isVault(selected)) {
      if (context.mounted) {
        _showError(
          context,
          '$selected does not look like a vault (no manifest.json + memex.db).',
        );
      }
      return;
    }
    await ref.read(settingsProvider.notifier).rememberVault(selected);
    ref.read(currentVaultProvider.notifier).state = selected;
  }
}

class _MemexBinaryFoundLine extends StatelessWidget {
  const _MemexBinaryFoundLine({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.check_circle, color: Colors.green, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'memex binary: $path',
            style: Theme.of(context).textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _MemexBinaryNotFoundCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'memex binary not found',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Install it with:\n  cargo install --path crates/memex-mcp --locked\n\n'
              'Or set the path manually:',
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () async {
                final r = await FilePicker.platform.pickFiles(
                  dialogTitle: 'Locate the memex binary',
                  type: FileType.any,
                );
                final path = r?.files.singleOrNull?.path;
                if (path != null && File(path).existsSync()) {
                  await ref
                      .read(settingsProvider.notifier)
                      .setMemexBinary(path);
                }
              },
              child: const Text('Locate memex binary…'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentVaultTile extends ConsumerWidget {
  const _RecentVaultTile({required this.path});
  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exists = VaultDb.isVault(path);
    return ListTile(
      leading: Icon(
        exists ? Icons.folder : Icons.folder_off,
        color: exists ? null : Theme.of(context).colorScheme.error,
      ),
      title: Text(p.basename(path)),
      subtitle: Text(path, overflow: TextOverflow.ellipsis),
      onTap: exists
          ? () async {
              await ref.read(settingsProvider.notifier).rememberVault(path);
              ref.read(currentVaultProvider.notifier).state = path;
            }
          : null,
      trailing: IconButton(
        tooltip: 'Remove from recents',
        icon: const Icon(Icons.close),
        onPressed: () => ref.read(settingsProvider.notifier).forgetVault(path),
      ),
    );
  }
}

void _showError(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}
