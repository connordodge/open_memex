import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../state/settings.dart';
import '../../state/vault_open_controller.dart';
import '../../state/vault_ref.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../atoms.dart';
import 'create_on_server_dialog.dart';
import 'server_select.dart';

/// Shows "open vault on a server" (board A6). Starts on [serverId], or the
/// first saved server. "connect to a vault server…" calls [onConnect];
/// "update token" calls [onUpdateToken] with the server's id.
Future<void> showOpenOnServerDialog(
  BuildContext context, {
  String? serverId,
  VoidCallback? onConnect,
  void Function(String serverId)? onUpdateToken,
}) => showServerDialog<void>(
  context,
  _OpenOnServerDialog(
    serverId: serverId,
    onConnect: onConnect,
    onUpdateToken: onUpdateToken,
  ),
);

enum _ListState { loading, loaded, failed }

class _OpenOnServerDialog extends ConsumerStatefulWidget {
  const _OpenOnServerDialog({
    required this.serverId,
    required this.onConnect,
    required this.onUpdateToken,
  });

  final String? serverId;
  final VoidCallback? onConnect;
  final void Function(String serverId)? onUpdateToken;

  @override
  ConsumerState<_OpenOnServerDialog> createState() =>
      _OpenOnServerDialogState();
}

class _OpenOnServerDialogState extends ConsumerState<_OpenOnServerDialog> {
  String? _serverId;
  _ListState _listState = _ListState.loading;
  List<String> _vaults = const [];
  String? _selected;
  ServerDialogError? _error;
  bool _opening = false;

