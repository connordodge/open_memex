import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../state/picker_actions.dart';
import '../state/server_probes.dart';
import '../state/settings.dart';
import '../state/vault_open_controller.dart';
import '../state/vault_open_hosted.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/atoms.dart';
import '../widgets/memex_too_old_dialog.dart';
import '../widgets/picker/recent_row.dart';
import '../widgets/picker/remove_server_dialog.dart';
import '../widgets/picker/server_row.dart';
import '../widgets/vault_open_refusal.dart';

class VaultPickerScreen extends ConsumerStatefulWidget {
  const VaultPickerScreen({super.key});

  @override
  ConsumerState<VaultPickerScreen> createState() => _VaultPickerScreenState();
}

const _openEyebrow = 'OPEN LOCAL VAULT';
const _createEyebrow = 'CREATE NEW VAULT';

/// The subtitle (board A1).
const _subtitle =
    'a vault is a folder of your notes. open one on this mac, or one hosted '
    'by a vault server.';

class _VaultPickerScreenState extends ConsumerState<VaultPickerScreen> {
  /// The last vault while the launch reopen runs on it; its recent row
  /// shows as opening.
  VaultRef? _launchRef;

  /// The binary that could not be started on the last open (a spawn
  /// failure); while it is still the configured one the picker shows the
  /// "memex binary not found" card.
  String? _unstartableBinary;

  @override
  void initState() {
    super.initState();
    // Launch reopen (#92, #96): with a last vault and no vault open, reopen
    // it once, after the first frame.
    final last = ref.read(settingsProvider).lastVaultRef;
    if (last != null && ref.read(currentVaultProvider) == null) {
      _launchRef = last;
      WidgetsBinding.instance.addPostFrameCallback((_) => _launch());
    }
  }

  Future<void> _launch() async {
    if (!mounted) return;
    final outcome = await ref.read(vaultOpenControllerProvider).launchReopen();
    if (!mounted) return;
    setState(() => _launchRef = null);
    await _present(outcome, eyebrow: _openEyebrow);
  }

  /// Shows what an open gave: nothing for a hosted failure (its recent row
  /// shows it, D19), a refusal dialog for a refused folder, the
  /// binary-not-found card for a binary that could not start, and the open
  /// error in a SnackBar for any other failure.
  Future<void> _present(
    VaultOpenOutcome outcome, {
    required String eyebrow,
  }) async {
    if (!mounted ||
        outcome is! VaultOpenFailure ||
        outcome is HostedVaultOpenFailure) {
      return;
    }
    if (await showVaultOpenRefusal(context, outcome, eyebrow: eyebrow)) {
      return;
    }
    if (!mounted) return;
    if (outcome is VaultBinaryNotFound) {
      setState(
        () => _unstartableBinary = ref.read(memexCliProvider)?.binaryPath,
      );
      return;
    }
    _showError(context, outcome.message);
  }

  Future<void> _openRecent(VaultRef vault) async {
    final outcome = await ref
        .read(vaultOpenControllerProvider)
        .openVault(vault);
    await _present(outcome, eyebrow: _openEyebrow);
  }

  /// Req 42: with no saved server, "connect" first; [flow] runs once it
  /// saved one. A cancelled connect runs nothing else.
  Future<void> _serverFlow(
    Future<void> Function(PickerActions actions, BuildContext context) flow,
  ) async {
    final actions = ref.read(pickerActionsProvider);
    if (ref.read(settingsProvider).savedServers.isEmpty) {
      final saved = await actions.connect(context);
      if (saved == null || !mounted) return;
    }
    await flow(actions, context);
  }

  Future<void> _connect() => ref.read(pickerActionsProvider).connect(context);

