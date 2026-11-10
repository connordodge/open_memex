// WI #321 (A0, D19, D23): the backup controller's public API. The abstract
// class, the providers' types and the in-flight set are frozen.
// WI #324 (A3, D12, D23): the live controller. The local schedule (a check
// on open and on every hourly tick), "Back up now", the app-wide in-flight
// set, the warning, the state re-read write-through and the hosted status
// with its 2 s sheet poll.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cli/backup_cli.dart';
import '../vault_access/errors.dart';
import '../vault_access/hosted/backup.dart';
import 'backup_messages.dart';
import 'backup_models.dart';
import 'backup_settings_state.dart';
import 'backup_state_reader.dart';
import 'clock.dart';
import 'hosted_identity.dart';
import 'vault_state.dart';

/// 24 hours, the D12 due interval.
const _dueAfterMs = 86400000;

/// The due rule (D12, Spec req 23), the Dart port of Rust `state::is_due`:
/// a check backs up when there is no [lastSuccessAt], when [lastSuccessAt] is
/// after [now] (the clock went backwards), or when 24 hours (86 400 000 ms)
/// or more have passed. Compares instants, never calendar fields.
bool isBackupDue(DateTime? lastSuccessAt, DateTime now) {
  if (lastSuccessAt == null) return true;
  final last = lastSuccessAt.millisecondsSinceEpoch;
  final at = now.millisecondsSinceEpoch;
  if (last > at) return true;
  return at - last >= _dueAfterMs;
}

// The provider folders `discoverBackupDestinations` offers (Spec req 20):
// `<provider folder>/Open Memex Backups`.
final _iCloudFolder = RegExp(
  r'/Library/Mobile Documents/com~apple~CloudDocs/Open Memex Backups$',
);
final _googleDriveFolder = RegExp(
  r'/Library/CloudStorage/GoogleDrive-[^/]+/My Drive/Open Memex Backups$',
);
final _oneDriveFolder = RegExp(
  r'/Library/CloudStorage/OneDrive-[^/]+/Open Memex Backups$',
);

/// The provider whose backup folder [destination] is, or null for a folder
/// chosen with "Choose folder…" (the card's `<where>` and `<provider>`).
BackupProvider? _providerOf(String destination) {
  var path = destination;
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (_iCloudFolder.hasMatch(path)) return BackupProvider.icloud;
  if (_googleDriveFolder.hasMatch(path)) return BackupProvider.googleDrive;
  if (_oneDriveFolder.hasMatch(path)) return BackupProvider.oneDrive;
  return null;
}

/// Backups for the open vault (D23): the automatic schedule, "Back up now",
/// the hosted status and its polling, and the per-vault view state the sheet
/// and the sidebar entry show. App-wide (not autoDispose), kept alive by
/// `Sidebar.build` watching [backupControllerProvider].
///
/// [state] holds the view state of each vault the controller has seen, so a
/// widget that watches the provider rebuilds when one changes.
abstract class BackupController
    extends StateNotifier<Map<VaultRef, BackupViewState>> {
  BackupController(super.state);

  /// [vault]'s current view state. A vault the controller hasn't seen reads
  /// as [BackupSheetMode.off] (`hosted` per the ref).
  BackupViewState viewStateOf(VaultRef vault);

  /// "Back up now" (without `--if-changed`) for a local vault, or the POST
  /// for a hosted one. Returns without any CLI or HTTP call while a backup of
  /// [vault] is in flight, however it started.
  Future<void> backUpNow(VaultRef vault);

  /// The Backups sheet opened on [vault]: re-reads the state, and for a
  /// hosted vault starts the 2 s poll while the server reports `in_progress`.
  void openSheet(VaultRef vault);

  /// The sheet closed: the hosted poll stops.
  void closeSheet(VaultRef vault);
}

const _hourly = Duration(hours: 1);
const _pollEvery = Duration(seconds: 2);

/// The last `backup-state.json` entry read for a vault, with the
/// destination it was read for.
class _StateEntry {
  const _StateEntry(this.destination, this.status);

  final String destination;
  final BackupStatus? status;
}