  /// Bumped on every list request; a reply of an older one is dropped.
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    final servers = ref.read(settingsProvider).savedServers;
    _serverId = servers.any((s) => s.id == widget.serverId)
        ? widget.serverId
        : servers.firstOrNull?.id;
    _loadList();
  }

  SavedServer? get _server {
    for (final s in ref.read(settingsProvider).savedServers) {
      if (s.id == _serverId) return s;
    }
    return null;
  }

  Future<void> _loadList() async {
    final server = _server;
    final epoch = ++_epoch;
    setState(() {
      _listState = _ListState.loading;
      _vaults = const [];
      _selected = null;
      _error = null;
    });
    if (server == null) return;
    const operation = 'list vaults';
    try {
      final body = await sendServerDialogRequest(
        ref,
        server,
        'GET',
        '/vaults',
        operation: operation,
      );
      if (!mounted || epoch != _epoch) return;
      final raw = body['vaults'];
      setState(() {
        _listState = _ListState.loaded;
        _vaults = [
          if (raw is List)
            for (final v in raw)
              if (v is Map && v['name'] is String) v['name'] as String,
        ];
      });
    } catch (e) {
      final error = describeServerFailure(e, server, operation: operation);
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _listState = _ListState.failed;
        _error = error;
      });
    }
  }

  void _pickServer(String id) {
    _serverId = id;
    _loadList();
  }

  Future<void> _open() async {
    final server = _server;
    final name = _selected;
    if (_opening || server == null || name == null) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    final outcome = await ref
        .read(vaultOpenControllerProvider)
        .openVault(HostedVaultRef(server.id, name));
    if (!mounted) return;
    if (outcome is VaultOpenFailure) {
      setState(() {
        _opening = false;
        _error = ServerDialogError(outcome.message);
      });
      return;
    }
    Navigator.of(context).pop();
  }

  Future<void> _create() async {
    final server = _server;
    if (server == null) return;
    final created = await showCreateOnServerDialogForResult(
      context,
      serverId: server.id,
      onConnect: widget.onConnect,
      onUpdateToken: widget.onUpdateToken,
    );
    if (created && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(settingsProvider).savedServers;
    final server = _server;
    final name = server?.name ?? '';
    final error = _error;
    return ServerDialogShell(
      key: const Key('open-on-server-dialog'),
      eyebrow: 'OPEN VAULT ON A SERVER',
      children: [
        const SizedBox(height: 16),
        const ServerDialogLabel('server'),
        const SizedBox(height: 6),
        ServerSelect(
          servers: servers,
          selectedId: _serverId,
          onSelected: _pickServer,
          onConnect: widget.onConnect,
          hasError: error != null,
        ),
        if (error != null && server != null) ...[
          const SizedBox(height: 8),
          ServerFailureRow(
            error: error,
            onUpdateToken: () => widget.onUpdateToken?.call(server.id),
          ),
        ],
        const SizedBox(height: 16),
        if (_listState == _ListState.loading) _Loading(serverName: name),
        if (_listState == _ListState.loaded && _vaults.isNotEmpty)
          _VaultList(
            serverName: name,
            vaults: _vaults,
            selected: _selected,
            onSelected: (v) => setState(() => _selected = v),
          ),
        if (_listState == _ListState.loaded && _vaults.isEmpty)
          _Empty(serverName: name, onCreate: _create),
        if (_listState != _ListState.failed) const SizedBox(height: 16),
        SizedBox(
          height: 30,
          child: Row(
            children: [
              if (_listState == _ListState.loaded && _vaults.isNotEmpty)
                Flexible(
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      key: const Key('open-on-server-create-link'),
                      behavior: HitTestBehavior.opaque,
                      onTap: _create,
                      child: Text(
                        '+ create vault on $name…',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OmType.sans(size: 12, color: OmColors.info),
                      ),
                    ),
                  ),
                ),
              const Spacer(),
              OmButton(
                kind: OmButtonKind.ghost,
                label: 'cancel',
                onPressed: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: 8),
              OmButton(
                key: const Key('open-on-server-open'),
                kind: OmButtonKind.primary,
                label: 'open',
                onPressed: _selected == null || _opening ? null : _open,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Loading extends StatefulWidget {
  const _Loading({required this.serverName});

  final String serverName;

  @override
  State<_Loading> createState() => _LoadingState();
}

class _LoadingState extends State<_Loading>
    with SingleTickerProviderStateMixin {
  late final _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            RotationTransition(
              turns: _spin,
              child: const Icon(
                LucideIcons.loader2,
                size: 12,
                color: OmColors.fg2,
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'loading vaults on ${widget.serverName}…',
                style: OmType.mono(size: 11, color: OmColors.fg2),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final (i, w) in const [152.0, 208.0, 120.0].indexed) ...[
          if (i > 0) const SizedBox(height: 4),
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
            decoration: BoxDecoration(
              color: OmColors.surface2,
              border: Border.all(color: OmColors.line2),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: w,
                height: 10,
                decoration: BoxDecoration(
                  color: OmColors.surface4,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _VaultList extends StatelessWidget {
  const _VaultList({
    required this.serverName,
    required this.vaults,
    required this.selected,
    required this.onSelected,
  });

  final String serverName;
  final List<String> vaults;
  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ServerDialogLabel('vaults on $serverName · ${vaults.length}'),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 250),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, v) in vaults.indexed) ...[
                  if (i > 0) const SizedBox(height: 4),
                  _VaultRow(
                    key: Key('open-on-server-vault-$v'),
                    name: v,
                    selected: v == selected,
                    onTap: () => onSelected(v),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _VaultRow extends StatelessWidget {
  const _VaultRow({
    super.key,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 36.2,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? OmColors.surface4 : OmColors.surface2,
            border: Border.all(
              color: selected ? OmColors.line3 : OmColors.line2,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OmType.sans(size: 13.5, weight: FontWeight.w500),
                ),
              ),
              if (selected)
                const Icon(LucideIcons.check, size: 14, color: OmColors.accent),
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.serverName, required this.onCreate});

  final String serverName;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
      decoration: BoxDecoration(
        border: Border.all(color: OmColors.line3),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          Text(
            'no vaults on $serverName yet',
            style: OmType.sans(size: 13, color: OmColors.fg1, height: 1.5),
          ),
          const SizedBox(height: 12),
          OmButton(
            key: const Key('open-on-server-empty-create'),
            icon: LucideIcons.plus,
            label: 'create vault on $serverName…',
            onPressed: onCreate,
          ),
        ],
      ),
    );
  }
}
