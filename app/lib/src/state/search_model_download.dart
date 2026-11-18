// WI #78 (56-A4, Spec #59 req 31, TD4, TD9): the Command palette's model
// download, kept per vault outside the palette's own state.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../vault_access/search_access.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// Where a vault's palette model download stands.
enum SearchModelDownloadStatus {
  /// No palette download has run for this vault.
  idle,

  /// `search(<input>, allowDownload: true)` is running.
  downloading,

  /// The download answered anything but `semantic: on`, threw or timed out.
  failed,

  /// The download answered `semantic: on`.
  succeeded,
}

/// The palette's model download for one vault (req 31): non-autoDispose, so
/// closing the palette never cancels it. It doesn't touch the Echoes tab's
/// download state.
class SearchModelDownloadNotifier
    extends FamilyNotifier<SearchModelDownloadStatus, VaultRef> {
  var _disposed = false;

  @override
  SearchModelDownloadStatus build(VaultRef arg) {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return SearchModelDownloadStatus.idle;
  }

  /// The `Download model (130 MB)` button: runs `search([query],
  /// allowDownload: true)` once; does nothing while a download runs, or when
  /// [arg] is not the open vault. The search's own timeout (10 min for a
  /// download) ends it as a failure.
  void start(String query) {
    if (state == SearchModelDownloadStatus.downloading) return;
    if (ref.read(currentVaultProvider) != arg) return;
    final search = ref.read(vaultAccessProvider)?.search;
    if (search == null) return;
    state = SearchModelDownloadStatus.downloading;
    _run(search, query);
  }

  Future<void> _run(SearchAccess search, String query) async {
    SearchModelDownloadStatus outcome;
    try {
      final result = await search.search(query, allowDownload: true);
      outcome = result is SearchReady && result.semantic == Semantic.on
          ? SearchModelDownloadStatus.succeeded
          : SearchModelDownloadStatus.failed;
    } catch (_) {
      outcome = SearchModelDownloadStatus.failed;
    }
    if (!_disposed) state = outcome;
  }
}

final searchModelDownloadProvider =
    NotifierProvider.family<
      SearchModelDownloadNotifier,
      SearchModelDownloadStatus,
      VaultRef
    >(SearchModelDownloadNotifier.new);
