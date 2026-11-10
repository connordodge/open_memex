import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../../state/picker_actions.dart';
import '../../state/server_probes.dart';
import '../../state/settings.dart';
import '../../state/vault_open_controller.dart';
import '../../state/vault_open_hosted.dart';
import '../../state/vault_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../atoms.dart';
import '../backups/backup_keys.dart';
import '../backups/restore_dialog.dart';
import '../dialog_button.dart';
import '../memex_too_old_dialog.dart';
import '../vault_open_refusal.dart';
import 'recent_row.dart';
import 'remove_server_dialog.dart';
import 'server_row.dart';

/// The eyebrow of a refusal shown for an open.
const vaultPickerOpenEyebrow = 'OPEN LOCAL VAULT';
const _createEyebrow = 'CREATE NEW VAULT';

/// The subtitle (board A1).
const _subtitle =
    'a vault is a folder of your notes. open one on this mac, or one hosted '
    'by a vault server.';

/// The tooltip of the disabled remove server on the open hosted vault's
/// server (Spec #357 Req 13, design A5).
String openOnServerTooltip(String vault) =>
    '$vault is open on this server. switch to another vault first.';

/// The vault picker's content (Spec #357 TD1): the one body the full-screen
/// picker (`VaultPickerScreen`) and the vault picker modal both show. It
/// reads `currentVaultProvider`; with no vault open it is the full-screen
/// picker of before.
///
/// With a vault open (the modal): that vault is the first RECENT row, with
/// the OPEN tag, and a tap on it calls [onClose]; any other row opens
/// through `openVaultGuarded` and clears the selected note on success; the
/// five flows ask `leaveVaultGuardProvider` once before their first dialog;
/// remove server is disabled on the open hosted vault's server.
class VaultPickerBody extends ConsumerStatefulWidget {
  const VaultPickerBody({super.key, this.opening, this.onClose});

  /// The vault the launch reopen is opening; its row shows as opening.
  final VaultRef? opening;

  /// Closes the modal the body shows in. When set, the header is the
  /// modal's (`CHOOSE A VAULT`, the `esc` hint and the × close button
  /// `vault-picker-modal-close`) instead of the full-screen brand row.
  final VoidCallback? onClose;

  @override
  ConsumerState<VaultPickerBody> createState() => VaultPickerBodyState();
}

class VaultPickerBodyState extends ConsumerState<VaultPickerBody> {
  /// The binary that could not be started on the last open (a spawn
  /// failure); while it is still the configured one the picker shows the
  /// "memex binary not found" card.
  String? _unstartableBinary;

  /// An open or flow started from the modal is running: a second press
  /// (the same frame, say) starts nothing.
  bool _busy = false;