/// A failed run this controller started (`lastRunFailure`), kept in memory
/// because the CLI records some failures nowhere (exit 2, binary not found,
/// `network_filesystem`, `internal` before the lock).
class _RunFailure {
  const _RunFailure({
    required this.destination,
    required this.result,
    required this.at,
    required this.automatic,
    required this.warn,
    required this.seenAttemptAt,
  });

  final String destination;
  final BackupRunResult result;

  /// The state file's `lastAttemptAt` as read when the run ended (null: no
  /// entry). A later read with another attempt time is newer news; wall
  /// times are never compared, so a clock jump cannot keep the failure.
  final DateTime? seenAttemptAt;

  /// When the run ended (the card's `<failedAt>`).
  final DateTime at;

  /// The run was the scheduled one (false: "Back up now").
  final bool automatic;

  /// An automatic run failed since the last success: the entry warns.
  final bool warn;
}

/// A "Back up now" answered `backup_in_progress`.
class _BusyPress {
  const _BusyPress(this.destination, this.at, this.message);

  final String destination;
  final DateTime at;
  final String? message;
}

/// What the controller knows of one hosted vault's backups.
class _HostedEntry {
  /// The last answer of `GET` or `POST` (never [HostedBackupAlreadyRunning]).
  HostedBackupResult? last;

  /// The last call could not reach the server.
  bool unreachable = false;

  /// A `POST` is waiting for its answer.
  bool posting = false;

  /// The last `POST` answered 409 `backup_in_progress`; the next `GET` says.
  bool alreadyRunning = false;

  /// When this controller's `POST` started the running backup.
  DateTime? postedAt;

  /// This controller's `POST` started a backup whose result no answer has
  /// shown yet.
  bool pressed = false;

  /// `lastAttemptAt` of the result that backup left: a failure with this
  /// attempt time came from "Back up now", not the server's schedule.
  DateTime? manualAttemptAt;

  /// The number of requests sent; each request takes the next one.
  int sent = 0;

  /// A `GET` numbered at or below this was sent before the latest `POST`
  /// was sent or answered: its answer is older news and is dropped, so a
  /// slow `GET` cannot end the pressed backup or stop its poll.
  int staleUpTo = 0;

  BackupStatus? get status => switch (last) {
    HostedBackupOk(:final status) => status,
    _ => null,
  };

  bool get running =>
      posting || alreadyRunning || (status?.inProgress ?? false);
}

/// The real controller over A1's runner, state reader and hosted API and
/// A2's per-vault settings.
class LiveBackupController extends BackupController {
  LiveBackupController(this._ref) : super(const {}) {
    _clock = _ref.read(clockProvider);
    // Captured so a run that ends after dispose still clears the set.
    _inFlight = _ref.read(backupInFlightProvider.notifier);
    _ref.listen<Set<String>>(backupInFlightProvider, _onInFlightChanged);
    _ref.listen<VaultRef?>(
      currentVaultProvider,
      (_, next) => _onOpen(next),
      fireImmediately: true,
    );
    _tick = _clock.periodic(_hourly, (_) => _onTick());
  }

  final Ref _ref;
  late final AppClock _clock;
  late final StateController<Set<String>> _inFlight;
  late final Timer _tick;

  /// Local vault paths seen (their settings are listened to).
  final Set<String> _local = {};
  final Map<String, _StateEntry> _states = {};
  final Map<String, _RunFailure> _failures = {};

  /// When the run this controller started for a path began.
  final Map<String, DateTime> _startedAt = {};

  /// A "Back up now" answered `backup_in_progress`: the sheet says so until
  /// the next state read.
  final Map<String, _BusyPress> _busyPress = {};

  final Map<HostedVaultRef, _HostedEntry> _hosted = {};
  final Set<VaultRef> _sheets = {};
  final Map<HostedVaultRef, Timer> _polls = {};

  @override
  void dispose() {
    _tick.cancel();
    for (final t in _polls.values) {
      t.cancel();
    }
    _polls.clear();
    super.dispose();
  }

  // -------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------

