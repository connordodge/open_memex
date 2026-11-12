// #424 (391-A0): test doubles for the echoes seam. A1-A5 build on them.
import 'dart:async';

import 'package:open_memex_app/src/state/echo_link_actions.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';

/// One recorded [FakeEchoesAccess.echoes] call.
class FakeEchoesCall {
  FakeEchoesCall(this.noteId, {required this.allowDownload});

  final String noteId;
  final bool allowDownload;

  /// True once the call has answered (returned or thrown).
  bool get finished => _finished;
  bool _finished = false;

  @override
  String toString() => 'FakeEchoesCall($noteId, allowDownload: $allowDownload)';
}

/// An echoes domain that answers scripted results (D21: it extends the
/// local class, so it is passed to `LocalVaultAccess(echoes:)`).
///
/// Each call takes the next [enqueue]d answer, or [result] once the queue is
/// empty. An answer that is an [EchoesResult] is returned; anything else is
/// thrown. The answer is picked when the call starts, so calls answer in the
/// order they were made. While [gate] is set, a call waits for the gate it
/// saw when it started: set a fresh `Completer` before each call to release
/// runs one at a time.
class FakeEchoesAccess extends LocalEchoesAccess {
  FakeEchoesAccess({
    EchoesResult? result,
    super.vaultPath = '/fake-echoes-vault',
    super.cli,
  }) : result = result ?? const EchoesReady([], emptyNote: false, pending: 0);

  /// The answer once the queue is empty.
  EchoesResult result;

  /// Holds calls that start while it is set until it completes.
  Completer<void>? gate;

  final List<Object> _queue = [];

  /// Every call, in order.
  final List<FakeEchoesCall> calls = [];

  /// Calls that started and have not answered yet.
  int get inFlight => calls.where((c) => !c.finished).length;

  /// Queue [answer] (an [EchoesResult] to return, or an error to throw) for
  /// the next call that finds the queue non-empty.
  void enqueue(Object answer) => _queue.add(answer);

  @override
  Future<EchoesResult> echoes(
    String noteId, {
    bool allowDownload = false,
  }) async {
    final call = FakeEchoesCall(noteId, allowDownload: allowDownload);
    calls.add(call);
    final answer = _queue.isEmpty ? result : _queue.removeAt(0);
    final held = gate;
    try {
      if (held != null) await held.future;
      if (answer is EchoesResult) return answer;
      throw answer;
    } finally {
      call._finished = true;
    }
  }
}

/// One recorded [FakeEchoLinkActions.link] call.
class FakeEchoLinkCall {
  const FakeEchoLinkCall({
    required this.openNoteId,
    required this.echo,
    required this.plan,
  });

  final String openNoteId;
  final Echo echo;
  final EchoLinkPlan plan;

  @override
  String toString() => 'FakeEchoLinkCall($openNoteId, ${echo.noteId}, $plan)';
}

/// Records every `link` call. While [gate] is set, a call waits for the gate
/// it saw when it started; then it throws [failure] when one is set, else
/// completes.
class FakeEchoLinkActions implements EchoLinkActions {
  FakeEchoLinkActions({this.failure});

  /// Thrown by each call once its gate opens; null completes normally.
  Object? failure;

  /// Holds calls that start while it is set until it completes.
  Completer<void>? gate;

  /// Every call, in order.
  final List<FakeEchoLinkCall> calls = [];

  @override
  Future<void> link({
    required String openNoteId,
    required Echo echo,
    required EchoLinkPlan plan,
  }) async {
    calls.add(FakeEchoLinkCall(openNoteId: openNoteId, echo: echo, plan: plan));
    final held = gate;
    if (held != null) await held.future;
    final error = failure;
    if (error != null) throw error;
  }
}
