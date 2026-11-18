import 'package:http/http.dart' as http;

import 'appcast.dart';
import 'update_state.dart';

/// The only thing an updater port throws (D1): the [cause] the controller
/// shows, plus the not-writable [folder] or the recorded marker [reason]
/// where the cause needs one. Fillers map every IO exception to one of
/// these, so the controller never sees a `dart:io` type.
class UpdateFailure implements Exception {
  const UpdateFailure(this.cause, {this.folder, this.reason});

  final UpdateErrorCause cause;

  /// The folder that is not writable ([UpdateErrorCause.folderNotWritable]).
  final String? folder;

  /// The marker reason ([UpdateErrorCause.failureRecorded]).
  final String? reason;

  @override
  String toString() => 'UpdateFailure(${cause.name})';
}

/// Fetches and parses the Appcast (A1).
abstract interface class AppcastFetcher {
  /// The Appcast's items, parsed with `parseAppcast`. Throws [UpdateFailure]
  /// with [UpdateErrorCause.offline], [UpdateErrorCause.noAppcast] (HTTP 404)
  /// or [UpdateErrorCause.feedUnreadable] (other non-2xx, malformed feed).
  Future<List<AppcastItem>> fetch();
}

/// Downloads an item's DMG into the update download directory (A1).
abstract interface class UpdateDownloader {
  /// Downloads [item]'s enclosure and returns the downloaded file's path.
  /// Calls [onProgress] with the fraction done in `0..1`, or null when the
  /// length is unknown. Throws [UpdateFailure] with
  /// [UpdateErrorCause.downloadFailed]; it leaves no partial file behind.
  Future<String> download(
    AppcastItem item, {
    void Function(double? progress)? onProgress,
  });

  /// Deletes the leftover update download directory (req 16a; launch, D8).
  /// A missing directory is not a failure.
  Future<void> deleteLeftovers();
}

/// Verifies a downloaded DMG's EdDSA signature against the built-in public
/// key (A1).
abstract interface class EdDsaVerifier {
  /// Completes when [edSignature] verifies over the file at [dmgPath].
  /// Otherwise deletes that file and throws [UpdateFailure] with
  /// [UpdateErrorCause.noPublicKey], [UpdateErrorCause.noSignature] or
  /// [UpdateErrorCause.badSignature] (req 20).
  Future<void> verify({required String dmgPath, required String edSignature});
}

/// The install-location check (req 24, A2).
abstract interface class InstallLocationCheck {
  /// The installed `.app` bundle's path. Throws [UpdateFailure] with
  /// [UpdateErrorCause.diskImage], or with
  /// [UpdateErrorCause.folderNotWritable] and the bundle's parent folder.
  Future<String> check();
}

/// Starts the detached install helper (req 25, A2).
abstract interface class InstallHelper {
  /// Starts the helper: it waits for process [pid] to exit, then replaces
  /// the bundle at [bundlePath] with the app in the DMG at [dmgPath]. Throws
  /// [UpdateFailure] when the helper can't be started.
  Future<void> start({
    required int pid,
    required String dmgPath,
    required String bundlePath,
  });
}

/// The failure marker the install helper writes after the app quit (req 26,
/// A2).
abstract interface class FailureMarkerStore {
  /// Reads and clears the marker. Returns its reason when it holds one of
  /// the five fixed reasons; null when there is no marker or its text is
  /// unknown (cleared and ignored, D8).
  Future<String?> take();
}

/// When the last check fetched and parsed the Appcast (req 11).
abstract interface class LastCheckStore {
  /// The stamped time, or null when never stamped.
  Future<DateTime?> read();

  /// Stamps [time].
  Future<void> write(DateTime time);
}

/// Makes the HTTP client the fetcher and the downloader use (D6). Tests
/// return a `MockClient`.
typedef UpdateHttpClientFactory = http.Client Function();

/// Whether the app can create and delete a file in [folder] (D6).
typedef FolderWritable = Future<bool> Function(String folder);

/// Starts [executable] with [arguments], detached from the app, so it keeps
/// running after the app exits (D6; the install helper's `/bin/sh`).
typedef InstallHelperRunner =
    Future<void> Function(String executable, List<String> arguments);