  @override
  BackupViewState viewStateOf(VaultRef vault) {
    if (!mounted) return state[vault] ?? _unseen(vault);
    return _compute(vault);
  }

  @override
  Future<void> backUpNow(VaultRef vault) async {
    switch (vault) {
      case LocalVaultRef(:final path):
        _see(path);
        final settings = _settingsOf(path);
        if (!settings.enabled || settings.destination == null) return;
        await _run(path, settings, automatic: false);
      case HostedVaultRef():
        await _hostedStart(vault);
    }
  }

  @override
  void openSheet(VaultRef vault) {
    _sheets.add(vault);
    switch (vault) {
      case LocalVaultRef(:final path):
        _see(path);
        final destination = _settingsOf(path).destination;
        if (destination == null) {
          _publish(vault);
          return;
        }
        unawaited(_readState(path, destination));
      case HostedVaultRef():
        unawaited(_hostedRead(vault));
    }
  }

  @override
  void closeSheet(VaultRef vault) {
    _sheets.remove(vault);
    _polls.remove(vault)?.cancel();
  }

  // -------------------------------------------------------------------
  // Schedule
  // -------------------------------------------------------------------

  void _onOpen(VaultRef? vault) {
    switch (vault) {
      case LocalVaultRef(:final path):
        unawaited(_check(path));
      case HostedVaultRef():
        unawaited(_hostedRead(vault));
      case null:
        break;
    }
  }

  /// The hourly tick checks the open vault only.
  void _onTick() {
    if (!mounted) return;
    _onOpen(_ref.read(currentVaultProvider));
  }

  /// Re-reads the state and, with backups and automatic on, backs up with
  /// `--if-changed` when due.
  Future<void> _check(String path) async {
    _see(path);
    final destination = _settingsOf(path).destination;
    if (destination == null) {
      _publish(LocalVaultRef(path));
      return;
    }
    await _readState(path, destination);
    if (!mounted) return;
    final settings = _settingsOf(path);
    if (!settings.enabled ||
        !settings.automatic ||
        settings.destination != destination) {
      return;
    }
    final last = _states[path]?.status?.lastSuccessAt;
    if (!isBackupDue(last, _clock.now())) return;
    // A vault closed while its state was read (an open-vault delete may be
    // moving its folder, Spec #357 Req 33) is not backed up.
    if (_ref.read(currentVaultProvider) != LocalVaultRef(path)) return;
    await _run(path, settings, automatic: true);
  }

  /// The one run path, automatic or "Back up now". Returns with no runner
  /// call while [path] is in flight.
  Future<void> _run(
    String path,
    VaultBackupSettings settings, {
    required bool automatic,
  }) async {
    final destination = settings.destination!;
    final busy = _inFlight.state;
    if (busy.contains(path)) return;
    final runner = _ref.read(backupRunnerProvider);
    final before = _attemptAt(path, destination);
    _startedAt[path] = _clock.now();
    _inFlight.state = {...busy, path};
    try {
      BackupRunResult result;
      try {
        result = await runner.backup(
          vaultPath: path,
          destination: destination,
          keep: settings.keep,
          ifChanged: automatic,
        );
      } catch (e) {
        result = BackupFailure(code: 'internal', message: '$e');
      }
      if (!mounted) return;
      await _readState(path, destination, publish: false);
      if (!mounted) return;
      _record(
        path,
        destination,
        result,
        automatic: automatic,
        // An unreadable file after the run keeps the attempt seen before it.
        seenAttemptAt: _attemptAt(path, destination) ?? before,
      );
    } finally {
      _startedAt.remove(path);
      _inFlight.state = {..._inFlight.state}..remove(path);
    }
  }

