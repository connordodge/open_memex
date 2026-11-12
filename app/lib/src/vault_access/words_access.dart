// WI #432 (Spec #392 req 15b): the learned-words domain on `VaultAccess`.

/// One learned word: [word] as first written (trimmed) and [createdAt], when
/// it was learned, in unix ms.
class LearnedWord {
  const LearnedWord({required this.word, required this.createdAt});

  final String word;
  final int createdAt;
}

/// The result of a learn or unlearn: the trimmed [word] and whether a row
/// was inserted or deleted ([changed]).
class WordWriteResult {
  const WordWriteResult({required this.word, required this.changed});

  final String word;
  final bool changed;
}

/// The `{vault_id, word, changed}` reply of `memex words add|rm` and of
/// `POST /words` / `DELETE /words/{word}`; null when [json] is not an object
/// with a string `word` and a bool `changed`.
WordWriteResult? parseWordWriteResult(Object? json) {
  if (json case {'word': final String word, 'changed': final bool changed}) {
    return WordWriteResult(word: word, changed: changed);
  }
  return null;
}

/// The open vault's learned words (Spec #392 req 14, 15b).
///
/// Test doubles `extends LocalWordsAccess` (D21).
abstract interface class WordsAccess {
  /// Every learned word, sorted by `word_key`.
  Future<List<LearnedWord>> list();

  /// `memex words add` / `POST /words`.
  Future<WordWriteResult> learn(String word);

  /// `memex words rm` / `DELETE /words/{word}`.
  Future<WordWriteResult> unlearn(String word);
}
