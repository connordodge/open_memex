// Pure-Dart Outline entries for a note (Spec #58 R5-R11, R16, TD2, WI #67).
//
// No Flutter imports, in the style of `markdown_lines.dart`.

import 'markdown_inline.dart';
import 'markdown_lines.dart';
import 'segments.dart';

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

  @override
  bool operator ==(Object other) =>
      other is OutlineEntry &&
      other.level == level &&
      other.depth == depth &&
      other.text == text &&
      other.segment == segment &&
      other.local == local;

  @override
  int get hashCode => Object.hash(level, depth, text, segment, local);

  @override
  String toString() =>
      'OutlineEntry(level $level, depth $depth, "$text", segment $segment, '
      'local $local)';
}

/// The Outline entries of [contentMd], in document order.
///
/// Every heading line of every text segment is an entry, except fenced code,
/// frontmatter, transcluded cards, the footer and a heading whose plain text
/// is empty. [role] `daily` and `guide` select the same split the editor
/// uses.
List<OutlineEntry> outlineEntries(String contentMd, {String? role}) {
  final segments = split(
    contentMd,
    isDaily: role == 'daily',
    noteFooter: role != 'guide',
  );
  final out = <OutlineEntry>[];
  // Ascending levels: the open ancestors of the next heading.
  final open = <OutlineEntry>[];
  for (var i = 0; i < segments.length; i++) {
    final segment = segments[i];
    if (segment is! TextSegment) continue;
    final text = segment.text;
    for (final line in classifyLines(text, atSegmentStart: true)) {
      if (line.kind != MdLineKind.heading) continue;
      final plain = outlineText(
        text.substring(line.textStart, line.contentEnd),
      );
      if (plain.isEmpty) continue;
      while (open.isNotEmpty && open.last.level >= line.level) {
        open.removeLast();
      }
      final entry = OutlineEntry(
        level: line.level,
        depth: open.isEmpty ? 0 : open.last.depth + 1,
        text: plain,
        segment: i,
        local: line.start,
      );
      open.add(entry);
      out.add(entry);
    }
  }
  return out;
}

/// The plain text of a heading's [headingText] (Spec R11): emphasis, strike
/// and code span markers dropped, a wikilink shown as its alias or title, a
/// markdown link as its text, a `#tag` kept as written, then trimmed.
String outlineText(String headingText) {
  final tokens = tokenizeInline(headingText);
  final out = StringBuffer();
  _render(headingText, tokens, 0, headingText.length, out);
  return out.toString().trim();
}

/// Writes [text] from [from] to [to] into [out], replacing each token of
/// [tokens] that lies inside the range with its shown text.
void _render(
  String text,
  List<InlineToken> tokens,
  int from,
  int to,
  StringBuffer out,
) {
  var pos = from;
  for (final token in tokens) {
    if (token.start < pos || token.end > to) continue;
    out.write(text.substring(pos, token.start));
    switch (token.kind) {
      case InlineTokenKind.bold:
      case InlineTokenKind.italic:
      case InlineTokenKind.boldItalic:
      case InlineTokenKind.strike:
      case InlineTokenKind.link:
        _render(text, tokens, token.content.start, token.content.end, out);
      case InlineTokenKind.codeSpan:
      case InlineTokenKind.wikilink:
        out.write(token.content.of(text));
      case InlineTokenKind.transclusion:
      case InlineTokenKind.escape:
      case InlineTokenKind.tag:
        out.write(token.span.of(text));
    }
    pos = token.end;
  }
  out.write(text.substring(pos, to));
}