  /// Shows what an open gave: nothing for a hosted failure (its recent row
  /// shows it, D19), a refusal dialog for a refused folder, the
  /// binary-not-found card for a binary that could not start, and the open
  /// error in a SnackBar for any other failure.
  Future<void> present(
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

  bool get _vaultOpen => ref.read(currentVaultProvider) != null;

  Future<void> _openRecent(VaultRef vault) async {
    final controller = ref.read(vaultOpenControllerProvider);
    if (!_vaultOpen) {
      final outcome = await controller.openVault(vault);
      await present(outcome, eyebrow: vaultPickerOpenEyebrow);
      return;
    }
    if (_busy) return;
    _busy = true;
    // Read before the open: the modal closes (and this body goes) as soon
    // as the vault changes.
    final selected = ref.read(selectedNoteIdProvider.notifier);
    try {
      final outcome = await controller.openVaultGuarded(context, vault);
      if (outcome is VaultOpened) {
        selected.state = null;
        return;
      }
      await present(outcome, eyebrow: vaultPickerOpenEyebrow);
    } finally {
      _busy = false;
    }
  }

  /// Runs [flow]; with a vault open, only once `leaveVaultGuardProvider`
  /// allows leaving it (asked once, before the flow's first dialog), and
  /// never while another open or flow from the modal runs.
  Future<void> _guarded(Future<void> Function() flow) async {
    if (!_vaultOpen) return flow();
    if (_busy) return;
    _busy = true;
    try {
      if (!await ref.read(leaveVaultGuardProvider)(context)) return;
      if (!mounted) return;
      await flow();
    } finally {
      _busy = false;
    }
  }

  /// Req 42: with no saved server, "connect" first; [flow] runs once it
  /// saved one. A cancelled connect runs nothing else.
  Future<void> _serverFlow(
    Future<void> Function(PickerActions actions, BuildContext context) flow,
  ) => _guarded(() async {
    final actions = ref.read(pickerActionsProvider);
    if (ref.read(settingsProvider).savedServers.isEmpty) {
      final saved = await actions.connect(context);
      if (saved == null || !mounted) return;
    }
    await flow(actions, context);
  });

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
    final current = ref.watch(currentVaultProvider);
    // The picker probes each saved server while it shows.
    ref.watch(serverProbesProvider);
    final binaryNotFound =
        cli == null ||
        (_unstartableBinary != null && cli.binaryPath == _unstartableBinary);
    // With a vault open it comes first; the others keep their recents
    // order. The recents setting itself is never reordered here.
    final recents = [
      ?current,
      for (final r in settings.recentRefs)
        if (r != current) r,
    ];
    final servers = settings.savedServers;
    final openHosted = current is HostedVaultRef ? current : null;
    final onClose = widget.onClose;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (onClose == null) ...[
          const _BrandRow(),
          const SizedBox(height: 36),
          Text('CHOOSE A VAULT', style: OmType.eyebrow()),
        ] else
          _ModalHeader(onClose: onClose),
        const SizedBox(height: 10),
        Text(
          _subtitle,
          style: OmType.sans(size: 13, color: OmColors.fg2, height: 21.45 / 13),
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
            if (current != null && i == 0)
              RecentRow(
                index: i,
                entry: recents[i],
                opening: false,
                binaryMissing: binaryNotFound,
                open: true,
                onOpen: () => widget.onClose?.call(),
              )
            else
              RecentRow(
                index: i,
                entry: recents[i],
                opening: recents[i] == widget.opening,
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
            onSetUp: () => ref.read(pickerActionsProvider).setUp(context),
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
              removeDisabledReason: openHosted?.serverId == servers[i].id
                  ? openOnServerTooltip(openHosted!.vaultName)
                  : null,
            ),
          ],
        const SizedBox(height: 24),
        _GridRow(
          label: 'THIS MAC',
          left: KeyedSubtree(
            key: const Key('vault-picker-create'),
            child: _ActionButton(
              kind: binaryNotFound
                  ? OmButtonKind.secondary
                  : OmButtonKind.primary,
              icon: LucideIcons.folderPlus,
              label: 'create local vault…',
              onPressed: binaryNotFound ? null : () => _guarded(_createVault),
            ),
          ),
          right: KeyedSubtree(
            key: const Key('vault-picker-open'),
            child: _ActionButton(
              kind: OmButtonKind.secondary,
              icon: LucideIcons.folderOpen,
              label: 'open local vault…',
              onPressed: binaryNotFound
                  ? null
                  : () => _guarded(_openExistingVault),
            ),
          ),
        ),
        const SizedBox(height: 8),
        _GridRow(
          label: 'VAULT SERVER',
          left: KeyedSubtree(
            key: const Key('vault-picker-open-on-server'),
            child: _ActionButton(
              // Binary not found (A3 state 1): the first server action takes
              // the primary style.
              kind: binaryNotFound
                  ? OmButtonKind.primary
                  : OmButtonKind.secondary,
              icon: LucideIcons.server,
              label: 'open vault on a server…',
              onPressed: () => _serverFlow((a, c) => a.openOnServer(c)),
            ),
          ),
          right: KeyedSubtree(
            key: const Key('vault-picker-create-on-server'),
            child: _ActionButton(
              kind: OmButtonKind.secondary,
              icon: LucideIcons.plus,
              label: 'create vault on a server…',
              onPressed: () => _serverFlow((a, c) => a.createOnServer(c)),
            ),
          ),
        ),
        const SizedBox(height: 8),
        _GridRow(
          label: 'BACKUP',
          left: KeyedSubtree(
            key: vaultPickerRestoreKey,
            child: _ActionButton(
              kind: OmButtonKind.secondary,
              icon: LucideIcons.history,
              label: 'restore from backup…',
              onPressed: binaryNotFound
                  ? null
                  : () => _guarded(_restoreFromBackup),
            ),
          ),
          right: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              'makes a new vault from a .memex.zip; never writes over one',
              style: OmType.sans(size: 12, color: OmColors.fg2, height: 1.5),
            ),
          ),
        ),
      ],
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
    await present(outcome, eyebrow: _createEyebrow);
  }

  /// Req 35: pick a `.zip`, then the Restore dialog; it runs the restore
  /// and closes only on success, with the restored folder, which opens.
  Future<void> _restoreFromBackup() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose a backup to restore',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    final file = picked?.files.firstOrNull;
    final path = file?.path;
    if (path == null || !mounted) return;
    final restored = await showRestoreDialog(
      context,
      file: path,
      bytes: _sizeOf(path, fallback: file!.size),
    );
    if (restored == null || !mounted) return;
    final outcome = await ref
        .read(vaultOpenControllerProvider)
        .openVault(LocalVaultRef(restored));
    await present(outcome, eyebrow: vaultPickerOpenEyebrow);
  }

  Future<void> _openExistingVault() async {
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose a vault folder',
    );
    if (selected == null || !mounted) return;
    final outcome = await ref
        .read(vaultOpenControllerProvider)
        .openVault(LocalVaultRef(selected));
    await present(outcome, eyebrow: vaultPickerOpenEyebrow);
  }
}

