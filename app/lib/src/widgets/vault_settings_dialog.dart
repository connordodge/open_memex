import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cli/settings_cli.dart';
import '../memex_cli.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'inline_error.dart';

/// The lowest and highest `smart_folder_max_depth` the app offers (C2.11).
const minSmartFolderDepth = 1;
const maxSmartFolderDepth = 5;

/// The per-vault settings surface (Key `vault-settings-dialog`, TD13). It
/// shows `Smart Folder depth` (field Key `vault-settings-depth`), read with
/// `memex settings get` each time it opens, and saves (Key
/// `vault-settings-save`) an integer from 1 to 5 with `memex settings set`.
/// Anything else is not sent. A CLI failure keeps the dialog open with the
/// message in a dismissible inline error; a save closes it.
Future<void> showVaultSettingsDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _VaultSettingsDialog(),
);

class _VaultSettingsDialog extends ConsumerStatefulWidget {
  const _VaultSettingsDialog();

  @override
  ConsumerState<_VaultSettingsDialog> createState() =>
      _VaultSettingsDialogState();
}

class _VaultSettingsDialogState extends ConsumerState<_VaultSettingsDialog> {
  final _depth = TextEditingController();
  String? _error;
  bool _invalid = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _depth.dispose();
    super.dispose();
  }

  /// Runs [call] against the open vault; a failure lands in [_error].
  Future<T?> _cli<T>(
    Future<T> Function(MemexCli cli, String vault) call,
  ) async {
    final cli = ref.read(memexCliProvider);
    final vault = ref.read(currentVaultProvider);
    if (cli == null || vault == null) {
      setState(() => _error = 'The memex CLI is not available.');
      return null;
    }
    try {
      return await call(cli, vault);
    } on Exception catch (e) {
      if (mounted) {
        setState(() => _error = e is MemexException ? e.message : '$e');
      }
      return null;
    }
  }

  Future<void> _load() async {
    final value = await _cli(
      (cli, vault) => cli.getSetting(vault, smartFolderMaxDepthKey),
    );
    if (value != null && mounted) setState(() => _depth.text = '$value');
  }

  Future<void> _save() async {
    final value = int.tryParse(_depth.text.trim());
    final invalid =
        value == null ||
        value < minSmartFolderDepth ||
        value > maxSmartFolderDepth;
    setState(() {
      _invalid = invalid;
      _error = null;
    });
    if (value == null || invalid) return;
    final saved = await _cli(
      (cli, vault) => cli.setSetting(vault, smartFolderMaxDepthKey, value),
    );
    if (saved == null || !mounted) return;
    ref.read(vaultRevisionProvider.notifier).state++;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return AlertDialog(
      key: const Key('vault-settings-dialog'),
      title: const Text('Vault settings'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (error != null)
              InlineError(
                message: error,
                onDismiss: () => setState(() => _error = null),
              ),
            Text(
              'Smart Folder depth',
              style: OmType.sans(size: 13, color: OmColors.fg0),
            ),
            const SizedBox(height: 4),
            Text(
              'How deep Smart Folders may nest, from '
              '$minSmartFolderDepth to $maxSmartFolderDepth.',
              style: OmType.sans(size: 12, color: OmColors.fg2),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('vault-settings-depth'),
              controller: _depth,
              keyboardType: TextInputType.number,
              style: OmType.mono(size: 13, color: OmColors.fg0),
              decoration: InputDecoration(
                errorText: _invalid
                    ? 'Enter a whole number from $minSmartFolderDepth to '
                          '$maxSmartFolderDepth.'
                    : null,
              ),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('vault-settings-save'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
