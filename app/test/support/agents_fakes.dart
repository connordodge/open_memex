// WI #452 (390-A1): the AgentsAccess test doubles A4 (#455), A5 (#456) and
// #394 share (D14, D21).
//
// - [FakeAgentsAccess] extends LocalAgentsAccess: a queue of scripted
//   [AgentActivity] values or errors, a read count, and one read held in
//   flight until the test releases it.
// - [agentPresence] / [agentEntry]: model builders with defaults relative to
//   [agentsT0], the default FakeClock start, so a default presence is
//   connected and idle at the clock's start.
// - [agentsOverrides]: the ProviderScope overrides (the fake on the open
//   vault's access, FakeClock, window focus).
import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_memex_app/src/state/app_focus.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/agents_access.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import 'fake_clock.dart';
import 'poll_fakes.dart' show FakeAppFocus;

export 'poll_fakes.dart' show FakeAppFocus;

/// The vault path a [FakeAgentsAccess] reports by default.
const fakeAgentsVaultPath = '/fake/om-452-agents-vault';

/// The default `FakeClock()` start, ms epoch: the builders' time origin.
final int agentsT0 = FakeClock().now().millisecondsSinceEpoch;

/// A scripted [LocalAgentsAccess] (D21).
///
/// Each [activity] call counts in [reads] and takes the next scripted item:
/// an [AgentActivity] is returned, anything else is thrown. With the queue
/// empty it answers the last value it returned (the last pushed state), or
/// [AgentActivity] with no agents, no entries and `available: true` before
/// any value.
///
/// [holdNextRead] parks the next read in flight: it counts at once, but does
/// not take its scripted item or complete until [release].
class FakeAgentsAccess extends LocalAgentsAccess {
  FakeAgentsAccess({
    super.vaultPath = fakeAgentsVaultPath,
    Iterable<Object> script = const [],
  }) {
    _script.addAll(script);
  }

  final Queue<Object> _script = Queue();
  AgentActivity? _last;
  bool _holdNext = false;
  final Queue<Completer<void>> _held = Queue();

  /// How many times [activity] was called.
  int reads = 0;

  /// The last value [activity] returned, if any.
  AgentActivity? get lastReturned => _last;

  /// Scripted items not yet taken.
  int get pending => _script.length;

  /// True while any held read waits for [release].
  bool get holding => _held.isNotEmpty;

  /// Queue [value] as the result of a later read.
  void answer(AgentActivity value) => _script.add(value);

  /// Queue [error] to be thrown by a later read.
  void fail(Object error) => _script.add(error);

  /// Park the next read in flight until [release].
  void holdNextRead() => _holdNext = true;

  /// Let the oldest held read take its scripted item and complete. Reads
  /// held one after another are released one per call, oldest first.
  void release() {
    if (_held.isEmpty) throw StateError('FakeAgentsAccess: no read is held');
    _held.removeFirst().complete();
  }

  @override
  Future<AgentActivity> activity() async {
    reads++;
    if (_holdNext) {
      _holdNext = false;
      final gate = Completer<void>();
      _held.add(gate);
      await gate.future;
    }
    if (_script.isEmpty) {
      return _last ??= const AgentActivity(
        agents: [],
        recent: [],
        available: true,
      );
    }
    final next = _script.removeFirst();
    if (next is AgentActivity) return _last = next;
    throw next;
  }
}

/// An [AgentPresence] with defaults: started a minute before [agentsT0],
/// seen and requested at [agentsT0], no tool call, expiring 15 s later.
AgentPresence agentPresence({
  String sessionId = '01JAGENTSESSION0000000000A',
  String clientName = 'claude-code',
  String? clientVersion = '1.0.0',
  String transport = 'stdio',
  int? startedAt,
  int? lastSeenAt,
  int? lastRequestAt,
  int? lastToolAt,
  int? expiresAt,
  bool embeddings = false,
}) => AgentPresence(
  sessionId: sessionId,
  clientName: clientName,
  clientVersion: clientVersion,
  transport: transport,
  startedAt: startedAt ?? agentsT0 - 60000,
  lastSeenAt: lastSeenAt ?? agentsT0,
  lastRequestAt: lastRequestAt ?? agentsT0,
  lastToolAt: lastToolAt,
  expiresAt: expiresAt ?? agentsT0 + 15000,
  embeddings: embeddings,
);

/// An [AgentActivityEntry] with defaults, created at [agentsT0].
AgentActivityEntry agentEntry({
  String id = '01JAGENTENTRY00000000000A1',
  String sessionId = '01JAGENTSESSION0000000000A',
  String clientName = 'claude-code',
  String tool = 'add_excerpt',
  String summary = 'filed 4 blocks → Rest & Recharge',
  String? noteId,
  int? createdAt,
}) => AgentActivityEntry(
  id: id,
  sessionId: sessionId,
  clientName: clientName,
  tool: tool,
  summary: summary,
  noteId: noteId,
  createdAt: createdAt ?? agentsT0,
);

/// The overrides A4, A5 and #394 share: a local vault at [access]'s path is
/// open, its `VaultAccess` serves [access] as `agents`, [clock] (default a
/// new [FakeClock]) is the app clock, and the window is [focused]. The
/// vault db and memex cli are null; override `vaultDbProvider` and
/// `memexCliProvider` after these to give the other domains theirs.
List<Override> agentsOverrides({
  FakeAgentsAccess? access,
  FakeClock? clock,
  bool focused = true,
}) {
  final agents = access ?? FakeAgentsAccess();
  return [
    // The real `vaultAccessProvider` reads these two: null by default (the
    // providers throw unoverridden); a later override of either wins and
    // reaches every other domain on the access.
    vaultDbProvider.overrideWithValue(null),
    memexCliProvider.overrideWithValue(null),
    currentVaultProvider.overrideWith((_) => LocalVaultRef(agents.vaultPath)),
    vaultAccessProvider.overrideWith((ref) {
      final path = ref.watch(currentVaultProvider).localPath;
      if (path == null) return null;
      return LocalVaultAccess(
        vaultPath: path,
        db: ref.watch(vaultDbProvider),
        cli: ref.watch(memexCliProvider),
        agents: agents,
      );
    }),
    clockProvider.overrideWithValue(clock ?? FakeClock()),
    appFocusProvider.overrideWith(() => FakeAppFocus(focused)),
  ];
}
