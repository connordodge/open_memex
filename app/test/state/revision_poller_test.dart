// WI #79 (W7, D15): the vault-wide revision poller that replaces the per-note
// NotePoller of WI #28. It reads the open vault's revision through the
// revision-reader seam (`revisionReaderProvider`) on `clockProvider` timers:
// every 2 s while the window is focused, every 30 s while unfocused, once at
// start (the baseline, no bump) and once on regaining focus. A changed
// revision bumps `vaultRevisionProvider` and hands the active stored note to
// `EditorController.serverChanged`; D16: no echo suppression. Errors (D17,
// lead ruling): `unauthorized` stops polling until the open vault server's
// `hostedConnectionStatusProvider` returns to connected, `vault_not_found`
// stops it for good, anything else keeps polling.
//
// Seams: FakeClock / RecordingClock (no real timers), FakeAppFocus (the
// app-focus seam; the real one is driven by
// `tester.binding.handleAppLifecycleStateChanged`), ScriptedRevisionReader
// (counting, Completer-gated or throwing), fakeRevisionReader over a
// FakeVaultDb, pumpWorkspace / pumpLiveWorkspace.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/conflict_merge.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/state/app_focus.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/revision_poller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_client.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_server.dart';
import '../support/fake_vault_db.dart';
import '../support/poll_fakes.dart';
import '../support/vault_folders.dart';

const _vaultA = LocalVaultRef('/tmp/om-79-vault-a');
const _vaultB = LocalVaultRef('/tmp/om-79-vault-b');
const _serverId = 'srv-79';
const _hosted = HostedVaultRef(_serverId, 'work');

const _s1 = Duration(milliseconds: 1);
const _s2 = Duration(seconds: 2);
const _s30 = Duration(seconds: 30);

/// The largest single [FakeClock] step [_Wi79Env.advance] takes.
const _step = Duration(seconds: 1);

/// A [FakeClock] whose `now()` can be skewed from its timers' time: a wall
/// clock that jumps (NTP, a manual change) while timers keep their pace.
class _Wi79SkewedClock extends FakeClock {
  _Wi79SkewedClock() : super(DateTime(2026, 10, 20, 9));

  Duration skew = Duration.zero;

  @override
  DateTime now() => super.now().add(skew);
}

/// A poller running in a plain [ProviderContainer] on [clock], the
/// [FakeAppFocus] seam and one [ScriptedRevisionReader] per vault (made on
/// first use, answering `rev-0`).
class _Wi79Env {
  _Wi79Env(this.c, this.clock, this.readers);

  final ProviderContainer c;
  final FakeClock clock;
  final Map<VaultRef, ScriptedRevisionReader> readers;

  ScriptedRevisionReader readerFor(VaultRef vault) =>
      readers.putIfAbsent(vault, ScriptedRevisionReader.new);

  int get revision => c.read(vaultRevisionProvider);
  FakeAppFocus get focus => c.read(appFocusProvider.notifier) as FakeAppFocus;

  Future<void> settle() => pumpEventQueue();

  /// Moves the [FakeClock] by [by] in steps of at most 1 s, draining the
  /// event queue after each step. A real read completes between two ticks;
  /// one synchronous jump over several intervals would fire every tick while
  /// the first read is still pending, and AC5 (one read in flight) rightly
  /// skips those.
  Future<void> advance(Duration by) async {
    var left = by;
    while (left > Duration.zero) {
      final step = left < _step ? left : _step;
      clock.advance(step);
      left -= step;
      await pumpEventQueue();
    }
  }

  Future<void> setFocused(bool focused) async {
    focus.set(focused);
    await pumpEventQueue();
  }

  Future<void> setStatus(String serverId, HostedConnectionStatus status) async {
    c.read(hostedConnectionStatusProvider(serverId).notifier).state = status;
    await pumpEventQueue();
  }

  Future<void> switchTo(VaultRef? vault) async {
    c.read(currentVaultProvider.notifier).state = vault;
    await pumpEventQueue();
  }
}

/// Starts the poller on [vault] (its reader is [reader], else a fresh
/// [ScriptedRevisionReader]) and lets the start read land.
Future<_Wi79Env> _start({
  VaultRef vault = _vaultA,
  ScriptedRevisionReader? reader,
  bool focused = true,
  FakeClock? clock,
}) async {
  final readers = <VaultRef, ScriptedRevisionReader>{vault: ?reader};
  final fakeClock = clock ?? FakeClock(DateTime(2026, 10, 20, 9));
  final c = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(fakeClock),
      appFocusProvider.overrideWith(() => FakeAppFocus(focused)),
      currentVaultProvider.overrideWith((_) => vault),
      vaultDbProvider.overrideWithValue(null),
      memexCliProvider.overrideWithValue(null),
      revisionReaderProvider.overrideWith((ref) {
        final open = ref.watch(currentVaultProvider);
        if (open == null) return null;
        return readers.putIfAbsent(open, ScriptedRevisionReader.new).read;
      }),
    ],
  );
  addTearDown(c.dispose);
  final env = _Wi79Env(c, fakeClock, readers);
  c.listen<void>(revisionPollerProvider, (_, _) {});
  await pumpEventQueue();
  return env;
}

