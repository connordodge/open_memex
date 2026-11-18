// WI #78 (56-A4, Spec #59 req 31, TD4, TD9): the Command palette's model
// download, kept per vault outside the palette's own state.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'vault_ref.dart';

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
  @override
  SearchModelDownloadStatus build(VaultRef arg) =>
      SearchModelDownloadStatus.idle;

  /// The `Download model (130 MB)` button: runs `search([query],
  /// allowDownload: true)` once; does nothing while a download runs.
  void start(String query) {}
}

final searchModelDownloadProvider =
    NotifierProvider.family<
      SearchModelDownloadNotifier,
      SearchModelDownloadStatus,
      VaultRef
    >(SearchModelDownloadNotifier.new);
