// WI #432 (Spec #392 req 15b, D21): the shared WordsAccess test double. It
// extends LocalWordsAccess, so it is passed to `LocalVaultAccess(words: …)`.
//
// - Scripted mode ([words] non-null): `list`, `learn` and `unlearn` work on
//   that in-memory list, keyed by Dart `toLowerCase()` like `word_key`.
//   Without [words] every call goes to the real LocalWordsAccess ([db],
//   [cli]).
// - [learnError] / [unlearnError]: thrown by the next and every later call
//   (recorded first) instead of writing.
// - [holdLists] / [holdLearns] / [holdUnlearns]: calls wait until
//   [releaseLists] / [releaseLearns] / [releaseUnlearns].
// - Every call is recorded in [listCalls], [learnCalls] and [unlearnCalls].
import 'dart:async';

import 'package:open_memex_app/src/vault_access/local/words.dart';
import 'package:open_memex_app/src/vault_access/words_access.dart';

class FakeWordsAccess extends LocalWordsAccess {
  FakeWordsAccess({
    required super.vaultPath,
    super.db,
    super.cli,
    List<LearnedWord>? words,
  }) : words = words == null ? null : List.of(words);

  /// The scripted learned words, in the order `list` answers them; null to
  /// read through the real LocalWordsAccess.
  List<LearnedWord>? words;

  /// Thrown by `learn` / `unlearn` (after recording the call) while set.
  Object? learnError;
  Object? unlearnError;

  /// The `createdAt` scripted learns stamp.
  int learnedAt = 1792539488433;

  int listCalls = 0;
  final List<String> learnCalls = [];
  final List<String> unlearnCalls = [];

  bool holdLists = false;
  bool holdLearns = false;
  bool holdUnlearns = false;
  Completer<void> _listGate = Completer<void>();
  Completer<void> _learnGate = Completer<void>();
  Completer<void> _unlearnGate = Completer<void>();

  void releaseLists() {
    holdLists = false;
    if (!_listGate.isCompleted) _listGate.complete();
    _listGate = Completer<void>();
  }

  void releaseLearns() {
    holdLearns = false;
    if (!_learnGate.isCompleted) _learnGate.complete();
    _learnGate = Completer<void>();
  }

  void releaseUnlearns() {
    holdUnlearns = false;
    if (!_unlearnGate.isCompleted) _unlearnGate.complete();
    _unlearnGate = Completer<void>();
  }

  /// Replaces the scripted words with [plain], each stamped [learnedAt].
  void script(List<String> plain) => words = [
    for (final w in plain) LearnedWord(word: w, createdAt: learnedAt),
  ];

  @override
  Future<List<LearnedWord>> list() async {
    listCalls++;
    if (holdLists) await _listGate.future;
    final scripted = words;
    if (scripted == null) return super.list();
    return List.unmodifiable(scripted);
  }

  @override
  Future<WordWriteResult> learn(String word) async {
    learnCalls.add(word);
    if (holdLearns) await _learnGate.future;
    final error = learnError;
    if (error != null) throw error;
    final scripted = words;
    if (scripted == null) return super.learn(word);
    final key = word.toLowerCase();
    final present = scripted.any((w) => w.word.toLowerCase() == key);
    if (!present) scripted.add(LearnedWord(word: word, createdAt: learnedAt));
    return WordWriteResult(word: word, changed: !present);
  }

  @override
  Future<WordWriteResult> unlearn(String word) async {
    unlearnCalls.add(word);
    if (holdUnlearns) await _unlearnGate.future;
    final error = unlearnError;
    if (error != null) throw error;
    final scripted = words;
    if (scripted == null) return super.unlearn(word);
    final key = word.toLowerCase();
    final before = scripted.length;
    scripted.removeWhere((w) => w.word.toLowerCase() == key);
    return WordWriteResult(word: word, changed: scripted.length != before);
  }
}
