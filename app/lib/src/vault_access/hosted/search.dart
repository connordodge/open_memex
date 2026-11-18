import '../../memex_cli.dart';
import '../search_access.dart';
import 'hosted_client.dart';

/// How long a hosted search waits for the vault server (Spec #59 req 39).
const hostedSearchTimeout = Duration(seconds: 60);

/// The vault server's answer to a route it does not have: a released
/// server without the search route (req 38).
const _noRouteMessage = 'not found: no route for this path';

/// [SearchAccess] for a hosted vault: `GET /search?q=<query>&limit=8`
/// through [client] for [vaultName] (Spec #59 req 37, 39), waiting up to
/// 60 s.
///
/// A `not_found` with exactly the no-route message answers
/// [SearchUnavailable] with [ServerOutdated]. Every other error, a
/// [HostedRequestTimeout] included, is thrown to the caller.
class HostedSearchAccess implements SearchAccess {
  HostedSearchAccess({required this.client, required this.vaultName});

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

  /// [allowDownload] is ignored: a hosted server never downloads for the
  /// app.
  @override
  Future<SearchResult> search(
    String query, {
    bool allowDownload = false,
  }) async {
    final Map<String, Object?> body;
    try {
      body = await client.vaultRequest(
        'GET',
        vaultName,
        '/search',
        operation: 'search',
        query: {'q': query, 'limit': '8'},
        timeout: hostedSearchTimeout,
      );
    } on MemexException catch (e) {
      if (e.code == 'not_found' &&
          e.message == 'search failed: $_noRouteMessage') {
        return const SearchUnavailable(ServerOutdated());
      }
      rethrow;
    }
    return searchReadyFromJson(body);
  }
}
