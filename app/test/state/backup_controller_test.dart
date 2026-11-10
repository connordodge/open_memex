// WI #324 (A3, D12, D23): the live backup controller. The due rule ported
// from Rust (`due_cases.json`), the local schedule (a check on open and on
// every hourly `clockProvider.periodic` tick, `--if-changed` when due),
// "Back up now" (no `--if-changed`), the app-wide in-flight set, the warning
// (a recorded error or an unrecorded automatic failure, never while backups
// are off), the state re-read write-through, the lifecycle (switching vault
// and dispose never wait or cancel) and the hosted vault (one GET on open
// then hourly, 2 s polling only while a sheet is open and `in_progress`).
//
// Seams: A0's harness (`createBackupContainer`) and fakes only
// (FakeBackupRunner, FakeBackupStateReader, FakeHostedBackupApi) on a
// FakeClock. The per-vault settings come from a scoped
// `vaultBackupSettingsProvider` override in a child container (A2's real
// provider is not used), with `backupControllerProvider` scoped into that
// child so the live controller reads them. `backupInFlightProvider` stays in
// the harness container, so it outlives a disposed controller.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/backup_controller.dart';
import 'package:open_memex_app/src/state/backup_messages.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/backup_settings_state.dart';
import 'package:open_memex_app/src/state/hosted_identity.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/backup.dart';

import '../support/backup_fakes.dart';
import '../support/backup_harness.dart';
import '../support/fake_clock.dart';

// Paths with spaces, `~` and `@` are the normal case.
const _vaultA = LocalVaultRef('/Users/tester/Documents/My Notes');
const _vaultB = LocalVaultRef('/Users/tester/Documents/Work Vault');
const _destA =
    '/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/'
    'Open Memex Backups';
const _destB =
    '/Users/tester/Library/CloudStorage/GoogleDrive-connor@example.com/'
    'My Drive/Open Memex Backups';
const _hosted = HostedVaultRef('nas', 'work');

const _hour = Duration(hours: 1);
const _s1 = Duration(seconds: 1);
const _s2 = Duration(seconds: 2);

final _start = DateTime.utc(2026, 11, 9, 9);

/// Settings from run-time values, so the constructor really runs.
VaultBackupSettings _on({
  String destination = _destA,
  int keep = 45,
  bool automatic = true,
  bool enabled = true,
}) => VaultBackupSettings(
  enabled: enabled,
  destination: destination,
  keep: keep,
  automatic: automatic,
);

/// A state-file entry after a successful run at [at].
BackupStatus _ok(DateTime at, {String result = 'created'}) => BackupStatus(
  lastAttemptAt: at,
  lastSuccessAt: at,
  lastResult: result,
  lastFile: 'My-Notes-20261109T090000Z-01HV0000000000000000000000.memex.zip',
  lastFileCreatedAt: at,
  lastBytes: 136000000,
  lastFingerprint: 'ab12',
);

/// A state-file entry after a recorded failure at [at] ([lastSuccess] kept).
BackupStatus _failed(
  DateTime at, {
  DateTime? lastSuccess,
  String code = 'backup_destination_unavailable',
}) => BackupStatus(
  lastAttemptAt: at,
  lastSuccessAt: lastSuccess,
  lastResult: code,
  lastError: 'cannot write to the backup folder',
);

/// What `GET .../backup` answers.
HostedBackupOk _hostedStatus({
  bool inProgress = false,
  String? result,
  DateTime? at,
  bool enabled = true,
}) => HostedBackupOk(
  BackupStatus(
    enabled: enabled,
    keep: 30,
    inProgress: inProgress,
    lastAttemptAt: at,
    lastSuccessAt: result == null || result == 'created' ? at : null,
    lastResult: result,
    lastError: result == null || result == 'created' ? null : 'disk full',
    lastFile: result == 'created'
        ? 'work-20261109T030000Z-01HV0000000000000000000000.memex.zip'
        : null,
  ),
);

/// A FakeClock whose `now()` can be skewed from its timers' time: a wall
/// clock that jumps (NTP, a manual change) while the timers keep their pace.
class _SkewedClock extends FakeClock {
  _SkewedClock(super.start);

  Duration skew = Duration.zero;

  @override
  DateTime now() => super.now().add(skew);
}

/// The live controller over A0's harness, with per-vault settings a test can
/// change, and a runner that writes the state file the way `memex backup`
/// does (through [recordOnRun], once the run is released by [hold]).
class _Rig {
  _Rig(this.h, this.c, this._settings) {
    h.runner.onCall = (call) async {
      if (call is! FakeBackupCall) return;
      final gate = _gate;
      if (gate != null) await gate.future;
      final record = recordOnRun;
      final status = record?.call(call);
      if (status != null) {
        h.reader.setEntry(call.vaultPath, call.destination, status);
      }
    };
  }

  final BackupHarness h;

  /// The child container the controller lives in (scoped settings).
  final ProviderContainer c;
  final StateProvider<Map<String, VaultBackupSettings>> _settings;
  Completer<void>? _gate;

  /// What the CLI records for a run (null: records nothing). Defaults to a
  /// success at the run's time.
  BackupStatus? Function(FakeBackupCall call)? recordOnRun;

  FakeBackupRunner get runner => h.runner;
  FakeBackupStateReader get reader => h.reader;
  FakeHostedBackupApi get api => h.hostedApi;
  FakeClock get clock => h.clock;

  List<FakeBackupCall> get calls => h.runner.backupCalls;

  BackupController get controller => c.read(backupControllerProvider.notifier);

  BackupViewState view(VaultRef vault) => controller.viewStateOf(vault);

  /// Read from the harness container (it outlives the controller's).
  Set<String> get inFlight => h.container.read(backupInFlightProvider);

  /// From now on every backup run stays open until the returned completer
  /// completes (the state file is written then).
  Completer<void> hold() => _gate = Completer<void>();

  /// Lets later runs answer at once again.
  void unhold() => _gate = null;

  void setSettings(String path, VaultBackupSettings settings) {
    h.container.read(_settings.notifier).update((m) => {...m, path: settings});
  }

  /// Opens [vault] (the vault picker or a pill sets the current vault).
  Future<void> open(VaultRef? vault) async {
    h.container.read(currentVaultProvider.notifier).state = vault;
    await settle();
  }

  Future<void> settle() => pumpEventQueue();

  /// Moves the clock forward by [by] in [step]s, letting async work finish
  /// between steps (a real app has time between ticks).
  Future<void> advance(Duration by, {Duration step = _hour}) async {
    var left = by;
    while (left > Duration.zero) {
      final next = left < step ? left : step;
      clock.advance(next);
      left -= next;
      await settle();
    }
  }
}

/// Builds the rig with [vault] open and [settings] stored per vault path.
/// The controller starts the way `Sidebar.build` keeps it: watched.
Future<_Rig> _rig({
  VaultRef? vault,
  Map<String, VaultBackupSettings> settings = const {},
  Map<(String, String), BackupStatus> state = const {},
  FakeClock? clock,
  String? serverName,
  void Function(BackupHarness h)? before,
}) async {
  final h = await createBackupContainer(
    vault: vault,
    clock: clock ?? FakeClock(_start),
  );
  for (final e in state.entries) {
    h.reader.setEntry(e.key.$1, e.key.$2, e.value);
  }
  before?.call(h);
  final settingsState = StateProvider<Map<String, VaultBackupSettings>>(
    (_) => settings,
  );
  final c = ProviderContainer(
    parent: h.container,
    overrides: [
      vaultBackupSettingsProvider.overrideWith(
        (ref, path) =>
            ref.watch(settingsState)[path] ?? const VaultBackupSettings(),
      ),
      if (serverName != null)
        hostedServerNameProvider.overrideWith((ref, id) => serverName),
      backupControllerProvider,
    ],
  );
  addTearDown(c.dispose);
  final rig = _Rig(h, c, settingsState);
  rig.recordOnRun = (call) => _ok(h.clock.now());
  c.listen(backupControllerProvider, (_, _) {});
  await rig.settle();
  return rig;
}

