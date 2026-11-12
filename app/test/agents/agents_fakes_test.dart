// WI #452 (390-A1): the shared agents doubles (D14, D21) as A4, A5 and #394
// reach them: through `agentsOverrides`, the open vault's VaultAccess.agents.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/agent_activity.dart';
import 'package:open_memex_app/src/state/app_focus.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';

import '../support/agents_fakes.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';

/// The open vault's `agents`, as the provider reads it.
AgentsAccess _agents(ProviderContainer c) =>
    c.read(vaultAccessProvider)!.agents;

ProviderContainer _container(
  FakeAgentsAccess fake, {
  FakeClock? clock,
  bool focused = true,
}) {
  final c = ProviderContainer(
    overrides: agentsOverrides(access: fake, clock: clock, focused: focused),
  );
  addTearDown(c.dispose);
  return c;
}

AgentActivity _activity(String sessionId, {int? serverNow}) => AgentActivity(
  agents: [agentPresence(sessionId: sessionId)],
  recent: [agentEntry(sessionId: sessionId)],
  available: true,
  serverNow: serverNow,
);

List<String> _ids(AgentActivity a) => [for (final p in a.agents) p.sessionId];

void main() {
  test('FakeAgentsAccess returns its scripted values in order', () async {
    final fake = FakeAgentsAccess(script: [_activity('s1'), _activity('s2')]);
    fake.answer(_activity('s3', serverNow: 99));
    final agents = _agents(_container(fake));

    expect(agents, same(fake));
    expect(_ids(await agents.activity()), ['s1']);
    expect(_ids(await agents.activity()), ['s2']);
    final third = await agents.activity();
    expect(_ids(third), ['s3']);
    expect(third.serverNow, 99);
    // An empty queue answers the last value again.
    expect(await agents.activity(), same(third));
    expect(fake.pending, 0);
  });

  test('FakeAgentsAccess throws a scripted error', () async {
    final error = StateError('presence file locked');
    final fake = FakeAgentsAccess(script: [_activity('s1'), error]);
    fake.fail(const FormatException('bad record'));
    final agents = _agents(_container(fake));

    final first = await agents.activity();
    expect(_ids(first), ['s1']);
    await expectLater(agents.activity(), throwsA(same(error)));
    await expectLater(agents.activity(), throwsFormatException);
    // After the errors the last good value comes back.
    expect(await agents.activity(), same(first));
    expect(fake.reads, 4);
  });

  test('FakeAgentsAccess counts reads', () async {
    final fake = FakeAgentsAccess();
    final agents = _agents(_container(fake));
    expect(fake.reads, 0);

    final empty = await agents.activity();
    expect(empty.agents, isEmpty);
    expect(empty.recent, isEmpty);
    expect(empty.available, isTrue);
    expect(empty.serverNow, isNull);
    await agents.activity();
    await agents.activity();
    expect(fake.reads, 3);
  });

  test('FakeAgentsAccess holds a read until released', () async {
    final fake = FakeAgentsAccess(script: [_activity('held')]);
    final agents = _agents(_container(fake));
    fake.holdNextRead();

    AgentActivity? held;
    final pending = agents.activity().then((a) => held = a);
    await pumpEventQueue();
    expect(held, isNull);
    expect(fake.holding, isTrue);
    expect(fake.reads, 1);
    // The held read has not taken its scripted item yet.
    expect(fake.pending, 1);

    fake.answer(_activity('second'));
    // The held read takes the first queued item when released, so the
    // read below gets the second.
    fake.release();
    await pending;
    expect(_ids(held!), ['held']);
    expect(fake.holding, isFalse);
    expect(_ids(await agents.activity()), ['second']);
    expect(fake.reads, 2);
    expect(() => fake.release(), throwsStateError);
  });

  test(
    'FakeAgentsAccess releases reads held one after another oldest first',
    () async {
      final fake = FakeAgentsAccess(script: [_activity('a'), _activity('b')]);
      final agents = _agents(_container(fake));

      final done = <String>[];
      fake.holdNextRead();
      final first = agents.activity().then((a) => done.addAll(_ids(a)));
      await pumpEventQueue();
      fake.holdNextRead();
      final second = agents.activity().then((a) => done.addAll(_ids(a)));
      await pumpEventQueue();
      expect(fake.reads, 2);
      expect(fake.holding, isTrue);

      fake.release();
      await first;
      expect(done, ['a']);
      // The second read is still held, not orphaned.
      expect(fake.holding, isTrue);
      await pumpEventQueue();
      expect(done, ['a']);

      fake.release();
      await second;
      expect(done, ['a', 'b']);
      expect(fake.holding, isFalse);
      expect(() => fake.release(), throwsStateError);
    },
  );

  test('FakeAgentsAccess holds only the next read', () async {
    final fake = FakeAgentsAccess(script: [_activity('a'), _activity('b')]);
    final agents = _agents(_container(fake));
    fake.holdNextRead();

    AgentActivity? held;
    final pending = agents.activity().then((a) => held = a);
    await pumpEventQueue();
    // A read while one is held is not held: it takes the first item.
    expect(_ids(await agents.activity()), ['a']);
    expect(held, isNull);
    fake.release();
    await pending;
    expect(_ids(held!), ['b']);
    expect(fake.reads, 2);
  });

  test(
    'agentsOverrides opens a local vault with the fake agents, the fake clock and the focus',
    () async {
      final clock = FakeClock(DateTime(2026, 11, 11, 9));
      final fake = FakeAgentsAccess(vaultPath: '/tmp/om-452-overrides');
      final c = _container(fake, clock: clock, focused: false);

      expect(
        c.read(currentVaultProvider),
        const LocalVaultRef('/tmp/om-452-overrides'),
      );
      expect(c.read(vaultAccessProvider)!.agents, same(fake));
      expect(c.read(clockProvider), same(clock));
      expect(c.read(appFocusProvider), isFalse);
      (c.read(appFocusProvider.notifier) as FakeAppFocus).set(true);
      expect(c.read(appFocusProvider), isTrue);

      // Closing the vault leaves no access.
      c.read(currentVaultProvider.notifier).state = null;
      expect(c.read(vaultAccessProvider), isNull);
    },
  );

  test(
    'agentsOverrides passes the vault db and cli providers through to the other domains',
    () {
      final db = FakeVaultDb();
      addTearDown(db.close);
      final cli = FakeMemexCli();
      final c = ProviderContainer(
        overrides: [
          ...agentsOverrides(),
          vaultDbProvider.overrideWithValue(db),
          memexCliProvider.overrideWithValue(cli),
        ],
      );
      addTearDown(c.dispose);
      final access = c.read(vaultAccessProvider)! as LocalVaultAccess;
      expect(access.notes.db, same(db));
      expect(access.notes.cli, same(cli));
      expect(access.tags.db, same(db));
      // The agents seam is still the fake.
      expect(access.agents, isA<FakeAgentsAccess>());
    },
  );

  test(
    'agentsOverrides defaults to a focused window and a fresh fake',
    () async {
      final c = ProviderContainer(overrides: agentsOverrides());
      addTearDown(c.dispose);
      expect(c.read(appFocusProvider), isTrue);
      expect(c.read(clockProvider), isA<FakeClock>());
      final agents = c.read(vaultAccessProvider)!.agents;
      expect(agents, isA<FakeAgentsAccess>());
      expect((agents as FakeAgentsAccess).vaultPath, fakeAgentsVaultPath);
    },
  );

  test(
    'the agents builders default to an idle agent connected at the fake clock start',
    () {
      final now = FakeClock().now();
      final view = deriveAgentActivityView(
        AgentActivity(
          agents: [agentPresence()],
          recent: [agentEntry()],
          available: true,
        ),
        now: now,
        clockOffsetMs: 0,
      );
      expect(
        [for (final c in view.connected) (c.presence.clientName, c.working)],
        [('claude-code', false)],
      );
      expect(view.recent.single.createdAt, now.millisecondsSinceEpoch);
    },
  );

  test('the agents builders take every field', () {
    final t = DateTime(2026, 11, 11, 10).millisecondsSinceEpoch;
    final p = agentPresence(
      sessionId: 's9',
      clientName: 'cursor',
      clientVersion: null,
      transport: 'http',
      startedAt: t - 3,
      lastSeenAt: t - 2,
      lastRequestAt: t - 1,
      lastToolAt: t,
      expiresAt: t + 60000,
      embeddings: true,
    );
    expect(
      [
        p.sessionId,
        p.clientName,
        p.clientVersion,
        p.transport,
        p.startedAt,
        p.lastSeenAt,
        p.lastRequestAt,
        p.lastToolAt,
        p.expiresAt,
        p.embeddings,
      ],
      ['s9', 'cursor', null, 'http', t - 3, t - 2, t - 1, t, t + 60000, true],
    );
    final e = agentEntry(
      id: 'e9',
      sessionId: 's9',
      clientName: 'cursor',
      tool: 'tag_note',
      summary: 'tagged Plan #work',
      noteId: 'n9',
      createdAt: t,
    );
    expect(
      [
        e.id,
        e.sessionId,
        e.clientName,
        e.tool,
        e.summary,
        e.noteId,
        e.createdAt,
      ],
      ['e9', 's9', 'cursor', 'tag_note', 'tagged Plan #work', 'n9', t],
    );
  });
}
