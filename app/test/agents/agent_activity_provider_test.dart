// WI #455 (390-A4): agentActivityAsyncProvider keeps the open vault's agents
// view live (#390 req 14a, 17, 18, 25, 26, 29; D4, D14, D24).
//
// - Reads `vaultAccessProvider.agents.activity()` once at build, on every
//   `vaultRevisionProvider` change and on its own presence tick (2 s focused,
//   30 s unfocused, through `clockProvider`), one read in flight at a time.
// - Every tick re-derives the last good activity with
//   `deriveAgentActivityView` against `clock.now()`, so expiry and `working`
//   move while a read is held or failing.
// - Hosted offset: `serverNow - clock.now()` at response arrival; local 0.
// - Errors never surface as AsyncError; `vault_not_found` stops the tick,
//   `unauthorized` stops it until the server status turns `connected`.
// - Lifecycle via `currentVaultProvider` (switch clears and re-reads, null
//   stops the tick). Presence never bumps `vaultRevisionProvider`.
//
// Seams: FakeClock (no real timers), FakeAppFocus, one FakeAgentsAccess per
// vault (scripted values or errors, read count, held reads). Every wait is a
// FakeClock.advance plus pumpEventQueue: no wall time.
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/agent_activity.dart';
import 'package:open_memex_app/src/state/app_focus.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/agents_access.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/widgets/agents/agent_age.dart';

import '../support/agents_fakes.dart';
import '../support/fake_clock.dart';

const _wi455VaultA = LocalVaultRef('/fake/om-455-vault-a');
const _wi455VaultB = LocalVaultRef('/fake/om-455-vault-b');
const _wi455ServerId = 'srv-455';
const _wi455Hosted = HostedVaultRef(_wi455ServerId, 'work');

const _ms1 = Duration(milliseconds: 1);
const _s1 = Duration(seconds: 1);
const _s2 = Duration(seconds: 2);
const _s30 = Duration(seconds: 30);

/// The largest single FakeClock step [_Wi455Env.advance] takes: reads
/// complete between two ticks, as they do in the app.
const _wi455Step = Duration(milliseconds: 500);

/// A [FakeClock] whose `now()` can be skewed from its timers' time: a wall
/// clock that jumps (NTP, a manual change) while timers keep their pace.
class _Wi455SkewedClock extends FakeClock {
  Duration skew = Duration.zero;

  @override
  DateTime now() => super.now().add(skew);
}

/// An [AgentActivity] with [agents] and [recent].
AgentActivity _wi455Activity({
  List<AgentPresence> agents = const [],
  List<AgentActivityEntry> recent = const [],
  bool available = true,
  int? serverNow,
}) => AgentActivity(
  agents: agents,
  recent: recent,
  available: available,
  serverNow: serverNow,
);

/// The branch a consumer's `AsyncValue.when` (default flags) takes.
String _wi455Branch(AsyncValue<AgentActivityView> state) => state.when(
  data: (_) => 'data',
  error: (_, _) => 'error',
  loading: () => 'loading',
);

MemexException _wi455Coded(String code) =>
    MemexException('agents failed: $code', code: code);

/// The provider in a plain [ProviderContainer], one [FakeAgentsAccess] per
/// vault, a [FakeClock] and the [FakeAppFocus] seam.
class _Wi455Env {
  _Wi455Env(this.c, this.clock, this.agents);

  final ProviderContainer c;
  final FakeClock clock;
  final Map<VaultRef, FakeAgentsAccess> agents;

  FakeAgentsAccess agentsFor(VaultRef vault) => agents.putIfAbsent(
    vault,
    () => FakeAgentsAccess(vaultPath: _wi455PathOf(vault)),
  );

  AsyncValue<AgentActivityView> get state => c.read(agentActivityAsyncProvider);

  AgentActivityView get view => state.requireValue;

  List<String> get connectedIds => [
    for (final a in view.connected) a.presence.sessionId,
  ];

  FakeAppFocus get focus => c.read(appFocusProvider.notifier) as FakeAppFocus;

  /// Moves the clock by [by] in steps of at most [_wi455Step], draining the
  /// event queue after each step.
  Future<void> advance(Duration by) async {
    var left = by;
    while (left > Duration.zero) {
      final step = Duration(
        microseconds: min(left.inMicroseconds, _wi455Step.inMicroseconds),
      );
      clock.advance(step);
      left -= step;
      await pumpEventQueue();
    }
  }

  Future<void> setFocused(bool focused) async {
    focus.set(focused);
    await pumpEventQueue();
  }

  Future<void> bumpRevision() async {
    c.read(vaultRevisionProvider.notifier).state++;
    await pumpEventQueue();
  }

  Future<void> setStatus(HostedConnectionStatus status) async {
    c.read(hostedConnectionStatusProvider(_wi455ServerId).notifier).state =
        status;
    await pumpEventQueue();
  }

  Future<void> switchTo(VaultRef? vault) async {
    c.read(currentVaultProvider.notifier).state = vault;
    await pumpEventQueue();
  }

