// WI #395 (U1): the plain-text preview of one block's markdown (Spec #393
// requirement 7, ruling D10). Pure Dart: no Flutter imports.
//
// Built read-only on the line grammar (`classifyLines`, markdown_lines.dart)
// and the inline tokenizer (`tokenizeInline`, markdown_inline.dart): what
// counts as a line marker or an inline token is exactly what they decide.

import 'markdown_inline.dart';
import 'markdown_lines.dart';

/// Shown before a transclusion's date (Spec #393 requirement 7).
const _transclusionArrow = '↪ ';

/// Reduces a block's [markdown] to the plain text a preview shows.
///
/// The one reduction both the Filed from this day rows (#393) and the Echoes
/// rows (#391) use (ruling D10). It returns the full reduced text; cutting
/// it to a length is the caller's job.
///
/// - Every line is reduced on its own; the non-empty ones are joined by one
///   space, so the result holds no line terminator, blank lines add nothing
///   and the result has no leading or trailing whitespace (lead ruling LR4).
/// - Fence lines are dropped and the lines inside a fence are shown as
///   written, with no inline reduction.
/// - Heading, bullet, ordered, task and quote markers and a line's leading
///   indentation are dropped, as `classifyLines` finds them. After a quote
///   marker the markers that follow are dropped too (`> > x`, `> - x`,
///   `> - [ ] x`, `> # h` all show `x` or `h`), and so is an indented quote
///   marker, as on a list item's continuation line (`  > q` shows `q`).
/// - Inline tokens (`tokenizeInline`) show their content without their
///   markers: a link its text, a wikilink its alias else its title, an
///   escape the escaped character, a code span its code, a tag as written,
///   and a transclusion `↪ <date>`.
String markdownPreviewText(String markdown) {
  final parts = <String>[];
  for (final line in classifyLines(markdown, atSegmentStart: false)) {
    final String text;
    switch (line.kind) {
      case MdLineKind.blank:
      case MdLineKind.fenceOpen:
      case MdLineKind.fenceClose:
        continue;
      case MdLineKind.fenceInside:
        text = markdown.substring(line.start, line.contentEnd);
      default:
        text = _reduceInline(
          markdown,
          _textStart(markdown, line),
          line.contentEnd,
        );
    }
    final trimmed = text.trim();
    if (trimmed.isNotEmpty) parts.add(trimmed);
  }
  return parts.join(' ');
}

/// Where the shown text of [line] (no fence line) starts: past its marker,
/// and past every marker that follows a quote marker.
///
/// A plain line whose text after its leading whitespace is a quote (an
/// indented `> q`) counts as that quote. After a quote marker the rest of
/// the line is classified again as a line of its own: a further quote is
/// peeled the same way, and a heading, bullet, ordered or task marker is
/// peeled once.
int _textStart(String markdown, MdLine line) {
  var start = line.textStart;
  var quoted = line.kind == MdLineKind.quote;
  if (line.kind == MdLineKind.plain) {
    var at = start;
    while (at < line.contentEnd && _isIndent(markdown.codeUnitAt(at))) {
      at++;
    }
    if (at > start) {
      final inner = _classifyRest(markdown, at, line.contentEnd);
      if (inner.kind == MdLineKind.quote) {
        start = at + inner.textStart;
        quoted = true;
      }
    }
  }
  while (quoted) {
    final inner = _classifyRest(markdown, start, line.contentEnd);
    quoted = inner.kind == MdLineKind.quote;
    start += inner.textStart;
  }
  return start;
}

/// `markdown[start, end)`, part of one line, classified as a line of its own
/// (offsets relative to [start]).
MdLine _classifyRest(String markdown, int start, int end) =>
    classifyLines(markdown.substring(start, end), atSegmentStart: false).first;

/// Whether [unit] is a space or a tab.
bool _isIndent(int unit) => unit == 0x20 || unit == 0x09;

/// The shown text of `markdown[start, end)`, one line outside any fence:
/// every token's markers (and an escape's backslash) are left out, and a
/// transclusion gets [_transclusionArrow] before its date.
String _reduceInline(String markdown, int start, int end) {
  final text = markdown.substring(start, end);
  final hidden = List<bool>.filled(text.length, false);
  final arrows = <int>{};
  for (final token in tokenizeInline(
    text,
    before: unitBeforeInLine(markdown, start),
  )) {
    for (final marker in token.markers) {
      hidden.fillRange(marker.start, marker.end, true);
    }
    switch (token.kind) {
      case InlineTokenKind.escape:
        hidden.fillRange(token.start, token.content.start, true);
      case InlineTokenKind.transclusion:
        arrows.add(token.start);
      default:
        break;
    }
  }
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (arrows.contains(i)) out.write(_transclusionArrow);
    if (!hidden[i]) out.writeCharCode(text.codeUnitAt(i));
  }
  return out.toString();
}