  void _record(
    String path,
    String destination,
    BackupRunResult result, {
    required bool automatic,
    required DateTime? seenAttemptAt,
  }) {
    switch (result) {
      case BackupCreated() || BackupUnchanged():
        _failures.remove(path);
      case BackupFailure(code: 'backup_in_progress', :final message):
        // Not a failure: no warning, state untouched, the next tick decides.
        if (!automatic) {
          _busyPress[path] = _BusyPress(destination, _clock.now(), message);
        }
      case BackupFailure() || BackupTooOld() || BackupBinaryNotFound():
        final previous = _failures[path];
        final warned =
            previous != null &&
            previous.destination == destination &&
            previous.warn;
        _failures[path] = _RunFailure(
          destination: destination,
          result: result,
          at: _clock.now(),
          automatic: automatic,
          warn: automatic || warned,
          seenAttemptAt: seenAttemptAt,
        );
    }
  }

  /// The write-through: re-reads `backup-state.json` for [destination].
  Future<void> _readState(
    String path,
    String destination, {
    bool publish = true,
  }) async {
    _busyPress.remove(path);
    BackupStatus? status;
    try {
      status = await _ref
          .read(backupStateReaderProvider)
          .read(vaultPath: path, destination: destination);
    } catch (_) {
      // An unreadable file reads as no entry.
      status = null;
    }
    if (!mounted) return;
    _states[path] = _StateEntry(destination, status);
    final failure = _failures[path];
    final attempted = status?.lastAttemptAt;
    if (failure != null &&
        failure.destination == destination &&
        attempted != null &&
        attempted != failure.seenAttemptAt) {
      // A later attempt (a scheduled `memex backup`) is newer news.
      _failures.remove(path);
    }
    if (publish) _publish(LocalVaultRef(path));
  }

  /// `lastAttemptAt` of the last state read for [path] at [destination].
  DateTime? _attemptAt(String path, String destination) {
    final entry = _states[path];
    if (entry == null || entry.destination != destination) return null;
    return entry.status?.lastAttemptAt;
  }

  // -------------------------------------------------------------------
  // Hosted
  // -------------------------------------------------------------------

  /// One `GET`; only for the open vault (the API is the open vault's).
  Future<void> _hostedRead(HostedVaultRef vault) async {
    if (!mounted) return;
    final api = _apiFor(vault);
    if (api == null) return;
    final entry = _hosted.putIfAbsent(vault, _HostedEntry.new);
    final id = ++entry.sent;
    try {
      final result = await api.status();
      if (!mounted) return;
      if (id <= entry.staleUpTo) return;
      _applyHosted(entry, result);
    } on VaultUnreachableException {
      if (!mounted || id <= entry.staleUpTo) return;
      entry.unreachable = true;
    } catch (_) {
      // Anything else leaves the last value as it was.
      if (!mounted) return;
    }
    _publish(vault);
    _schedulePoll(vault);
  }

  /// The hosted "Back up now": one `POST`, never while one is pending or the
  /// server reports a backup running.
  Future<void> _hostedStart(HostedVaultRef vault) async {
    final entry = _hosted.putIfAbsent(vault, _HostedEntry.new);
    if (entry.running) return;
    final api = _apiFor(vault);
    if (api == null) return;
    entry.posting = true;
    entry.postedAt = _clock.now();
    entry.staleUpTo = ++entry.sent;
    _publish(vault);
    try {
      final result = await api.start();
      if (!mounted) return;
      _applyHosted(entry, result, posted: true);
    } on VaultUnreachableException {
      if (!mounted) return;
      entry.unreachable = true;
    } catch (_) {
      if (!mounted) return;
    } finally {
      entry.posting = false;
      if (!entry.pressed) entry.postedAt = null;
      // A `GET` sent while the `POST` waited answers older news than it.
      entry.staleUpTo = entry.sent;
    }
    _publish(vault);
    _schedulePoll(vault);
  }

  HostedBackupApi? _apiFor(HostedVaultRef vault) {
    if (_ref.read(currentVaultProvider) != vault) return null;
    return _ref.read(hostedBackupApiProvider);
  }

  void _applyHosted(
    _HostedEntry entry,
    HostedBackupResult result, {
    bool posted = false,
  }) {
    entry.unreachable = false;
    if (result is HostedBackupAlreadyRunning) {
      // Someone else's backup, not this controller's press.
      entry.alreadyRunning = true;
      return;
    }
    entry.last = result;
    entry.alreadyRunning = false;
    if (result is! HostedBackupOk) {
      entry
        ..pressed = false
        ..postedAt = null;
      return;
    }
    if (posted) {
      entry.pressed = true;
      return;
    }
    if (!result.status.inProgress) {
      // The pressed backup has ended: its result carries this attempt time.
      if (entry.pressed) entry.manualAttemptAt = result.status.lastAttemptAt;
      entry
        ..pressed = false
        ..postedAt = null;
    }
  }

