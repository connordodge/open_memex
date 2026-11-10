// WI #326 (A5, D24): the sidebar "backups" row under the vault pills and the
// automatic-failure warning (Spec #315 reqs 24, 31a, 37; design pack
// design/315-vault-backups/packs/326.md, board B1).
import 'dart:async';

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
/// no schedule, CLI call or poll of its own. While it shows a time (an age, a
/// clock time or a date), one `clockProvider` timer redraws it when that text
/// next turns: the age's next minute, hour or day, or local midnight.
/// Renders nothing with no vault open.
class BackupEntry extends ConsumerStatefulWidget {
  const BackupEntry({super.key});

  @override
  ConsumerState<BackupEntry> createState() => _BackupEntryState();
}

class _BackupEntryState extends ConsumerState<BackupEntry> {
  /// The failure each vault's warning row last stated, kept while its
  /// warning holds. A retry (backing up) or a "Back up now" that finds a
  /// backup already running keeps the warning but carries no failure of its
  /// own, so the row goes on naming the failure that raised the warning.
  final Map<VaultRef, _Failure> _stated = {};

  Timer? _redraw;
  DateTime? _redrawAt;

  @override
  void dispose() {
    _redraw?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(backupControllerProvider);
    final vault = ref.watch(currentVaultProvider);
    final clock = ref.read(clockProvider);
    if (vault == null) {
      _scheduleRedraw(clock, null, null);
      return const SizedBox.shrink();
    }
    final view = ref.read(backupControllerProvider.notifier).viewStateOf(vault);
    final now = clock.now();
    final failure = _failureOf(vault, view);
    final row = switch (vault) {
      LocalVaultRef(:final path) => _localRow(
        view,
        failure,
        now,
        p.basename(path),
      ),
      HostedVaultRef(:final serverId, :final vaultName) => _hostedRow(
        view,
        failure,
        now,
        vaultName,
        ref.watch(hostedServerNameProvider(serverId)),
      ),
    };
    _scheduleRedraw(clock, now, row.redrawAt);
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

  /// The failure [vault]'s warning names, or null with no warning. A view
  /// that carries its own failure (a failed run) is stated and kept. One that
  /// doesn't (a retry running, a press that found a backup already running,
  /// an unreachable server) states the kept one, else the failed attempt the
  /// state file recorded.
  _Failure? _failureOf(VaultRef vault, BackupViewState view) {
    if (!view.warning) {
      _stated.remove(vault);
      return null;
    }
    final failedAt = view.failedAt;
    if (failedAt != null && view.errorCode != _busyCode) {
      return _stated[vault] = _Failure(failedAt, view.automatic, view.message);
    }
    final kept = _stated[vault];
    if (kept != null) return kept;
    final status = view.status;
    final attemptAt = status?.lastAttemptAt;
    if (status != null && status.lastAttemptFailed && attemptAt != null) {
      return _Failure(attemptAt, true, null);
    }
    return null;
  }

  /// Keeps one timer, due at [at] (when the shown time text next turns), or
  /// none when [at] is null.
  void _scheduleRedraw(AppClock clock, DateTime? now, DateTime? at) {
    if (at == _redrawAt && (at == null || _redraw != null)) return;
    _redraw?.cancel();
    _redraw = null;
    _redrawAt = at;
    if (now == null || at == null) return;
    _redraw = clock.after(at.difference(now), () {
      _redraw = null;
      _redrawAt = null;
      if (mounted) setState(() {});
    });
  }
}

/// A press that found a backup already running: not a failure (Spec req 22),
/// so it never stands in for the warning's failure.
const _busyCode = 'backup_in_progress';

/// The failure a warning row states: when, whether the automatic backup or
/// "Back up now" failed, and the controller's message (its `short` is the
/// semantic-label tail).
class _Failure {
  const _Failure(this.at, this.automatic, this.message);

