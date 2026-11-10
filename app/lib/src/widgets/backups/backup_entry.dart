// WI #326 (A5, D24): the sidebar "backups" row under the vault pills and the
// automatic-failure warning (Spec #315 reqs 24, 31a, 37; design pack
// design/315-vault-backups/packs/326.md, board B1).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../../state/backup_controller.dart';
import '../../state/backup_messages.dart';
import '../../state/backup_models.dart';
import '../../state/clock.dart';
import '../../state/hosted_identity.dart';
import '../../state/vault_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import 'backup_keys.dart';
import 'backups_sheet.dart';

/// The warning row's border (pack 325/326 `warnLine`).
final _warnLine = OmColors.warn.withAlpha(77);

const _monthNames = [
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

/// The open vault's backups row: its state as text (off, never, the last
/// backup's age, backing up…, or the amber failure), and a press opens
/// `showBackupsSheet`. Reads the state from `backupControllerProvider` only:
/// no schedule, CLI call, poll or timer of its own. Renders nothing with no
/// vault open.
class BackupEntry extends ConsumerWidget {
  const BackupEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(backupControllerProvider);
    final vault = ref.watch(currentVaultProvider);
    if (vault == null) return const SizedBox.shrink();
    final view = ref.read(backupControllerProvider.notifier).viewStateOf(vault);
    final now = ref.read(clockProvider).now();
    final row = switch (vault) {
      LocalVaultRef(:final path) => _localRow(view, now, p.basename(path)),
      HostedVaultRef(:final serverId, :final vaultName) => _hostedRow(
        view,
        now,
        vaultName,
        ref.watch(hostedServerNameProvider(serverId)),
      ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: KeyedSubtree(
        key: backupsEntryKey,
        child: _EntryBox(
          row: row,
          onPressed: () => showBackupsSheet(context, vault),
        ),
      ),
    );
  }
}

/// What one row shows.
class _Row {
  const _Row({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.status,
    required this.semantics,
    this.warning = false,
    this.spinning = false,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String status;

  /// The full semantic label (`backups for <vault>: <state>. open backups`).
  final String semantics;

  /// The amber failure look and the `backups-entry-warning` badge.
  final bool warning;
  final bool spinning;
}

String _semantic(String vaultName, String state) =>
    'backups for $vaultName: $state. open backups';

_Row _plain(
  String vaultName,
  String label, {
  required String status,
  required String state,
  IconData icon = LucideIcons.archive,
  Color iconColor = OmColors.fg2,
  bool spinning = false,
}) => _Row(
  icon: icon,
  iconColor: iconColor,
  label: label,
  status: status,
  semantics: _semantic(vaultName, state),
  spinning: spinning,
);

_Row _backingUp(String vaultName, String label) => _plain(
  vaultName,
  label,
  status: 'backing up…',
  state: 'backing up',
  icon: LucideIcons.loaderCircle,
  iconColor: OmColors.info,
  spinning: true,
);

_Row _failure(
  String vaultName,
  String label,
  DateTime failedAt,
  DateTime now,
  String clause,
  BackupMessage? message,
) {
  final tail = message == null ? '' : ', ${message.short}';
  return _Row(
    icon: LucideIcons.triangleAlert,
    iconColor: OmColors.warn,
    label: label,
    status: _failureTime(failedAt, now),
    semantics: _semantic(
      vaultName,
      '$clause ${backupWhen(failedAt, now)}$tail',
    ),
    warning: true,
  );
}

_Row _localRow(BackupViewState view, DateTime now, String vaultName) {
  final status = view.status;
  final failedAt = view.failedAt ?? status?.lastAttemptAt;
  if (view.warning && failedAt != null) {
    return _failure(
      vaultName,
      'backup failed',
      failedAt,
      now,
      view.automatic ? 'the automatic backup failed' : 'back up now failed',
      view.message,
    );
  }
  switch (view.mode) {
    case BackupSheetMode.off:
    case BackupSheetMode.pickingDestination:
      return _plain(vaultName, 'backups', status: 'off', state: 'off');
    case BackupSheetMode.backingUp:
      return _backingUp(vaultName, 'backups');
    default:
      break;
  }
  final fileAt = status?.lastFileCreatedAt ?? status?.lastSuccessAt;
  if (fileAt == null) {
    return _plain(
      vaultName,
      'backups',
      status: 'never',
      state: 'never backed up',
    );
  }
  return _plain(
    vaultName,
    'backups',
    status: _age(fileAt, now),
    state: 'last backup ${backupWhen(fileAt, now)}',
    icon: LucideIcons.check,
    iconColor: OmColors.accent,
  );
}

_Row _hostedRow(
  BackupViewState view,
  DateTime now,
  String vaultName,
  String server,
) {
  final label = 'backups on $server';
  final status = view.status;
  var mode = view.mode;
  if (mode == BackupSheetMode.hostedUnreachable) {
    // The last value read stays (31a).
    mode = switch (status) {
      null => BackupSheetMode.off,
      BackupStatus(enabled: false) => BackupSheetMode.hostedNotConfigured,
      BackupStatus(lastResult: null) => BackupSheetMode.neverBackedUp,
      _ => BackupSheetMode.success,
    };
  }
  final failedAt = view.failedAt ?? status?.lastAttemptAt;
  if (view.warning && failedAt != null) {
    return _failure(
      vaultName,
      '$server backup failed',
      failedAt,
      now,
      "$server's backup failed",
      view.message,
    );
  }
  switch (mode) {
    case BackupSheetMode.hostedNotConfigured:
      return _plain(
        vaultName,
        label,
        status: 'set on $server',
        state: 'set on $server',
      );
    case BackupSheetMode.hostedServerTooOld:
      return _plain(
        vaultName,
        label,
        status: 'not on $server yet',
        state: 'not on $server yet',
      );
    case BackupSheetMode.backingUp:
      return _backingUp(vaultName, label);
    default:
      break;
  }
  final fileAt = status?.lastFileCreatedAt ?? status?.lastSuccessAt;
  if (fileAt == null) {
    if (status == null) {
      // Not read from the server yet: nothing to say beyond the label.
      return _plain(vaultName, label, status: '', state: label);
    }
    return _plain(vaultName, label, status: 'never', state: 'never backed up');
  }
  return _plain(
    vaultName,
    label,
    status: _sameDay(fileAt, now) ? _clock(fileAt) : _age(fileAt, now),
    state: "$server's last backup ${backupWhen(fileAt, now)}",
    icon: LucideIcons.check,
    iconColor: OmColors.accent,
  );
}

/// "just now" (under a minute, or a time after [now]), "N min ago",
/// "N h ago", "N d ago".
String _age(DateTime at, DateTime now) {
  final ago = now.difference(at);
  if (ago.inMinutes < 1) return 'just now';
  if (ago.inHours < 1) return '${ago.inMinutes} min ago';
  if (ago.inDays < 1) return '${ago.inHours} h ago';
  return '${ago.inDays} d ago';
}

/// "09:00" today, otherwise "7 nov" (local time).
String _failureTime(DateTime at, DateTime now) {
  if (_sameDay(at, now)) return _clock(at);
  final local = at.toLocal();
  return '${local.day} ${_monthNames[local.month - 1]}';
}

String _clock(DateTime at) {
  final local = at.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

bool _sameDay(DateTime a, DateTime b) {
  final x = a.toLocal();
  final y = b.toLocal();
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

/// The tappable bordered box: hover fill, keyboard-focus border and ring,
/// Enter / Space activation, one press → one sheet.
class _EntryBox extends StatefulWidget {
  const _EntryBox({required this.row, required this.onPressed});

  final _Row row;
  final VoidCallback onPressed;

  @override
  State<_EntryBox> createState() => _EntryBoxState();
}

class _EntryBoxState extends State<_EntryBox> {
  static const _shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
  };

  late final Map<Type, Action<Intent>> _actions = {
    ActivateIntent: CallbackAction<ActivateIntent>(
      onInvoke: (_) {
        widget.onPressed();
        return null;
      },
    ),
  };

  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final warn = row.warning;
    final large = MediaQuery.textScalerOf(context).scale(1) > 1;
    final Color border = switch ((warn, _focus)) {
      (true, true) => OmColors.warn,
      (true, false) => _warnLine,
      (false, true) => OmColors.lineStrong,
      (false, false) => OmColors.line1,
    };
    final Color? fill = warn
        ? OmColors.warnBg
        : (_hover ? OmColors.surface3 : null);
    final labelColor = warn ? OmColors.warn : OmColors.fg1;
    final statusColor = warn ? OmColors.warn : OmColors.fg2;

    final Widget icon = warn
        ? IgnorePointer(
            child: KeyedSubtree(
              key: backupsEntryWarningKey,
              child: Icon(row.icon, size: 12, color: row.iconColor),
            ),
          )
        : row.spinning
        ? _Spinner(icon: row.icon, color: row.iconColor)
        : Icon(row.icon, size: 12, color: row.iconColor);

    final box = Container(
      constraints: const BoxConstraints(minHeight: 28),
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: large ? 4 : 0),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: border, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: ExcludeSemantics(
        child: Row(
          children: [
            icon,
            const SizedBox(width: 8),
            Expanded(
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Text(
                    row.label,
                    style: OmType.sans(
                      size: 12.5,
                      height: 1.2,
                      color: labelColor,
                    ),
                  ),
                  if (row.status.isNotEmpty)
                    Text(
                      row.status,
                      style: OmType.mono(
                        size: 10.5,
                        height: 1.24,
                        color: statusColor,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return Semantics(
      container: true,
      button: true,
      label: row.semantics,
      onTap: widget.onPressed,
      child: FocusableActionDetector(
        shortcuts: _shortcuts,
        actions: _actions,
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: widget.onPressed,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                box,
                // Keyboard focus: a 2 px ring just outside the border, drawn
                // over nothing else and never hit.
                if (_focus)
                  Positioned(
                    left: -2,
                    top: -2,
                    right: -2,
                    bottom: -2,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: warn ? _warnLine : OmColors.accentGlow,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
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
}

/// The backing-up icon, turning while it is shown.
class _Spinner extends StatefulWidget {
  const _Spinner({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turns = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _turns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _turns,
    child: Icon(widget.icon, size: 12, color: widget.color),
  );
}
