import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'appcast_fetcher.dart';
import 'eddsa_verifier.dart';
import 'failure_marker.dart';
import 'install_helper.dart';
import 'install_location.dart';
import 'sparkle_ed_public_key.dart';
import 'update_downloader.dart';
import 'update_ports.dart';
import 'update_version.dart';

// The updater's injection seams (Spec #31 TD6, D6). A provider whose
// production value does IO delegates to a `defaultX(Ref)` in its filler's
// file, so a filler never edits this file. No default touches the file
// system when it is built (D7).

/// Whether Self-update is active: only in a release build ([releaseMode])
/// not running under `flutter test` (`FLUTTER_TEST` unset in [environment]).
bool updatesEnabledFor(bool releaseMode, Map<String, String> environment) =>
    releaseMode && !environment.containsKey('FLUTTER_TEST');

/// Whether Self-update is active in this process (req 10). The production
/// value is [updatesEnabledFor] of `kReleaseMode` and `Platform.environment`.
final updatesEnabledProvider = Provider<bool>(
  (_) => updatesEnabledFor(kReleaseMode, Platform.environment),
);

/// The installed `CFBundleVersion` (the pubspec build number), the
/// tie-break of the version decision (req 9). Empty until `main()`
/// overrides it.
final appBuildNumberProvider = Provider<String>((_) => '');

/// The running macOS version, from `Platform.operatingSystemVersion`; null
/// when it can't be parsed (meets every minimum, D21).
final runningMacosVersionProvider = Provider<SystemVersion?>(
  (_) => parseOperatingSystemVersion(Platform.operatingSystemVersion),
);

/// The SharedPreferences key the last check time is stamped under
/// (integer milliseconds since the epoch).
const lastCheckKey = 'self_update.last_check';

/// The [LastCheckStore] over SharedPreferences, under [lastCheckKey].
class SharedPrefsLastCheckStore implements LastCheckStore {
  const SharedPrefsLastCheckStore();

  @override
  Future<DateTime?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(lastCheckKey);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  @override
  Future<void> write(DateTime time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(lastCheckKey, time.millisecondsSinceEpoch);
  }
}

/// When the last check fetched and parsed the Appcast.
final lastCheckStoreProvider = Provider<LastCheckStore>(
  (_) => const SharedPrefsLastCheckStore(),
);

/// This process's pid, which the install helper waits on.
final currentPidProvider = Provider<int>((_) => pid);

/// The base64 Ed25519 public key downloads are verified against
/// (`sparkleEdPublicKey`, req 21). Tests inject an ephemeral key (D9).
final sparkleEdPublicKeyProvider = Provider<String>((_) => sparkleEdPublicKey);

/// Fetches and parses the Appcast.
final appcastFetcherProvider = Provider<AppcastFetcher>(defaultAppcastFetcher);

/// Downloads an item's DMG.
final updateDownloaderProvider = Provider<UpdateDownloader>(
  defaultUpdateDownloader,
);

/// Verifies a downloaded DMG's signature.
final edDsaVerifierProvider = Provider<EdDsaVerifier>(defaultEdDsaVerifier);

/// The install-location check.
final installLocationCheckProvider = Provider<InstallLocationCheck>(
  defaultInstallLocationCheck,
);

/// Starts the detached install helper.
final installHelperProvider = Provider<InstallHelper>(defaultInstallHelper);

/// Reads and clears the install helper's failure marker.
final failureMarkerStoreProvider = Provider<FailureMarkerStore>(
  defaultFailureMarkerStore,
);

/// The HTTP client factory for the fetch and the download.
final updateHttpClientFactoryProvider = Provider<UpdateHttpClientFactory>(
  defaultUpdateHttpClientFactory,
);

/// The update download directory (`<Directory.systemTemp>/open-memex-update`).
final updateDownloadDirProvider = Provider<String>(defaultUpdateDownloadDir);

/// The running executable (`Platform.resolvedExecutable`), from which the
/// install-location check resolves the `.app` bundle.
final resolvedExecutableProvider = Provider<String>(defaultResolvedExecutable);

/// Probes whether a folder is writable (create and delete a file).
final folderWritableProvider = Provider<FolderWritable>(defaultFolderWritable);

/// Starts the install helper detached (`Process.start`).
final installHelperRunnerProvider = Provider<InstallHelperRunner>(
  defaultInstallHelperRunner,
);

/// The failure marker's path (`<appSupportDir>/self_update_failure`).
final failureMarkerFileProvider = Provider<String>(defaultFailureMarkerFile);
