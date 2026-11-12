import '../../memex_cli.dart';
import '../words_access.dart';
import 'hosted_client.dart';

/// [WordsAccess] for a hosted vault: `GET`/`POST /words` and
/// `DELETE /words/{word}` through [client] (D17), with `{word}`
/// percent-encoded into one path segment. A response that is not the
/// contract shape throws a null-code [MemexException]. Writes leave
/// `vaultRevisionProvider` to their callers.
///
/// An older server without these routes answers C1 `not_found` (req 15b,
/// the `hosted/backup.dart` idiom; the message is never matched): [list]
/// then reads as no learned words, and [learn] and [unlearn] throw it. Every
/// other refusal, `vault_not_found` included, throws.
class HostedWordsAccess implements WordsAccess {
  HostedWordsAccess({required this.client, required this.vaultName});

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

  /// `GET /words`, in the server's `word_key` order.
  @override
  Future<List<LearnedWord>> list() async {
    const op = 'words';
    final Map<String, Object?> json;
    try {
      json = await client.vaultRequest(
        'GET',
        vaultName,
        '/words',
        operation: op,
      );
    } on MemexException catch (e) {
      if (e.code == 'not_found') return const [];
      rethrow;
    }
    final list = json['words'];
    if (list is List) {
      final words = <LearnedWord>[];
      for (final r in list) {
        if (r case {'word': final String word, 'created_at': final int at}) {
          words.add(LearnedWord(word: word, createdAt: at));
        } else {
          break;
        }
      }
      if (words.length == list.length) return words;
    }
    throw MemexException('$op: could not parse output: $json');
  }

  /// `POST /words` with `{"word": word}`.
  @override
  Future<WordWriteResult> learn(String word) =>
      _write('POST', '/words', 'words add', body: {'word': word});

  /// `DELETE /words/{word}` (no body).
  ///
  /// A word of `.` or `..` throws a null-code [MemexException] and sends
  /// nothing: as a path segment the client's `Uri.parse` would drop it as a
  /// dot segment (escaped or not) and send the DELETE to another route.
  @override
  Future<WordWriteResult> unlearn(String word) async {
    if (word == '.' || word == '..') {
      throw MemexException(
        'words rm failed: "$word" cannot be removed from a hosted vault.',
      );
    }
    return _write('DELETE', '/words/${Uri.encodeComponent(word)}', 'words rm');
  }

  Future<WordWriteResult> _write(
    String method,
    String path,
    String op, {
    Object? body,
  }) async {
    final json = await client.vaultRequest(
      method,
      vaultName,
      path,
      operation: op,
      body: body,
    );
    final result = parseWordWriteResult(json);
    if (result == null) {
      throw MemexException('$op: could not parse output: $json');
    }
    return result;
  }
}
