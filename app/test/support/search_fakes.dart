// #74 (56-A1): the test double for the search seam. #76-#78 build on it.
import 'dart:async';

import 'package:open_memex_app/src/vault_access/vault_access.dart';

/// One recorded [FakeSearchAccess.search] call.
class FakeSearchCall {
  FakeSearchCall(this.query, {required this.allowDownload});

  final String query;
  final bool allowDownload;

  /// True once the call has answered (returned or thrown).
  bool get finished => _finished;
  bool _finished = false;

  @override
  String toString() => 'FakeSearchCall($query, allowDownload: $allowDownload)';
}

/// A search domain that answers scripted results (D21: it extends the local
/// class, so it is passed to `LocalVaultAccess(search:)`).
///
/// Each call takes the next [enqueue]d answer, or [result] once the queue is
/// empty. An answer that is a [SearchResult] is returned; anything else is
/// thrown. The answer is picked when the call starts, so calls answer in the
/// order they were made. While [gate] is set, a call waits for the gate it
/// saw when it started: set a fresh `Completer` before each call to release
/// runs one at a time.
class FakeSearchAccess extends LocalSearchAccess {
  FakeSearchAccess({
    SearchResult? result,
    super.vaultPath = '/vaults/Fake Search',
    super.cli,
  }) : result =
           result ??
           const SearchReady([], semantic: Semantic.on, truncated: false);

  /// The answer once the queue is empty.
  SearchResult result;

  /// Holds calls that start while it is set until it completes.
  Completer<void>? gate;

  final List<Object> _queue = [];

  /// Every call, in order.
  final List<FakeSearchCall> calls = [];

  /// Calls that started and have not answered yet.
  int get inFlight => calls.where((c) => !c.finished).length;

  /// Queue [answer] (a [SearchResult] to return, or an error to throw) for
  /// the next call that finds the queue non-empty.
  void enqueue(Object answer) => _queue.add(answer);

  @override
  Future<SearchResult> search(
    String query, {
    bool allowDownload = false,
  }) async {
    final call = FakeSearchCall(query, allowDownload: allowDownload);
    calls.add(call);
    final answer = _queue.isEmpty ? result : _queue.removeAt(0);
    final held = gate;
    try {
      if (held != null) await held.future;
      if (answer is SearchResult) return answer;
      throw answer;
    } finally {
      call._finished = true;
    }
  }
}
