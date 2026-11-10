import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../../db.dart';
import '../../state/hosted_connection_state.dart';
import '../../state/picker_actions.dart';
import '../../state/server_probes.dart';
import '../../state/settings.dart';
import '../../state/vault_open_controller.dart';
import '../../state/vault_open_hosted.dart';
import '../../state/vault_ref.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../atoms.dart';
import 'delete_vault_dialog.dart';
import 'server_row.dart';

/// A RECENT row (key `recent-row-<index>`, pack 97, board A3 state 3) for
/// [entry], local or hosted.
///
/// A recorded `recentRowOutcomeProvider(entry)` wins over the server's
/// probe status. [opening] is true while the picker's launch reopen runs on
/// [entry]; an opening row has no × and does not open. [binaryMissing] is
/// true while no `memex` binary can run: local rows then show "needs the
/// memex binary" and do not open. [onOpen] opens [entry] (a tap, or a
/// hosted row's "retry").
///
/// A local row whose folder is a vault also has a delete button
/// (`recent-row-delete-<index>`) before its ×; it opens the delete-vault
/// dialog, and the row re-checks its folder when the dialog closes.
class RecentRow extends ConsumerStatefulWidget {
  const RecentRow({
    super.key,
    required this.index,
    required this.entry,
    required this.opening,
    required this.binaryMissing,
    required this.onOpen,
  });

  final int index;
  final VaultRef entry;
  final bool opening;
  final bool binaryMissing;
  final VoidCallback onOpen;

  @override
  ConsumerState<RecentRow> createState() => _RecentRowState();
}

class _RecentRowState extends ConsumerState<RecentRow> {
  int get index => widget.index;
  VaultRef get entry => widget.entry;
  bool get opening => widget.opening;
  bool get binaryMissing => widget.binaryMissing;
  VoidCallback get onOpen => widget.onOpen;

  @override
  Widget build(BuildContext context) {
    final recorded = ref.watch(recentRowOutcomeProvider(entry));
    final isOpening = opening || recorded is RecentRowOpening;
    final key = Key('recent-row-$index');
    return switch (entry) {
      LocalVaultRef(:final path) =>
        isOpening
            ? _OpeningRow(key: key, name: p.basename(path), subline: path)
            : _localRow(ref, key, path),
      final HostedVaultRef hosted => _hostedRow(
        context,
        ref,
        key,
        hosted,
        isOpening,
        recorded,
      ),
    };
  }