  /// Req 46: the remove confirm, then `removeServer` (token, server and its
  /// hosted recents).
  Future<void> _removeServer(SavedServer server) async {
    final settings = ref.read(settingsProvider.notifier);
    if (!await confirmRemoveServer(context, serverName: server.name)) return;
    await settings.removeServer(server.id);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final cli = ref.watch(memexCliProvider);
    // The picker probes each saved server while it shows.
    ref.watch(serverProbesProvider);
    final binaryNotFound =
        cli == null ||
        (_unstartableBinary != null && cli.binaryPath == _unstartableBinary);
    final recents = settings.recentRefs;
    final servers = settings.savedServers;

    return Scaffold(
      backgroundColor: OmColors.surface1,
      body: Center(
        child: ConstrainedBox(
          // Pack 97: a 560 px content column inside 40 px padding.
          constraints: const BoxConstraints(maxWidth: 640),
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
                  _subtitle,
                  style: OmType.sans(
                    size: 13,
                    color: OmColors.fg2,
                    height: 21.45 / 13,
                  ),
                ),
                const SizedBox(height: 24),
                if (binaryNotFound)
                  const _BinaryNotFoundCard()
                else
                  _BinaryFoundLine(path: cli.binaryPath),
                if (recents.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text('RECENT', style: OmType.eyebrow()),
                  const SizedBox(height: 10),
                  for (var i = 0; i < recents.length; i++) ...[
                    if (i > 0) const SizedBox(height: 6),
                    RecentRow(
                      index: i,
                      entry: recents[i],
                      opening: recents[i] == _launchRef,
                      binaryMissing: binaryNotFound,
                      onOpen: () => _openRecent(recents[i]),
                    ),
                  ],
                ],
                const SizedBox(height: 24),
                _ServersHeader(count: servers.length, onConnect: _connect),
                const SizedBox(height: 10),
                if (servers.isEmpty)
                  _NoServersBox(
                    onConnect: _connect,
                    onSetUp: () =>
                        ref.read(pickerActionsProvider).setUp(context),
                  )
                else
                  for (var i = 0; i < servers.length; i++) ...[
                    if (i > 0) const SizedBox(height: 6),
                    ServerRow(
                      server: servers[i],
                      onEdit: () => ref
                          .read(pickerActionsProvider)
                          .editServer(context, servers[i].id),
                      onRemove: () => _removeServer(servers[i]),
                    ),
                  ],
                const SizedBox(height: 24),
                _GridRow(
                  label: 'THIS MAC',
                  left: KeyedSubtree(
                    key: const Key('vault-picker-create'),
                    child: OmButton(
                      kind: binaryNotFound
                          ? OmButtonKind.secondary
                          : OmButtonKind.primary,
                      size: 36,
                      icon: LucideIcons.folderPlus,
                      label: 'create local vault…',
                      onPressed: binaryNotFound ? null : _createVault,
                    ),
                  ),
                  right: KeyedSubtree(
                    key: const Key('vault-picker-open'),
                    child: OmButton(
                      kind: OmButtonKind.secondary,
                      size: 36,
                      icon: LucideIcons.folderOpen,
                      label: 'open local vault…',
                      onPressed: binaryNotFound ? null : _openExistingVault,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _GridRow(
                  label: 'VAULT SERVER',
                  left: KeyedSubtree(
                    key: const Key('vault-picker-open-on-server'),
                    child: OmButton(
                      // Binary not found (A3 state 1): the first server
                      // action takes the primary style.
                      kind: binaryNotFound
                          ? OmButtonKind.primary
                          : OmButtonKind.secondary,
                      size: 36,
                      icon: LucideIcons.server,
                      label: 'open vault on a server…',
                      onPressed: () => _serverFlow((a, c) => a.openOnServer(c)),
                    ),
                  ),
                  right: KeyedSubtree(
                    key: const Key('vault-picker-create-on-server'),
                    child: OmButton(
                      kind: OmButtonKind.secondary,
                      size: 36,
                      icon: LucideIcons.plus,
                      label: 'create vault on a server…',
                      onPressed: () =>
                          _serverFlow((a, c) => a.createOnServer(c)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _createVault() async {
    final result = await showDialog<_CreateVaultResult>(
      context: context,
      builder: (_) => const _CreateVaultDialog(),
    );
    if (result == null || !mounted) return;
    final fullPath = p.join(result.parentDir, result.name);
    final outcome = await ref
        .read(vaultOpenControllerProvider)
        .createLocalVault(fullPath);
    await _present(outcome, eyebrow: _createEyebrow);
  }

  Future<void> _openExistingVault() async {
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose a vault folder',
    );
    if (selected == null || !mounted) return;
    final outcome = await ref
        .read(vaultOpenControllerProvider)
        .openVault(LocalVaultRef(selected));
    await _present(outcome, eyebrow: _openEyebrow);
  }
}

/// A row of the action grid (pack 97): a 92 px upper-case mono label, then
/// two equal 36 px buttons, gaps 8.
class _GridRow extends StatelessWidget {
  const _GridRow({
    required this.label,
    required this.left,
    required this.right,
  });

  final String label;
  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: OmType.mono(
                size: 10.5,
                weight: FontWeight.w500,
                color: OmColors.fg2,
                letterSpacing: 0.8,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: left),
          const SizedBox(width: 8),
          Expanded(child: right),
        ],
      ),
    );
  }
}

/// "SERVERS · n" with "+ CONNECT" (key `picker-servers-connect`).
class _ServersHeader extends StatelessWidget {
  const _ServersHeader({required this.count, required this.onConnect});

  final int count;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 16.5,
      child: Row(
        children: [
          Text('SERVERS', style: OmType.eyebrow()),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              '· $count',
              style: OmType.mono(
                size: 11,
                weight: FontWeight.w500,
                color: OmColors.fg2,
                letterSpacing: 0.6,
              ),
            ),
          ),
          const Spacer(),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: const Key('picker-servers-connect'),
              behavior: HitTestBehavior.opaque,
              onTap: onConnect,
              child: Text(
                '+ CONNECT',
                style: OmType.mono(
                  size: 10.5,
                  color: OmColors.fg2,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// No saved server (A3 state 2): the copy, "connect to a vault server…"
/// (`picker-no-servers-connect`) and "how do I set one up?"
/// (`picker-no-servers-setup`).
class _NoServersBox extends StatelessWidget {
  const _NoServersBox({required this.onConnect, required this.onSetUp});

  final VoidCallback onConnect;
  final VoidCallback onSetUp;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: OmColors.line3),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'no vault servers yet. connect to one to open its vaults on this '
            'mac.',
            style: OmType.sans(size: 13, color: OmColors.fg1, height: 1.5),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OmButton(
                key: const Key('picker-no-servers-connect'),
                kind: OmButtonKind.secondary,
                icon: LucideIcons.server,
                label: 'connect to a vault server…',
                onPressed: onConnect,
              ),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  key: const Key('picker-no-servers-setup'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onSetUp,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        LucideIcons.circleHelp,
                        size: 12,
                        color: OmColors.info,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'how do I set one up?',
                        style: OmType.sans(
                          size: 12,
                          color: OmColors.info,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
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

/// A3 state 1: the binary-not-found card. It says hosted vaults don't need
/// the binary.
class _BinaryNotFoundCard extends ConsumerWidget {
  const _BinaryNotFoundCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: OmColors.dangerBg,
        border: Border.all(color: OmColors.danger.withAlpha(69), width: 1),
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
          const SizedBox(height: 8),
          Text(
            "local vaults need it. hosted vaults don't.",
            style: OmType.sans(size: 12, color: OmColors.fg2, height: 1.5),
          ),
          const SizedBox(height: 8),
          OmButton(
            kind: OmButtonKind.secondary,
            label: 'locate memex binary…',
            onPressed: () =>
                locateMemexBinary(ref.read(settingsProvider.notifier)),
          ),
        ],
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
