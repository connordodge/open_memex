// WI #327 (A6, D24, Spec req 35 and 37): the Restore dialog. The vault
// picker's "restore from backup…" opens it for the picked `.zip`; it runs
// `BackupRunner.restore` while it stays open and closes only on success, with
// the restored vault's folder. Layout, states and copy are design pack 327
// (`design/315-vault-backups/packs/327.md`, board R).
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../../cli/backup_cli.dart';
import '../../state/backup_messages.dart';
import '../../state/backup_models.dart';
import '../../state/backup_names.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../atoms.dart';
import '../dialog_button.dart';
import 'backup_keys.dart';

const _cancelKey = Key('restore-cancel');
const _fileKey = Key('restore-file');
const _metaKey = Key('restore-meta');
const _targetKey = Key('restore-target');

const _hint = 'a new vault folder. nothing that exists is changed.';

/// Shows the Restore dialog for the backup at [file] of [bytes] bytes.
/// Resolves to the restored vault's folder (`<parent>/<name>`) once a
/// restore succeeded, or null when the person cancelled. Failures keep the
/// dialog open with their message, so they never resolve it.
Future<String?> showRestoreDialog(
  BuildContext context, {
  required String file,
  required int bytes,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => RestoreDialog(file: file, bytes: bytes),
  );
}

/// The Restore dialog (Key `restore-dialog`). Use [showRestoreDialog].
class RestoreDialog extends ConsumerStatefulWidget {
  const RestoreDialog({super.key, required this.file, required this.bytes});

  /// The backup file's path.
  final String file;

  /// Its size in bytes.
  final int bytes;

