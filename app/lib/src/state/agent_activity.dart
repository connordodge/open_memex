import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../memex_cli.dart';
import '../vault_access/agents_access.dart';
import 'app_focus.dart';
import 'clock.dart';
import 'hosted_connection_state.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// One connected (unexpired) agent and whether it is working (#390 req 20,
/// D1). #394 reads [working] and never re-derives it (D14).
class ConnectedAgent {
  const ConnectedAgent({required this.presence, required this.working});

  final AgentPresence presence;
  final bool working;
}

/// The derived view of the open vault's agents (#390 req 14a, D14).
class AgentActivityView {
  const AgentActivityView({
    required this.connected,
    required this.recent,
    required this.available,
    required this.clockOffsetMs,
  });

  /// Unexpired agents, by `lastRequestAt` descending.
  final List<ConnectedAgent> connected;

  /// As read: newest first, up to 20.
  final List<AgentActivityEntry> recent;
  final bool available;

  /// `serverNow − receivedAt`; 0 for a local vault.
  final int clockOffsetMs;

  /// A server timestamp on the local clock.
  int localMs(int serverMs) => serverMs - clockOffsetMs;

  /// No agents, no entries, available, offset 0.
  static const empty = AgentActivityView(
    connected: [],
    recent: [],
    available: true,
    clockOffsetMs: 0,
  );
}

/// [activity] at [now] (#390 req 14a, 20): expired records left out,
/// `working` per D1, `recent` and `available` passed through.
AgentActivityView deriveAgentActivityView(
  AgentActivity activity, {
  required DateTime now,
  required int clockOffsetMs,
}) {
  final nowMs = now.millisecondsSinceEpoch;
  int localMs(int serverMs) => serverMs - clockOffsetMs;
  final live = [
    for (final p in activity.agents)
      if (nowMs < localMs(p.expiresAt)) p,
  ]..sort((a, b) => b.lastRequestAt.compareTo(a.lastRequestAt));
  return AgentActivityView(
    connected: [
      for (final p in live)
        ConnectedAgent(
          presence: p,
          // D1: only a tool call in the last 10 s; requests never count.
          working:
              p.lastToolAt != null &&
              nowMs - localMs(p.lastToolAt!) < _workingWindowMs,
        ),
    ],
    recent: activity.recent,
    available: activity.available,
    clockOffsetMs: clockOffsetMs,
  );
}

/// How long after its last tool call an agent counts as working (D1).
const _workingWindowMs = 10000;

/// The open vault's live agents view (#390 req 18). A4 (#455) implements the
/// notifier; #394 watches it (D14).
///
/// Seam convention (D14): after a vault switch it is `AsyncLoading` with
/// `isRefreshing` false, and Riverpod may keep the old vault's view in
/// `value` until the new vault's first read lands. Every consumer branches
/// on `isLoading`, or on `when`/`switch` with the default
/// `skipLoadingOnReload: false`, and never renders from `valueOrNull` or
/// `hasValue` alone. With no vault open the value is
/// [AgentActivityView.empty].
final agentActivityAsyncProvider =
    AsyncNotifierProvider<AgentActivityNotifier, AgentActivityView>(
      AgentActivityNotifier.new,
    );

/// Keeps [agentActivityAsyncProvider] live (#390 req 14a, 17, 18, 25, 26, 29;
/// D4, D14, D24).
///
/// - It reads the open vault's `VaultAccess.agents.activity()` once when it
///   builds, on every [vaultRevisionProvider] change and on its presence
///   tick: every 2 s while [appFocusProvider] is true and every 30 s while it
///   is false, through [clockProvider], re-armed on a focus change.
/// - At most one read is in flight; a tick or revision change during a read
///   is dropped, not queued.
/// - Every tick re-derives the last good activity at `clock.now()`, so
///   expiry and `working` move while a read is held or failing.
/// - A read with `serverNow` sets `clockOffsetMs` to `serverNow` minus
///   `clock.now()` when the response arrived; without it the offset is 0.
/// - It is `AsyncLoading` until the first read completes and never
///   `AsyncError`: a failed read keeps the last good value, or gives
///   [AgentActivityView.empty] when there is none.
/// - A `MemexException` with code `vault_not_found` stops reads for good;
///   `unauthorized` stops them until the open vault server's
///   [hostedConnectionStatusProvider] turns connected, then it reads at once
///   (as `revisionPollerProvider`). While reads are stopped the tick keeps
///   re-deriving the last good activity, so expired agents still drop out
///   and `working` still turns off.
/// - A new [currentVaultProvider] value rebuilds it: back to `AsyncLoading`
///   with `isRefreshing` false, the old vault's pending read dropped; with
///   no vault open it holds no timer. Riverpod 2 copies the previous value
///   onto that `AsyncLoading`, so until the new vault's first read lands
///   `value`, `valueOrNull` and `hasValue` still describe the old vault.
///   Consumers follow the seam convention on [agentActivityAsyncProvider]:
///   branch on `isLoading` or `when` (default flags) and never render from
///   `valueOrNull` or `hasValue` alone.
/// - It never writes [vaultRevisionProvider].
class AgentActivityNotifier extends AsyncNotifier<AgentActivityView> {
  @override
  FutureOr<AgentActivityView> build() {
    final vault = ref.watch(currentVaultProvider);
    if (vault == null) return AgentActivityView.empty;
    final poll = _AgentActivityPoll(ref, vault, _publish);
    ref.onDispose(poll._dispose);
    ref.listen<bool>(appFocusProvider, (_, focused) {
      poll._focusChanged(focused);
    });
    ref.listen<int>(vaultRevisionProvider, (_, _) {
      unawaited(poll._read());
    });
    if (vault is HostedVaultRef) {
      ref.listen<HostedConnectionStatus?>(
        hostedConnectionStatusProvider(vault.serverId),
        (_, status) {
          if (status == HostedConnectionStatus.connected) poll._connected();
        },
      );
    }
    poll._start(ref.read(appFocusProvider));
    return poll._first.future;
  }

