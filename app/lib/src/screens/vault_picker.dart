import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../db.dart';
import '../state/settings.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/atoms.dart';

class VaultPickerScreen extends ConsumerWidget {
  const VaultPickerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final cli = ref.watch(memexCliProvider);

    return Scaffold(
      backgroundColor: OmColors.surface1,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: OmColors.fg2, width: 1.4),
                      ),
                      child: Center(
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(
                            color: OmColors.fg2,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 11),
                    Text(
                      'open memex',
                      style: OmType.mono(
                        size: 15,
                        weight: FontWeight.w500,
                        color: OmColors.fg0,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'v0.4',
                      style: OmType.mono(
                        size: 11,
                        color: OmColors.fg3,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 36),
                Text('CHOOSE A VAULT', style: OmType.eyebrow()),
                const SizedBox(height: 10),
                Text(
                  'a vault is a folder of your notes (manifest.json + memex.db). open one you have, or create a new one.',
                  style: OmType.sans(
                    size: 13,
                    color: OmColors.fg2,
                    height: 1.65,
                  ),
                ),
                const SizedBox(height: 28),
                if (cli == null)
                  _BinaryNotFoundCard()
                else
                  _BinaryFoundLine(path: cli.binaryPath),
                const SizedBox(height: 24),
                if (settings.recentVaults.isNotEmpty) ...[
                  Text('RECENT', style: OmType.eyebrow()),
                  const SizedBox(height: 10),
                  for (final v in settings.recentVaults)
                    _RecentVaultRow(path: v),
                  const SizedBox(height: 24),
                ],
                Row(
                  children: [
                    Expanded(
                      child: KeyedSubtree(
                        key: const Key('vault-picker-create'),
                        child: OmButton(
                          kind: OmButtonKind.primary,
                          size: 36,
                          icon: LucideIcons.folderPlus,
                          label: 'create new vault…',
                          onPressed: cli == null
                              ? null
                              : () => _createVault(context, ref),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: KeyedSubtree(
                        key: const Key('vault-picker-open'),
                        child: OmButton(
                          kind: OmButtonKind.secondary,
                          size: 36,
                          icon: LucideIcons.folderOpen,
                          label: 'open existing vault…',
                          onPressed: () => _openExistingVault(context, ref),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
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

class _BinaryFoundLine extends StatelessWidget {
  const _BinaryFoundLine({required this.path});
  final String path;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const OmDot(color: OmColors.accent, size: 5),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'memex binary  $path',
            style: OmType.mono(size: 11, color: OmColors.fg2),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _BinaryNotFoundCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: OmColors.dangerBg,
        border: Border.all(color: OmColors.danger.withAlpha(70), width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'memex binary not found',
            style: OmType.sans(
              size: 14,
              weight: FontWeight.w600,
              color: OmColors.fg0,
            ),
          ),
          const SizedBox(height: 8),
          SelectableText(
            'install with:\n  cargo install --path crates/memex-mcp --locked',
            style: OmType.mono(size: 11.5, color: OmColors.fg1, height: 1.5),
          ),
          const SizedBox(height: 12),
          OmButton(
            kind: OmButtonKind.secondary,
            label: 'locate memex binary…',
            onPressed: () async {
              final r = await FilePicker.platform.pickFiles(
                dialogTitle: 'Locate the memex binary',
                type: FileType.any,
              );
              final path = r?.files.singleOrNull?.path;
              if (path != null && File(path).existsSync()) {
                await ref.read(settingsProvider.notifier).setMemexBinary(path);
              }
            },
          ),
        ],
      ),
    );
  }
}

class _RecentVaultRow extends ConsumerStatefulWidget {
  const _RecentVaultRow({required this.path});
  final String path;
  @override
  ConsumerState<_RecentVaultRow> createState() => _RecentVaultRowState();
}

class _RecentVaultRowState extends ConsumerState<_RecentVaultRow> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final exists = VaultDb.isVault(widget.path);
    return MouseRegion(
      cursor: exists ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: exists
            ? () async {
                await ref
                    .read(settingsProvider.notifier)
                    .rememberVault(widget.path);
                ref.read(currentVaultProvider.notifier).state = widget.path;
              }
            : null,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
            color: _hover ? OmColors.surface3 : OmColors.surface2,
            border: Border.all(color: OmColors.line2, width: 1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(
                exists ? LucideIcons.folder : LucideIcons.folderX,
                size: 14,
                color: exists ? OmColors.fg2 : OmColors.danger,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.basename(widget.path),
                      style: OmType.sans(
                        size: 13.5,
                        weight: FontWeight.w500,
                        color: exists ? OmColors.fg0 : OmColors.fg2,
                      ),
                    ),
                    Text(
                      widget.path,
                      style: OmType.mono(size: 10.5, color: OmColors.fg3),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'remove from recents',
                splashRadius: 14,
                iconSize: 12,
                color: OmColors.fg3,
                icon: const Icon(LucideIcons.x),
                onPressed: () => ref
                    .read(settingsProvider.notifier)
                    .forgetVault(widget.path),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
    if (home != null) _parentDir = p.join(home, 'Documents');
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
    if (dir != null) setState(() => _parentDir = dir);
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
    if (_parentDir == null) {
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
      title: Text('CREATE NEW VAULT', style: OmType.eyebrow()),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'vault name',
              style: OmType.mono(size: 11, color: OmColors.fg2),
            ),
            const SizedBox(height: 6),
            Container(
              decoration: BoxDecoration(
                color: OmColors.surface3,
                border: Border.all(color: OmColors.line2, width: 1),
                borderRadius: BorderRadius.circular(6),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: TextField(
                controller: _nameCtrl,
                autofocus: true,
                style: OmType.sans(size: 13, color: OmColors.fg0),
                onChanged: (_) => setState(() => _error = null),
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'parent folder',
              style: OmType.mono(size: 11, color: OmColors.fg2),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: OmColors.surface3,
                      border: Border.all(color: OmColors.line2, width: 1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _parentDir ?? '(none selected)',
                      overflow: TextOverflow.ellipsis,
                      style: OmType.mono(size: 11.5, color: OmColors.fg1),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OmButton(
                  kind: OmButtonKind.secondary,
                  label: 'choose…',
                  onPressed: _pickParent,
                ),
              ],
            ),
            if (fullPath != null) ...[
              const SizedBox(height: 16),
              Text(
                'will be created at',
                style: OmType.mono(size: 10.5, color: OmColors.fg3),
              ),
              const SizedBox(height: 4),
              Text(
                fullPath,
                style: OmType.mono(
                  size: 12,
                  color: OmColors.accent,
                  height: 1.4,
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: OmType.mono(size: 11, color: OmColors.danger),
              ),
            ],
          ],
        ),
      ),
      actions: [
        OmButton(
          kind: OmButtonKind.ghost,
          label: 'cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        OmButton(
          kind: OmButtonKind.primary,
          label: 'create',
          onPressed: _submit,
        ),
      ],
    );
  }
}

void _showError(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}