  Widget _localRow(WidgetRef ref, Key key, String path) {
    final exists = VaultDb.isVault(path);
    final IconData icon;
    final Color iconColor;
    if (!exists) {
      icon = LucideIcons.folderX;
      iconColor = OmColors.danger;
    } else {
      icon = LucideIcons.folder;
      iconColor = binaryMissing ? OmColors.fg3 : OmColors.fg2;
    }
    return PickerRowShell(
      key: key,
      onTap: exists && !binaryMissing ? onOpen : null,
      child: _RowBody(
        icon: Icon(icon, size: 14, color: iconColor),
        name: p.basename(path),
        nameColor: exists && !binaryMissing ? OmColors.fg0 : OmColors.fg2,
        subline: Text(
          path,
          style: pickerRowSublineStyle(OmColors.fg2),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        trailing: [
          if (binaryMissing)
            Text(
              'needs the memex binary',
              style: OmType.mono(size: 10.5, color: OmColors.fg2),
            ),
          if (exists) _deleteButton(path),
          _removeButton(ref),
        ],
      ),
    );
  }

  Widget _deleteButton(String path) => PickerRowIconButton(
    key: Key('recent-row-delete-$index'),
    icon: LucideIcons.trash,
    tooltip: 'delete vault',
    semanticLabel: 'delete vault ${p.basename(path)}',
    onPressed: () => _delete(path),
  );

  /// Opens the delete-vault dialog, then rebuilds so the row re-checks
  /// `VaultDb.isVault` (a folder gone during a failed delete shows folderX).
  Future<void> _delete(String path) async {
    await confirmDeleteVault(context, path: path);
    if (mounted) setState(() {});
  }

  Widget _hostedRow(
    BuildContext context,
    WidgetRef ref,
    Key key,
    HostedVaultRef hosted,
    bool isOpening,
    RecentRowOutcome? recorded,
  ) {
    final settings = ref.watch(settingsProvider);
    final server = settings.savedServers
        .where((s) => s.id == hosted.serverId)
        .firstOrNull;
    final serverName = server?.name ?? hosted.serverId;

    if (isOpening) {
      return _OpeningRow(
        key: key,
        name: hosted.vaultName,
        subline: 'connecting to $serverName…',
      );
    }

    final view = recorded is RecentRowFailed
        ? _HostedView.fromFailure(recorded.failure)
        : _HostedView.fromStatus(
            ref.watch(hostedConnectionStatusProvider(hosted.serverId)),
            serverName: serverName,
            subline: server == null
                ? serverName
                : '$serverName · ${serverHostPort(server.url)}',
            incompatible: () => server == null
                ? hostedNotMemexMessage(serverName)
                : incompatibleCopy(
                    server,
                    ref.watch(serverProbeResultProvider(server.id)),
                  ),
          );

    final action = switch (view.action) {
      _HostedAction.none => null,
      _HostedAction.retry => OmButton(
        key: Key('recent-row-retry-$index'),
        kind: OmButtonKind.secondary,
        size: 24,
        dense: true,
        icon: LucideIcons.refreshCw,
        label: 'retry',
        onPressed: onOpen,
      ),
      _HostedAction.updateToken => OmButton(
        key: Key('recent-row-update-token-$index'),
        kind: OmButtonKind.secondary,
        size: 24,
        dense: true,
        label: 'update token',
        onPressed: () => ref
            .read(pickerActionsProvider)
            .editServer(context, hosted.serverId),
      ),
      _HostedAction.removeFromRecents => OmButton(
        key: Key('recent-row-remove-from-recents-$index'),
        kind: OmButtonKind.secondary,
        size: 24,
        dense: true,
        label: 'remove from recents',
        onPressed: () => _forget(ref),
      ),
    };

    return PickerRowShell(
      key: key,
      onTap: view.opens ? onOpen : null,
      border: view.border,
      child: _RowBody(
        icon: Icon(view.icon, size: 14, color: view.iconColor),
        name: hosted.vaultName,
        nameColor: OmColors.fg0,
        subline: Row(
          children: [
            StatusDot(state: view.dot),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                view.text,
                style: pickerRowSublineStyle(view.textColor),
                maxLines: view.wraps ? null : 1,
                overflow: view.wraps ? null : TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        trailing: [?action, _removeButton(ref)],
      ),
    );
  }

  Widget _removeButton(WidgetRef ref) => PickerRowIconButton(
    key: Key('recent-row-remove-$index'),
    icon: LucideIcons.x,
    tooltip: 'remove from recents',
    onPressed: () => _forget(ref),
  );

  /// Drops [entry] from the recents and its recorded outcome.
  void _forget(WidgetRef ref) {
    ref.read(recentRowOutcomeProvider(entry).notifier).state = null;
    ref.read(settingsProvider.notifier).forgetRef(entry);
  }
}

enum _HostedAction { none, retry, updateToken, removeFromRecents }

/// How a hosted row shows its server status or recorded failure.
class _HostedView {
  const _HostedView({
    required this.icon,
    required this.iconColor,
    required this.dot,
    required this.text,
    required this.textColor,
    this.border,
    this.action = _HostedAction.none,
    this.opens = true,
    this.wraps = false,
  });

  final IconData icon;
  final Color iconColor;
  final StatusDotState dot;
  final String text;
  final Color textColor;
  final Color? border;
  final _HostedAction action;

  /// Whether a tap opens the vault.
  final bool opens;

  /// Long messages wrap in the subline (the row grows).
  final bool wraps;

  static final _warnBorder = OmColors.warn.withAlpha(89);
  static final _dangerBorder = OmColors.danger.withAlpha(89);

  /// Can't reach: `wifiOff` and the text in `warn`, the warn border, retry.
  factory _HostedView.unreachable(String text) => _HostedView(
    icon: LucideIcons.wifiOff,
    iconColor: OmColors.warn,
    dot: StatusDotState.cantReach,
    text: text,
    textColor: OmColors.warn,
    border: _warnBorder,
    action: _HostedAction.retry,
  );

  /// The A3 token-rejected layout: [icon] and the text in `danger`, the
  /// danger border and the filled danger dot.
  factory _HostedView.danger(
    IconData icon,
    String text, {
    _HostedAction action = _HostedAction.none,
    bool opens = true,
  }) => _HostedView(
    icon: icon,
    iconColor: OmColors.danger,
    dot: StatusDotState.tokenRejected,
    text: text,
    textColor: OmColors.danger,
    border: _dangerBorder,
    action: action,
    opens: opens,
    wraps: true,
  );

  /// A recorded failed open (Req 47, D19): the failure's own message.
  factory _HostedView.fromFailure(VaultOpenFailure failure) =>
      switch (failure) {
        HostedServerUnreachable(:final message) => _HostedView.unreachable(
          message,
        ),
        HostedTokenRejected(:final message) => _HostedView.danger(
          LucideIcons.keyRound,
          message,
          action: _HostedAction.updateToken,
        ),
        HostedVaultGone(:final message) => _HostedView.danger(
          LucideIcons.folderX,
          message,
          action: _HostedAction.removeFromRecents,
        ),
        HostedNotMemexServer(:final message) ||
        HostedApiMismatch(:final message) ||
        HostedSchemaRefused(:final message) => _HostedView.danger(
          LucideIcons.alertTriangle,
          message,
          opens: false,
        ),
        _ => _HostedView.danger(LucideIcons.alertTriangle, failure.message),
      };

  /// The server's probe [status] (Req 38, 39).
  factory _HostedView.fromStatus(
    HostedConnectionStatus? status, {
    required String serverName,
    required String subline,
    required String Function() incompatible,
  }) => switch (status) {
    null || HostedConnectionStatus.connected => _HostedView(
      icon: LucideIcons.server,
      iconColor: OmColors.fg2,
      dot: statusDotFor(status),
      text: subline,
      textColor: OmColors.fg2,
    ),
    HostedConnectionStatus.unreachable => _HostedView.unreachable(
      hostedUnreachableMessage(serverName),
    ),
    HostedConnectionStatus.tokenRejected => _HostedView.danger(
      LucideIcons.keyRound,
      hostedTokenRejectedMessage(serverName),
      action: _HostedAction.updateToken,
    ),
    HostedConnectionStatus.incompatible => _HostedView.danger(
      LucideIcons.alertTriangle,
      incompatible(),
      opens: false,
    ),
  };
}

/// Icon, name over subline, then [trailing] (gap 10 between children).
class _RowBody extends StatelessWidget {
  const _RowBody({
    required this.icon,
    required this.name,
    required this.nameColor,
    required this.subline,
    this.trailing = const [],
  });

  final Widget icon;
  final String name;
  final Color nameColor;
  final Widget subline;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        icon,
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                style: pickerRowNameStyle(nameColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subline,
            ],
          ),
        ),
        for (final t in trailing) ...[const SizedBox(width: 10), t],
      ],
    );
  }
}

/// A row while its vault opens (A3 state 3, A12 "opening · fg2, spinner"):
/// a spinning loader in place of the icon, the name and [subline], no ×,
/// no hover, not tappable. Also keyed `recent-row-opening` inside.
class _OpeningRow extends StatefulWidget {
  const _OpeningRow({super.key, required this.name, required this.subline});

  final String name;
  final String subline;

  @override
  State<_OpeningRow> createState() => _OpeningRowState();
}

class _OpeningRowState extends State<_OpeningRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
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
    return Container(
      key: const Key('recent-row-opening'),
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: OmColors.surface2,
        border: Border.all(color: OmColors.line2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: _RowBody(
        icon: RotationTransition(
          turns: _spin,
          child: const Icon(LucideIcons.loader2, size: 14, color: OmColors.fg2),
        ),
        name: widget.name,
        nameColor: OmColors.fg0,
        subline: Text(
          widget.subline,
          style: pickerRowSublineStyle(OmColors.fg2),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      ),
    );
  }
}