  /// The 2 s poll: one `GET` 2 s after the last answer while a sheet is open
  /// on [vault] and its backup runs; cancelled otherwise, and while the
  /// server cannot be reached (the hourly read and the next sheet open try
  /// again).
  void _schedulePoll(HostedVaultRef vault) {
    if (!mounted) return;
    final entry = _hosted[vault];
    final wanted =
        entry != null &&
        entry.running &&
        !entry.unreachable &&
        _sheets.contains(vault);
    if (!wanted) {
      _polls.remove(vault)?.cancel();
      return;
    }
    _polls[vault] ??= _clock.after(_pollEvery, () {
      _polls.remove(vault);
      unawaited(_hostedRead(vault));
    });
  }

  // -------------------------------------------------------------------
  // View state
  // -------------------------------------------------------------------

  VaultBackupSettings _settingsOf(String path) =>
      _ref.read(vaultBackupSettingsProvider(path));

  /// Starts following [path]'s settings, so turning backups off hides the
  /// warning at once.
  void _see(String path) {
    if (!_local.add(path)) return;
    _ref.listen<VaultBackupSettings>(
      vaultBackupSettingsProvider(path),
      (_, _) => _publish(LocalVaultRef(path)),
    );
  }

  void _onInFlightChanged(Set<String>? previous, Set<String> next) {
    if (!mounted) return;
    final before = previous ?? const <String>{};
    for (final path in {...before, ...next}) {
      if (before.contains(path) != next.contains(path) &&
          _local.contains(path)) {
        _publish(LocalVaultRef(path));
      }
    }
  }

  void _publish(VaultRef vault) {
    if (!mounted) return;
    final view = _compute(vault);
    if (state[vault] == view) return;
    state = {...state, vault: view};
  }

  BackupViewState _unseen(VaultRef vault) => BackupViewState(
    mode: BackupSheetMode.off,
    hosted: vault is HostedVaultRef,
  );

  BackupViewState _compute(VaultRef vault) => switch (vault) {
    LocalVaultRef(:final path) =>
      _local.contains(path) ? _localView(path) : _unseen(vault),
    HostedVaultRef() => _hostedView(vault),
  };

  BackupViewState _localView(String path) {
    final settings = _settingsOf(path);
    final destination = settings.destination;
    final entry = _states[path];
    final status = destination != null && entry?.destination == destination
        ? entry!.status
        : null;
    if (!settings.enabled || destination == null) {
      return BackupViewState(
        mode: BackupSheetMode.off,
        settings: settings,
        status: status,
      );
    }
    final stored = _failures[path];
    final failure = stored?.destination == destination ? stored : null;
    final warning =
        (failure?.warn ?? false) || (status?.lastAttemptFailed ?? false);
    final now = _clock.now();
    BackupViewState view(
      BackupSheetMode mode, {
      String? errorCode,
      BackupMessage? message,
      bool automatic = false,
      DateTime? failedAt,
      DateTime? startedAt,
    }) => BackupViewState(
      mode: mode,
      settings: settings,
      status: status,
      errorCode: errorCode,
      message: message,
      automatic: automatic,
      failedAt: failedAt,
      startedAt: startedAt,
      warning: warning,
    );
    BackupViewState failed(
      String code,
      String? raw, {
      required bool automatic,
      required DateTime failedAt,
    }) => view(
      BackupSheetMode.error,
      errorCode: code,
      automatic: automatic,
      failedAt: failedAt,
      message: backupFailureMessage(
        code: code,
        message: raw,
        automatic: automatic,
        failedAt: failedAt,
        now: now,
        destination: destination,
        provider: _providerOf(destination),
      ),
    );
    if (_inFlight.state.contains(path)) {
      return view(BackupSheetMode.backingUp, startedAt: _startedAt[path]);
    }
    final busy = _busyPress[path];
    if (busy != null && busy.destination == destination) {
      return failed(
        'backup_in_progress',
        busy.message,
        automatic: false,
        failedAt: busy.at,
      );
    }
    if (failure != null) {
      switch (failure.result) {
        case BackupTooOld():
          return view(
            BackupSheetMode.memexTooOld,
            message: backupTooOldMessage(),
            automatic: failure.automatic,
            failedAt: failure.at,
          );
        case BackupBinaryNotFound():
          return view(
            BackupSheetMode.binaryNotFound,
            message: backupBinaryNotFoundMessage(),
            automatic: failure.automatic,
            failedAt: failure.at,
          );
        case BackupFailure(:final code, :final message):
          return failed(
            code,
            message,
            automatic: failure.automatic,
            failedAt: failure.at,
          );
        case BackupCreated() || BackupUnchanged():
          break;
      }
    }
    if (status == null || status.lastResult == null) {
      return view(BackupSheetMode.neverBackedUp);
    }
    if (status.lastAttemptFailed) {
      // Recorded by a run this controller did not start (a scheduled
      // `memex backup`, or an earlier session).
      return failed(
        status.lastResult!,
        status.lastError,
        automatic: true,
        failedAt: status.lastAttemptAt ?? now,
      );
    }
    return view(BackupSheetMode.success);
  }

