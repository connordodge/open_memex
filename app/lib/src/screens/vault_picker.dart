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
    final result = await showDialog<_CreateVaultResult>(
      context: context,
      builder: (_) => const _CreateVaultDialog(),
    );
    if (result == null) return;
    final fullPath = p.join(result.parentDir, result.name);
    if (Directory(fullPath).existsSync() &&
        Directory(fullPath).listSync().isNotEmpty) {
      if (context.mounted) {
        _showError(context, '$fullPath already exists and is not empty.');
      }
      return;
    }
    final cli = ref.read(memexCliProvider);
    if (cli == null) return;
    try {
      await cli.initVault(fullPath);
      await ref.read(settingsProvider.notifier).rememberVault(fullPath);
      ref.read(currentVaultProvider.notifier).state = fullPath;
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

class _CreateVaultResult {
  _CreateVaultResult({required this.parentDir, required this.name});
  final String parentDir;
  final String name;
}

class _CreateVaultDialog extends StatefulWidget {
  const _CreateVaultDialog();

  @override
  State<_CreateVaultDialog> createState() => _CreateVaultDialogState();
}

class _CreateVaultDialogState extends State<_CreateVaultDialog> {
  final _nameCtrl = TextEditingController(text: 'MyMemex');
  String? _parentDir;
  String? _error;

  @override
  void initState() {
    super.initState();
    final home = Platform.environment['HOME'];
    if (home != null) {
      _parentDir = p.join(home, 'Documents');
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickParent() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose where the new vault folder should live',
      initialDirectory: _parentDir,
    );
    if (dir != null) {
      setState(() => _parentDir = dir);
    }
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Vault name cannot be empty.');
      return;
    }
    if (name.contains('/') || name.contains('..')) {
      setState(() => _error = 'Vault name cannot contain "/" or "..".');
      return;
    }
    if (_parentDir == null || _parentDir!.isEmpty) {
      setState(() => _error = 'Choose a parent folder.');
      return;
    }
    Navigator.of(
      context,
    ).pop(_CreateVaultResult(parentDir: _parentDir!, name: name));
  }

  @override
  Widget build(BuildContext context) {
    final fullPath = (_parentDir != null && _nameCtrl.text.trim().isNotEmpty)
        ? p.join(_parentDir!, _nameCtrl.text.trim())
        : null;

    return AlertDialog(
      title: const Text('Create new vault'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Vault name'),
            const SizedBox(height: 6),
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'MyMemex',
              ),
              onChanged: (_) => setState(() => _error = null),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            const Text('Parent folder'),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _parentDir ?? '(none selected)',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _pickParent,
                  child: const Text('Choose…'),
                ),
              ],
            ),
            if (fullPath != null) ...[
              const SizedBox(height: 16),
              Text(
                'Vault will be created at:',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 2),
              Text(
                fullPath,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontFamily: 'Menlo'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}
