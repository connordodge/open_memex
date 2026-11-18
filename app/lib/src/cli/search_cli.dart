// WI #74 (56-A1): `memex search` through [MemexCli] and its answer's mapping
// to a [SearchResult].
import '../memex_cli.dart';
import '../vault_access/search_access.dart';

/// How long `memex search` may run (req 39).
const searchTimeout = Duration(seconds: 60);

/// How long `memex search --allow-download` may run: it fetches the model.
const searchDownloadTimeout = Duration(minutes: 10);

extension SearchCli on MemexCli {
  /// `memex search --vault <vaultPath> --query <query>`, plus
  /// `--allow-download` when [allowDownload] (no `--limit`).
  // TODO(#74): skeleton only.
  Future<SearchResult> search({
    required String vaultPath,
    required String query,
    bool allowDownload = false,
  }) async =>
      const SearchReady([], semantic: Semantic.unknown, truncated: false);
}