  final DateTime at;
  final bool automatic;
  final BackupMessage? message;
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
    this.redrawAt,
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

  /// When the shown time text next turns; null when no time is shown.
  final DateTime? redrawAt;
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
  DateTime? redrawAt,
}) => _Row(
  icon: icon,
  iconColor: iconColor,
  label: label,
  status: status,
  semantics: _semantic(vaultName, state),
  spinning: spinning,
  redrawAt: redrawAt,
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
  _Failure? failure,
  DateTime now,
  String clause,
) {
  if (failure == null) {
    // The warning holds but no failure time is known: amber, no time.
    return _Row(
      icon: LucideIcons.triangleAlert,
      iconColor: OmColors.warn,
      label: label,
      status: '',
      semantics: _semantic(vaultName, clause),
      warning: true,
    );
  }
  final message = failure.message;
  final tail = message == null ? '' : ', ${message.short}';
  return _Row(
    icon: LucideIcons.triangleAlert,
    iconColor: OmColors.warn,
    label: label,
    status: _failureTime(failure.at, now),
    semantics: _semantic(
      vaultName,
      '$clause ${backupWhen(failure.at, now)}$tail',
    ),
    warning: true,
    redrawAt: _nextMidnight(now),
  );
}

/// Whether the row shows the amber warning: the warning holds and names a
/// failure, or a retry or a press that found a backup already running is
/// under way while it holds (lead ruling Q1), even with no failure time known.
bool _warns(BackupViewState view, _Failure? failure) =>
    view.warning &&
    (failure != null ||
        view.mode == BackupSheetMode.backingUp ||
        view.errorCode == _busyCode);

_Row _localRow(
  BackupViewState view,
  _Failure? failure,
  DateTime now,
  String vaultName,
) {
  final status = view.status;
  if (_warns(view, failure)) {
    return _failure(
      vaultName,
      'backup failed',
      failure,
      now,
      (failure?.automatic ?? true)
          ? 'the automatic backup failed'
          : 'back up now failed',
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
    redrawAt: _earlier(_ageTurn(fileAt, now), _nextMidnight(now)),
  );
}

_Row _hostedRow(
  BackupViewState view,
  _Failure? failure,
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
  if (_warns(view, failure)) {
    return _failure(
      vaultName,
      '$server backup failed',
      failure,
      now,
      "$server's backup failed",
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
  final sameDay = _sameDay(fileAt, now);
  return _plain(
    vaultName,
    label,
    status: sameDay ? _clock(fileAt) : _age(fileAt, now),
    state: "$server's last backup ${backupWhen(fileAt, now)}",
    icon: LucideIcons.check,
    iconColor: OmColors.accent,
    redrawAt: sameDay
        ? _nextMidnight(now)
        : _earlier(_ageTurn(fileAt, now), _nextMidnight(now)),
  );
}

/// When [_age] of [at] next reads differently: the next whole minute, hour
/// or day since [at]. A time after [now] reads "just now" until a minute
/// after it.
DateTime _ageTurn(DateTime at, DateTime now) {
  final ago = now.difference(at);
  if (ago.inMinutes < 1) return at.add(const Duration(minutes: 1));
  if (ago.inHours < 1) return at.add(Duration(minutes: ago.inMinutes + 1));
  if (ago.inDays < 1) return at.add(Duration(hours: ago.inHours + 1));
  return at.add(Duration(days: ago.inDays + 1));
}

/// The next local midnight after [now], when "today" turns into "yesterday"
/// and a clock time into a date.
DateTime _nextMidnight(DateTime now) {
  final local = now.toLocal();
  return DateTime(local.year, local.month, local.day + 1);
}

DateTime _earlier(DateTime a, DateTime b) => a.isBefore(b) ? a : b;

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
  );

  /// Turns unless the platform asks for reduced motion.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _turns.stop();
    } else if (!_turns.isAnimating) {
      _turns.repeat();
    }
  }

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
