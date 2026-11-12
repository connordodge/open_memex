import '../db.dart';
import '../vault_access/words_access.dart';

/// Learned-word reads (V7). Synchronous.
extension WordsReads on VaultDb {
  /// Every `learned_words` row, sorted by `word_key`. Empty when the table is
  /// missing (below V7); the table is probed on every call, never cached.
  List<LearnedWord> learnedWords() {
    if (!hasTables(const ['learned_words'])) return const [];
    return db
        .select('SELECT word, created_at FROM learned_words ORDER BY word_key')
        .map(
          (r) => LearnedWord(
            word: r['word'] as String,
            createdAt: (r['created_at'] as num).toInt(),
          ),
        )
        .toList();
  }
}
