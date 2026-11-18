import '../search_access.dart';
import 'hosted_client.dart';

/// [SearchAccess] for a hosted vault: `GET /search?q=<query>&limit=8`
/// through [client] for [vaultName] (Spec #59 req 37, 39), waiting up to
/// 60 s.
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
  }) async =>
      // Skeleton (#75 red): no behavior yet.
      const SearchReady([], semantic: Semantic.unknown, truncated: false);
}