  void _publish(AgentActivityView view) => state = AsyncData(view);
}

/// How often the presence tick runs while the window is focused (req 18).
const _focusedInterval = Duration(seconds: 2);

/// How often the presence tick runs while the window is unfocused (req 18).
const _unfocusedInterval = Duration(seconds: 30);

/// Why reads stopped (req 17).
enum _Stop { unauthorized, vaultNotFound }

/// One open vault's reads and presence tick; a rebuild disposes it.
class _AgentActivityPoll {
  _AgentActivityPoll(this._ref, this._vault, this._onView);

  final Ref _ref;
  final VaultRef _vault;
  final void Function(AgentActivityView view) _onView;

  /// Completes with the first read's view (empty when it fails): the
  /// provider's build value.
  final Completer<AgentActivityView> _first = Completer();

  Timer? _timer;
  bool _focused = true;
  bool _inFlight = false;
  bool _disposed = false;

  /// Non-null while reads are stopped by an error.
  _Stop? _stop;

  /// The last successful read and its clock offset.
  AgentActivity? _last;
  int _offsetMs = 0;

  void _start(bool focused) {
    _focused = focused;
    _run();
  }

  /// Schedules the tick at the current interval and reads once now.
  void _run() {
    _schedule();
    unawaited(_read());
  }

  void _schedule() {
    _timer?.cancel();
    _timer = _ref
        .read(clockProvider)
        .periodic(
          _focused ? _focusedInterval : _unfocusedInterval,
          (_) => _tick(),
        );
  }

  void _tick() {
    final last = _last;
    if (last != null && !_disposed) {
      _publish(
        deriveAgentActivityView(
          last,
          now: _ref.read(clockProvider).now(),
          clockOffsetMs: _offsetMs,
        ),
      );
    }
    unawaited(_read());
  }

  /// Re-arms the tick at the new interval; a stopped tick keeps
  /// re-deriving, and [_read] skips while stopped.
  void _focusChanged(bool focused) {
    final regained = focused && !_focused;
    _focused = focused;
    if (_disposed) return;
    _schedule();
    if (regained) unawaited(_read());
  }

  void _connected() {
    if (_stop != _Stop.unauthorized || _disposed) return;
    _stop = null;
    _run();
  }

  /// Stops reads. The tick keeps running so [_tick] still re-derives the
  /// last good activity (req 14a, 18, 22).
  void _halt(_Stop why) => _stop = why;

  void _dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  /// The view for the provider: the build value until the first read
  /// completes, then a new state.
  void _publish(AgentActivityView view) {
    if (_first.isCompleted) {
      _onView(view);
    } else {
      _first.complete(view);
    }
  }

  Future<void> _read() async {
    if (_inFlight || _stop != null || _disposed) return;
    // A revision change can land before the switch rebuilds this poll.
    if (_ref.read(currentVaultProvider) != _vault) return;
    final access = _ref.read(vaultAccessProvider);
    if (access == null) return;
    _inFlight = true;
    try {
      final activity = await access.agents.activity();
      if (_disposed) return;
      final now = _ref.read(clockProvider).now();
      final serverNow = activity.serverNow;
      _offsetMs = serverNow == null
          ? 0
          : serverNow - now.millisecondsSinceEpoch;
      _last = activity;
      _publish(
        deriveAgentActivityView(activity, now: now, clockOffsetMs: _offsetMs),
      );
    } on MemexException catch (e) {
      if (_disposed) return;
      switch (e.code) {
        case 'unauthorized':
          _halt(_Stop.unauthorized);
        case 'vault_not_found':
          _halt(_Stop.vaultNotFound);
      }
      _failed();
    } catch (_) {
      // Unreachable or anything else: keep the last good value; the next
      // tick retries.
      if (!_disposed) _failed();
    } finally {
      _inFlight = false;
    }
  }

  /// A failed read: the first one settles the build value as empty (req 26:
  /// no last good value); later ones change nothing.
  void _failed() {
    if (!_first.isCompleted) _first.complete(AgentActivityView.empty);
  }
}
