import 'package:flutter/foundation.dart';

import 'appcast.dart';

/// Where **try again** goes for an [UpdateErrorCause] (Spec #31 req 15).
enum UpdateRetryTarget {
  /// A new check: the modal goes to Checking.
  checking,

  /// The same item, downloaded again: the modal goes to Downloading.
  downloading,

  /// No **try again** action.
  none,
}

/// Why Self-update failed: one value per row of req 15's error table.
///
/// Check causes ([offline], [feedUnreadable], [noAppcast]) show the title
/// `Update check failed`; every other cause shows `Update failed`.
enum UpdateErrorCause {
  /// No connection, DNS failure or timeout while fetching the Appcast.
  offline,

  /// The Appcast answered a non-2xx other than 404, or is malformed.
  feedUnreadable,

  /// No Appcast published yet (HTTP 404).
  noAppcast,

  /// The item's `sparkle:edSignature` does not verify.
  badSignature,

  /// The item has no `sparkle:edSignature`.
  noSignature,

  /// No public key is built in (`sparkleEdPublicKey` is empty).
  noPublicKey,

  /// The download did not finish (connection lost, non-2xx).
  downloadFailed,

  /// The installed bundle's folder is not writable (req 24).
  folderNotWritable,

  /// Running from a disk image or App Translocation (req 24).
  diskImage,

  /// The install helper recorded a failure after the app quit (req 26).
  failureRecorded;

  /// Where **try again** goes for this cause.
  UpdateRetryTarget get tryAgain => UpdateRetryTarget.none;

  /// Whether this cause is a check failure (title `Update check failed`)
  /// rather than an install failure (title `Update failed`).
  bool get isCheckFailure => false;

  /// Whether the modal offers **download from GitHub** for this cause.
  bool get offersGitHubDownload => false;
}

/// The state of Self-update: the single source of truth the modal and the
/// version labels render from (Spec #31 TD3, D1).
@immutable
sealed class UpdateState {
  const UpdateState();
}

/// No check in flight and nothing to show.
final class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

/// The Appcast is being fetched and parsed.
final class UpdateChecking extends UpdateState {
  const UpdateChecking();
}

/// No Appcast item is newer than the installed version.
final class UpdateUpToDate extends UpdateState {
  const UpdateUpToDate();
}

/// [item] is newer than the installed version and offered.
final class UpdateAvailable extends UpdateState {
  const UpdateAvailable(this.item);

  final AppcastItem item;
}

/// [item]'s DMG is downloading. [progress] is the fraction done in `0..1`,
/// or null when the length is unknown (indeterminate).
final class UpdateDownloading extends UpdateState {
  const UpdateDownloading(this.item, {this.progress});

  final AppcastItem item;
  final double? progress;
}

/// [item]'s downloaded DMG is being verified against the built-in key.
final class UpdateVerifying extends UpdateState {
  const UpdateVerifying(this.item);

  final AppcastItem item;
}

/// [item] is downloaded and verified at [dmgPath]; a relaunch applies it.
final class UpdateReady extends UpdateState {
  const UpdateReady(this.item, {required this.dmgPath});

  final AppcastItem item;

  /// The verified, staged DMG the install helper mounts.
  final String dmgPath;
}

/// Self-update failed with [cause].
///
/// [item] is the item being installed (null for a check failure), so
/// **try again** can download it again and **download from GitHub** can open
/// its `<link>`. [folder] is the not-writable folder
/// ([UpdateErrorCause.folderNotWritable]); [reason] is the recorded marker
/// reason ([UpdateErrorCause.failureRecorded]).
final class UpdateError extends UpdateState {
  const UpdateError(this.cause, {this.item, this.folder, this.reason});

  final UpdateErrorCause cause;
  final AppcastItem? item;
  final String? folder;
  final String? reason;
}