/// The full-screen picker's brand row (A3): the ring logo, `open memex` and
/// the version.
class _BrandRow extends StatelessWidget {
  const _BrandRow();

  @override
  Widget build(BuildContext context) {
    return Row(
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
          style: OmType.mono(size: 11, color: OmColors.fg3, letterSpacing: 0.8),
        ),
      ],
    );
  }
}

/// The modal's header (pack 362): `CHOOSE A VAULT`, then the `esc` hint and
/// the × close button (`vault-picker-modal-close`), 24 high, gap 8.
class _ModalHeader extends StatelessWidget {
  const _ModalHeader({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          Text('CHOOSE A VAULT', style: OmType.eyebrow()),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 5),
            decoration: BoxDecoration(
              border: Border.all(color: OmColors.line2),
              borderRadius: BorderRadius.circular(3),
            ),
            child: const OmKbd('esc'),
          ),
          const SizedBox(width: 8),
          PickerRowIconButton(
            key: const Key('vault-picker-modal-close'),
            icon: LucideIcons.x,
            iconSize: 14,
            tooltip: null,
            semanticLabel: 'close the vault picker',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// A 36-high action [OmButton] that works from the keyboard: Tab reaches
/// it (unless disabled), Enter and Space press it once per key press, and
/// it draws an `accentSoft` radius-6 ring while the focus highlight is on.
class _ActionButton extends StatefulWidget {
  const _ActionButton({
    required this.kind,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final OmButtonKind kind;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _highlight = false;

  late final Map<Type, Action<Intent>> _actions = {
    ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: _press),
    ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
      onInvoke: _press,
    ),
  };

  Object? _press(Intent _) {
    widget.onPressed?.call();
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      enabled: widget.onPressed != null,
      shortcuts: keyboardButtonShortcuts,
      actions: _actions,
      onShowFocusHighlight: (v) => setState(() => _highlight = v),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: _highlight ? Border.all(color: OmColors.accentSoft) : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: OmButton(
          kind: widget.kind,
          size: 36,
          icon: widget.icon,
          label: widget.label,
          onPressed: widget.onPressed,
        ),
      ),
    );
  }
}

/// The size of the file at [path] read from the file itself; [fallback]
/// (the picker's report) when it can't be read.
int _sizeOf(String path, {required int fallback}) {
  try {
    return File(path).lengthSync();
  } on FileSystemException {
    return fallback;
  }
}

/// A row of the action grid (pack 97): a 92 px upper-case mono label, then
/// two equal cells, gaps 8. At least 36 high, so a text cell can wrap at
/// large text (pack 327).
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
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 36),
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
