import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import 'update_ports.dart';
import 'update_state.dart';

/// The Sparkle XML namespace the Appcast's `sparkle:` prefix is bound to.
const sparkleNamespace = 'http://www.andymatuschak.org/xml-namespaces/sparkle';

/// One `<item>` of the Appcast: one Release (Spec #31 req 2, D12, D21).
///
/// Every field is the text from the feed: element text trimmed of
/// surrounding whitespace, except [notes], which is kept as written, and
/// attributes as written. Optional fields the item lacks are empty: `''` for
/// text, null for [length] (also null when it is not an integer).
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
List<AppcastItem> parseAppcast(String xml) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(xml);
  } on XmlException {
    throw const UpdateFailure(UpdateErrorCause.feedUnreadable);
  }
  final channel = document.children
      .whereType<XmlElement>()
      .expand((root) => root.findElements('channel'))
      .firstOrNull;
  if (channel == null) {
    throw const UpdateFailure(UpdateErrorCause.feedUnreadable);
  }
  final elements = channel.findElements('item').toList();
  final items = elements.map(_parseItem).nonNulls.toList();
  if (elements.isNotEmpty && items.isEmpty) {
    throw const UpdateFailure(UpdateErrorCause.feedUnreadable);
  }
  return List.unmodifiable(items);
}

/// The item in [element], or null when it lacks `sparkle:version`,
/// `sparkle:shortVersionString` or an enclosure `url`.
AppcastItem? _parseItem(XmlElement element) {
  final version = _sparkleText(element, 'version');
  final shortVersionString = _sparkleText(element, 'shortVersionString');
  final enclosure = element.getElement('enclosure');
  final url = enclosure?.getAttribute('url') ?? '';
  if (version.isEmpty || shortVersionString.isEmpty || url.isEmpty) {
    return null;
  }
  final length = enclosure?.getAttribute('length');
  return AppcastItem(
    version: version,
    shortVersionString: shortVersionString,
    url: url,
    notes: element.getElement('description')?.innerText ?? '',
    link: element.getElement('link')?.innerText.trim() ?? '',
    edSignature:
        enclosure?.getAttribute(
          'edSignature',
          namespaceUri: sparkleNamespace,
        ) ??
        '',
    length: length == null ? null : int.tryParse(length.trim()),
    minimumSystemVersion: _sparkleText(element, 'minimumSystemVersion'),
  );
}

/// The trimmed text of [item]'s first `sparkle:<localName>` child; `''`
/// when there is none.
String _sparkleText(XmlElement item, String localName) =>
    item
        .getElement(localName, namespaceUri: sparkleNamespace)
        ?.innerText
        .trim() ??
    '';