  Future<void> release(VaultRef vault) async {
    agentsFor(vault).release();
    await pumpEventQueue();
  }
}

String _wi455PathOf(VaultRef vault) => switch (vault) {
  LocalVaultRef(:final path) => path,
  HostedVaultRef(:final serverId, :final vaultName) =>
    '/fake/hosted/$serverId/$vaultName',
};

/// Builds the container with [vault] open (or none) and subscribes to the
/// provider. [prepare] scripts each vault's fake before the provider builds.
/// A vault in [noAccess] has no `VaultAccess` yet (a hosted session not
/// connected).
Future<_Wi455Env> _wi455Start({
  VaultRef? vault = _wi455VaultA,
  bool focused = true,
  FakeClock? clock,
  Set<VaultRef> noAccess = const {},
  void Function(_Wi455Env env)? prepare,
}) async {
  final fakeClock = clock ?? FakeClock();
  final agents = <VaultRef, FakeAgentsAccess>{};
  late final _Wi455Env env;
  final c = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(fakeClock),
      appFocusProvider.overrideWith(() => FakeAppFocus(focused)),
      currentVaultProvider.overrideWith((_) => vault),
      vaultAccessProvider.overrideWith((ref) {
        final open = ref.watch(currentVaultProvider);
        if (open == null || noAccess.contains(open)) return null;
        return LocalVaultAccess(
          vaultPath: _wi455PathOf(open),
          agents: env.agentsFor(open),
        );
      }),
    ],
  );
  env = _Wi455Env(c, fakeClock, agents);
  addTearDown(c.dispose);
  prepare?.call(env);
  c.listen(agentActivityAsyncProvider, (_, _) {});
  await pumpEventQueue();
  return env;
}