void main() {
  // ------------------------------------------------------------------
  // AC 1: the due rule
  // ------------------------------------------------------------------
  group('due rule', () {
    test('isBackupDue matches every due_cases.json row', () {
      final fixture =
          jsonDecode(
                File('test/fixtures/backup/due_cases.json').readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(fixture['due_after_ms'], 86400000);
      final cases = (fixture['cases']! as List).cast<Map<String, Object?>>();
      expect(cases, isNotEmpty);
      for (final row in cases) {
        final lastMs = row['last_success_at'] as int?;
        final last = lastMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(lastMs, isUtc: true);
        final now = DateTime.fromMillisecondsSinceEpoch(
          row['now']! as int,
          isUtc: true,
        );
        expect(isBackupDue(last, now), row['due'], reason: '${row['name']}');
      }
    });

    test('isBackupDue compares instants whatever the time zone', () {
      final last = DateTime.utc(2026, 10, 31, 9);
      // The same instants in local time: 24 h later is due, 1 ms short is
      // not, across the US DST change of 1 November 2026.
      expect(
        isBackupDue(last.toLocal(), last.add(const Duration(hours: 24))),
        isTrue,
      );
      expect(
        isBackupDue(
          last,
          last
              .add(const Duration(hours: 24))
              .subtract(const Duration(milliseconds: 1))
              .toLocal(),
        ),
        isFalse,
      );
      expect(isBackupDue(last.toLocal(), last.toLocal()), isFalse);
      expect(
        isBackupDue(last, last.subtract(const Duration(minutes: 1))),
        isTrue,
      );
    });
  });

  // ------------------------------------------------------------------
  // AC 2-3: the local schedule
  // ------------------------------------------------------------------
  group('local schedule', () {
    test(
      'opening a never backed up local vault runs exactly one backup if changed',
      () async {
        final r = await _rig(vault: _vaultA, settings: {_vaultA.path: _on()});
        expect(r.calls, hasLength(1));
        final call = r.calls.single;
        expect(call.vaultPath, _vaultA.path);
        expect(call.destination, _destA);
        expect(call.keep, 45);
        expect(call.ifChanged, isTrue);
        expect(r.api.calls, isEmpty, reason: 'a local vault never GETs');
        // The run's own record makes the next check not due.
        await r.advance(const Duration(hours: 3));
        expect(r.calls, hasLength(1));
      },
    );

    test(
      'a vault opened after the controller started runs its check on open',
      () async {
        final r = await _rig(settings: {_vaultA.path: _on()});
        expect(r.calls, isEmpty);
        await r.open(_vaultA);
        expect(r.calls, hasLength(1));
        expect(r.calls.single.ifChanged, isTrue);
      },
    );

    test(
      'not due runs nothing on open and at each tick until the first tick 24 h after the last success',
      () async {
        final last = _start.subtract(const Duration(hours: 20));
        final r = await _rig(
          vault: _vaultA,
          settings: {_vaultA.path: _on()},
          state: {(_vaultA.path, _destA): _ok(last)},
        );
        expect(r.calls, isEmpty, reason: 'not due on open');
        await r.advance(const Duration(hours: 3));
        expect(r.calls, isEmpty, reason: 'ticks at 21, 22 and 23 h');
        await r.advance(const Duration(minutes: 59), step: _s1 * 60);
        expect(r.calls, isEmpty, reason: 'no check between ticks');
        await r.advance(const Duration(minutes: 1), step: _s1 * 60);
        expect(r.calls, hasLength(1), reason: 'the tick at exactly 24 h');
        expect(r.calls.single.ifChanged, isTrue);
        await r.advance(const Duration(hours: 23));
        expect(r.calls, hasLength(1), reason: 'the run recorded a success');
        await r.advance(_hour);
        expect(r.calls, hasLength(2), reason: '24 h after that success');
      },
    );

    test('a last success in the future counts as due on open', () async {
      // The clock went backwards since the last success.
      final r = await _rig(
        vault: _vaultA,
        settings: {_vaultA.path: _on()},
        state: {
          (_vaultA.path, _destA): _ok(_start.add(const Duration(hours: 2))),
        },
      );
      expect(r.calls, hasLength(1));
      expect(r.calls.single.ifChanged, isTrue);
    });

    test('a wall clock jump backwards makes the next tick due', () async {
      final clock = _SkewedClock(_start);
      final r = await _rig(
        vault: _vaultA,
        settings: {_vaultA.path: _on()},
        state: {
          (_vaultA.path, _destA): _ok(
            _start.subtract(const Duration(hours: 1)),
          ),
        },
        clock: clock,
      );
      expect(r.calls, isEmpty);
      await r.advance(_hour);
      expect(r.calls, isEmpty, reason: '2 h since the last success');
      clock.skew = const Duration(days: -2);
      await r.advance(_hour);
      expect(r.calls, hasLength(1), reason: 'last success is after now');
    });

    test(
      'automatic off runs nothing on open or at ticks but Back up now still runs',
      () async {
        final r = await _rig(
          vault: _vaultA,
          settings: {_vaultA.path: _on(automatic: false)},
        );
        await r.advance(const Duration(hours: 48));
        expect(r.calls, isEmpty);
        await r.controller.backUpNow(_vaultA);
        await r.settle();
        expect(r.calls, hasLength(1));
        expect(r.calls.single.ifChanged, isFalse);
      },
    );

    test(
      'backups off runs nothing until they are turned on and the next tick',
      () async {
        final r = await _rig(
          vault: _vaultA,
          settings: {_vaultA.path: _on(enabled: false)},
        );
        await r.advance(const Duration(hours: 48));
        expect(r.calls, isEmpty);
        r.setSettings(_vaultA.path, _on());
        await r.advance(_hour);
        expect(r.calls, hasLength(1));
        expect(r.calls.single.ifChanged, isTrue);
        expect(r.calls.single.destination, _destA);
      },
    );

    test('ticks check only the open vault', () async {
      final r = await _rig(
        vault: _vaultA,
        settings: {
          _vaultA.path: _on(),
          _vaultB.path: _on(destination: _destB, keep: 7),
        },
        state: {
          (_vaultA.path, _destA): _ok(_start),
          (_vaultB.path, _destB): _ok(_start),
        },
      );
      await r.open(_vaultB);
      expect(r.calls, isEmpty);
      await r.advance(const Duration(hours: 24));
      expect(r.calls, hasLength(1));
      expect(r.calls.single.vaultPath, _vaultB.path);
      expect(r.calls.single.destination, _destB);
      expect(r.calls.single.keep, 7);
    });
  });

  // ------------------------------------------------------------------
  // Write-through: the state re-read
  // ------------------------------------------------------------------
  group('write-through', () {
    test(
      'the state file is re-read exactly once on open, each tick, sheet open and after each run',
      () async {
        final r = await _rig(
          vault: _vaultA,
          settings: {_vaultA.path: _on()},
          state: {(_vaultA.path, _destA): _ok(_start)},
        );
        expect(r.reader.reads, hasLength(1), reason: 'on open');
        expect(r.reader.reads.single.vaultPath, _vaultA.path);
        expect(r.reader.reads.single.destination, _destA);
        await r.advance(const Duration(minutes: 59), step: _s1 * 60);
        expect(r.reader.reads, hasLength(1), reason: 'no file watcher');
        await r.advance(const Duration(minutes: 1), step: _s1 * 60);
        expect(r.reader.reads, hasLength(2), reason: 'the hourly tick');
        r.controller.openSheet(_vaultA);
        await r.settle();
        expect(r.reader.reads, hasLength(3), reason: 'sheet open');
        r.controller.closeSheet(_vaultA);
        await r.controller.backUpNow(_vaultA);
        await r.settle();
        expect(r.calls, hasLength(1));
        expect(r.reader.reads, hasLength(4), reason: 'after the run');
        expect(r.view(_vaultA).status, _ok(_start.add(_hour)));
        expect(r.runner.restoreCalls, isEmpty);
      },
    );

    test(
      'an error written to the state file from outside shows the warning after the next tick with no backup',
      () async {
        final r = await _rig(
          vault: _vaultA,
          settings: {_vaultA.path: _on()},
          state: {
            (_vaultA.path, _destA): _ok(
              _start.subtract(const Duration(hours: 1)),
            ),
          },
        );
        expect(r.view(_vaultA).warning, isFalse);
        expect(r.view(_vaultA).mode, BackupSheetMode.success);
        // A scheduled `memex backup` fails and records it.
        r.reader.setEntry(
          _vaultA.path,
          _destA,
          _failed(
            _start.add(const Duration(minutes: 10)),
            lastSuccess: _start.subtract(const Duration(hours: 1)),
          ),
        );
        await r.advance(const Duration(minutes: 30), step: _s1 * 60);
        expect(r.view(_vaultA).warning, isFalse, reason: 'no file watcher');
        await r.advance(const Duration(minutes: 30), step: _s1 * 60);
        expect(r.view(_vaultA).warning, isTrue);
        expect(r.view(_vaultA).mode, BackupSheetMode.error);
        expect(r.view(_vaultA).errorCode, 'backup_destination_unavailable');
        expect(r.calls, isEmpty, reason: 'not due: 2 h since the success');
      },
    );
  });

  // ------------------------------------------------------------------
  // AC 4-5: "Back up now" and the in-flight set
  // ------------------------------------------------------------------
  group('Back up now', () {
    test('Back up now runs exactly one backup without if changed', () async {
      final r = await _rig(
        vault: _vaultA,
        settings: {_vaultA.path: _on(keep: 12)},
        state: {(_vaultA.path, _destA): _ok(_start)},
      );
      expect(r.calls, isEmpty);
      await r.controller.backUpNow(_vaultA);
      await r.settle();
      expect(r.calls, hasLength(1));
      final call = r.calls.single;
      expect(call.vaultPath, _vaultA.path);
      expect(call.destination, _destA);
      expect(call.keep, 12);
      expect(call.ifChanged, isFalse);
      expect(r.inFlight, isEmpty);
      expect(r.view(_vaultA).mode, BackupSheetMode.success);
      // Not a permanent block: a later press runs again.
      await r.controller.backUpNow(_vaultA);
      await r.settle();
      expect(r.calls, hasLength(2));
    });

    test(
      'a double press of Back up now runs one backup and the vault is in flight until it ends',
      () async {
        final r = await _rig(
          vault: _vaultA,
          settings: {_vaultA.path: _on()},
          state: {(_vaultA.path, _destA): _ok(_start)},
        );
        final gate = r.hold();
        final first = r.controller.backUpNow(_vaultA);
        final second = r.controller.backUpNow(_vaultA);
        await r.settle();
        expect(r.calls, hasLength(1));
        expect(r.inFlight, {_vaultA.path});
        expect(r.view(_vaultA).mode, BackupSheetMode.backingUp);
        await second;
        expect(r.calls, hasLength(1), reason: 'no queued second run');
        gate.complete();
        await first;
        await r.settle();
        expect(r.calls, hasLength(1));
        expect(r.inFlight, isEmpty);
        expect(r.view(_vaultA).mode, BackupSheetMode.success);
      },
    );

    test('a tick during a manual run starts no backup', () async {
      final r = await _rig(
        vault: _vaultA,
        settings: {_vaultA.path: _on()},
        state: {
          (_vaultA.path, _destA): _ok(
            _start.subtract(const Duration(hours: 23, minutes: 30)),
          ),
        },
      );
      expect(r.calls, isEmpty);
      final gate = r.hold();
      final press = r.controller.backUpNow(_vaultA);
      await r.settle();
      expect(r.calls, hasLength(1));
      expect(r.calls.single.ifChanged, isFalse);
      await r.advance(const Duration(hours: 2));
      expect(r.calls, hasLength(1), reason: 'due, but the vault is in flight');
      gate.complete();
      await press;
      await r.settle();
      expect(r.calls, hasLength(1));
      expect(r.inFlight, isEmpty);
    });

    test('a press during an automatic run starts no backup', () async {
      final r = await _rig(settings: {_vaultA.path: _on()});
      final gate = r.hold();
      await r.open(_vaultA);
      expect(r.calls, hasLength(1), reason: 'the open check, held');
      expect(r.calls.single.ifChanged, isTrue);
      expect(r.inFlight, {_vaultA.path});
      await r.controller.backUpNow(_vaultA);
      await r.settle();
      expect(r.calls, hasLength(1), reason: 'press while automatic runs');
      gate.complete();
      await r.settle();
      expect(r.inFlight, isEmpty);
      expect(r.calls, hasLength(1));
    });

    test(
      'a failed Back up now shows the error and its recorded result raises the warning',
      () async {
        final r = await _rig(
          vault: _vaultA,
          settings: {_vaultA.path: _on(automatic: false)},
          state: {(_vaultA.path, _destA): _ok(_start)},
        );
        r.runner.scriptBackup(
          const BackupFailure(
            code: 'backup_destination_unavailable',
            message: 'cannot write to the backup folder',
          ),
        );
        r.recordOnRun = (call) => _failed(r.clock.now(), lastSuccess: _start);
        await r.controller.backUpNow(_vaultA);
        await r.settle();
        final view = r.view(_vaultA);
        expect(view.mode, BackupSheetMode.error);
        expect(view.errorCode, 'backup_destination_unavailable');
        expect(view.warning, isTrue);
        // Retry succeeds and clears both.
        r.recordOnRun = (call) => _ok(r.clock.now());
        await r.controller.backUpNow(_vaultA);
        await r.settle();
        expect(r.calls, hasLength(2));
        expect(r.view(_vaultA).mode, BackupSheetMode.success);
        expect(r.view(_vaultA).warning, isFalse);
      },
    );
  });

  // ------------------------------------------------------------------
  // AC 6, 7, 10, 11: failures and the warning
  // ------------------------------------------------------------------
  group('failures', () {
    test(
      'an automatic failure turns the warning on the next tick retries once and a success turns it off',
      () async {
        final r = await _rig(settings: {_vaultA.path: _on()});
        // The CLI records the failure (there is still no last success).
        r.recordOnRun = (call) => _failed(r.clock.now(), code: 'backup_failed');
        r.runner.scriptBackup(
          const BackupFailure(
            code: 'backup_failed',
            message: 'quick_check failed',
          ),
        );
        await r.open(_vaultA);
        expect(r.calls, hasLength(1));
        expect(r.view(_vaultA).warning, isTrue);
        expect(r.view(_vaultA).mode, BackupSheetMode.error);
        expect(r.view(_vaultA).errorCode, 'backup_failed');
        await r.advance(const Duration(minutes: 59), step: _s1 * 60);
        expect(r.calls, hasLength(1), reason: 'no retry before the tick');
        expect(r.view(_vaultA).warning, isTrue);
        r.recordOnRun = (call) => _ok(r.clock.now());
        await r.advance(const Duration(minutes: 1), step: _s1 * 60);
        expect(r.calls, hasLength(2), reason: 'exactly one retry');
        expect(r.calls.last.ifChanged, isTrue);
        expect(r.view(_vaultA).warning, isFalse);
        expect(r.view(_vaultA).mode, BackupSheetMode.success);
        await r.advance(const Duration(hours: 5));
        expect(r.calls, hasLength(2));
      },
    );

    for (final (name, result, mode) in [
      (
        'an automatic exit 2 failure turns the warning on and keeps it in memory',
        const BackupTooOld() as BackupRunResult,
        BackupSheetMode.memexTooOld,
      ),
      (
        'an automatic binary not found failure turns the warning on and keeps it in memory',
        const BackupBinaryNotFound() as BackupRunResult,
        BackupSheetMode.binaryNotFound,
      ),
      (
        'an automatic network_filesystem failure turns the warning on and keeps it in memory',
        const BackupFailure(
              code: 'network_filesystem',
              message: 'the vault is on a network drive',
            )
            as BackupRunResult,
        BackupSheetMode.error,
      ),
      (
        'an automatic internal failure before the lock turns the warning on and keeps it in memory',
        const BackupFailure(code: 'internal', message: 'manifest unreadable')
            as BackupRunResult,
        BackupSheetMode.error,
      ),
    ]) {
      test(name, () async {
        // Unrecorded: the CLI writes nothing for these.
        final r = await _rig(
          settings: {_vaultA.path: _on()},
          state: {
            (_vaultA.path, _destA): _ok(
              _start.subtract(const Duration(hours: 30)),
            ),
          },
        );
        r.recordOnRun = (_) => null;
        r.runner.scriptBackup(result);
        await r.open(_vaultA);
        expect(r.calls, hasLength(1));
        expect(r.view(_vaultA).warning, isTrue);
        expect(r.view(_vaultA).mode, mode);
        if (result is BackupFailure) {
          expect(r.view(_vaultA).errorCode, result.code);
        }
        // The state file still holds the old success; the warning stays
        // across ticks until a later success.
        r.runner.scriptBackup(result);
        await r.advance(_hour);
        expect(r.calls, hasLength(2), reason: 'still due: one retry');
        expect(r.view(_vaultA).warning, isTrue);
        // A later success (here a manual one) clears it.
        r.recordOnRun = (call) => _ok(r.clock.now());
        await r.controller.backUpNow(_vaultA);
        await r.settle();
        expect(r.calls, hasLength(3));
        expect(r.view(_vaultA).warning, isFalse);
        expect(r.view(_vaultA).mode, BackupSheetMode.success);
      });
    }

    test(
      'backup_in_progress shows no warning leaves the state untouched and the next tick runs once',
      () async {
        final r = await _rig(settings: {_vaultA.path: _on()});
        r.recordOnRun = (_) => null;
        r.runner.scriptBackup(
          const BackupFailure(
            code: 'backup_in_progress',
            message: 'a backup of this vault is already running',
          ),
        );
        await r.open(_vaultA);
        expect(r.calls, hasLength(1));
        final view = r.view(_vaultA);
        expect(view.warning, isFalse);
        expect(view.mode, BackupSheetMode.neverBackedUp);
        expect(view.errorCode, isNull);
        expect(view.status, isNull);
        expect(r.inFlight, isEmpty);
        r.recordOnRun = (call) => _ok(r.clock.now());
        await r.advance(_hour);
        expect(r.calls, hasLength(2), reason: 'the next tick decides again');
        expect(r.calls.last.ifChanged, isTrue);
        expect(r.view(_vaultA).mode, BackupSheetMode.success);
      },
    );

    test(
      'no warning shows while backups are off whatever the state file says',
      () async {
        final r = await _rig(
          vault: _vaultA,
          settings: {_vaultA.path: _on(enabled: false)},
          state: {(_vaultA.path, _destA): _failed(_start)},
        );
        expect(r.view(_vaultA).warning, isFalse);
        await r.advance(const Duration(hours: 2));
        expect(r.view(_vaultA).warning, isFalse);
        expect(r.calls, isEmpty);
        // Turned on, the same recorded error shows at the next check.
        r.setSettings(_vaultA.path, _on(automatic: false));
        await r.advance(_hour);
        expect(r.view(_vaultA).warning, isTrue);
        // Off again: no warning at once, before any tick.
        r.setSettings(_vaultA.path, _on(enabled: false, automatic: false));
        await r.settle();
        expect(r.view(_vaultA).warning, isFalse);
        expect(r.view(_vaultA).mode, BackupSheetMode.off);
      },
    );

    test(
      'an unrecorded automatic failure shows no warning once backups are turned off',
      () async {
        final r = await _rig(settings: {_vaultA.path: _on()});
        r.recordOnRun = (_) => null;
        r.runner.scriptBackup(const BackupBinaryNotFound());
        await r.open(_vaultA);
        expect(r.view(_vaultA).warning, isTrue);
        r.setSettings(_vaultA.path, _on(enabled: false));
        await r.settle();
        expect(r.view(_vaultA).warning, isFalse);
      },
    );
  });

  // ------------------------------------------------------------------
  // AC 8: lifecycle
  // ------------------------------------------------------------------
  group('lifecycle', () {
    test(
      'switching vault A to B to A during A run starts nothing and A stays in flight until it ends',
      () async {
        final r = await _rig(
          settings: {
            _vaultA.path: _on(),
            _vaultB.path: _on(destination: _destB),
          },
          state: {(_vaultB.path, _destB): _ok(_start)},
        );
        final gate = r.hold();
        await r.open(_vaultA);
        expect(r.calls, hasLength(1));
        expect(r.inFlight, {_vaultA.path});
        await r.open(_vaultB);
        expect(
          r.reader.reads.where((read) => read.vaultPath == _vaultB.path),
          isNotEmpty,
          reason: 'B opened without waiting for A',
        );
        await r.open(_vaultA);
        expect(r.calls, hasLength(1), reason: 'A is still in flight');
        expect(r.inFlight, {_vaultA.path});
        expect(r.view(_vaultA).mode, BackupSheetMode.backingUp);
        await r.controller.backUpNow(_vaultA);
        await r.settle();
        expect(r.calls, hasLength(1), reason: 'Back up now stays disabled');
        gate.complete();
        await r.settle();
        expect(r.inFlight, isEmpty);
        expect(r.calls, hasLength(1));
        expect(r.view(_vaultA).mode, BackupSheetMode.success);
      },
    );

    test(
      'a run that ends after switching vault still records its result',
      () async {
        final r = await _rig(
          settings: {
            _vaultA.path: _on(),
            _vaultB.path: _on(destination: _destB),
          },
          state: {(_vaultB.path, _destB): _ok(_start)},
        );
        final gate = r.hold();
        await r.open(_vaultA);
        await r.open(_vaultB);
        gate.complete();
        await r.settle();
        expect(r.inFlight, isEmpty);
        expect(r.calls, hasLength(1), reason: 'never cancelled or restarted');
        expect(r.view(_vaultB).mode, BackupSheetMode.success);
        await r.open(_vaultA);
        expect(r.calls, hasLength(1), reason: 'A recorded its success');
      },
    );

    test(
      'after dispose a held run completes quietly clears the in-flight set and nothing runs again',
      () async {
        final r = await _rig(settings: {_vaultA.path: _on()});
        final gate = r.hold();
        await r.open(_vaultA);
        expect(r.calls, hasLength(1));
        expect(r.inFlight, {_vaultA.path});
        r.c.dispose();
        expect(
          r.clock.pendingTimers,
          0,
          reason: 'dispose stops the hourly check',
        );
        gate.complete();
        await r.settle();
        expect(r.inFlight, isEmpty, reason: 'the in-flight set still clears');
        await r.advance(const Duration(hours: 48));
        expect(r.calls, hasLength(1), reason: 'after dispose: 0 calls');
      },
    );

    test(
      'a rebuilt controller starts nothing for a vault still in flight',
      () async {
        final r = await _rig(settings: {_vaultA.path: _on()});
        final gate = r.hold();
        await r.open(_vaultA);
        expect(r.calls, hasLength(1));
        r.c.invalidate(backupControllerProvider);
        await r.settle();
        final fresh = r.controller;
        await r.settle();
        expect(r.calls, hasLength(1), reason: 'open check: A in flight');
        await fresh.backUpNow(_vaultA);
        await r.settle();
        expect(r.calls, hasLength(1), reason: 'press: A in flight');
        expect(r.inFlight, {_vaultA.path});
        gate.complete();
        await r.settle();
        expect(r.inFlight, isEmpty);
      },
    );
  });

  // ------------------------------------------------------------------
  // AC 12-15: hosted vaults
  // ------------------------------------------------------------------
  group('hosted', () {
    test('hosted vault open reads GET once then once per hour', () async {
      final r = await _rig(vault: _hosted);
      expect(r.api.statusCalls, 1);
      expect(r.api.startCalls, 0);
      expect(r.runner.calls, isEmpty);
      expect(r.view(_hosted).hosted, isTrue);
      expect(r.view(_hosted).mode, BackupSheetMode.neverBackedUp);
      await r.advance(const Duration(minutes: 59), step: _s1 * 60);
      expect(r.api.statusCalls, 1, reason: 'no 2 s poll with the sheet shut');
      await r.advance(const Duration(minutes: 1), step: _s1 * 60);
      expect(r.api.statusCalls, 2);
      await r.advance(_hour);
      expect(r.api.statusCalls, 3);
    });

    test('an unreachable hosted GET leaves the warning as it was', () async {
      final r = await _rig(
        vault: _hosted,
        before: (h) => h.hostedApi.scriptStatus(
          _hostedStatus(result: 'backup_failed', at: _start),
        ),
      );
      expect(r.view(_hosted).warning, isTrue);
      r.api.goUnreachable();
      await r.advance(_hour);
      expect(r.api.statusCalls, 2);
      expect(r.view(_hosted).warning, isTrue, reason: 'unchanged');
      r.api.comeBack();
      r.api.defaultStatus = _hostedStatus(
        result: 'created',
        at: _start.add(_hour),
      );
      await r.advance(_hour);
      expect(r.view(_hosted).warning, isFalse);
    });

    test(
      'an unreachable hosted vault on open shows unreachable and no warning',
      () async {
        final r = await _rig(
          vault: _hosted,
          before: (h) => h.hostedApi.goUnreachable(),
        );
        expect(r.api.statusCalls, 1);
        expect(r.view(_hosted).warning, isFalse);
        expect(r.view(_hosted).mode, BackupSheetMode.hostedUnreachable);
        expect(r.view(_hosted).hosted, isTrue);
      },
    );

    test('a hosted last_result error turns the warning on', () async {
      final failed = _hostedStatus(result: 'backup_failed', at: _start);
      final r = await _rig(
        vault: _hosted,
        before: (h) => h.hostedApi.defaultStatus = failed,
      );
      expect(r.view(_hosted).warning, isTrue);
      expect(r.view(_hosted).mode, BackupSheetMode.error);
      expect(r.view(_hosted).status, failed.status);
      expect(r.view(_hosted).errorCode, 'backup_failed');
      // A later server success clears it at the next hourly read.
      r.api.defaultStatus = _hostedStatus(
        result: 'created',
        at: _start.add(_hour),
      );
      await r.advance(_hour);
      expect(r.view(_hosted).warning, isFalse);
      expect(r.view(_hosted).mode, BackupSheetMode.success);
    });

    test(
      'a hosted sheet polls GET every 2 s while in progress and stops when it ends',
      () async {
        final r = await _rig(
          vault: _hosted,
          before: (h) =>
              h.hostedApi.defaultStatus = _hostedStatus(inProgress: true),
        );
        expect(r.view(_hosted).mode, BackupSheetMode.backingUp);
        r.controller.openSheet(_hosted);
        await r.settle();
        final base = r.api.statusCalls;
        await r.advance(_s1, step: _s1);
        expect(r.api.statusCalls, base);
        await r.advance(_s1, step: _s1);
        expect(r.api.statusCalls, base + 1);
        await r.advance(_s2, step: _s1);
        expect(r.api.statusCalls, base + 2);
        r.api.defaultStatus = _hostedStatus(
          result: 'created',
          at: _start.add(_s2 * 3),
        );
        await r.advance(_s2, step: _s1);
        expect(r.api.statusCalls, base + 3, reason: 'this GET says done');
        expect(r.view(_hosted).mode, BackupSheetMode.success);
        await r.advance(const Duration(seconds: 30), step: _s1);
        expect(r.api.statusCalls, base + 3, reason: 'polling stopped');
        expect(r.api.startCalls, 0);
      },
    );

    test(
      'a hosted vault in progress with the sheet closed never polls',
      () async {
        final r = await _rig(
          vault: _hosted,
          before: (h) =>
              h.hostedApi.defaultStatus = _hostedStatus(inProgress: true),
        );
        expect(r.api.statusCalls, 1);
        expect(r.view(_hosted).mode, BackupSheetMode.backingUp);
        await r.advance(const Duration(minutes: 10), step: _s2);
        expect(r.api.statusCalls, 1, reason: 'sheet closed: no poll');
        r.controller.openSheet(_hosted);
        await r.settle();
        final base = r.api.statusCalls;
        await r.advance(_s2, step: _s1);
        expect(r.api.statusCalls, base + 1, reason: 'sheet open: polls');
        r.controller.closeSheet(_hosted);
        await r.advance(const Duration(seconds: 20), step: _s1);
        expect(r.api.statusCalls, base + 1, reason: 'sheet closed again');
      },
    );

    test('a hosted press while in progress posts nothing', () async {
      final r = await _rig(
        vault: _hosted,
        before: (h) =>
            h.hostedApi.defaultStatus = _hostedStatus(inProgress: true),
      );
      expect(r.view(_hosted).mode, BackupSheetMode.backingUp);
      r.controller.openSheet(_hosted);
      await r.settle();
      await r.controller.backUpNow(_hosted);
      await r.settle();
      expect(r.api.startCalls, 0);
      expect(r.runner.calls, isEmpty);
    });

    test(
      'a hosted Back up now posts once and a double press posts once',
      () async {
        final r = await _rig(vault: _hosted);
        r.controller.openSheet(_hosted);
        await r.settle();
        final release = r.api.holdStart();
        final first = r.controller.backUpNow(_hosted);
        final second = r.controller.backUpNow(_hosted);
        await r.settle();
        expect(r.api.startCalls, 1);
        release.complete();
        await first;
        await second;
        await r.settle();
        expect(r.api.startCalls, 1);
        expect(r.view(_hosted).mode, BackupSheetMode.backingUp);
        // 202 said in progress: the open sheet polls until it ends.
        r.api.defaultStatus = _hostedStatus(inProgress: true);
        final base = r.api.statusCalls;
        await r.advance(_s2, step: _s1);
        expect(r.api.statusCalls, base + 1);
        await r.controller.backUpNow(_hosted);
        await r.settle();
        expect(r.api.startCalls, 1, reason: 'press while it runs');
        expect(r.runner.calls, isEmpty);
      },
    );

    test(
      'a hosted POST answered 409 backup_in_progress polls with no extra POST',
      () async {
        final r = await _rig(vault: _hosted);
        r.controller.openSheet(_hosted);
        await r.settle();
        r.api.scriptStart(const HostedBackupAlreadyRunning());
        await r.controller.backUpNow(_hosted);
        await r.settle();
        expect(r.api.startCalls, 1);
        expect(r.view(_hosted).mode, BackupSheetMode.backingUp);
        expect(r.view(_hosted).hosted, isTrue);
        expect(r.view(_hosted).warning, isFalse);
        r.api.defaultStatus = _hostedStatus(inProgress: true);
        final base = r.api.statusCalls;
        await r.advance(_s2, step: _s1);
        expect(r.api.statusCalls, base + 1, reason: 'the polling state');
        await r.controller.backUpNow(_hosted);
        await r.settle();
        expect(r.api.startCalls, 1, reason: '0 extra POSTs');
        r.api.defaultStatus = _hostedStatus(result: 'created', at: _start);
        await r.advance(_s2, step: _s1);
        expect(r.view(_hosted).mode, BackupSheetMode.success);
        final done = r.api.statusCalls;
        await r.advance(const Duration(seconds: 10), step: _s1);
        expect(r.api.statusCalls, done);
        expect(r.api.startCalls, 1);
      },
    );

    test(
      'a hosted not_found shows the server too old state and no warning',
      () async {
        final r = await _rig(
          vault: _hosted,
          before: (h) =>
              h.hostedApi.defaultStatus = const HostedBackupServerTooOld(),
        );
        expect(r.api.statusCalls, 1);
        expect(r.view(_hosted).mode, BackupSheetMode.hostedServerTooOld);
        expect(r.view(_hosted).hosted, isTrue);
        expect(r.view(_hosted).warning, isFalse);
        await r.advance(_hour);
        expect(r.view(_hosted).warning, isFalse);
      },
    );

    test(
      'a hosted server without backup-dir shows not configured and no warning',
      () async {
        final r = await _rig(
          vault: _hosted,
          before: (h) =>
              h.hostedApi.defaultStatus = _hostedStatus(enabled: false),
        );
        expect(r.view(_hosted).mode, BackupSheetMode.hostedNotConfigured);
        expect(r.view(_hosted).warning, isFalse);
      },
    );
  });

  // ------------------------------------------------------------------
  // The view state's run origin, times and card (Q1)
  // ------------------------------------------------------------------
  group('view state fields', () {
    test(
      'a running local backup reports when it started and an automatic failure when it ended',
      () async {
        final r = await _rig(settings: {_vaultA.path: _on()});
        r.recordOnRun = (_) => null;
        r.runner.scriptBackup(
          const BackupFailure(code: 'internal', message: 'manifest unreadable'),
        );
        r.clock.advance(const Duration(minutes: 17));
        final gate = r.hold();
        await r.open(_vaultA);
        final running = r.view(_vaultA);
        expect(running.mode, BackupSheetMode.backingUp);
        expect(running.startedAt, _start.add(const Duration(minutes: 17)));
        expect(running.failedAt, isNull);
        expect(running.message, isNull);
        r.clock.advance(const Duration(minutes: 5));
        gate.complete();
        await r.settle();
        final failedAt = _start.add(const Duration(minutes: 22));
        final view = r.view(_vaultA);
        expect(view.mode, BackupSheetMode.error);
        expect(view.errorCode, 'internal');
        expect(view.automatic, isTrue);
        expect(view.failedAt, failedAt);
        expect(view.startedAt, isNull);
        expect(
          view.message,
          backupFailureMessage(
            code: 'internal',
            message: 'manifest unreadable',
            automatic: true,
            failedAt: failedAt,
            now: r.clock.now(),
            destination: _destA,
            provider: BackupProvider.icloud,
          ),
        );
        expect(view.message, isNotNull);
        // The failure keeps the time it happened, not the time it is read.
        r.clock.advance(const Duration(minutes: 3));
        expect(r.view(_vaultA).failedAt, failedAt);
      },
    );

    for (final (name, result, mode) in [
      (
        'a failed Back up now carries its press time and no automatic flag for a failure code',
        const BackupFailure(code: 'backup_failed', message: 'disk full')
            as BackupRunResult,
        BackupSheetMode.error,
      ),
      (
        'a failed Back up now carries its press time and no automatic flag for exit 2',
        const BackupTooOld() as BackupRunResult,
        BackupSheetMode.memexTooOld,
      ),
      (
        'a failed Back up now carries its press time and no automatic flag for a missing binary',
        const BackupBinaryNotFound() as BackupRunResult,
        BackupSheetMode.binaryNotFound,
      ),
    ]) {
      test(name, () async {
        final r = await _rig(
          vault: _vaultA,
          settings: {_vaultA.path: _on(automatic: false)},
          state: {(_vaultA.path, _destA): _ok(_start)},
        );
        r.recordOnRun = (_) => null;
        r.runner.scriptBackup(result);
        r.clock.advance(const Duration(minutes: 4));
        final gate = r.hold();
        final press = r.controller.backUpNow(_vaultA);
        await r.settle();
        expect(
          r.view(_vaultA).startedAt,
          _start.add(const Duration(minutes: 4)),
        );
        r.clock.advance(const Duration(minutes: 3));
        gate.complete();
        await press;
        await r.settle();
        final view = r.view(_vaultA);
        expect(view.mode, mode);
        expect(view.automatic, isFalse);
        expect(view.failedAt, _start.add(const Duration(minutes: 7)));
        expect(view.startedAt, isNull);
        expect(view.message, isNotNull);
        expect(
          view.warning,
          isFalse,
          reason: 'an unrecorded manual failure is not an automatic failure',
        );
        if (result is BackupFailure) {
          expect(
            view.message,
            backupFailureMessage(
              code: result.code,
              message: result.message,
              automatic: false,
              failedAt: _start.add(const Duration(minutes: 7)),
              now: r.clock.now(),
              destination: _destA,
              provider: BackupProvider.icloud,
            ),
          );
        } else if (result is BackupTooOld) {
          expect(view.message, backupTooOldMessage());
        } else {
          expect(view.message, backupBinaryNotFoundMessage());
        }
      });
    }

    test(
      'a failed Back up now after an automatic failure keeps the warning on',
      () async {
        final r = await _rig(settings: {_vaultA.path: _on()});
        r.recordOnRun = (_) => null;
        r.runner.scriptBackup(const BackupBinaryNotFound());
        await r.open(_vaultA);
        expect(r.view(_vaultA).warning, isTrue);
        expect(r.view(_vaultA).automatic, isTrue);
        r.clock.advance(const Duration(minutes: 9));
        r.runner.scriptBackup(
          const BackupFailure(code: 'internal', message: 'again'),
        );
        await r.controller.backUpNow(_vaultA);
        await r.settle();
        final view = r.view(_vaultA);
        expect(view.mode, BackupSheetMode.error);
        expect(view.automatic, isFalse, reason: 'the latest run was a press');
        expect(view.failedAt, _start.add(const Duration(minutes: 9)));
        expect(view.warning, isTrue, reason: 'still no success since');
      },
    );

    test(
      'an error recorded by a run the controller did not start is automatic and keeps its recorded time',
      () async {
        final attempt = _start.subtract(const Duration(minutes: 30));
        final r = await _rig(
          vault: _vaultA,
          settings: {_vaultA.path: _on()},
          state: {
            (_vaultA.path, _destA): _failed(
              attempt,
              lastSuccess: _start.subtract(const Duration(hours: 1)),
            ),
          },
        );
        expect(r.calls, isEmpty, reason: 'not due');
        final view = r.view(_vaultA);
        expect(view.mode, BackupSheetMode.error);
        expect(view.automatic, isTrue);
        expect(view.failedAt, attempt);
        expect(view.startedAt, isNull);
        expect(
          view.message,
          backupFailureMessage(
            code: 'backup_destination_unavailable',
            message: 'cannot write to the backup folder',
            automatic: true,
            failedAt: attempt,
            now: r.clock.now(),
            destination: _destA,
            provider: BackupProvider.icloud,
          ),
        );
        expect(view.message, isNotNull);
      },
    );

    test(
      'a recorded error without an attempt time is stamped with the time it was read',
      () async {
        final r = await _rig(
          vault: _vaultA,
          settings: {_vaultA.path: _on()},
          state: {
            (_vaultA.path, _destA): BackupStatus(
              lastSuccessAt: _start.subtract(const Duration(hours: 1)),
              lastResult: 'backup_failed',
              lastError: 'quick_check failed',
            ),
          },
        );
        r.clock.advance(const Duration(minutes: 10));
        final view = r.view(_vaultA);
        expect(view.mode, BackupSheetMode.error);
        expect(view.automatic, isTrue);
        expect(view.failedAt, _start.add(const Duration(minutes: 10)));
      },
    );

    for (final (name, destination, provider) in [
      (
        'the failure card is built for an iCloud folder with a trailing slash',
        '$_destA/',
        BackupProvider.icloud,
      ),
      (
        'the failure card is built for a Google Drive folder',
        _destB,
        BackupProvider.googleDrive,
      ),
      (
        'the failure card is built for a OneDrive folder',
        '/Users/tester/Library/CloudStorage/OneDrive-Personal/'
            'Open Memex Backups',
        BackupProvider.oneDrive,
      ),
      (
        'the failure card is built for a chosen folder with no provider',
        '/Users/tester/Backups/My Vault Copies',
        null,
      ),
      (
        'the failure card is built for a chosen folder inside a provider root with no provider',
        '/Users/tester/Library/CloudStorage/GoogleDrive-connor@example.com/'
            'My Drive/Work/Backups',
        null,
      ),
    ]) {
      test(name, () async {
        final attempt = _start.subtract(const Duration(minutes: 30));
        final r = await _rig(
          vault: _vaultA,
          settings: {_vaultA.path: _on(destination: destination)},
          state: {
            (_vaultA.path, destination): _failed(
              attempt,
              lastSuccess: _start.subtract(const Duration(hours: 1)),
            ),
          },
        );
        expect(
          r.view(_vaultA).message,
          backupFailureMessage(
            code: 'backup_destination_unavailable',
            message: 'cannot write to the backup folder',
            automatic: true,
            failedAt: attempt,
            now: r.clock.now(),
            destination: destination,
            provider: provider,
          ),
        );
        expect(r.view(_vaultA).message, isNotNull);
      });
    }

    test(
      'a Back up now answered backup_in_progress shows a manual error card until the next state read',
      () async {
        final r = await _rig(
          vault: _vaultA,
          settings: {_vaultA.path: _on(automatic: false)},
          state: {(_vaultA.path, _destA): _ok(_start)},
        );
        r.recordOnRun = (_) => null;
        r.runner.scriptBackup(
          const BackupFailure(
            code: 'backup_in_progress',
            message: 'a backup of this vault is already running',
          ),
        );
        final gate = r.hold();
        final press = r.controller.backUpNow(_vaultA);
        await r.settle();
        r.clock.advance(const Duration(minutes: 2));
        gate.complete();
        await press;
        await r.settle();
        final view = r.view(_vaultA);
        expect(view.mode, BackupSheetMode.error);
        expect(view.errorCode, 'backup_in_progress');
        expect(view.automatic, isFalse);
        expect(view.failedAt, _start.add(const Duration(minutes: 2)));
        expect(view.warning, isFalse, reason: 'never a warning');
        expect(view.status, _ok(_start), reason: 'state untouched');
        expect(
          view.message,
          backupFailureMessage(
            code: 'backup_in_progress',
            message: 'a backup of this vault is already running',
            automatic: false,
            failedAt: _start.add(const Duration(minutes: 2)),
            now: r.clock.now(),
            destination: _destA,
            provider: BackupProvider.icloud,
          ),
        );
        expect(view.message, isNotNull);
        r.controller.openSheet(_vaultA);
        await r.settle();
        expect(r.view(_vaultA).mode, BackupSheetMode.success);
        expect(r.view(_vaultA).errorCode, isNull);
      },
    );

    test(
      'a backup_in_progress card of the old destination is hidden once the destination changes',
      () async {
        final r = await _rig(
          vault: _vaultA,
          settings: {_vaultA.path: _on(automatic: false)},
        );
        r.recordOnRun = (_) => null;
        r.runner.scriptBackup(
          const BackupFailure(
            code: 'backup_in_progress',
            message: 'a backup of this vault is already running',
          ),
        );
        await r.controller.backUpNow(_vaultA);
        await r.settle();
        expect(r.view(_vaultA).errorCode, 'backup_in_progress');
        r.setSettings(_vaultA.path, _on(destination: _destB, automatic: false));
        await r.settle();
        expect(r.view(_vaultA).mode, BackupSheetMode.neverBackedUp);
        expect(r.view(_vaultA).errorCode, isNull);
      },
    );

    test(
      'a state attempt newer than an unrecorded failure replaces it and an older one does not',
      () async {
        final r = await _rig(settings: {_vaultA.path: _on()});
        r.recordOnRun = (_) => null;
        r.runner.scriptBackup(const BackupBinaryNotFound());
        await r.open(_vaultA);
        expect(r.view(_vaultA).mode, BackupSheetMode.binaryNotFound);
        // A scheduled `memex backup` that ran before the failure.
        r.reader.setEntry(
          _vaultA.path,
          _destA,
          _ok(_start.subtract(const Duration(hours: 1))),
        );
        await r.advance(_hour);
        expect(r.view(_vaultA).mode, BackupSheetMode.binaryNotFound);
        expect(r.view(_vaultA).warning, isTrue);
        // One that ran after it.
        r.reader.setEntry(
          _vaultA.path,
          _destA,
          _ok(_start.add(const Duration(minutes: 90))),
        );
        await r.advance(_hour);
        expect(r.view(_vaultA).mode, BackupSheetMode.success);
        expect(r.view(_vaultA).warning, isFalse);
      },
    );

    test(
      'changing the destination hides an unrecorded failure of the old one',
      () async {
        final r = await _rig(settings: {_vaultA.path: _on()});
        r.recordOnRun = (_) => null;
        r.runner.scriptBackup(const BackupBinaryNotFound());
        await r.open(_vaultA);
        expect(r.view(_vaultA).warning, isTrue);
        r.setSettings(_vaultA.path, _on(destination: _destB, automatic: false));
        await r.settle();
        expect(r.view(_vaultA).warning, isFalse);
        expect(r.view(_vaultA).mode, BackupSheetMode.neverBackedUp);
        // A manual failure at the new destination starts from no warning.
        r.runner.scriptBackup(
          const BackupFailure(code: 'internal', message: 'oops'),
        );
        await r.controller.backUpNow(_vaultA);
        await r.settle();
        expect(r.view(_vaultA).mode, BackupSheetMode.error);
        expect(r.view(_vaultA).warning, isFalse);
      },
    );

    test(
      'a hosted press reports its POST time and its failure as manual',
      () async {
        final r = await _rig(vault: _hosted, serverName: 'Home NAS');
        r.clock.advance(const Duration(minutes: 10));
        r.controller.openSheet(_hosted);
        await r.settle();
        final postedAt = _start.add(const Duration(minutes: 10));
        final release = r.api.holdStart();
        final press = r.controller.backUpNow(_hosted);
        await r.settle();
        expect(r.view(_hosted).mode, BackupSheetMode.backingUp);
        expect(r.view(_hosted).startedAt, postedAt, reason: 'POST pending');
        release.complete();
        await press;
        await r.settle();
        expect(r.view(_hosted).startedAt, postedAt, reason: 'answered 202');
        r.api.defaultStatus = _hostedStatus(inProgress: true);
        await r.advance(_s2, step: _s1);
        expect(r.view(_hosted).startedAt, postedAt, reason: 'polling');
        final attempt = _start.add(const Duration(minutes: 12));
        r.api.defaultStatus = _hostedStatus(
          result: 'backup_failed',
          at: attempt,
        );
        await r.advance(_s2, step: _s1);
        var view = r.view(_hosted);
        expect(view.mode, BackupSheetMode.error);
        expect(view.automatic, isFalse, reason: 'the failed run was our press');
        expect(view.failedAt, attempt);
        expect(view.startedAt, isNull);
        expect(view.warning, isTrue);
        expect(
          view.message,
          backupFailureMessage(
            code: 'backup_failed',
            message: 'disk full',
            automatic: false,
            failedAt: attempt,
            now: r.clock.now(),
            serverName: 'Home NAS',
          ),
        );
        expect(view.message, isNotNull);
        // The server's own schedule fails later: another attempt, automatic.
        final later = _start.add(const Duration(hours: 1));
        r.api.defaultStatus = _hostedStatus(result: 'backup_failed', at: later);
        await r.advance(_hour);
        view = r.view(_hosted);
        expect(view.mode, BackupSheetMode.error);
        expect(view.automatic, isTrue);
        expect(view.failedAt, later);
      },
    );

    test(
      'a hosted backup the controller did not start has no start time and its failure is automatic',
      () async {
        final r = await _rig(
          vault: _hosted,
          serverName: 'Home NAS',
          before: (h) =>
              h.hostedApi.defaultStatus = _hostedStatus(inProgress: true),
        );
        expect(r.view(_hosted).mode, BackupSheetMode.backingUp);
        expect(r.view(_hosted).startedAt, isNull, reason: 'a server run');
        final attempt = _start.add(const Duration(minutes: 20));
        r.api.defaultStatus = _hostedStatus(
          result: 'backup_failed',
          at: attempt,
        );
        await r.advance(_hour);
        final view = r.view(_hosted);
        expect(view.mode, BackupSheetMode.error);
        expect(view.automatic, isTrue);
        expect(view.failedAt, attempt);
        expect(view.startedAt, isNull);
        expect(
          view.message,
          backupFailureMessage(
            code: 'backup_failed',
            message: 'disk full',
            automatic: true,
            failedAt: attempt,
            now: r.clock.now(),
            serverName: 'Home NAS',
          ),
        );
        expect(view.message, isNotNull);
      },
    );

    test(
      'a hosted error without an attempt time is automatic and stamped with the time it was read',
      () async {
        final r = await _rig(
          vault: _hosted,
          before: (h) => h.hostedApi.defaultStatus = _hostedStatus(
            result: 'backup_failed',
          ),
        );
        r.clock.advance(const Duration(minutes: 10));
        final view = r.view(_hosted);
        expect(view.mode, BackupSheetMode.error);
        expect(view.automatic, isTrue);
        expect(view.failedAt, _start.add(const Duration(minutes: 10)));
      },
    );

    test(
      'a runner that throws is an automatic internal failure and frees the vault',
      () async {
        final r = await _rig(settings: {_vaultA.path: _on()});
        r.runner.onCall = (_) => throw StateError('spawn failed');
        await r.open(_vaultA);
        expect(r.calls, hasLength(1));
        expect(r.inFlight, isEmpty);
        final view = r.view(_vaultA);
        expect(view.mode, BackupSheetMode.error);
        expect(view.errorCode, 'internal');
        expect(view.automatic, isTrue);
        expect(view.warning, isTrue);
        expect(view.failedAt, _start);
        expect(view.message, isNotNull);
        await r.controller.backUpNow(_vaultA);
        await r.settle();
        expect(r.calls, hasLength(2), reason: 'the vault is not stuck');
      },
    );

    test(
      'a hosted POST that cannot reach the server leaves the state as it was and a later press posts again',
      () async {
        final r = await _rig(vault: _hosted);
        r.api.goUnreachable();
        await r.controller.backUpNow(_hosted);
        await r.settle();
        expect(r.api.startCalls, 1);
        expect(r.view(_hosted).mode, BackupSheetMode.neverBackedUp);
        expect(r.view(_hosted).startedAt, isNull);
        expect(r.view(_hosted).warning, isFalse);
        r.api.comeBack();
        await r.controller.backUpNow(_hosted);
        await r.settle();
        expect(r.api.startCalls, 2, reason: 'the first press is not pending');
      },
    );

    test(
      'a hosted POST answered 409 backup_in_progress has no start time',
      () async {
        final r = await _rig(vault: _hosted);
        r.controller.openSheet(_hosted);
        await r.settle();
        r.api.scriptStart(const HostedBackupAlreadyRunning());
        await r.controller.backUpNow(_hosted);
        await r.settle();
        expect(r.view(_hosted).mode, BackupSheetMode.backingUp);
        expect(r.view(_hosted).startedAt, isNull);
      },
    );
  });

  // ------------------------------------------------------------------
  // Hygiene (not AC-mapped: guards that hold on main too)
  // ------------------------------------------------------------------
  group('hygiene', () {
    test('backup controller never reads wall time or makes a Timer', () {
      final source = File(
        'lib/src/state/backup_controller.dart',
      ).readAsStringSync();
      expect(source.contains('DateTime.now('), isFalse);
      expect(RegExp(r'\bTimer(\.periodic)?\(').hasMatch(source), isFalse);
    });

    test('workspace.dart never watches the backup controller', () {
      final source = File('lib/src/screens/workspace.dart').readAsStringSync();
      expect(source.contains('backupControllerProvider'), isFalse);
    });
  });
}
