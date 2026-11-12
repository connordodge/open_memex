// WI #435 (392-E2): what spelling checks and what it skips (Spec #392
// requirements 2 and 3). Pure Dart: no Flutter imports. Every offset is a
// UTF-16 code-unit index into the text passed in.

import 'dart:math' show max, min;

import 'markdown_inline.dart';
import 'markdown_lines.dart';
import 'markdown_table.dart';

/// The kinds of range the spell checker skips.
enum SpellSkipKind {
  code,
  wikilink,
  transclusion,
  url,
  tag,
  escape,
  marker,
  frontmatter,
  footer,
}

/// A half-open UTF-16 range `[start, end)` the spell checker skips.
class SpellSkipRange {
  const SpellSkipRange({
    required this.kind,
    required this.start,
    required this.end,
  });

  /// The construct this range belongs to.
  final SpellSkipKind kind;

  /// First skipped code unit.
  final int start;

  /// One past the last skipped code unit.
  final int end;
}

/// The ranges of [text] the spell checker skips (Spec #392 requirement 2).
///
/// [text] is one segment or one live preview row; with [atSegmentStart] its
/// leading `---` block is frontmatter. [footerStart], when given, is the
/// offset where the Note footer starts: everything from it to the end is a
/// `footer` range (callers find it with `splitNoteBody` / `splitDailyBody`).
///
/// For an item row, pass the same text and offsets you pass to
/// [spellParagraphs]: the row's segment text (marker included), not the
/// marker-less field text, so block markers are classified as in Source mode.
///
/// Ranges come from `classifyLines` (fences, frontmatter, block markers,
/// table pipes and delimiter lines) and `tokenizeInline` (code spans,
/// wikilinks, transclusions, link urls, tags, escapes, emphasis and strike
/// markers), plus `bareUrlRanges`. They are the same whether markers are
/// hidden or revealed. Returned sorted by start, then end. Ranges may overlap
/// (a footer holds other ranges); none splits a surrogate pair.
List<SpellSkipRange> spellSkipRanges(
  String text, {
  required bool atSegmentStart,
  int? footerStart,
}) {
  final out = <SpellSkipRange>[];
  void add(SpellSkipKind kind, int start, int end) {
    if (end <= start) return;
    out.add(SpellSkipRange(kind: kind, start: start, end: end));
  }

  final lines = classifyLines(text, atSegmentStart: atSegmentStart);
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    switch (line.kind) {
      case MdLineKind.frontmatter:
        var last = i;
        while (last + 1 < lines.length &&
            lines[last + 1].kind == MdLineKind.frontmatter) {
          last++;
        }
        add(SpellSkipKind.frontmatter, line.start, lines[last].contentEnd);
        i = last;
      case MdLineKind.fenceOpen:
        var last = i;
        while (last + 1 < lines.length && _isFenceBody(lines[last].kind)) {
          last++;
        }
        add(SpellSkipKind.code, line.start, lines[last].contentEnd);
        i = last;
      case MdLineKind.fenceInside || MdLineKind.fenceClose:
        break;
      case MdLineKind.blank || MdLineKind.rule:
        break;
      case MdLineKind.tableDelimiter:
        add(SpellSkipKind.marker, line.start, line.contentEnd);
      case MdLineKind.tableHeader || MdLineKind.tableBody:
        _tableRanges(text, line, add);
      case MdLineKind.heading ||
          MdLineKind.bullet ||
          MdLineKind.numbered ||
          MdLineKind.task ||
          MdLineKind.quote:
        add(SpellSkipKind.marker, line.markerStart, line.markerEnd);
        _inlineRanges(text, line.textStart, line.contentEnd, add);
      case MdLineKind.plain:
        _inlineRanges(text, line.start, line.contentEnd, add);
    }
    i++;
  }

  if (footerStart != null) {
    final at = min(max(footerStart, 0), text.length);
    add(SpellSkipKind.footer, at, text.length);
  }
  out.sort((a, b) {
    final byStart = a.start.compareTo(b.start);
    return byStart != 0 ? byStart : a.end.compareTo(b.end);
  });
  return out;
}

/// Whether a fence line that follows [kind] is still inside the fence: the
/// opening line and the lines inside it, but not the closing line.
bool _isFenceBody(MdLineKind kind) =>
    kind == MdLineKind.fenceOpen || kind == MdLineKind.fenceInside;

/// Marker ranges for every pipe of a table header or body [line], and the
/// inline ranges of every cell.
void _tableRanges(
  String text,
  MdLine line,
  void Function(SpellSkipKind, int, int) add,
) {
  final table = splitTableLine(text, start: line.start, end: line.contentEnd);
  for (final pipe in table.pipes) {
    add(SpellSkipKind.marker, pipe, pipe + 1);
  }
  for (final cell in table.cells) {
    _inlineRanges(text, cell.start, cell.end, add);
  }
}

