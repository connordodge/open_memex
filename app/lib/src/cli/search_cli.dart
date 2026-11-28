// WI #74 (56-A1): `memex search` through [MemexCli] and its answer's mapping
// to a [SearchResult].
import 'dart:convert';

import '../memex_cli.dart';
import '../vault_access/search_access.dart';

/// How long `memex search` may run (req 39).
const searchTimeout = Duration(seconds: 60);

/// How long `memex search --allow-download` may run: it fetches the model.
const searchDownloadTimeout = Duration(minutes: 10);

extension SearchCli on MemexCli {
  /// `memex search --vault <vaultPath> --query <query>`, plus
  /// `--allow-download` when [allowDownload] (no `--limit`: the CLI's default
  /// applies). Exit 0 is [SearchReady]; exit 2 with non-JSON stderr is
  /// [MemexOutdated] (a `memex` that predates the subcommand). A
  /// [MemexCliTimeout] reaches the caller; every other failure throws
  /// [MemexException], with the C1 code when stderr carries one, and so does
  /// an exit-0 answer that is not a search answer.
  Future<SearchResult> search({
    required String vaultPath,
    required String query,
    bool allowDownload = false,
  }) async {
    final r = await run([
      'search',
      '--vault',
      vaultPath,
      '--query',
      query,
      if (allowDownload) '--allow-download',
    ], timeout: allowDownload ? searchDownloadTimeout : searchTimeout);
    if (r.exitCode == 0) {
      final Object? decoded;
      try {
        decoded = jsonDecode(r.stdout);
      } on FormatException {
        throw MemexException(
          'search failed: memex search printed output the app cannot read',
        );
      }
      return searchReadyFromJson(decoded);
    }
    final failure = MemexException.fromCliFailure('search', r);
    if (failure.code == null && r.exitCode == 2) {
      return const SearchUnavailable(MemexOutdated());
    }
    throw failure;
  }
}
