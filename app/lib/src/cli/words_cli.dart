import 'dart:convert';

import '../memex_cli.dart';
import '../vault_access/words_access.dart';

/// `memex words add|rm` wrappers (Spec #392 req 16, D22).
extension WordsCli on MemexCli {
  /// `memex words add --vault <vaultPath> --word <word>`.
  ///
  /// Stdout is `{"vault_id":…,"word":…,"changed":<bool>}`. A CLI failure
  /// (a clap exit 2 from a `memex` without `words` included) throws
  /// [MemexException.fromCliFailure], with the C1 `code` when stderr has one
  /// (e.g. `word_invalid`); stdout without a string `word` and a bool
  /// `changed` throws a [MemexException] with a null code.
  Future<WordWriteResult> wordsAdd({
    required String vaultPath,
    required String word,
  }) => _wordsCall('add', vaultPath, word);

  /// `memex words rm --vault <vaultPath> --word <word>`, with the stdout and
  /// failures of [wordsAdd].
  Future<WordWriteResult> wordsRm({
    required String vaultPath,
    required String word,
  }) => _wordsCall('rm', vaultPath, word);

  Future<WordWriteResult> _wordsCall(
    String sub,
    String vaultPath,
    String word,
  ) async {
    final r = await run(['words', sub, '--vault', vaultPath, '--word', word]);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('words $sub', r);
    }
    Object? json;
    try {
      json = jsonDecode(r.stdout.trim());
    } on FormatException {
      json = null;
    }
    final result = parseWordWriteResult(json);
    if (result == null) {
      throw MemexException('words $sub: could not parse output: ${r.stdout}');
    }
    return result;
  }
}