/// An agent append to today's daily note, as the server makes it.
void _agentAppend(LiveRobot r, String text, String blockId) =>
    r.db.serverAppend(liveDailyId, text, blockId: blockId, at: r.clock.now());

const _person = 'Morning pages\n';
const _agentText = 'Agent saw the jump arc bug.';
const _topicId = 'topic-79-loop';

Future<(LiveRobot, PollReadCounter)> _launchLive(WidgetTester tester) async {
  final db = FakeVaultDb.v5()
    ..seedLiveDaily()
    ..seedNote(
      id: _topicId,
      title: 'Player Loop',
      role: 'topic',
      content: 'Loop notes\n',
    );
  final clock = FakeClock(DateTime(2026, 10, 3, 9));
  final cli = FakeMemexCli()..onUpdateServer(db, clock: clock);
  final counter = PollReadCounter();
  final r = await pumpLiveWorkspace(
    tester,
    db: db,
    cli: cli,
    clock: clock,
    reads: counter,
  );
  return (r, counter);
}

void main() {
  group('focused interval (AC1)', () {
    test(
      'the poller reads the open vault revision as soon as it starts',
      () async {
        final env = await _start();

        expect(env.readerFor(_vaultA).reads, 1);
      },
    );

    test(
      'while focused the poller reads the revision every 2 s and never more often',
      () async {
        final env = await _start();
        final reader = env.readerFor(_vaultA);
        final base = reader.reads;

        await env.advance(_s2 - _s1);
        expect(reader.reads, base);
        await env.advance(_s1);
        expect(reader.reads, base + 1);

        for (var i = 0; i < 20; i++) {
          await env.advance(const Duration(milliseconds: 500));
        }
        expect(reader.reads, base + 6);

        await env.advance(const Duration(seconds: 10));
        expect(reader.reads, base + 11);
      },
    );

    test(
      'a wall clock jump backward or forward leaves the 2 s cadence unchanged',
      () async {
        final clock = _Wi79SkewedClock();
        final env = await _start(clock: clock);
        final reader = env.readerFor(_vaultA);
        await env.advance(_s2);
        final base = reader.reads;

        clock.skew = const Duration(hours: -1);
        await env.advance(_s2);
        expect(reader.reads, base + 1);
        await env.advance(const Duration(seconds: 10));
        expect(reader.reads, base + 6);

        clock.skew = const Duration(hours: 3);
        await env.advance(_s2 - _s1);
        expect(reader.reads, base + 6, reason: 'no catch-up burst');
        await env.advance(_s1);
        expect(reader.reads, base + 7);
      },
    );
  });

  group('unfocused interval and refocus (AC2)', () {
    test('while unfocused the poller reads the revision every 30 s', () async {
      final env = await _start();
      final reader = env.readerFor(_vaultA);
      await env.advance(_s2);
      await env.setFocused(false);
      final base = reader.reads;

      await env.advance(_s30 - _s1);
      expect(reader.reads, base);
      await env.advance(_s1);
      expect(reader.reads, base + 1);
      await env.advance(_s30);
      expect(reader.reads, base + 2);
      await env.advance(const Duration(seconds: 60));
      expect(reader.reads, base + 4);
    });

    test(
      'regaining focus reads once immediately and then every 2 s again',
      () async {
        final env = await _start();
        final reader = env.readerFor(_vaultA);
        await env.advance(_s2);
        await env.setFocused(false);
        await env.advance(const Duration(seconds: 7));
        final base = reader.reads;

        await env.setFocused(true);
        expect(reader.reads, base + 1);

        await env.advance(_s2 - _s1);
        expect(reader.reads, base + 1);
        await env.advance(_s1);
        expect(reader.reads, base + 2);
        await env.advance(const Duration(seconds: 6));
        expect(reader.reads, base + 5);
      },
    );

    test(
      'a poller started while unfocused reads every 30 s until focus returns',
      () async {
        final env = await _start(focused: false);
        final reader = env.readerFor(_vaultA);
        final base = reader.reads;

        await env.advance(_s30 - _s1);
        expect(reader.reads, base);
        await env.advance(_s1);
        expect(reader.reads, base + 1);

        await env.setFocused(true);
        expect(reader.reads, base + 2);
        await env.advance(_s2);
        expect(reader.reads, base + 3);
      },
    );

    test(
      'regaining focus while a revision read is pending starts no second read',
      () async {
        final env = await _start();
        final reader = env.readerFor(_vaultA);
        await env.advance(_s2);
        await env.setFocused(false);
        reader.gated = true;
        await env.advance(_s30);
        expect(reader.pending, 1);
        final base = reader.reads;

        await env.setFocused(true);
        expect(reader.reads, base, reason: 'one read in flight at a time');

        reader
          ..gated = false
          ..release();
        await env.settle();
        await env.advance(_s2);
        expect(reader.reads, base + 1);
      },
    );
  });

  group('the app-focus seam (AC3)', () {
    testWidgets(
      'the app focus seam reports focused on resumed and unfocused on inactive',
      (tester) async {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        final seen = <bool>[];
        c.listen<bool>(appFocusProvider, (_, next) => seen.add(next));

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        expect(c.read(appFocusProvider), isFalse);

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        expect(c.read(appFocusProvider), isTrue);
        expect(seen, [false, true]);
      },
    );

    testWidgets(
      'the app focus seam reports focused before any lifecycle state is known',
      (tester) async {
        expect(tester.binding.lifecycleState, isNull);
        final c = ProviderContainer();
        addTearDown(c.dispose);

        expect(c.read(appFocusProvider), isTrue);
      },
    );

    testWidgets(
      'the app focus seam starts unfocused when the window is already inactive',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        final c = ProviderContainer();
        addTearDown(c.dispose);

        expect(c.read(appFocusProvider), isFalse);

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        expect(c.read(appFocusProvider), isTrue);
      },
    );

    testWidgets(
      'the app focus seam stays unfocused from inactive to hidden and back until resumed',
      (tester) async {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        c.listen<bool>(appFocusProvider, (_, _) {});

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        expect(c.read(appFocusProvider), isFalse);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        expect(c.read(appFocusProvider), isFalse);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        expect(c.read(appFocusProvider), isTrue);
      },
    );

    testWidgets(
      'the app focus seam stops listening once its container is disposed',
      (tester) async {
        final c = ProviderContainer();
        expect(c.read(appFocusProvider), isTrue);
        c.dispose();

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'losing window focus slows the workspace poll to 30 s and regaining it polls at once',
      (tester) async {
        final (r, counter) = await _launchLive(tester);
        await r.poll();

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await r.settle();
        final base = counter.reads;
        _agentAppend(r, _agentText, 'a-79-1');

        await r.advance(_s30 - _s1);
        expect(counter.reads, base);
        expect(r.bodyText, _person);
        await r.advance(_s1);
        expect(counter.reads, base + 1);
        expect(r.bodyText, appendToPerson(_person, _agentText));

        _agentAppend(r, 'Second capture.', 'a-79-2');
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await r.settle();
        expect(counter.reads, base + 2);
        expect(
          r.bodyText,
          appendToPerson(
            appendToPerson(_person, _agentText),
            'Second capture.',
          ),
        );
      },
    );
  });

  group('the baseline read (AC4)', () {
    for (final (name, value) in [
      (
        'the first revision read after the poller starts bumps nothing whatever its value',
        'rev-0',
      ),
      ('a first revision read of an empty string bumps nothing', ''),
      (
        'a first revision read of a handle-prefixed revision bumps nothing',
        '7-1234',
      ),
    ]) {
      test(name, () async {
        final env = await _start(reader: ScriptedRevisionReader(value));
        expect(env.readerFor(_vaultA).reads, 1);
        expect(env.revision, 0);

        await env.advance(const Duration(seconds: 10));
        expect(env.revision, 0);
      });
    }

    test(
      'when the first read fails the next successful read is the baseline',
      () async {
        final reader = ScriptedRevisionReader('a')
          ..error = const VaultUnreachableException(
            serverName: 'nas',
            mayHaveCommitted: false,
          );
        final env = await _start(reader: reader);
        expect(reader.reads, 1);

        reader.error = null;
        await env.advance(_s2);
        expect(reader.reads, 2);
        expect(env.revision, 0);

        reader.revision = 'b';
        await env.advance(_s2);
        expect(env.revision, 1);
      },
    );
  });

  group('one read in flight (AC5)', () {
    test(
      'while a revision read is pending further ticks start no new read',
      () async {
        final reader = ScriptedRevisionReader('a')..gated = true;
        final env = await _start(reader: reader);
        expect(reader.reads, 1);
        expect(reader.pending, 1);

        await env.advance(const Duration(seconds: 10));
        expect(reader.reads, 1);

        reader.release();
        await env.settle();
        expect(env.revision, 0, reason: 'the released read is the baseline');
        await env.advance(_s2);
        expect(reader.reads, 2);
      },
    );

    test(
      'changes seen while a read is pending coalesce into one revision bump',
      () async {
        final reader = ScriptedRevisionReader('a');
        final env = await _start(reader: reader);
        await env.advance(_s2);
        reader.gated = true;
        await env.advance(_s2);
        expect(reader.pending, 1);
        final reads = reader.reads;

        // Two more writes land on the server while the read is pending.
        await env.advance(const Duration(seconds: 6));
        expect(reader.reads, reads);
        reader.release('c');
        await env.settle();
        expect(env.revision, 1);

        reader
          ..gated = false
          ..revision = 'c';
        await env.advance(_s2);
        expect(reader.reads, reads + 1);
        expect(env.revision, 1);
      },
    );

    test(
      'a pending read that fails frees the poller for the next tick with no bump',
      () async {
        final reader = ScriptedRevisionReader('a');
        final env = await _start(reader: reader);
        reader.gated = true;
        await env.advance(_s2);
        expect(reader.pending, 1);
        final reads = reader.reads;

        reader.fail(StateError('socket closed'));
        await env.settle();
        expect(env.revision, 0);

        reader
          ..gated = false
          ..revision = 'b';
        await env.advance(_s2);
        expect(reader.reads, reads + 1);
        expect(env.revision, 1);
      },
    );
  });

  group('a changed revision (AC6)', () {
    test(
      'a changed revision after the baseline bumps the vault revision exactly once',
      () async {
        final reader = ScriptedRevisionReader('a');
        final env = await _start(reader: reader);

        reader.revision = 'b';
        await env.advance(_s2);
        expect(env.revision, 1);

        await env.advance(const Duration(seconds: 10));
        expect(env.revision, 1);
      },
    );

    test('an unchanged revision bumps nothing', () async {
      final reader = ScriptedRevisionReader('a');
      final env = await _start(reader: reader);

      await env.advance(const Duration(seconds: 20));

      expect(reader.reads, 11);
      expect(env.revision, 0);
    });

    test(
      'a revision that changes back to an earlier value bumps again',
      () async {
        final reader = ScriptedRevisionReader('a');
        final env = await _start(reader: reader);

        reader.revision = 'b';
        await env.advance(_s2);
        reader.revision = 'a';
        await env.advance(_s2);

        expect(env.revision, 2);
      },
    );

    testWidgets(
      'a changed revision hands the open clean daily note to the editor on the next revision read',
      (tester) async {
        final (r, counter) = await _launchLive(tester);
        final base = counter.reads;
        final revision = r.revision;
        _agentAppend(r, _agentText, 'a-79-1');

        await r.poll();

        expect(counter.reads, base + 1);
        expect(r.revision, revision + 1);
        expect(r.bodyText, appendToPerson(_person, _agentText));
        expect(r.editor.status, SaveStatus.clean);
        expect(r.updates, isEmpty);
      },
    );

    testWidgets(
      'with the virtual Today tab active a changed revision bumps once and changes nothing in the editor',
      (tester) async {
        final db = FakeVaultDb.v5();
        final counter = PollReadCounter();
        final h = await pumpWorkspace(
          tester,
          db: db,
          overrides: [
            revisionReaderProvider.overrideWithValue(
              fakeRevisionReader(db, counter),
            ),
          ],
        );
        expect(h.read(activeTabProvider), isA<VirtualTodayTab>());
        final revision = h.read(vaultRevisionProvider);
        final calls = h.cli.calls.length;

        db.seedNote(id: 'n-79-elsewhere', title: 'Written elsewhere');
        h.clock.advance(_s2);
        await pumpFrames(tester);

        expect(counter.reads, greaterThan(0));
        expect(h.read(vaultRevisionProvider), revision + 1);
        expect(h.read(editorControllerProvider).contentMd, '');
        expect(h.read(activeTabProvider), isA<VirtualTodayTab>());
        expect(h.cli.calls, hasLength(calls), reason: 'nothing was written');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'after a local save the next poll still bumps the revision and keeps the typed text and caret',
      (tester) async {
        final (r, counter) = await _launchLive(tester);
        const typed = '${_person}Then lunch.\n';
        await r.type(typed);
        await r.placeCaret(3);
        await r.fireDebounce();
        expect(r.updates, hasLength(1));
        expect(r.editor.status, SaveStatus.clean);
        final revision = r.revision;
        final selection = r.bodySelection;
        final base = counter.reads;

        // D16: no echo suppression. The own save moved the vault revision.
        await r.poll();

        expect(counter.reads, base + 1);
        expect(r.revision, revision + 1);
        expect(r.bodyText, typed);
        expect(r.bodySelection, selection);
        expect(r.updates, hasLength(1));
        expect(r.editor.status, SaveStatus.clean);

        _agentAppend(r, _agentText, 'a-79-1');
        await r.poll();
        expect(r.revision, revision + 2);
        expect(r.bodyText, appendToPerson(typed, _agentText));
        expect(r.updates, hasLength(1));
      },
    );
  });

  group('appends reach the editor (AC7)', () {
    testWidgets(
      'an append made elsewhere reaches the clean daily note on the next revision read and a dirty editor keeps its typed text',
      (tester) async {
        final (r, counter) = await _launchLive(tester);
        final base = counter.reads;

        r.db.serverAppend(
          liveDailyId,
          'Buy milk.',
          blockId: 'q-79-milk',
          source: 'quick-entry',
          at: r.clock.now(),
        );
        await r.poll();
        expect(counter.reads, base + 1);
        final clean = appendToPerson(_person, 'Buy milk.');
        expect(r.bodyText, clean);
        expect(r.updates, isEmpty);

        // Unsaved edits: the save never answers, so the editor stays dirty.
        r.h.cli.on('update', (_) => Completer<MemexResult>().future);
        final typed = '${clean}Typed here.\n';
        await r.type(typed);
        _agentAppend(r, _agentText, 'a-79-2');
        await r.poll();

        expect(counter.reads, base + 2);
        expect(r.bodyText, typed);
      },
    );
  });

  group('the Days list (AC8)', () {
    testWidgets(
      'a daily note created elsewhere appears in the Days list after the next poll while a canvas tab is active',
      (tester) async {
        final db = FakeVaultDb.v5();
        db.db.execute(
          'INSERT INTO canvases (id, title, created_at, updated_at, version) '
          "VALUES ('c-79', 'Board', 1759500000000, 1759500000000, 1)",
        );
        final counter = PollReadCounter();
        final h = await pumpWorkspace(
          tester,
          db: db,
          overrides: [
            revisionReaderProvider.overrideWithValue(
              fakeRevisionReader(db, counter),
            ),
          ],
        );
        h.container
            .read(tabsProvider.notifier)
            .openOrFocus(const CanvasTab('c-79'));
        await pumpFrames(tester);
        expect(h.read(activeTabProvider), const CanvasTab('c-79'));
        const row = Key('days-row-2026-10-01');
        expect(find.byKey(row), findsNothing);

        db.seedDailyNote('2026-10-01');
        h.clock.advance(_s2 - _s1);
        await pumpFrames(tester);
        expect(find.byKey(row), findsNothing);

        h.clock.advance(_s1);
        await pumpFrames(tester);
        expect(find.byKey(row), findsOneWidget);
        expect(counter.reads, greaterThan(0));
        expect(h.read(activeTabProvider), const CanvasTab('c-79'));
      },
    );
  });

  group('a real SQLite vault (AC9)', () {
    test(
      'a write from a second connection to a real temp SQLite vault is noticed through the local VaultAccess revision',
      () async {
        final dir = createVaultFolder('om79_vault_');
        final clock = FakeClock(DateTime(2026, 10, 20, 9));
        final c = ProviderContainer(
          overrides: [
            clockProvider.overrideWithValue(clock),
            appFocusProvider.overrideWith(() => FakeAppFocus()),
            currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
            memexCliProvider.overrideWithValue(null),
          ],
        );
        addTearDown(c.dispose);
        c.listen<void>(revisionPollerProvider, (_, _) {});
        await pumpEventQueue();
        expect(c.read(revisionReaderProvider), isNotNull);
        final handle = c.read(vaultDbProvider)!;
        final before = c.read(vaultRevisionProvider);

        clock.advance(_s2);
        await pumpEventQueue();
        expect(c.read(vaultRevisionProvider), before, reason: 'no write yet');

        final writer = sqlite3.open(p.join(dir.path, 'memex.db'));
        addTearDown(writer.dispose);
        writer.execute(
          'INSERT INTO notes (id, title, content_md, frontmatter, version, '
          'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
          [
            'n-79',
            'From the CLI',
            'body',
            '{}',
            1,
            1759500000000,
            1759500000000,
          ],
        );

        clock.advance(_s2);
        await pumpEventQueue();
        expect(c.read(vaultRevisionProvider), before + 1);
        // Each poll is an autocommit read: no read transaction stays open.
        expect(handle.db.autocommit, isTrue);

        clock.advance(const Duration(seconds: 6));
        await pumpEventQueue();
        expect(c.read(vaultRevisionProvider), before + 1);
      },
    );

    test(
      'with no open vault the revision reader is null and the poller holds no timer',
      () async {
        final clock = FakeClock(DateTime(2026, 10, 20, 9));
        final c = ProviderContainer(
          overrides: [
            clockProvider.overrideWithValue(clock),
            appFocusProvider.overrideWith(() => FakeAppFocus()),
            currentVaultProvider.overrideWith((_) => null),
            vaultDbProvider.overrideWithValue(null),
            memexCliProvider.overrideWithValue(null),
          ],
        );
        addTearDown(c.dispose);

        expect(c.read(revisionReaderProvider), isNull);
        c.listen<void>(revisionPollerProvider, (_, _) {});
        await pumpEventQueue();
        clock.advance(const Duration(seconds: 10));
        await pumpEventQueue();

        expect(clock.pendingTimers, 0);
        expect(c.read(vaultRevisionProvider), 0);
      },
    );
  });

  group('unauthorized stops polling (AC10)', () {
    MemexException unauthorized() =>
        MemexException('revision failed: token rejected', code: 'unauthorized');

    test(
      'a revision read that fails with unauthorized stops polling until the server returns to connected',
      () async {
        final reader = ScriptedRevisionReader('a');
        final env = await _start(vault: _hosted, reader: reader);
        reader.error = unauthorized();
        await env.advance(_s2);
        final stopped = reader.reads;
        // HostedClient's 401 hook marks the server (#77).
        await env.setStatus(_serverId, HostedConnectionStatus.tokenRejected);
        reader.error = null;

        await env.advance(const Duration(seconds: 20));
        expect(reader.reads, stopped);
        await env.setFocused(false);
        await env.setFocused(true);
        expect(reader.reads, stopped, reason: 'refocus does not restart it');

        await env.setStatus(_serverId, HostedConnectionStatus.connected);
        final resumed = reader.reads;
        expect(resumed - stopped, lessThanOrEqualTo(1));
        for (var i = 1; i <= 3; i++) {
          await env.advance(_s2);
          expect(reader.reads, resumed + i);
        }
        expect(env.revision, 0, reason: 'the revision did not change');
      },
    );

    test(
      'after an unauthorized stop only the open vault server returning to connected resumes polling',
      () async {
        final reader = ScriptedRevisionReader('a');
        final env = await _start(vault: _hosted, reader: reader);
        reader.error = unauthorized();
        await env.advance(_s2);
        await env.setStatus(_serverId, HostedConnectionStatus.tokenRejected);
        reader.error = null;
        final stopped = reader.reads;

        await env.setStatus('srv-other', HostedConnectionStatus.connected);
        await env.advance(const Duration(seconds: 10));
        expect(reader.reads, stopped);

        await env.setStatus(_serverId, HostedConnectionStatus.unreachable);
        await env.advance(const Duration(seconds: 10));
        expect(reader.reads, stopped);

        await env.setStatus(_serverId, HostedConnectionStatus.connected);
        await env.advance(_s2);
        expect(reader.reads, greaterThan(stopped));
      },
    );

    test(
      'polling resumed after unauthorized runs at the unfocused interval while the window is unfocused',
      () async {
        final reader = ScriptedRevisionReader('a');
        final env = await _start(vault: _hosted, reader: reader);
        reader.error = unauthorized();
        await env.advance(_s2);
        await env.setStatus(_serverId, HostedConnectionStatus.tokenRejected);
        reader.error = null;
        await env.setFocused(false);

        await env.setStatus(_serverId, HostedConnectionStatus.connected);
        final resumed = reader.reads;
        await env.advance(_s30);
        expect(reader.reads, resumed + 1);
        await env.advance(_s30 - _s1);
        expect(reader.reads, resumed + 1);
        await env.advance(_s1);
        expect(reader.reads, resumed + 2);
      },
    );

    test(
      'a revision change made while polling was stopped bumps once when polling resumes',
      () async {
        final reader = ScriptedRevisionReader('a');
        final env = await _start(vault: _hosted, reader: reader);
        reader.error = unauthorized();
        await env.advance(_s2);
        await env.setStatus(_serverId, HostedConnectionStatus.tokenRejected);
        reader
          ..error = null
          ..revision = 'b';

        await env.setStatus(_serverId, HostedConnectionStatus.connected);
        await env.advance(const Duration(seconds: 6));

        expect(env.revision, 1);
      },
    );
  });

  group('unauthorized with the real hosted client (AC10)', () {
    test(
      'with the real hosted client a 401 leaves the server token rejected and a later connected probe resumes polling',
      () async {
        const vault = HostedVaultRef(fakeServerId, 'work');
        const revisionPath = '/vaults/work/api/v1/revision';
        final server = FakeVaultServer()
          ..route('GET', revisionPath, json: {'revision': 'r1'})
          ..route(
            'GET',
            '/api/v1/info',
            json: {'server_version': '0.1.0', 'api_version': kApiVersion},
          );
        final clock = FakeClock(DateTime(2026, 10, 20, 9));
        late final HostedClient client;
        final c = ProviderContainer(
          overrides: [
            clockProvider.overrideWithValue(clock),
            appFocusProvider.overrideWith(() => FakeAppFocus()),
            currentVaultProvider.overrideWith((_) => vault),
            vaultDbProvider.overrideWithValue(null),
            memexCliProvider.overrideWithValue(null),
            revisionReaderProvider.overrideWith(
              (_) => () async {
                final body = await client.vaultRequest(
                  'GET',
                  'work',
                  '/revision',
                  operation: 'revision',
                );
                return body['revision']! as String;
              },
            ),
          ],
        );
        addTearDown(c.dispose);
        client = server.connect(c);
        HostedConnectionStatus? status() =>
            c.read(hostedConnectionStatusProvider(fakeServerId));
        int revisionReads() =>
            server.requests.where((r) => r.url.path == revisionPath).length;
        Future<void> advance(Duration by) async {
          for (var left = by; left > Duration.zero; left -= _step) {
            clock.advance(left < _step ? left : _step);
            await pumpEventQueue();
          }
        }

        c.listen<void>(revisionPollerProvider, (_, _) {});
        await pumpEventQueue();
        await advance(_s2);
        expect(revisionReads(), 2);
        expect(status(), HostedConnectionStatus.connected);

        // The token is rotated on the server: the next read gets a 401.
        server.token = 'rotated-on-the-server';
        await advance(_s2);
        expect(revisionReads(), 3);
        expect(
          status(),
          HostedConnectionStatus.tokenRejected,
          reason:
              'the 401 hook marks the server before the poller stops, so a '
              'later connected is a change the poller hears',
        );
        await advance(const Duration(seconds: 20));
        expect(revisionReads(), 3, reason: 'polling stopped');

        // The token is updated and the re-probe (#98) connects.
        server
          ..token = fakeServerToken
          ..route('GET', revisionPath, json: {'revision': 'r2'});
        final probe = await client.probeServer();
        await pumpEventQueue();
        expect(probe.kind, ServerProbeKind.connected);
        expect(status(), HostedConnectionStatus.connected);
        expect(revisionReads(), 4, reason: 'one immediate read on resume');
        expect(c.read(vaultRevisionProvider), 1);
        await advance(_s2);
        expect(revisionReads(), 5);
        expect(c.read(vaultRevisionProvider), 1);
      },
    );
  });

  group('vault_not_found stops polling (AC11)', () {
    test(
      'a revision read that fails with vault_not_found stops polling and nothing restarts it',
      () async {
        final reader = ScriptedRevisionReader('a');
        final env = await _start(vault: _hosted, reader: reader);
        reader.error = MemexException(
          'revision failed: no vault named work',
          code: 'vault_not_found',
        );
        await env.advance(_s2);
        final stopped = reader.reads;
        expect(stopped, 2, reason: 'the start read and the failing read');
        reader
          ..error = null
          ..revision = 'b';

        await env.advance(const Duration(seconds: 60));
        await env.setFocused(false);
        await env.setFocused(true);
        await env.setStatus(_serverId, HostedConnectionStatus.tokenRejected);
        await env.setStatus(_serverId, HostedConnectionStatus.connected);
        await env.advance(const Duration(seconds: 60));

        expect(reader.reads, stopped);
        expect(env.revision, 0);
      },
    );
  });

  group('other errors keep polling (AC12)', () {
    for (final (name, error, sync) in <(String, Object, bool)>[
      (
        'a revision read that throws VaultUnreachableException keeps polling at the current interval with no bump',
        const VaultUnreachableException(
          serverName: 'nas',
          mayHaveCommitted: false,
        ),
        false,
      ),
      (
        'a revision read that throws a MemexException with another code keeps polling with no bump',
        MemexException('revision failed: boom', code: 'internal_error'),
        false,
      ),
      (
        'a revision read that throws a MemexException with no code keeps polling with no bump',
        MemexException('revision failed'),
        false,
      ),
      (
        'a revision read that throws a FormatException keeps polling with no bump',
        const FormatException('not a revision'),
        false,
      ),
      (
        'a revision read that throws a StateError keeps polling with no bump',
        StateError('closed'),
        false,
      ),
      (
        'a revision reader that throws synchronously keeps polling with no bump',
        const VaultUnreachableException(
          serverName: 'nas',
          mayHaveCommitted: true,
        ),
        true,
      ),
    ]) {
      test(name, () async {
        final reader = ScriptedRevisionReader('a');
        final env = await _start(vault: _hosted, reader: reader);
        final base = reader.reads;
        reader
          ..error = error
          ..throwSync = sync;

        await env.advance(_s2);
        expect(reader.reads, base + 1);
        await env.advance(_s2);
        expect(reader.reads, base + 2);
        expect(env.revision, 0);

        reader.error = null;
        await env.advance(_s2);
        expect(reader.reads, base + 3);
        expect(env.revision, 0, reason: 'the baseline survives the errors');

        reader.revision = 'b';
        await env.advance(_s2);
        expect(env.revision, 1);
      });
    }

    test(
      'a failing revision read while unfocused keeps the 30 s interval',
      () async {
        final reader = ScriptedRevisionReader('a');
        final env = await _start(vault: _hosted, reader: reader);
        await env.advance(_s2);
        await env.setFocused(false);
        reader.error = const VaultUnreachableException(
          serverName: 'nas',
          mayHaveCommitted: false,
        );
        final base = reader.reads;

        await env.advance(_s30);
        expect(reader.reads, base + 1);
        await env.advance(_s30 - _s1);
        expect(reader.reads, base + 1);
        await env.advance(_s1);
        expect(reader.reads, base + 2);
      },
    );
  });

  group('leaving or switching the vault (AC13)', () {
    testWidgets(
      'leaving the workspace for the picker cancels the poller timer and makes no further reads',
      (tester) async {
        final db = FakeVaultDb.v5();
        final clock = RecordingClock(DateTime(2026, 10, 3, 9));
        final counter = PollReadCounter();
        final h = await pumpWorkspace(
          tester,
          db: db,
          clock: clock,
          overrides: [
            revisionReaderProvider.overrideWithValue(
              fakeRevisionReader(db, counter),
            ),
          ],
        );
        clock.advance(_s2);
        await pumpFrames(tester);
        expect(counter.reads, greaterThan(0), reason: 'polling in the vault');

        h.container.read(currentVaultProvider.notifier).state = null;
        await pumpFrames(tester);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        counter.reads = 0;

        clock.advance(const Duration(seconds: 60));
        await pumpFrames(tester);

        expect(counter.reads, 0);
        expect(clock.activeWith(_s2), isEmpty);
        expect(clock.activeWith(_s30), isEmpty);
        // The backup controller's hourly tick is app-wide (D23, kept alive by
        // Sidebar.build, WI #326) and outlives the workspace; no poller timer
        // is a 1 h one.
        expect(
          clock.timers.where(
            (t) =>
                t.periodic &&
                t.timer.isActive &&
                t.duration != const Duration(hours: 1),
          ),
          isEmpty,
        );
      },
    );

    test(
      'switching vaults restarts polling on the new vault and never applies the old vault revision',
      () async {
        final a = ScriptedRevisionReader('a-1');
        final env = await _start(reader: a);
        a.gated = true;
        await env.advance(_s2);
        expect(a.pending, 1);
        final aReads = a.reads;

        await env.switchTo(_vaultB);
        final b = env.readerFor(_vaultB);
        expect(b.reads, 1, reason: 'the new vault reads its baseline at once');
        expect(env.revision, 0);

        a.release('a-2');
        await env.settle();
        expect(env.revision, 0, reason: 'the old vault read is dropped');

        await env.advance(const Duration(seconds: 10));
        expect(a.reads, aReads);
        expect(b.reads, 6);
        expect(env.revision, 0);

        b.revision = 'rev-1';
        await env.advance(_s2);
        expect(env.revision, 1);
      },
    );

    test(
      'closing the vault in a running container stops the poller timer',
      () async {
        final env = await _start();
        await env.advance(_s2);
        expect(env.readerFor(_vaultA).reads, 2, reason: 'polling in the vault');

        await env.switchTo(null);
        final reads = env.readerFor(_vaultA).reads;
        await env.advance(const Duration(seconds: 60));

        expect(env.readerFor(_vaultA).reads, reads);
        expect(env.clock.pendingTimers, 0);
      },
    );

    test(
      'with no open vault the poller holds no timer even when a revision reader is supplied',
      () async {
        final reader = ScriptedRevisionReader('a');
        final clock = FakeClock(DateTime(2026, 10, 20, 9));
        final c = ProviderContainer(
          overrides: [
            clockProvider.overrideWithValue(clock),
            appFocusProvider.overrideWith(() => FakeAppFocus()),
            currentVaultProvider.overrideWith((_) => null),
            vaultDbProvider.overrideWithValue(null),
            memexCliProvider.overrideWithValue(null),
            revisionReaderProvider.overrideWith((_) => reader.read),
          ],
        );
        addTearDown(c.dispose);

        c.listen<void>(revisionPollerProvider, (_, _) {});
        await pumpEventQueue();
        expect(clock.pendingTimers, 0);
        clock.advance(const Duration(seconds: 10));
        await pumpEventQueue();

        expect(reader.reads, 0);
        expect(clock.pendingTimers, 0);
        expect(c.read(vaultRevisionProvider), 0);
      },
    );

    test(
      'closing the vault while a revision reader stays supplied stops the poller timer',
      () async {
        final reader = ScriptedRevisionReader('a');
        final clock = FakeClock(DateTime(2026, 10, 20, 9));
        final c = ProviderContainer(
          overrides: [
            clockProvider.overrideWithValue(clock),
            appFocusProvider.overrideWith(() => FakeAppFocus()),
            currentVaultProvider.overrideWith((_) => _vaultA),
            vaultDbProvider.overrideWithValue(null),
            memexCliProvider.overrideWithValue(null),
            revisionReaderProvider.overrideWith((_) => reader.read),
          ],
        );
        addTearDown(c.dispose);
        c.listen<void>(revisionPollerProvider, (_, _) {});
        await pumpEventQueue();
        expect(reader.reads, 1);
        expect(clock.pendingTimers, 1);

        c.read(currentVaultProvider.notifier).state = null;
        await pumpEventQueue();
        expect(clock.pendingTimers, 0);
        clock.advance(const Duration(seconds: 10));
        await pumpEventQueue();

        expect(reader.reads, 1);
        expect(c.read(vaultRevisionProvider), 0);
      },
    );
  });

  group('no per-note poll remains (AC14)', () {
    testWidgets(
      'opening a stored daily note adds no reads beyond the revision reader',
      (tester) async {
        final (r, counter) = await _launchLive(tester);
        expect(r.activeTab, const NoteTab(liveDailyId));
        var base = counter.reads;
        await r.advance(const Duration(seconds: 10));
        expect(counter.reads, base + 5);

        r.h.container
            .read(tabsProvider.notifier)
            .openOrFocus(const NoteTab(_topicId));
        await r.settle();
        base = counter.reads;
        await r.advance(const Duration(seconds: 10));
        expect(counter.reads, base + 5);

        r.h.container
            .read(tabsProvider.notifier)
            .openOrFocus(const NoteTab(liveDailyId));
        await r.settle();
        base = counter.reads;
        await r.advance(const Duration(seconds: 10));
        expect(counter.reads, base + 5);
      },
    );

    test('the per-note updated_at poller is gone from the app', () {
      expect(
        File('lib/src/state/note_poller_state.dart').existsSync(),
        isFalse,
      );
      expect(File('lib/src/db/poll_reads.dart').existsSync(), isFalse);
      expect(File('test/state/note_poller_test.dart').existsSync(), isFalse);
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        for (final symbol in const [
          'NotePoller',
          'notePollerProvider',
          'noteUpdatedAtReaderProvider',
          'notePollInterval',
          'note_poller_state.dart',
          'poll_reads.dart',
        ]) {
          if (src.contains(symbol)) offenders.add('${f.path}: $symbol');
        }
        if (_declaresOrCallsPollerNoteUpdatedAt(src)) {
          offenders.add('${f.path}: noteUpdatedAt(');
        }
      }
      expect(offenders, isEmpty);
    });

    test(
      'the poller-gone guard tells the removed noteUpdatedAt method from a field of that name',
      () {
        // The removed `PollReads.noteUpdatedAt(String noteId)` was a method
        // (a declaration or a call). `Echo.noteUpdatedAt` (#424) is a field,
        // read as a member and passed as a named argument, in any file.
        for (final offending in const [
          'int? noteUpdatedAt(String noteId) {',
          'final t = reads.noteUpdatedAt(id);',
          'noteUpdatedAt (id);',
        ]) {
          expect(
            _declaresOrCallsPollerNoteUpdatedAt(offending),
            isTrue,
            reason: offending,
          );
        }
        for (final fine in const [
          'final int noteUpdatedAt;',
          'required this.noteUpdatedAt,',
          'noteUpdatedAt: _required<int>(json, "note_updated_at"),',
          'Text(rel(echo.noteUpdatedAt));',
          'other.noteUpdatedAt == noteUpdatedAt;',
        ]) {
          expect(
            _declaresOrCallsPollerNoteUpdatedAt(fine),
            isFalse,
            reason: fine,
          );
        }
      },
    );
  });
}

/// Whether [src] declares or calls a `noteUpdatedAt(...)` method: the shape
/// of the removed per-note poller read. A field of that name does not match.
bool _declaresOrCallsPollerNoteUpdatedAt(String src) =>
    RegExp(r'(?<![A-Za-z0-9_$])noteUpdatedAt\s*\(').hasMatch(src);
