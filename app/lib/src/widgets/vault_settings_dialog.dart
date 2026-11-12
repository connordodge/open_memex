import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cli/settings_cli.dart';
import '../memex_cli.dart';
import '../state/learned_words_seam.dart';
import '../state/learned_words_state.dart';
import '../state/vault_access_state.dart';
import '../state/vault_state.dart';
import '../vault_access/errors.dart';
import '../vault_access/vault_access.dart';
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
///
/// Below it, `Learned words` (Spec #392 req 17) lists the vault's learned
/// words as written, sorted by `word_key`, each with a remove button (Key
/// `learned-word-remove-<word_key>`), or `no learned words yet.` with none.
/// Remove acts at once, not on Save, through `learnedWordsActionsProvider`:
/// success drops the row, a failure keeps it and shows its message in the
/// same inline error. A press while that word's removal runs is ignored.
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
    Future<T> Function(TopicsAccess topics) call, {
    bool guarded = false,
  }) async {
    final access = ref.read(vaultAccessProvider);
    if (access == null || !access.canWrite) {
      setState(() => _error = 'The memex CLI is not available.');
      return null;
    }
    try {
      if (guarded) {
        return await guardVaultWrite(context, () => call(access.topics));
      }
      return await call(access.topics);
    } on Exception catch (e) {
      if (mounted) {
        setState(() => _error = e is MemexException ? e.message : '$e');
      }
      return null;
    }
  }

  Future<void> _load() async {
    final value = await _cli((t) => t.getSetting(smartFolderMaxDepthKey));
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
      (t) => t.setSetting(smartFolderMaxDepthKey, value),
      guarded: true,
    );
    if (saved == null || !mounted) return;
    ref.read(vaultRevisionProvider.notifier).state++;
    Navigator.of(context).pop();
  }

  /// The `word_key`s whose removal is running.
  final _removing = <String>{};

  Future<void> _removeWord(String word) async {
    final key = learnedWordKey(word);
    if (!_removing.add(key)) return;
    setState(() => _error = null);
    final actions = ref.read(learnedWordsActionsProvider);
    final removed = await actions.unlearn(word);
    final message = removed
        ? null
        : (actions is LearnedWordsState ? actions.lastErrorMessage : null) ??
              'Could not remove "$word".';
    _removing.remove(key);
    if (!mounted) return;
    setState(() {
      if (message != null) _error = message;
    });
  }

  Widget _learnedWords(List<LearnedWord> words) {
    if (words.isEmpty) {
      return Text(
        'no learned words yet.',
        style: OmType.sans(size: 12, color: OmColors.fg2),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 240),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final w in words)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      w.word,
                      overflow: TextOverflow.ellipsis,
                      style: OmType.mono(size: 13, color: OmColors.fg0),
                    ),
                  ),
                  IconButton(
                    key: Key('learned-word-remove-${learnedWordKey(w.word)}'),
                    tooltip: 'Remove "${w.word}"',
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    color: OmColors.fg2,
                    onPressed: () => _removeWord(w.word),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return AlertDialog(
      key: const Key('vault-settings-dialog'),
      title: const Text('Vault settings'),
      scrollable: true,
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
            const SizedBox(height: 20),
            Text(
              'Learned words',
              style: OmType.sans(size: 13, color: OmColors.fg0),
            ),
            const SizedBox(height: 8),
            _learnedWords(ref.watch(learnedWordsProvider)),
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
