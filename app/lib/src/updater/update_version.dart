import 'dart:math' show max;

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
  static SystemVersion? tryParse(String text) {
    final parts = _dotted.hasMatch(text) ? _ints(text) : null;
    return parts == null ? null : SystemVersion(parts);
  }

  static final _dotted = RegExp(r'^\d+(\.\d+)*$');

  @override
  int compareTo(SystemVersion other) =>
      _compareParts(parts, other.parts, max(parts.length, other.parts.length));
}

/// The dot-separated integers in [text]; null when one overflows an `int`.
List<int>? _ints(String text) {
  final parts = text.split('.').map(int.tryParse).toList();
  return parts.contains(null) ? null : List.unmodifiable(parts.nonNulls);
}

/// Compares [a] and [b] part by part over [length] parts, a missing part
/// counting as zero.
int _compareParts(List<int> a, List<int> b, int length) {
  for (var i = 0; i < length; i++) {
    final byPart = (i < a.length ? a[i] : 0).compareTo(i < b.length ? b[i] : 0);
    if (byPart != 0) return byPart;
  }
  return 0;
}

/// The running macOS version from `Platform.operatingSystemVersion`
/// (`Version 15.1 (Build 24B83)` → 15.1); null when it can't be parsed, which
/// counts as meeting every minimum (D21).
SystemVersion? parseOperatingSystemVersion(String operatingSystemVersion) {
  final match = _osVersion.firstMatch(operatingSystemVersion);
  return match == null ? null : SystemVersion.tryParse(match.group(1)!);
}

final _osVersion = RegExp(r'^Version (\d+(?:\.\d+)*)(?![\d.])');

/// The version decision (Spec #31 req 9, D12a, D21): the item to offer, or
/// null for up to date.
///
/// Offers only the newest item whose `x.y.z` [AppcastItem.shortVersionString]
/// is greater than [installedVersion]; equal `x.y.z` falls back to the
/// higher build number ([AppcastItem.version] against [installedBuild]).
/// Never offers an older or equal item (no downgrade, no reinstall), nor an
/// item whose [AppcastItem.minimumSystemVersion] exceeds [runningMacos]
/// (null: meets every minimum; an item with no minimum has no limit).
///
/// An item whose short version is not `x.y.z`, or whose minimum is not a
/// dotted version, is never offered. An installed version that is not
/// `x.y.z` gets no offer. Build numbers compare as integers; when the
/// installed or the item's build is not an integer, an equal `x.y.z` is not
/// newer.
AppcastItem? decideUpdate(
  List<AppcastItem> items, {
  required String installedVersion,
  required String installedBuild,
  required SystemVersion? runningMacos,
}) {
  final installed = _Release.tryParse(installedVersion, installedBuild);
  if (installed == null) return null;
  AppcastItem? best;
  _Release? bestRelease;
  for (final item in items) {
    final release = _Release.tryParse(item.shortVersionString, item.version);
    if (release == null || release.compareTo(installed) <= 0) continue;
    if (!_meetsMinimum(item.minimumSystemVersion, runningMacos)) continue;
    if (bestRelease == null || release.compareTo(bestRelease) > 0) {
      best = item;
      bestRelease = release;
    }
  }
  return best;
}

/// Whether [running] meets [minimum]: an empty minimum has no limit, an
/// unknown running version meets every minimum, and a minimum that is not
/// a dotted version is never met.
bool _meetsMinimum(String minimum, SystemVersion? running) {
  if (minimum.isEmpty || running == null) return true;
  final required = SystemVersion.tryParse(minimum);
  return required != null && running.compareTo(required) >= 0;
}

/// An `x.y.z` version with its build number (null when not an integer).
class _Release {
  const _Release(this.core, this.build);

  final List<int> core;
  final int? build;

  static final _xyz = RegExp(r'^\d+\.\d+\.\d+$');

  static _Release? tryParse(String shortVersion, String build) {
    final core = _xyz.hasMatch(shortVersion) ? _ints(shortVersion) : null;
    return core == null ? null : _Release(core, int.tryParse(build));
  }

  /// Orders by `x.y.z`, then by build; an equal `x.y.z` with an unknown
  /// build on either side compares equal (never newer).
  int compareTo(_Release other) {
    final byCore = _compareParts(core, other.core, 3);
    if (byCore != 0) return byCore;
    final mine = build;
    final theirs = other.build;
    if (mine == null || theirs == null) return 0;
    return mine.compareTo(theirs);
  }
}