  BackupViewState _hostedView(HostedVaultRef vault) {
    final entry = _hosted[vault];
    if (entry == null) return _unseen(vault);
    final last = entry.last;
    final status = entry.status;
    final enabled = status?.enabled ?? false;
    final warning = enabled && (status?.lastAttemptFailed ?? false);
    BackupViewState view(BackupSheetMode mode, {DateTime? startedAt}) =>
        BackupViewState(
          mode: mode,
          hosted: true,
          status: status,
          startedAt: startedAt,
          warning: warning,
        );
    if (entry.unreachable && !entry.posting) {
      // The sheet's unreachable state, whatever was read before; the warning
      // stays as the last status left it (31a).
      return view(BackupSheetMode.hostedUnreachable);
    }
    if (last is HostedBackupServerTooOld) {
      return view(BackupSheetMode.hostedServerTooOld);
    }
    if (last is HostedBackupNotConfigured || (last != null && !enabled)) {
      return view(BackupSheetMode.hostedNotConfigured);
    }
    if (entry.running) {
      return view(BackupSheetMode.backingUp, startedAt: entry.postedAt);
    }
    if (status == null) return view(BackupSheetMode.off);
    if (status.lastResult == null) return view(BackupSheetMode.neverBackedUp);
    if (status.lastAttemptFailed) {
      final code = status.lastResult!;
      final attempted = status.lastAttemptAt;
      final now = _clock.now();
      // A failure left by this controller's "Back up now" carries the
      // attempt time the pressed backup ended with; any other is the
      // server's schedule.
      final automatic = attempted == null || attempted != entry.manualAttemptAt;
      final failedAt = attempted ?? now;
      return BackupViewState(
        mode: BackupSheetMode.error,
        hosted: true,
        status: status,
        errorCode: code,
        automatic: automatic,
        failedAt: failedAt,
        message: backupFailureMessage(
          code: code,
          message: status.lastError,
          automatic: automatic,
          failedAt: failedAt,
          now: now,
          serverName: _ref.read(hostedServerNameProvider(vault.serverId)),
        ),
        warning: warning,
      );
    }
    return view(BackupSheetMode.success);
  }
}

final backupControllerProvider =
    StateNotifierProvider<BackupController, Map<VaultRef, BackupViewState>>(
      (ref) => LiveBackupController(ref),
    );

/// The local vault paths with a backup running right now (manual or
/// automatic), app-wide. The "Back up now" button is disabled while the open
/// vault's path is in it, and an automatic check never starts for a path in
/// it.
final backupInFlightProvider = StateProvider<Set<String>>(
  (ref) => const <String>{},
);