void main() {
  group('presence tick (AC1)', () {
    test('focused: the fake clock advancing 2 s triggers one read', () async {
      final env = await _wi455Start();
      final a = env.agentsFor(_wi455VaultA);
      expect(a.reads, 1, reason: 'one read when the provider builds');

      await env.advance(_s2 - _ms1);
      expect(a.reads, 1, reason: 'no tick before 2 s');
      await env.advance(_ms1);
      expect(a.reads, 2, reason: 'the 2 s tick reads once');
      await env.advance(_s2);
      expect(a.reads, 3, reason: 'and again every 2 s');
    });

    test('unfocused: a read happens after 30 s and not after 2 s', () async {
      final env = await _wi455Start(focused: false);
      final a = env.agentsFor(_wi455VaultA);
      expect(a.reads, 1);

      await env.advance(_s2);
      expect(a.reads, 1, reason: 'no 2 s tick while unfocused');
      await env.advance(_s30 - _s2 - _ms1);
      expect(a.reads, 1, reason: 'no tick before 30 s');
      await env.advance(_ms1);
      expect(a.reads, 2, reason: 'the 30 s tick reads once');
      await env.advance(_s30);
      expect(a.reads, 3);
    });

    test('losing focus re-arms the tick at 30 s from the change', () async {
      final env = await _wi455Start();
      final a = env.agentsFor(_wi455VaultA);
      await env.advance(_s1);
      await env.setFocused(false);
      final r = a.reads;
      expect(r, 1);

      // The old 2 s timer would read at 2, 4, 6 s.
      await env.advance(_s30 - _ms1);
      expect(a.reads, r, reason: 'no read before 30 s after the change');
      await env.advance(_ms1);
      expect(a.reads, r + 1, reason: 'one read 30 s after the change');
    });

    test('regaining focus re-arms the tick at 2 s from the change', () async {
      final env = await _wi455Start(focused: false);
      final a = env.agentsFor(_wi455VaultA);
      await env.advance(const Duration(milliseconds: 10500));
      await env.setFocused(true);
      // An immediate read on regaining focus is allowed, not required.
      final r = a.reads;

      await env.advance(_s2 - _ms1);
      expect(a.reads, r, reason: 'no tick before 2 s after the change');
      await env.advance(_ms1);
      expect(a.reads, r + 1, reason: 'the first 2 s tick after the change');
      // From 12.5 s to 30.5 s: ticks at 14.5 ... 30.5 (9 more). The old
      // unfocused timer would add a read at 30 s.
      await env.advance(const Duration(seconds: 18));
      expect(a.reads, r + 10, reason: 'the old 30 s timer was cancelled');
    });
  });

  group('revision bump (AC2)', () {
    test('bumping vaultRevisionProvider triggers one read', () async {
      final agent = agentPresence(sessionId: 'S-455-BUMP');
      final env = await _wi455Start(
        prepare: (env) => env.agentsFor(_wi455VaultA)
          ..answer(_wi455Activity())
          ..answer(_wi455Activity(agents: [agent])),
      );
      final a = env.agentsFor(_wi455VaultA);
      await env.advance(const Duration(milliseconds: 500));
      expect(a.reads, 1);
      expect(env.connectedIds, isEmpty);

      await env.bumpRevision();
      expect(a.reads, 2, reason: 'one read per revision change');
      expect(env.connectedIds, ['S-455-BUMP']);

      await env.bumpRevision();
      expect(a.reads, 3);
    });
  });

  group('one read in flight (AC3)', () {
    test(
      'a tick or a revision bump while a read is held runs zero extra reads',
      () async {
        final env = await _wi455Start();
        final a = env.agentsFor(_wi455VaultA);
        expect(a.reads, 1);

        a.holdNextRead();
        await env.advance(_s2);
        expect(a.reads, 2);
        expect(a.holding, isTrue);

        await env.bumpRevision();
        expect(a.reads, 2, reason: 'a revision bump during a read is dropped');
        await env.advance(_s2);
        expect(a.reads, 2, reason: 'a tick during a read is dropped');

        await env.release(_wi455VaultA);
        expect(a.reads, 2, reason: 'dropped, not queued');
        await env.advance(_s2);
        expect(a.reads, 3, reason: 'the next tick after it completes reads');
      },
    );

    test('a tick while the first read is held runs zero extra reads', () async {
      final env = await _wi455Start(
        prepare: (env) => env.agentsFor(_wi455VaultA).holdNextRead(),
      );
      final a = env.agentsFor(_wi455VaultA);
      expect(a.reads, 1);
      await env.advance(_s2);
      await env.bumpRevision();
      await env.advance(_s2);
      expect(a.reads, 1);

      await env.release(_wi455VaultA);
      expect(a.reads, 1);
      await env.advance(_s2);
      expect(a.reads, 2);
    });

    test('a failed read frees the in-flight slot for the next tick', () async {
      final env = await _wi455Start(
        prepare: (env) => env.agentsFor(_wi455VaultA)
          ..answer(_wi455Activity())
          ..fail(Exception('network down')),
      );
      final a = env.agentsFor(_wi455VaultA);
      await env.advance(_s2);
      expect(a.reads, 2, reason: 'the second read throws');
      await env.advance(_s2);
      expect(a.reads, 3, reason: 'the tick after a failure reads again');
      await env.bumpRevision();
      expect(a.reads, 4);
    });
  });

  group('re-derive on every tick (AC4)', () {
    test(
      'a record that expires between two reads drops out on the next tick while the read is held',
      () async {
        final env = await _wi455Start(
          prepare: (env) => env
              .agentsFor(_wi455VaultA)
              .answer(
                _wi455Activity(
                  agents: [
                    agentPresence(
                      sessionId: 'S-455-LONG',
                      expiresAt: agentsT0 + 60000,
                    ),
                    agentPresence(
                      sessionId: 'S-455-SHORT',
                      expiresAt: agentsT0 + 3000,
                    ),
                  ],
                  recent: [agentEntry(id: 'E-455-1')],
                ),
              ),
        );
        final a = env.agentsFor(_wi455VaultA);
        expect(env.connectedIds, containsAll(['S-455-LONG', 'S-455-SHORT']));

        a.holdNextRead();
        await env.advance(_s2);
        expect(a.reads, 2);
        expect(env.connectedIds, hasLength(2), reason: 'not expired at 2 s');

        await env.advance(_s2);
        expect(a.reads, 2, reason: 'the 4 s tick read was dropped');
        expect(a.holding, isTrue);
        expect(env.connectedIds, ['S-455-LONG']);
        expect([for (final e in env.view.recent) e.id], ['E-455-1']);
      },
    );

    test(
      'working turns off on the tick ten seconds after the last tool call while the read is held',
      () async {
        final env = await _wi455Start(
          prepare: (env) => env
              .agentsFor(_wi455VaultA)
              .answer(
                _wi455Activity(
                  agents: [
                    agentPresence(
                      sessionId: 'S-455-WORK',
                      lastToolAt: agentsT0 - 9000,
                      expiresAt: agentsT0 + 60000,
                    ),
                  ],
                ),
              ),
        );
        final a = env.agentsFor(_wi455VaultA);
        expect(env.connectedIds, ['S-455-WORK']);
        expect(env.view.connected.single.working, isTrue);

        a.holdNextRead();
        await env.advance(_s2);
        expect(a.reads, 2);
        expect(a.holding, isTrue);
        expect(env.view.connected.single.working, isFalse);
      },
    );
  });

  group('errors keep the last good value (AC5)', () {
    test(
      'after a successful read a read that throws keeps the last good value and ticks drop expired agents while reads keep failing',
      () async {
        final env = await _wi455Start(
          prepare: (env) {
            final a = env.agentsFor(_wi455VaultA)
              ..answer(
                _wi455Activity(
                  agents: [
                    agentPresence(
                      sessionId: 'S-455-LONG',
                      expiresAt: agentsT0 + 15000,
                    ),
                    agentPresence(
                      sessionId: 'S-455-SHORT',
                      expiresAt: agentsT0 + 5000,
                    ),
                  ],
                  recent: [agentEntry(id: 'E-455-KEEP')],
                ),
              );
            for (var i = 0; i < 6; i++) {
              a
                ..fail(Exception('network down'))
                ..fail(
                  const VaultUnreachableException(
                    serverName: 'nas',
                    mayHaveCommitted: false,
                  ),
                )
                ..fail(_wi455Coded('internal'));
            }
          },
        );
        final a = env.agentsFor(_wi455VaultA);
        expect(env.connectedIds, hasLength(2));

        await env.advance(_s2);
        expect(a.reads, 2, reason: 'the 2 s read throws');
        expect(env.state.hasError, isFalse);
        expect(env.connectedIds, hasLength(2), reason: 'last good kept');
        expect([for (final e in env.view.recent) e.id], ['E-455-KEEP']);

        await env.advance(_s2 * 2);
        expect(a.reads, 4, reason: 'failing reads keep ticking');
        expect(env.state.hasError, isFalse);
        expect(env.connectedIds, ['S-455-LONG'], reason: 'expired at 5 s');

        await env.advance(_s2 * 6);
        expect(a.reads, 10);
        expect(env.state.hasError, isFalse);
        expect(env.connectedIds, isEmpty, reason: 'both expired by 16 s');
        expect([for (final e in env.view.recent) e.id], ['E-455-KEEP']);
      },
    );
  });

  group('first read errors (AC6)', () {
    test(
      'when the first read throws the value is AgentActivityView.empty not AsyncError',
      () async {
        final env = await _wi455Start(
          prepare: (env) => env.agentsFor(_wi455VaultA)
            ..fail(Exception('network down'))
            ..answer(
              _wi455Activity(agents: [agentPresence(sessionId: 'S-455-LATE')]),
            ),
        );
        final a = env.agentsFor(_wi455VaultA);
        expect(a.reads, 1);
        expect(env.state.hasError, isFalse);
        expect(env.state.isLoading, isFalse);
        expect(env.state.hasValue, isTrue);
        expect(env.view.connected, isEmpty);
        expect(env.view.recent, isEmpty);
        expect(env.view.available, isTrue);
        expect(env.view.clockOffsetMs, 0);

        // The tick is the retry.
        await env.advance(_s2);
        expect(a.reads, 2);
        expect(env.connectedIds, ['S-455-LATE']);
      },
    );

    test(
      'a first read failing with vault_not_found is AgentActivityView.empty not AsyncError',
      () async {
        final env = await _wi455Start(
          prepare: (env) =>
              env.agentsFor(_wi455VaultA).fail(_wi455Coded('vault_not_found')),
        );
        expect(env.agentsFor(_wi455VaultA).reads, 1);
        expect(env.state.hasError, isFalse);
        expect(env.state.hasValue, isTrue);
        expect(env.view.connected, isEmpty);
        expect(env.view.available, isTrue);
      },
    );
  });

  group('loading (AC7)', () {
    test(
      'before the first read completes the provider is AsyncLoading',
      () async {
        final env = await _wi455Start(
          prepare: (env) => env.agentsFor(_wi455VaultA)
            ..holdNextRead()
            ..answer(
              _wi455Activity(agents: [agentPresence(sessionId: 'S-455-A')]),
            ),
        );
        expect(env.agentsFor(_wi455VaultA).reads, 1);
        expect(env.state.isLoading, isTrue);
        expect(env.state.hasValue, isFalse);
        expect(env.state.hasError, isFalse);

        await env.release(_wi455VaultA);
        expect(env.state.isLoading, isFalse);
        expect(env.connectedIds, ['S-455-A']);
      },
    );
  });

  group('hosted clock offset (AC8)', () {
    test(
      'a hosted read with serverNow 5 s ahead sets clockOffsetMs to 5000 and expiry and working use it',
      () async {
        final t = agentsT0;
        final server = t + 5000;
        final env = await _wi455Start(
          vault: _wi455Hosted,
          prepare: (env) => env
              .agentsFor(_wi455Hosted)
              .answer(
                _wi455Activity(
                  serverNow: server,
                  agents: [
                    agentPresence(
                      sessionId: 'S-455-H',
                      lastRequestAt: server,
                      // Local t - 8000: working until t + 2000.
                      lastToolAt: t - 3000,
                      // Local t + 3000.
                      expiresAt: server + 3000,
                    ),
                  ],
                ),
              ),
        );
        final a = env.agentsFor(_wi455Hosted);
        expect(env.view.clockOffsetMs, 5000);
        expect(env.connectedIds, ['S-455-H']);
        expect(env.view.connected.single.working, isTrue);

        a.holdNextRead();
        await env.advance(_s2);
        expect(a.holding, isTrue);
        expect(env.connectedIds, ['S-455-H'], reason: 'local expiry t + 3 s');
        expect(
          env.view.connected.single.working,
          isFalse,
          reason: 'local last tool t - 8 s is 10 s old at t + 2 s',
        );

        await env.advance(_s2);
        expect(env.connectedIds, isEmpty, reason: 'expired at local t + 3 s');
      },
    );

    test(
      'the hosted offset uses the clock when the response arrives',
      () async {
        final server = agentsT0 + 5000;
        final env = await _wi455Start(
          vault: _wi455Hosted,
          prepare: (env) => env.agentsFor(_wi455Hosted)
            ..holdNextRead()
            ..answer(_wi455Activity(serverNow: server)),
        );
        expect(env.agentsFor(_wi455Hosted).reads, 1);
        // The request left at t; the response arrives at t + 1 s.
        await env.advance(_s1);
        await env.release(_wi455Hosted);
        expect(env.view.clockOffsetMs, 4000);
      },
    );

    test(
      'each hosted read recomputes the offset after a backward clock jump',
      () async {
        final clock = _Wi455SkewedClock();
        final t = agentsT0;
        final env = await _wi455Start(
          vault: _wi455Hosted,
          clock: clock,
          prepare: (env) => env.agentsFor(_wi455Hosted)
            ..answer(_wi455Activity(serverNow: t + 5000))
            ..answer(
              _wi455Activity(
                serverNow: t + 2000 + 5000,
                agents: [
                  agentPresence(
                    sessionId: 'S-455-JUMP',
                    lastRequestAt: t + 7000,
                    expiresAt: t + 7000 + 15000,
                  ),
                ],
              ),
            ),
        );
        final a = env.agentsFor(_wi455Hosted);
        expect(env.view.clockOffsetMs, 5000);

        // The wall clock jumps back a minute; timers keep their pace.
        clock.skew = const Duration(seconds: -60);
        await env.advance(_s2);
        expect(a.reads, 2, reason: 'ticks keep reading after the jump');
        expect(env.view.clockOffsetMs, 65000);
        expect(env.connectedIds, ['S-455-JUMP']);
      },
    );

    test('a local read has clockOffsetMs 0', () async {
      final env = await _wi455Start(
        prepare: (env) => env
            .agentsFor(_wi455VaultA)
            .answer(
              _wi455Activity(
                agents: [
                  agentPresence(
                    sessionId: 'S-455-L',
                    expiresAt: agentsT0 + 3000,
                  ),
                ],
              ),
            ),
      );
      expect(env.connectedIds, ['S-455-L']);
      expect(env.view.clockOffsetMs, 0);
      env.agentsFor(_wi455VaultA).holdNextRead();
      await env.advance(_s2 * 2);
      expect(env.connectedIds, isEmpty, reason: 'expired at local t + 3 s');
    });

    test('a hosted timestamp ahead of local now shows age now', () async {
      final t = agentsT0;
      final server = t + 5000;
      final env = await _wi455Start(
        vault: _wi455Hosted,
        prepare: (env) => env
            .agentsFor(_wi455Hosted)
            .answer(
              _wi455Activity(
                serverNow: server,
                agents: [
                  agentPresence(
                    sessionId: 'S-455-AHEAD',
                    lastRequestAt: server + 2000,
                    expiresAt: server + 15000,
                  ),
                ],
                recent: [
                  agentEntry(id: 'E-455-AHEAD', createdAt: server + 2000),
                  agentEntry(id: 'E-455-62S', createdAt: server - 62000),
                ],
              ),
            ),
      );
      final view = env.view;
      final now = env.clock.now();
      expect(view.clockOffsetMs, 5000);
      expect(view.recent, hasLength(2));
      expect(
        view.localMs(server + 2000),
        greaterThan(now.millisecondsSinceEpoch),
      );
      expect(
        formatAgentAge(view.localMs(view.recent[0].createdAt), now: now),
        'now',
      );
      expect(
        formatAgentAge(
          view.localMs(view.connected.single.presence.lastRequestAt),
          now: now,
        ),
        'now',
      );
      // 62 s old on the server clock: the offset makes it 1m, not now.
      expect(
        formatAgentAge(view.localMs(view.recent[1].createdAt), now: now),
        '1m',
      );
    });
  });

  group('stop on vault_not_found and unauthorized (AC9)', () {
    test(
      'a vault_not_found error stops the tick and no read happens on later ticks',
      () async {
        final env = await _wi455Start(
          prepare: (env) => env.agentsFor(_wi455VaultA)
            ..answer(_wi455Activity())
            ..fail(_wi455Coded('vault_not_found')),
        );
        final a = env.agentsFor(_wi455VaultA);
        await env.advance(_s2);
        expect(a.reads, 2);
        expect(env.state.hasError, isFalse);

        await env.advance(const Duration(seconds: 60));
        expect(a.reads, 2, reason: 'no tick after vault_not_found');

        // A focus change does not re-arm a stopped tick.
        await env.setFocused(false);
        await env.setFocused(true);
        await env.advance(const Duration(seconds: 60));
        expect(a.reads, 2);
      },
    );

    test(
      'a hosted vault_not_found stays stopped when the connection status turns connected',
      () async {
        final env = await _wi455Start(
          vault: _wi455Hosted,
          prepare: (env) => env.agentsFor(_wi455Hosted)
            ..answer(_wi455Activity(serverNow: agentsT0))
            ..fail(_wi455Coded('vault_not_found')),
        );
        final a = env.agentsFor(_wi455Hosted);
        await env.advance(_s2);
        expect(a.reads, 2);

        await env.setStatus(HostedConnectionStatus.unreachable);
        await env.setStatus(HostedConnectionStatus.connected);
        await env.advance(const Duration(seconds: 10));
        expect(a.reads, 2, reason: 'vault_not_found stops for good');
      },
    );

    test(
      'an unauthorized error stops the tick until the hosted connection status turns connected and then reads resume',
      () async {
        final env = await _wi455Start(
          vault: _wi455Hosted,
          prepare: (env) => env.agentsFor(_wi455Hosted)
            ..answer(_wi455Activity(serverNow: agentsT0))
            ..fail(_wi455Coded('unauthorized'))
            ..answer(
              _wi455Activity(
                serverNow: agentsT0 + 20000,
                agents: [
                  agentPresence(
                    sessionId: 'S-455-BACK',
                    lastRequestAt: agentsT0 + 20000,
                    expiresAt: agentsT0 + 40000,
                  ),
                ],
              ),
            ),
        );
        final a = env.agentsFor(_wi455Hosted);
        await env.advance(_s2);
        expect(a.reads, 2);
        expect(env.state.hasError, isFalse);

        await env.advance(const Duration(seconds: 10));
        expect(a.reads, 2, reason: 'stopped after unauthorized');

        await env.setStatus(HostedConnectionStatus.tokenRejected);
        await env.setStatus(HostedConnectionStatus.unreachable);
        await env.advance(_s2 * 2);
        expect(a.reads, 2, reason: 'only connected resumes');

        // A focus change does not re-arm a stopped tick.
        await env.setFocused(false);
        await env.setFocused(true);
        await env.advance(_s2 * 2);
        expect(a.reads, 2);

        await env.setStatus(HostedConnectionStatus.connected);
        expect(a.reads, 3, reason: 'connected reads at once, as the poller');
        expect(env.connectedIds, ['S-455-BACK']);
        await env.advance(_s2);
        expect(a.reads, 4, reason: 'and the tick resumes');
      },
    );

    test('an unauthorized first read stops the tick until connected', () async {
      final env = await _wi455Start(
        vault: _wi455Hosted,
        prepare: (env) =>
            env.agentsFor(_wi455Hosted).fail(_wi455Coded('unauthorized')),
      );
      final a = env.agentsFor(_wi455Hosted);
      expect(a.reads, 1);
      expect(env.state.hasError, isFalse);
      expect(env.state.hasValue, isTrue);
      await env.advance(const Duration(seconds: 10));
      expect(a.reads, 1);

      await env.setStatus(HostedConnectionStatus.connected);
      await env.advance(_s2);
      expect(a.reads, greaterThanOrEqualTo(2));
    });
  });

  group('vault lifecycle (AC10)', () {
    test(
      'switching currentVaultProvider to another vault clears the value and reads the new vault access',
      () async {
        final env = await _wi455Start(
          prepare: (env) {
            env
                .agentsFor(_wi455VaultA)
                .answer(
                  _wi455Activity(agents: [agentPresence(sessionId: 'S-455-A')]),
                );
            env.agentsFor(_wi455VaultB)
              ..holdNextRead()
              ..answer(
                _wi455Activity(agents: [agentPresence(sessionId: 'S-455-B')]),
              );
          },
        );
        final a = env.agentsFor(_wi455VaultA);
        final b = env.agentsFor(_wi455VaultB);
        expect(env.connectedIds, ['S-455-A']);
        expect(b.reads, 0);

        await env.switchTo(_wi455VaultB);
        expect(b.reads, 1, reason: 'the new vault is read');
        // Riverpod 2 keeps the previous value on any AsyncLoading
        // (asyncTransition copyWithPrevious), so "cleared" is what a consumer
        // sees: loading, not a refresh showing vault A's agents.
        expect(env.state.isLoading, isTrue, reason: 'back to loading');
        expect(env.state.isRefreshing, isFalse);
        expect(_wi455Branch(env.state), 'loading');

        // A tick while B's first read is held does not re-derive A's value.
        await env.advance(_s2);
        expect(b.reads, 1);
        expect(_wi455Branch(env.state), 'loading');

        await env.release(_wi455VaultB);
        expect(env.connectedIds, ['S-455-B']);

        final aReads = a.reads;
        await env.advance(_s2 * 3);
        expect(a.reads, aReads, reason: 'the old vault is no longer read');
        expect(b.reads, 4);
      },
    );

    test(
      'after a switch a failing first read of the new vault is AgentActivityView.empty not the old vault agents',
      () async {
        final env = await _wi455Start(
          prepare: (env) {
            env
                .agentsFor(_wi455VaultA)
                .answer(
                  _wi455Activity(
                    agents: [agentPresence(sessionId: 'S-455-A')],
                    recent: [agentEntry(id: 'E-455-A')],
                  ),
                );
            env.agentsFor(_wi455VaultB).fail(Exception('network down'));
          },
        );
        expect(env.connectedIds, ['S-455-A']);

        await env.switchTo(_wi455VaultB);
        expect(env.agentsFor(_wi455VaultB).reads, 1);
        expect(env.state.hasError, isFalse);
        expect(_wi455Branch(env.state), 'data');
        expect(env.connectedIds, isEmpty, reason: 'vault A is not last good');
        expect(env.view.recent, isEmpty);
        await env.advance(_s2);
        expect(env.connectedIds, isEmpty);
      },
    );

    test(
      'a read of the old vault that lands after a switch is dropped',
      () async {
        final env = await _wi455Start(
          prepare: (env) {
            env.agentsFor(_wi455VaultA)
              ..answer(_wi455Activity())
              ..answer(
                _wi455Activity(
                  agents: [agentPresence(sessionId: 'S-455-STALE')],
                ),
              );
            env
                .agentsFor(_wi455VaultB)
                .answer(
                  _wi455Activity(agents: [agentPresence(sessionId: 'S-455-B')]),
                );
          },
        );
        final a = env.agentsFor(_wi455VaultA);
        a.holdNextRead();
        await env.advance(_s2);
        expect(a.holding, isTrue);

        await env.switchTo(_wi455VaultB);
        expect(env.connectedIds, ['S-455-B']);
        await env.release(_wi455VaultA);
        expect(env.connectedIds, ['S-455-B'], reason: 'stale result dropped');
        await env.advance(_s2);
        expect(env.connectedIds, ['S-455-B']);
      },
    );

    test('setting currentVaultProvider to null cancels the tick', () async {
      final env = await _wi455Start();
      final a = env.agentsFor(_wi455VaultA);
      await env.advance(_s2);
      expect(a.reads, 2);

      await env.switchTo(null);
      expect(env.clock.pendingTimers, 0, reason: 'the tick timer cancelled');
      await env.advance(const Duration(seconds: 60));
      await env.bumpRevision();
      expect(a.reads, 2, reason: 'no reads with no vault open');
    });

    test('opening a vault after none reads it and starts the tick', () async {
      final env = await _wi455Start(vault: null);
      final a = env.agentsFor(_wi455VaultA);
      expect(env.clock.pendingTimers, 0);
      await env.advance(_s2 * 2);
      expect(a.reads, 0);

      await env.switchTo(_wi455VaultA);
      expect(a.reads, 1);
      await env.advance(_s2);
      expect(a.reads, 2);

      await env.switchTo(null);
      await env.switchTo(_wi455VaultA);
      expect(a.reads, 3, reason: 'reopening reads again');
    });

    test('disposing the container cancels the tick timer', () async {
      final env = await _wi455Start();
      expect(env.agentsFor(_wi455VaultA).reads, 1);
      expect(env.clock.pendingTimers, greaterThan(0));
      env.c.dispose();
      expect(env.clock.pendingTimers, 0);
    });
  });

  group('presence never bumps the revision (AC11)', () {
    test(
      'k presence ticks with changing agents cause zero vaultRevisionProvider bumps',
      () async {
        const k = 8;
        final env = await _wi455Start(
          prepare: (env) {
            final a = env.agentsFor(_wi455VaultA);
            for (var i = 0; i <= k; i++) {
              a.answer(
                _wi455Activity(
                  agents: [
                    agentPresence(
                      sessionId: 'S-455-K$i',
                      lastRequestAt: agentsT0 + i * 2000,
                      expiresAt: agentsT0 + i * 2000 + 15000,
                    ),
                  ],
                ),
              );
            }
          },
        );
        final bumps = <int>[];
        env.c.listen<int>(vaultRevisionProvider, (_, next) => bumps.add(next));
        final a = env.agentsFor(_wi455VaultA);

        await env.advance(_s2 * k);
        expect(a.reads, k + 1);
        expect(env.connectedIds, ['S-455-K$k']);
        expect(bumps, isEmpty);
        expect(env.c.read(vaultRevisionProvider), 0);
      },
    );
  });

  group('verify additions (AC1, AC3, AC9, AC10)', () {
    test('regaining focus reads at once and then ticks every 2 s', () async {
      final env = await _wi455Start(focused: false);
      final a = env.agentsFor(_wi455VaultA);
      await env.advance(const Duration(milliseconds: 10500));
      expect(a.reads, 1);

      await env.setFocused(true);
      expect(a.reads, 2, reason: 'one read at once on regaining focus');
      await env.advance(_s2);
      expect(a.reads, 3);
      await env.setFocused(false);
      expect(a.reads, 3, reason: 'losing focus does not read');
    });

    test(
      'a vault_not_found stop reads nothing on a revision bump while the tick keeps dropping expired agents',
      () async {
        final env = await _wi455Start(
          prepare: (env) => env.agentsFor(_wi455VaultA)
            ..answer(
              _wi455Activity(
                agents: [
                  agentPresence(
                    sessionId: 'S-455-SHORT',
                    expiresAt: agentsT0 + 5000,
                  ),
                ],
              ),
            )
            ..fail(_wi455Coded('vault_not_found')),
        );
        final a = env.agentsFor(_wi455VaultA);
        expect(env.clock.pendingTimers, 1);
        await env.advance(_s2);
        expect(a.reads, 2);
        expect(env.connectedIds, ['S-455-SHORT']);
        expect(
          env.clock.pendingTimers,
          1,
          reason: 'the tick keeps running to re-derive',
        );

        await env.bumpRevision();
        await env.bumpRevision();
        expect(a.reads, 2, reason: 'a stopped provider ignores revision bumps');

        await env.advance(_s2 * 2);
        expect(a.reads, 2, reason: 'ticks do not read while stopped');
        expect(env.connectedIds, isEmpty, reason: 'expired on a later tick');
      },
    );

    test(
      'an unauthorized stop reads nothing on a revision bump until connected while the tick keeps dropping expired agents',
      () async {
        final env = await _wi455Start(
          vault: _wi455Hosted,
          prepare: (env) => env.agentsFor(_wi455Hosted)
            ..answer(
              _wi455Activity(
                serverNow: agentsT0,
                agents: [
                  agentPresence(
                    sessionId: 'S-455-SHORT',
                    expiresAt: agentsT0 + 5000,
                  ),
                ],
              ),
            )
            ..fail(_wi455Coded('unauthorized')),
        );
        final a = env.agentsFor(_wi455Hosted);
        await env.advance(_s2);
        expect(a.reads, 2);
        expect(
          env.clock.pendingTimers,
          1,
          reason: 'the tick keeps running to re-derive',
        );

        await env.bumpRevision();
        expect(a.reads, 2, reason: 'stopped providers ignore revision bumps');

        await env.advance(_s2 * 2);
        expect(a.reads, 2, reason: 'ticks do not read while stopped');
        expect(env.connectedIds, isEmpty, reason: 'expired on a later tick');

        await env.setStatus(HostedConnectionStatus.connected);
        expect(a.reads, 3);
        expect(
          env.clock.pendingTimers,
          1,
          reason: 'the tick is re-armed, not doubled',
        );
        await env.bumpRevision();
        expect(a.reads, 4, reason: 'revision bumps read again once connected');
      },
    );

    test(
      'with no vault open the value is AgentActivityView.empty and no timer runs',
      () async {
        final env = await _wi455Start(vault: null);
        expect(env.state.isLoading, isFalse);
        expect(env.state.hasError, isFalse);
        expect(identical(env.view, AgentActivityView.empty), isTrue);
        expect(env.clock.pendingTimers, 0);

        await env.switchTo(_wi455VaultA);
        await env.switchTo(null);
        expect(env.state.hasError, isFalse);
        expect(identical(env.view, AgentActivityView.empty), isTrue);
        expect(env.clock.pendingTimers, 0);
      },
    );

    test(
      'a revision bump in the same step as a vault switch reads the new vault once',
      () async {
        final env = await _wi455Start(
          prepare: (env) => env
              .agentsFor(_wi455VaultB)
              .answer(
                _wi455Activity(agents: [agentPresence(sessionId: 'S-455-B')]),
              ),
        );
        final a = env.agentsFor(_wi455VaultA);
        final b = env.agentsFor(_wi455VaultB);
        expect(a.reads, 1);

        env.c.read(currentVaultProvider.notifier).state = _wi455VaultB;
        env.c.read(vaultRevisionProvider.notifier).state++;
        await pumpEventQueue();
        expect(a.reads, 1, reason: 'the old vault is not read again');
        expect(b.reads, 1, reason: 'the new vault is read once');
        expect(env.connectedIds, ['S-455-B']);
      },
    );

    test(
      'a vault without access yet stays loading and the next tick reads once access exists',
      () async {
        final noAccess = <VaultRef>{_wi455Hosted};
        final env = await _wi455Start(
          vault: _wi455Hosted,
          noAccess: noAccess,
          prepare: (env) => env
              .agentsFor(_wi455Hosted)
              .answer(
                _wi455Activity(
                  serverNow: agentsT0,
                  agents: [agentPresence(sessionId: 'S-455-LATE')],
                ),
              ),
        );
        final a = env.agentsFor(_wi455Hosted);
        expect(a.reads, 0);
        expect(env.state.isLoading, isTrue);
        await env.advance(_s2 * 2);
        expect(a.reads, 0, reason: 'no access, no read');
        expect(env.state.isLoading, isTrue);
        expect(env.clock.pendingTimers, 1, reason: 'the tick keeps retrying');

        noAccess.clear();
        env.c.invalidate(vaultAccessProvider);
        await pumpEventQueue();
        expect(
          env.state.isLoading,
          isTrue,
          reason: 'access is read, not watched',
        );
        expect(a.reads, 0);

        await env.advance(_s2);
        expect(a.reads, 1);
        expect(env.connectedIds, ['S-455-LATE']);

        env.c.invalidate(vaultAccessProvider);
        await pumpEventQueue();
        expect(env.state.isLoading, isFalse, reason: 'a session swap keeps it');
        expect(env.connectedIds, ['S-455-LATE']);
      },
    );
  });
}
