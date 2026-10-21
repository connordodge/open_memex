import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../memex_cli.dart';
import 'app_focus.dart';
import 'clock.dart';
import 'editor_controller.dart';
import 'hosted_connection_state.dart';
import 'tabs_state.dart' show VirtualTodayTab;
import 'vault_access_state.dart';
import 'vault_state.dart';

/// One read of the open vault's opaque revision (D9).
typedef RevisionReader = Future<String> Function();

/// The revision-reader seam (WI #79, D15): the open vault's
/// `VaultAccess.revision` (`vaultAccessProvider`), or null when there is no
/// vault access to poll. The revision poller reads only through it.
final revisionReaderProvider = Provider<RevisionReader?>(
  (ref) => ref.watch(vaultAccessProvider)?.revision,
);

/// How often the revision is read while the window is focused (Req 23).
const _focusedInterval = Duration(seconds: 2);

/// How often the revision is read while the window is unfocused (Req 23).
const _unfocusedInterval = Duration(seconds: 30);

/// The vault-wide revision poller (WI #79, D15). Watching it starts polling
/// the open vault's revision on `clockProvider`; `Workspace.build` watches
/// it first.
///
/// - The first read is the baseline and bumps nothing.
/// - Then it reads every 2 s while [appFocusProvider] is true and every 30 s
///   while it is false, and once immediately when focus returns.
/// - At most one read is in flight; ticks while one is pending start
///   nothing, so changes coalesce into one bump.
/// - A changed revision hands the active stored note to
///   [EditorController.serverChanged] and bumps [vaultRevisionProvider]
///   exactly once, whatever `serverChanged` answers (D16: no echo
///   suppression; reloads are idempotent).
/// - A `MemexException` with code `unauthorized` stops polling until the
///   open vault server's [hostedConnectionStatusProvider] returns to
///   connected (the last seen revision is kept); `vault_not_found` stops it
///   for good (#96 handles "vault gone"); any other error keeps polling with
///   the baseline (polling is the retry).
///
/// A new vault rebuilds it with a fresh baseline and drops the old vault's
/// pending read; with no open vault (or no reader) it holds no timer.
final revisionPollerProvider = Provider.autoDispose<void>((ref) {
  final vault = ref.watch(currentVaultProvider);
  final reader = ref.watch(revisionReaderProvider);
  if (vault == null || reader == null) return;
  final poller = _RevisionPoller(ref, reader);
  ref.onDispose(poller._dispose);
  ref.listen<bool>(appFocusProvider, (_, focused) {
    poller._focusChanged(focused);
  });
  if (vault is HostedVaultRef) {
    ref.listen<HostedConnectionStatus?>(
      hostedConnectionStatusProvider(vault.serverId),
      (_, status) {
        if (status == HostedConnectionStatus.connected) poller._connected();
      },
    );
  }
  poller._start(ref.read(appFocusProvider));
});

/// Why polling stopped.
enum _Stop { unauthorized, vaultNotFound }

class _RevisionPoller {
  _RevisionPoller(this._ref, this._reader);

  final Ref _ref;
  final RevisionReader _reader;

  Timer? _timer;
  bool _focused = true;
  bool _inFlight = false;
  bool _disposed = false;

  /// Non-null while polling is stopped by an error.
  _Stop? _stop;

  /// The revision the last successful read saw; null before the baseline.
  String? _seen;

  void _start(bool focused) {
    _focused = focused;
    _run();
  }

  /// Schedules the periodic read at the current interval and reads once now.
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
          (_) => unawaited(_read()),
        );
  }

  void _focusChanged(bool focused) {
    final regained = focused && !_focused;
    _focused = focused;
    if (_stop != null) return;
    _schedule();
    if (regained) unawaited(_read());
  }

  void _connected() {
    if (_stop != _Stop.unauthorized) return;
    _stop = null;
    _run();
  }

  void _halt(_Stop why) {
    _stop = why;
    _timer?.cancel();
    _timer = null;
  }

  void _dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _read() async {
    if (_inFlight || _stop != null || _disposed) return;
    _inFlight = true;
    try {
      final revision = await _reader();
      if (!_disposed) _changed(revision);
    } on MemexException catch (e) {
      if (_disposed) return;
      switch (e.code) {
        case 'unauthorized':
          _halt(_Stop.unauthorized);
        case 'vault_not_found':
          _halt(_Stop.vaultNotFound);
      }
    } catch (_) {
      // Unreachable or anything else: keep polling; the next tick retries.
    } finally {
      _inFlight = false;
    }
  }

  void _changed(String revision) {
    final seen = _seen;
    _seen = revision;
    if (seen == null || seen == revision) return;
    try {
      final noteId = _ref.read(selectedNoteIdProvider);
      if (noteId != null && VirtualTodayTab.dateOf(noteId) == null) {
        // D16: the bump below never depends on the answer.
        unawaited(
          _ref.read(editorControllerProvider.notifier).serverChanged(noteId),
        );
      }
    } finally {
      _ref.read(vaultRevisionProvider.notifier).state++;
    }
  }
}
