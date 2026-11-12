import '../../cli/words_cli.dart';
import '../../db.dart';
import '../../db/words_reads.dart';
import '../../memex_cli.dart';
import '../words_access.dart';
import 'write_guard.dart';

/// [WordsAccess] for a local vault: reads `learned_words` from [db], writes
/// through [cli] with `--vault` [vaultPath] (D13). Either may be null: no
/// [db] reads as no learned words, and with no [cli] a write throws
/// [StateError] before anything runs.
class LocalWordsAccess implements WordsAccess {
  LocalWordsAccess({required this.vaultPath, this.db, this.cli});

  final String vaultPath;
  final VaultDb? db;
  final MemexCli? cli;

  @override
  Future<List<LearnedWord>> list() async => db?.learnedWords() ?? const [];

  @override
  Future<WordWriteResult> learn(String word) async =>
      requireLocalCli(cli).wordsAdd(vaultPath: vaultPath, word: word);

  @override
  Future<WordWriteResult> unlearn(String word) async =>
      requireLocalCli(cli).wordsRm(vaultPath: vaultPath, word: word);
}