/// Adds the inline ranges of `text[from, to)`, one stretch of one line.
void _inlineRanges(
  String text,
  int from,
  int to,
  void Function(SpellSkipKind, int, int) add,
) {
  if (to <= from) return;
  final slice = text.substring(from, to);
  final tokens = tokenizeInline(slice, before: unitBeforeInLine(text, from));
  for (final token in tokens) {
    switch (token.kind) {
      case InlineTokenKind.codeSpan:
        add(SpellSkipKind.code, from + token.start, from + token.end);
      case InlineTokenKind.wikilink:
        add(SpellSkipKind.wikilink, from + token.start, from + token.end);
      case InlineTokenKind.transclusion:
        add(SpellSkipKind.transclusion, from + token.start, from + token.end);
      case InlineTokenKind.link:
        final url = (token as LinkToken).urlRange;
        add(SpellSkipKind.url, from + url.start, from + url.end);
      case InlineTokenKind.tag:
        add(SpellSkipKind.tag, from + token.start, from + token.end);
      case InlineTokenKind.escape:
        add(SpellSkipKind.escape, from + token.start, from + token.end);
      case InlineTokenKind.bold ||
          InlineTokenKind.italic ||
          InlineTokenKind.boldItalic ||
          InlineTokenKind.strike:
        for (final marker in token.markers) {
          add(SpellSkipKind.marker, from + marker.start, from + marker.end);
        }
    }
  }
  // A bare URL inside a code span, wikilink or transclusion is already
  // skipped as that construct.
  final opaque = [
    for (final token in tokens)
      if (token.kind == InlineTokenKind.codeSpan ||
          token.kind == InlineTokenKind.wikilink ||
          token.kind == InlineTokenKind.transclusion)
        token.span,
  ];
  bool inOpaque(int at) => opaque.any((s) => s.start <= at && at < s.end);
  // The tokenizer gives an image no token, so its `(url)` (any scheme or a
  // relative path) comes from bareUrlRanges too.
  for (final url in bareUrlRanges(slice, includeImageUrls: true)) {
    if (inOpaque(url.start)) continue;
    add(SpellSkipKind.url, from + url.start, from + url.end);
  }
}

/// One unit of spell checking: a paragraph of [text] at `[start, end)`.
class SpellParagraph {
  const SpellParagraph({
    required this.start,
    required this.end,
    required this.text,
  });

  /// First code unit of the paragraph.
  final int start;

  /// One past the last code unit, before any line terminator.
  final int end;

  /// `text.substring(start, end)` of the text the paragraph came from.
  final String text;
}

/// The paragraphs of [text] that spelling checks (Spec #392 requirement 3).
///
/// A prose paragraph runs over consecutive plain lines (inner line breaks
/// kept) and ends at a blank line, a rule, a heading or any other block. A
/// heading, a bullet, numbered, task or quote line and each table header or
/// body line is a paragraph of its own, starting after its marker. Fenced
/// code, frontmatter (with [atSegmentStart]), rules and table delimiter lines
/// give none. A paragraph never holds a trailing line terminator, and
/// whitespace-only text gives none. The same on a live preview row and on a
/// whole Source mode body. Callers pass the text of the row with its block
/// markers (an item row's whole line, not its marker-less field text) and map
/// the returned offsets back by the row's start.
List<SpellParagraph> spellParagraphs(
  String text, {
  required bool atSegmentStart,
}) {
  final out = <SpellParagraph>[];
  void add(int start, int end) {
    if (text.substring(start, end).trim().isEmpty) return;
    out.add(
      SpellParagraph(start: start, end: end, text: text.substring(start, end)),
    );
  }

  // The open prose paragraph: its first line start and last content end.
  int? proseStart;
  var proseEnd = 0;
  void flush() {
    if (proseStart != null) add(proseStart!, proseEnd);
    proseStart = null;
  }

  for (final line in classifyLines(text, atSegmentStart: atSegmentStart)) {
    switch (line.kind) {
      case MdLineKind.plain:
        proseStart ??= line.start;
        proseEnd = line.contentEnd;
      case MdLineKind.blank:
        flush();
      case MdLineKind.heading ||
          MdLineKind.bullet ||
          MdLineKind.numbered ||
          MdLineKind.task ||
          MdLineKind.quote:
        flush();
        add(line.textStart, line.contentEnd);
      case MdLineKind.tableHeader || MdLineKind.tableBody:
        flush();
        add(line.start, line.contentEnd);
      case MdLineKind.rule ||
          MdLineKind.fenceOpen ||
          MdLineKind.fenceInside ||
          MdLineKind.fenceClose ||
          MdLineKind.frontmatter ||
          MdLineKind.tableDelimiter:
        flush();
    }
  }
  flush();
  return out;
}

/// Whether `[start, end)` intersects any of [skips].
bool dropsSpelling(int start, int end, List<SpellSkipRange> skips) =>
    skips.any((skip) => _intersects(start, end, skip));

/// Whether `[start, end)` intersects a code, wikilink, transclusion or url
/// range of [skips]: the only skips that also drop a grammar match.
bool dropsGrammar(int start, int end, List<SpellSkipRange> skips) => skips.any(
  (skip) =>
      _intersects(start, end, skip) &&
      (skip.kind == SpellSkipKind.code ||
          skip.kind == SpellSkipKind.wikilink ||
          skip.kind == SpellSkipKind.transclusion ||
          skip.kind == SpellSkipKind.url),
);

/// Whether the half-open `[start, end)` shares a code unit with [skip].
bool _intersects(int start, int end, SpellSkipRange skip) =>
    start < skip.end && skip.start < end;