  @override
  ConsumerState<RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends ConsumerState<RestoreDialog> {
  late final TextEditingController _name;
  final _nameFocus = FocusNode(debugLabel: 'restore-name');
  String? _parent;

  /// The text of `restore-error`, or null when there is none.
  String? _error;

  /// Whether [_error] is about the name (its field gets the error border).
  bool _nameError = false;

  /// A restore runs: every control is disabled and the dialog can't close.
  bool _running = false;

  late final String _fileName = p.basename(widget.file);
  late final String _meta = _metaLine(_fileName, widget.bytes);

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: suggestedRestoreName(_fileName));
    final home = Platform.environment['HOME'];
    if (home != null) _parent = p.join(home, 'Documents');
    _nameFocus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _nameFocus
      ..removeListener(_onFocus)
      ..dispose();
    _name.dispose();
    super.dispose();
  }

  void _onFocus() => setState(() {});

  void _clearError() {
    _error = null;
    _nameError = false;
  }

  Future<void> _chooseParent() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose where the restored vault folder should live',
      initialDirectory: _parent,
    );
    if (dir == null || !mounted) return;
    setState(() {
      _parent = dir;
      _clearError();
    });
  }

  void _invalid(String message, {required bool name}) {
    setState(() {
      _error = message;
      _nameError = name;
    });
    if (name) _nameFocus.requestFocus();
  }

  Future<void> _submit() async {
    if (_running) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      return _invalid("vault name can't be empty.", name: true);
    }
    if (name.contains('/') || name.contains('..')) {
      return _invalid('vault name can\'t contain "/" or "..".', name: true);
    }
    final parent = _parent;
    if (parent == null) {
      return _invalid('choose a parent folder.', name: false);
    }
    final target = p.join(parent, name);
    setState(() {
      _running = true;
      _clearError();
    });
    RestoreRunResult result;
    try {
      result = await ref
          .read(backupRunnerProvider)
          .restore(from: widget.file, to: target);
    } catch (e) {
      // The runner reports failures as results; anything it throws still
      // ends the run, so the dialog never stays locked.
      result = RestoreFailure(code: 'internal', message: '$e');
    }
    if (!mounted) return;
    if (result is RestoreOk) {
      Navigator.of(context).pop(target);
      return;
    }
    final notEmpty =
        result is RestoreFailure && result.code == 'restore_target_not_empty';
    setState(() {
      _running = false;
      _error = restoreFailureMessage(result, name: name, parent: parent);
      _nameError = notEmpty;
    });
    if (notEmpty) _nameFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final name = _name.text.trim();
    final parent = _parent;
    final error = _error;
    final showTarget = error == null && parent != null && name.isNotEmpty;
    // Line heights are board R's (pack 327), never the dialog theme's.
    final label = OmType.mono(size: 11, color: OmColors.fg2, height: 1.27);

    return PopScope(
      canPop: !_running,
      child: AlertDialog(
        key: restoreDialogKey,
        scrollable: true,
        backgroundColor: OmColors.surface2,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: OmColors.line2),
        ),
        // 560 wide: padding 24 inside the 1 px border, content 510.
        titlePadding: const EdgeInsets.fromLTRB(25, 25, 25, 0),
        contentPadding: const EdgeInsets.fromLTRB(25, 16, 25, 0),
        actionsPadding: const EdgeInsets.fromLTRB(25, 20, 25, 25),
        title: Text(
          'RESTORE FROM BACKUP',
          style: OmType.eyebrow().copyWith(height: 1.27),
        ),
        content: SizedBox(
          width: 510,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('backup', style: label),
              const SizedBox(height: 6),
              _Field(
                key: _fileKey,
                fill: OmColors.surface1,
                child: Row(
                  children: [
                    const Icon(
                      LucideIcons.archive,
                      size: 12,
                      color: OmColors.fg1,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OmType.mono(
                          size: 11.5,
                          color: OmColors.fg1,
                          height: 1.22,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (error == null) ...[
                const SizedBox(height: 4),
                Text(_meta, key: _metaKey, style: label),
              ],
              const SizedBox(height: 16),
              Text('vault name', style: label),
              const SizedBox(height: 6),
              Opacity(
                opacity: _running ? 0.6 : 1,
                child: _NameField(
                  controller: _name,
                  focusNode: _nameFocus,
                  readOnly: _running,
                  error: _nameError,
                  onChanged: (_) => setState(_clearError),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(height: 16),
              Text('parent folder', style: label),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Opacity(
                      opacity: _running ? 0.6 : 1,
                      child: _Field(
                        fill: OmColors.surface3,
                        child: Text(
                          parent ?? '(none selected)',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OmType.mono(
                            size: 11.5,
                            color: OmColors.fg1,
                            height: 1.22,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DialogButton(
                    key: restoreFolderKey,
                    kind: OmButtonKind.secondary,
                    label: 'choose…',
                    onPressed: _running ? null : _chooseParent,
                  ),
                ],
              ),
              if (error != null) ...[
                const SizedBox(height: 16),
                _ErrorBox(message: error),
              ] else if (showTarget) ...[
                const SizedBox(height: 16),
                Text(
                  'will be restored to',
                  style: OmType.mono(
                    size: 10.5,
                    color: OmColors.fg2,
                    height: 1.24,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  p.join(parent, name),
                  key: _targetKey,
                  style: OmType.mono(
                    size: 12,
                    color: OmColors.accent,
                    height: 1.25,
                  ),
                ),
                if (!_running) ...[
                  const SizedBox(height: 8),
                  Text(
                    _hint,
                    style: OmType.sans(
                      size: 12,
                      color: OmColors.fg2,
                      height: 1.5,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
        actions: [
          // One Row: OmButton fills the width it is offered, so the dialog's
          // own action bar would stack them.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DialogButton(
                key: _cancelKey,
                kind: OmButtonKind.ghost,
                label: 'cancel',
                onPressed: _running ? null : () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: 8),
              DialogButton(
                key: restoreSubmitKey,
                kind: OmButtonKind.primary,
                icon: _running ? LucideIcons.loader2 : null,
                label: _running ? 'restoring…' : 'restore',
                onPressed: _running ? null : _submit,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "41.2 MB · made 9 nov 2026 at 14:03": the size, then the file name's
/// (UTC) timestamp in local time. The size only for a name that doesn't
/// match requirement 4.
String _metaLine(String fileName, int bytes) {
  final size = backupSize(bytes);
  final parsed = parseBackupFileName(fileName);
  if (parsed == null) return size;
  final t = parsed.timestamp.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '$size · made ${t.day} ${_months[t.month - 1]} ${t.year} '
      'at ${two(t.hour)}:${two(t.minute)}';
}

const _months = [
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec',
];

/// A read-only field box: at least 32 high, radius 6, `line2` border,
/// padding H10, its child vertically centred.
class _Field extends StatelessWidget {
  const _Field({super.key, required this.fill, required this.child});

  final Color fill;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 32),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: OmColors.line2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: child,
    );
  }
}

/// The vault-name field (Key `restore-name` on the TextField): `accentSoft`
/// border and an `accentGlow` ring while focused, `danger` ones for an error
/// about the name.
class _NameField extends StatelessWidget {
  const _NameField({
    required this.controller,
    required this.focusNode,
    required this.readOnly,
    required this.error,
    required this.onChanged,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool readOnly;
  final bool error;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    final focused = focusNode.hasFocus && !readOnly;
    final (border, ring) = error
        ? (OmColors.danger, OmColors.danger.withAlpha(51))
        : focused
        ? (OmColors.accentSoft, OmColors.accentGlow)
        : (OmColors.line2, null);
    return Container(
      constraints: const BoxConstraints(minHeight: 32),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: OmColors.surface3,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(6),
        boxShadow: [if (ring != null) BoxShadow(color: ring, spreadRadius: 2)],
      ),
      child: Semantics(
        label: 'vault name',
        child: TextField(
          key: restoreNameKey,
          controller: controller,
          focusNode: focusNode,
          autofocus: true,
          readOnly: readOnly,
          textInputAction: TextInputAction.done,
          cursorColor: OmColors.fg0,
          decoration: const InputDecoration.collapsed(hintText: null),
          style: OmType.sans(size: 13, color: OmColors.fg0, height: 1.23),
          onChanged: onChanged,
          onSubmitted: onSubmitted,
        ),
      ),
    );
  }
}

/// The error box: `restore-error` is its text, announced as a live region.
class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: OmColors.dangerBg,
        border: Border.all(color: OmColors.danger.withAlpha(69)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(
              LucideIcons.triangleAlert,
              size: 14,
              color: OmColors.danger,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Semantics(
              container: true,
              liveRegion: true,
              child: Text(
                message,
                key: restoreErrorKey,
                style: OmType.sans(
                  size: 12.5,
                  color: OmColors.fg0,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
