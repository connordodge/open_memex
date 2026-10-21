import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../memex_cli.dart';
import '../../state/settings.dart';
import '../../state/vault_open_controller.dart';
import '../../state/vault_ref.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../atoms.dart';
import 'server_select.dart';

/// Shows "create vault on a server" (board A7). Starts on [serverId], or the
/// first saved server. "connect to a vault server…" calls [onConnect];
/// "update token" calls [onUpdateToken] with the server's id.
Future<void> showCreateOnServerDialog(
  BuildContext context, {
  String? serverId,
  VoidCallback? onConnect,
  void Function(String serverId)? onUpdateToken,
}) => showCreateOnServerDialogForResult(
  context,
  serverId: serverId,
  onConnect: onConnect,
  onUpdateToken: onUpdateToken,
);

/// [showCreateOnServerDialog] that completes `true` when the vault was
/// created and opened (the dialog closed itself), else `false`. The open
/// dialog uses it to close with the create dialog.
Future<bool> showCreateOnServerDialogForResult(
  BuildContext context, {
  String? serverId,
  VoidCallback? onConnect,
  void Function(String serverId)? onUpdateToken,
}) async {
  final created = await showServerDialog<bool>(
    context,
    _CreateOnServerDialog(
      serverId: serverId,
      onConnect: onConnect,
      onUpdateToken: onUpdateToken,
    ),
  );
  return created ?? false;
}

const _invalidNameCopy = 'use letters, digits, - and _ (1–64 characters)';

class _CreateOnServerDialog extends ConsumerStatefulWidget {
  const _CreateOnServerDialog({
    required this.serverId,
    required this.onConnect,
    required this.onUpdateToken,
  });

  final String? serverId;
  final VoidCallback? onConnect;
  final void Function(String serverId)? onUpdateToken;

  @override
  ConsumerState<_CreateOnServerDialog> createState() =>
      _CreateOnServerDialogState();
}

class _CreateOnServerDialogState extends ConsumerState<_CreateOnServerDialog> {
  final _name = TextEditingController();
  final _focus = FocusNode();
  String? _serverId;
  bool _pending = false;

  /// The server refused the name (`invalid_vault_name`): create stays
  /// disabled until the name changes.
  bool _invalid = false;
  String? _nameError;
  ServerDialogError? _serverError;

  @override
  void initState() {
    super.initState();
    final servers = ref.read(settingsProvider).savedServers;
    _serverId = servers.any((s) => s.id == widget.serverId)
        ? widget.serverId
        : servers.firstOrNull?.id;
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  SavedServer? get _server {
    for (final s in ref.read(settingsProvider).savedServers) {
      if (s.id == _serverId) return s;
    }
    return null;
  }

  bool get _canCreate => _name.text.isNotEmpty && !_pending && !_invalid;

  void _nameChanged(String _) => setState(() {
    _invalid = false;
    _nameError = null;
  });

  void _pickServer(String id) => setState(() {
    _serverId = id;
    _nameError = null;
    _invalid = false;
    _serverError = null;
  });

  Future<void> _create() async {
    final server = _server;
    if (server == null || !_canCreate) return;
    final name = _name.text;
    setState(() {
      _pending = true;
      _nameError = null;
      _serverError = null;
    });
    const operation = 'create vault';
    try {
      await sendServerDialogRequest(
        ref,
        server,
        'POST',
        '/vaults',
        operation: operation,
        body: {'name': name},
      );
    } catch (e) {
      final code = e is MemexException ? e.code : null;
      final ServerDialogError? serverError;
      String? nameError;
      switch (code) {
        case 'invalid_vault_name':
          nameError = _invalidNameCopy;
          serverError = null;
        case 'vault_exists':
          nameError = 'a vault named $name already exists on ${server.name}';
          serverError = null;
        default:
          serverError = describeServerFailure(
            e,
            server,
            operation: operation,
            confirmable: true,
          );
      }
      if (!mounted) return;
      setState(() {
        _pending = false;
        _invalid = code == 'invalid_vault_name';
        _nameError = nameError;
        _serverError = serverError;
      });
      return;
    }
    if (!mounted) return;
    final outcome = await ref
        .read(vaultOpenControllerProvider)
        .openVault(HostedVaultRef(server.id, name));
    if (!mounted) return;
    if (outcome is VaultOpenFailure) {
      setState(() {
        _pending = false;
        _serverError = ServerDialogError(outcome.message);
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(settingsProvider).savedServers;
    final server = _server;
    final serverError = _serverError;
    final nameError = _nameError;
    final focused = _focus.hasFocus;
    final nameBorder = nameError != null
        ? OmColors.danger.withAlpha(166)
        : focused
        ? OmColors.accent.withAlpha(140)
        : OmColors.line2;
    return ServerDialogShell(
      key: const Key('create-on-server-dialog'),
      eyebrow: 'CREATE VAULT ON A SERVER',
      children: [
        const SizedBox(height: 16),
        const ServerDialogLabel('server'),
        const SizedBox(height: 6),
        ServerSelect(
          servers: servers,
          selectedId: _serverId,
          onSelected: _pickServer,
          onConnect: widget.onConnect,
          hasError: serverError != null,
          enabled: !_pending,
        ),
        if (serverError != null && server != null) ...[
          const SizedBox(height: 8),
          ServerFailureRow(
            error: serverError,
            onUpdateToken: () => widget.onUpdateToken?.call(server.id),
          ),
        ],
        const SizedBox(height: 16),
        const ServerDialogLabel('vault name'),
        const SizedBox(height: 6),
        Container(
          key: const Key('create-on-server-name'),
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: OmColors.surface3,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: nameBorder),
            boxShadow: [
              if (focused && nameError == null)
                BoxShadow(
                  color: OmColors.accent.withAlpha(31),
                  spreadRadius: 3,
                ),
            ],
          ),
          child: TextField(
            controller: _name,
            focusNode: _focus,
            autofocus: true,
            onChanged: _nameChanged,
            onSubmitted: (_) => _create(),
            cursorColor: OmColors.accent,
            style: OmType.sans(size: 13),
            decoration: const InputDecoration.collapsed(hintText: null),
          ),
        ),
        if (nameError != null) ...[
          const SizedBox(height: 6),
          ServerDialogErrorRow(
            key: const Key('create-on-server-error'),
            text: nameError,
          ),
        ],
        if (nameError == null && _name.text.isNotEmpty && server != null) ...[
          const SizedBox(height: 16),
          const ServerDialogLabel('will be created at'),
          const SizedBox(height: 4),
          Text(
            '${_trimmedUrl(server.url)}/vaults/${_name.text}',
            style: OmType.mono(size: 12, color: OmColors.accent, height: 1.4),
          ),
        ],
        const SizedBox(height: 16),
        SizedBox(
          height: 30,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OmButton(
                kind: OmButtonKind.ghost,
                label: 'cancel',
                onPressed: () => Navigator.of(context).pop(false),
              ),
              const SizedBox(width: 8),
              OmButton(
                key: const Key('create-on-server-submit'),
                kind: OmButtonKind.primary,
                label: 'create',
                onPressed: _canCreate ? _create : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _trimmedUrl(String url) {
  var end = url.length;
  while (end > 0 && url[end - 1] == '/') {
    end--;
  }
  return url.substring(0, end);
}
