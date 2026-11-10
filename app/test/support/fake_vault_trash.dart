// WI #348: a fake Trash seam. Records every path, answers from a queue
// (default Trashed), and can hold the next call so a widget test can observe
// the busy state.
import 'dart:async';

import 'package:open_memex_app/src/state/vault_trash.dart';

class FakeVaultTrash implements VaultTrash {
  /// Every path passed to [trash], in order.
  final List<String> calls = [];

  final List<TrashResult> _results = [];
  final List<Completer<TrashResult>> _holds = [];

  /// Queues [result] for a later call; calls past the queue get [Trashed].
  void answer(TrashResult result) => _results.add(result);

  /// Holds the next call until [completer] completes; it then returns the
  /// completer's result.
  void hold(Completer<TrashResult> completer) => _holds.add(completer);

  @override
  Future<TrashResult> trash(String path) {
    calls.add(path);
    if (_holds.isNotEmpty) return _holds.removeAt(0).future;
    return Future.value(
      _results.isEmpty ? const Trashed() : _results.removeAt(0),
    );
  }
}
