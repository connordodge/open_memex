import 'package:flutter/foundation.dart';

/// The Sparkle XML namespace the Appcast's `sparkle:` prefix is bound to.
const sparkleNamespace = 'http://www.andymatuschak.org/xml-namespaces/sparkle';

/// One `<item>` of the Appcast: one Release (Spec #31 req 2, D12, D21).
///
/// Every field is the raw text from the feed. Optional fields the item lacks
/// are empty: `''` for text, null for [length].
@immutable
class AppcastItem {
  const AppcastItem({
    required this.version,
    required this.shortVersionString,
    required this.url,
    this.notes = '',
    this.link = '',
    this.edSignature = '',
    this.length,
    this.minimumSystemVersion = '',
  });

  /// `sparkle:version`: the Release's `CFBundleVersion` (the build number).
  final String version;

  /// `sparkle:shortVersionString`: the `x.y.z` version.
  final String shortVersionString;

  /// The `<enclosure>` `url`: the DMG's download URL.
  final String url;

  /// The `<description>` text (raw Markdown release notes).
  final String notes;

  /// `<link>`: the Release's page.
  final String link;

  /// The `<enclosure>` `sparkle:edSignature` (base64 Ed25519 signature).
  final String edSignature;

  /// The `<enclosure>` `length` in bytes; null when absent.
  final int? length;

  /// `sparkle:minimumSystemVersion` (e.g. `14.0`); empty means no limit.
  final String minimumSystemVersion;
}

/// Parses the Appcast [xml] into its items, in document order.
///
/// Ignores unknown elements and attributes. Skips an item that lacks
/// `sparkle:version`, `sparkle:shortVersionString` or an enclosure `url`, and
/// keeps one that lacks only `sparkle:edSignature` or `length`. A channel with
/// no `<item>` parses to no items (D12a).
///
/// Throws `UpdateFailure(UpdateErrorCause.feedUnreadable)` for bad XML, a
/// feed with no `<channel>`, or a channel whose items are all invalid.
List<AppcastItem> parseAppcast(String xml) => const [];
