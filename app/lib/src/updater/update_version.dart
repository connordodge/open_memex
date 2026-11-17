import 'package:flutter/foundation.dart';

import 'appcast.dart';

/// A dotted numeric macOS version (`15.1`, `14.6.1`). Missing trailing parts
/// count as zero, so `15.1` equals `15.1.0`.
@immutable
class SystemVersion implements Comparable<SystemVersion> {
  const SystemVersion(this.parts);

  /// The numeric parts, most significant first.
  final List<int> parts;

  /// Parses `15.1` or `14.6.1`; null when [text] is not dotted numbers.
  static SystemVersion? tryParse(String text) => null;

  @override
  int compareTo(SystemVersion other) => 0;
}

/// The running macOS version from `Platform.operatingSystemVersion`
/// (`Version 15.1 (Build 24B83)` → 15.1); null when it can't be parsed, which
/// counts as meeting every minimum (D21).
SystemVersion? parseOperatingSystemVersion(String operatingSystemVersion) =>
    null;

/// The version decision (Spec #31 req 9, D12a, D21): the item to offer, or
/// null for up to date.
///
/// Offers only the newest item whose `x.y.z` [AppcastItem.shortVersionString]
/// is greater than [installedVersion]; equal `x.y.z` falls back to the
/// higher build number ([AppcastItem.version] against [installedBuild]).
/// Never offers an older or equal item (no downgrade, no reinstall), nor an
/// item whose [AppcastItem.minimumSystemVersion] exceeds [runningMacos]
/// (null: meets every minimum; an item with no minimum has no limit).
AppcastItem? decideUpdate(
  List<AppcastItem> items, {
  required String installedVersion,
  required String installedBuild,
  required SystemVersion? runningMacos,
}) => null;
