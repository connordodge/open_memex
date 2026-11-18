// Pure-Dart Outline entries for a note (Spec #58 R5-R11, R16, TD2, WI #67).
//
// No Flutter imports, in the style of `markdown_lines.dart`.

/// One Outline row: a heading line of a note's text.
class OutlineEntry {
  const OutlineEntry({
    required this.level,
    required this.depth,
    required this.text,
    required this.segment,
    required this.local,
  });

  /// The heading level, 1-6.
  final int level;

  /// The nesting depth (Spec R9).
  final int depth;

  /// The plain heading text (Spec R11).
  final String text;

  /// The index of the heading's `TextSegment` in `split()`.
  final int segment;

  /// The UTF-16 offset of the heading line's start in that segment's text.
  final int local;
}

/// The Outline entries of [contentMd], in document order.
List<OutlineEntry> outlineEntries(String contentMd, {String? role}) => const [];

/// The plain text of a heading's [headingText] (Spec R11).
String outlineText(String headingText) => '';
