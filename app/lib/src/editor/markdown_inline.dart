// WI #161 (A2): offset-preserving inline tokenizer for live preview (Spec
// R4, R5, R37, R38; rulings D2, D3).
//
// Pure Dart: no Flutter imports. Every offset is a UTF-16 code-unit index
// into the string passed to [tokenizeInline], and no range boundary ever
// falls inside a surrogate pair. Transclusions come from `parseTransclusions`
// in `segments.dart` (import it; never copy its regex).

import 'dart:typed_data';

import 'segments.dart' show parseTransclusions;
import 'tag_grammar.dart' show findTagsInLine;

/// A half-open UTF-16 range `[start, end)` in the tokenized text.
final class InlineRange {
  const InlineRange(this.start, this.end);

  /// First code unit of the range.
  final int start;

  /// One past the last code unit of the range.
  final int end;

  /// Number of code units in the range.
  int get length => end - start;

  /// Whether the range holds no code units.
  bool get isEmpty => length == 0;

  /// Whether [other] lies entirely inside this range (an equal range counts).
  bool encloses(InlineRange other) => start <= other.start && other.end <= end;

  /// Whether this range and [other] share at least one code unit. Empty
  /// ranges overlap nothing.
  bool overlaps(InlineRange other) =>
      !isEmpty && !other.isEmpty && start < other.end && other.start < end;

  /// The text this range covers in [source].
  String of(String source) => source.substring(start, end);

  @override
  bool operator ==(Object other) =>
      other is InlineRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'InlineRange($start, $end)';
}

/// The kinds of inline token (Spec R4, R37).
enum InlineTokenKind {
  /// `` `code` `` or ``` ``code`` ```: equal-length backtick runs on one line.
  codeSpan,

  /// `[[Title~kind|alias]]`, matched as the server's `WIKILINK_RE` does
  /// (`link_extractor.rs:87-91`). Always a [WikilinkToken].
  wikilink,

  /// `![[YYYY-MM-DD#^from(..^to)?]]`, found by `parseTransclusions`
  /// (`segments.dart`). Always a [TransclusionLinkToken].
  transclusion,

  /// `[text](url)` on one line, with no space in the URL. Always a
  /// [LinkToken].
  link,

  /// `**bold**` or `__bold__`.
  bold,

  /// `*italic*` or `_italic_`.
  italic,

  /// `***bold italic***` (one token, not a bold and an italic).
  boldItalic,

  /// `~~strike~~`.
  strike,

  /// A backslash escape such as `\*`. The backslash stays visible: it is in
  /// no marker range, and the escaped character is the [InlineToken.content].
  escape,

  /// `#work`: an inline tag (WI #245), found by `tag_grammar.dart`. A plain
  /// [InlineToken] with no markers, whose content is the whole span (the
  /// `#` included, nothing hidden), and which never nests another token.
  tag,
}

/// One inline token: the whole [span], the [markers] live preview hides off
/// the caret line, and the [content] it shows.
///
/// Contract (every kind):
/// - [markers] are sorted, non-empty, don't overlap each other or
///   [content], and lie inside [span];
/// - [content] lies inside [span];
/// - every code unit of [span] is in a marker or in [content], except an
///   [InlineTokenKind.escape] token's backslash, which is in neither;
/// - [span] never contains a line terminator.
class InlineToken {
  const InlineToken({
    required this.kind,
    required this.span,
    required this.markers,
    required this.content,
  });

  /// What construct this token is.
  final InlineTokenKind kind;

  /// The whole token, markers included.
  final InlineRange span;

  /// The delimiter ranges live preview hides off the caret line, in order.
  ///
  /// - emphasis, strike, code span: the opening and the closing delimiter
  ///   run (`**`, `_`, `***`, `~~`, `` ` ``, ``` `` ```);
  /// - link `[text](url)`: `[` and `](url)`;
  /// - wikilink: everything before the shown text and the closing `]]`, so
  ///   `[[Title]]` gives `[[` and `]]`, `[[Title~kind]]` gives `[[` and
  ///   `~kind]]`, and `[[Title~kind|alias]]` gives `[[Title~kind|` and `]]`;
  /// - transclusion `![[date#^from]]`: `![[` and `#^from]]`;
  /// - escape: none.
  final List<InlineRange> markers;

  /// The shown text: between the delimiters for emphasis, strike and code
  /// spans (nothing trimmed); a link's text; a wikilink's alias, else its
  /// title; a transclusion's date; an escape's escaped character.
  final InlineRange content;

  /// Shorthand for `span.start`.
  int get start => span.start;

  /// Shorthand for `span.end`.
  int get end => span.end;

  @override
  String toString() =>
      'InlineToken(${kind.name}, $span, markers: $markers, content: $content)';
}

/// A `[[Title~kind|alias]]` wikilink. The group ranges are exactly the
/// `title`, `kind` and `alias` groups of the server's `WIKILINK_RE`
/// (untrimmed); [target] is the title trimmed of surrounding whitespace, the
/// string a note title must equal for the link to resolve (Spec R4).
final class WikilinkToken extends InlineToken {
  const WikilinkToken({
    required super.span,
    required super.markers,
    required super.content,
    required this.titleRange,
    required this.kindRange,
    required this.aliasRange,
    required this.target,
  }) : super(kind: InlineTokenKind.wikilink);

  /// The `title` group, untrimmed.
  final InlineRange titleRange;

  /// The `kind` group after `~`, or null when there is none.
  final InlineRange? kindRange;

  /// The `alias` group after `|`, or null when there is none.
  final InlineRange? aliasRange;

  /// The title trimmed of surrounding whitespace (as `link_extractor.rs`).
  final String target;
}

/// A `[text](url)` link.
final class LinkToken extends InlineToken {
  const LinkToken({
    required super.span,
    required super.markers,
    required super.content,
    required this.textRange,
    required this.urlRange,
    required this.url,
  }) : super(kind: InlineTokenKind.link);

  /// The text between `[` and `]` (equal to [content]).
  final InlineRange textRange;

  /// The URL between `(` and `)`.
  final InlineRange urlRange;

  /// The URL text, exactly as written.
  final String url;
}

/// A transclusion token left in a text segment
/// (`![[YYYY-MM-DD#^from(..^to)?]]`). It renders like a wikilink that
/// targets the daily note titled with its [date] (Spec R4).
final class TransclusionLinkToken extends InlineToken {
  const TransclusionLinkToken({
    required super.span,
    required super.markers,
    required super.content,
    required this.date,
  }) : super(kind: InlineTokenKind.transclusion);

  /// The `YYYY-MM-DD` date (the range of [content]).
  final String date;
}

/// Tokenizes one line of prose or item text, or a multi-line prose field
/// (Spec R37). Never call it on fenced code.
///
/// Returns tokens sorted by [InlineToken.start] (strictly increasing).
/// Precedence: code span, then wikilink/transclusion (a transclusion wins
/// over the wikilink inside it), then `[text](url)`, then `#tag`, then
/// emphasis and strike. A tag is an atom for emphasis, so a `_` inside
/// `#my_tag_x` never opens emphasis, and `*a #x*` keeps its emphasis with the
/// tag nested inside it. A token may only nest inside the
/// [InlineToken.content] of a link, emphasis or strike token; nothing nests
/// inside a code span, wikilink, transclusion, escape or tag, and no token
/// touches another's markers.
///
/// Rules: code spans match equal-length backtick runs; `_` never opens or
/// closes inside a word; no token spans a line terminator; unclosed
/// delimiters stay literal (no token). No tokens for bare URLs,
/// `<autolinks>`, `==highlight==`, HTML, images, footnotes or math (Spec
/// R38). Tables are line grammar, not inline tokens: `classifyLines` and
/// `markdown_table.dart` find them (Spec #197).
///
/// Lines end at `\n`; the `\r` of a `\r\n` pair belongs to no line, as in
/// the server's `str::lines`.
List<InlineToken> tokenizeInline(String text) {
  final out = <InlineToken>[];
  var lineStart = 0;
  while (true) {
    final newline = text.indexOf('\n', lineStart);
    var lineEnd = newline < 0 ? text.length : newline;
    if (newline >= 0 &&
        lineEnd > lineStart &&
        text.codeUnitAt(lineEnd - 1) == _cr) {
      lineEnd--;
    }
    if (lineEnd > lineStart) {
      _LineTokenizer(text, lineStart, lineEnd, out).run();
    }
    if (newline < 0) break;
    lineStart = newline + 1;
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// The server's `WIKILINK_RE` (`link_extractor.rs:87-91`), verbatim.
final RegExp _wikilinkRe = RegExp(
  r'\[\[(?<title>[^\[\]\n~|]+?)(?:~(?<kind>[^\[\]\n|]+?))?(?:\|(?<alias>[^\[\]\n]+?))?\]\]',
  unicode: true,
);

const int _tab = 0x09;
const int _lf = 0x0A;
const int _cr = 0x0D;
const int _space = 0x20;
const int _bang = 0x21;
const int _openParen = 0x28;
const int _closeParen = 0x29;
const int _star = 0x2A;
const int _openBracket = 0x5B;
const int _backslash = 0x5C;
const int _closeBracket = 0x5D;
const int _underscore = 0x5F;
const int _backtick = 0x60;
const int _tilde = 0x7E;

/// Occupancy of a line's code units after the code span and wikilink passes.
const int _free = 0;
const int _inCode = 1;
const int _inLinkLike = 2;

bool _isAsciiPunctuation(int c) =>
    (c >= 0x21 && c <= 0x2F) ||
    (c >= 0x3A && c <= 0x40) ||
    (c >= 0x5B && c <= 0x60) ||
    (c >= 0x7B && c <= 0x7E);

bool _isWhitespace(int c) =>
    c == _space ||
    (c >= _tab && c <= _cr) ||
    c == 0xA0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000;

/// ASCII punctuation plus the common Latin-1, general and CJK punctuation
/// (the CommonMark flanking rules' "Unicode punctuation", approximately).
bool _isPunctuation(int c) =>
    _isAsciiPunctuation(c) ||
    c == 0xA1 ||
    c == 0xA7 ||
    c == 0xAB ||
    c == 0xB6 ||
    c == 0xB7 ||
    c == 0xBB ||
    c == 0xBF ||
    (c >= 0x2010 && c <= 0x2027) ||
    (c >= 0x2030 && c <= 0x205E) ||
    (c >= 0x3001 && c <= 0x3003) ||
    (c >= 0x3008 && c <= 0x3011);

/// One `*`, `_` or `~~` delimiter run (CommonMark's delimiter stack entry).
/// Its unused code units are `[lo, hi)`: a closer uses them from [lo], an
/// opener from [hi].
final class _Delimiter {
  _Delimiter(this.unit, this.lo, this.hi, this.canOpen, this.canClose)
    : length = hi - lo;

  final int unit;
  final int length;
  final bool canOpen;
  final bool canClose;
  int lo;
  int hi;
  bool removed = false;

  int get count => hi - lo;
}

/// Tokenizes one line `[start, end)` of [text] (no line terminator inside).
final class _LineTokenizer {
  _LineTokenizer(this.text, this.start, this.end, this.out)
    : _occupancy = Uint8List(end - start);

  final String text;
  final int start;
  final int end;
  final List<InlineToken> out;

  /// [_free], [_inCode] or [_inLinkLike] per code unit, indexed from [start].
  final Uint8List _occupancy;

  final List<InlineRange> _codeSpans = [];

  /// Backslash offsets of the escapes found by the lexical scan.
  final List<int> _escapes = [];

  /// Offsets of the characters escaped by a kept escape.
  final Set<int> _escaped = {};

  /// Start -> end of every construct an emphasis run steps over whole.
  final Map<int, int> _atomEnd = {};

  /// Each link's text, where emphasis is tokenized on its own.
  final List<InlineRange> _linkTexts = [];

  /// Each link's URL, where escapes are dropped (it is a marker).
  final List<InlineRange> _linkUrls = [];

  int _occupied(int offset) => _occupancy[offset - start];

  void _occupy(int from, int to, int what) {
    _occupancy.fillRange(from - start, to - start, what);
  }

  void run() {
    _scanCodeSpansAndEscapes();
    _findWikilinksAndTransclusions();
    for (final b in _escapes) {
      if (_occupied(b) == _free && _occupied(b + 1) == _free) {
        _escaped.add(b + 1);
      }
    }
    _findLinks();
    for (final b in _escapes) {
      if (!_escaped.contains(b + 1)) continue;
      if (_linkUrls.any((url) => url.start <= b && b < url.end)) continue;
      _atomEnd[b] = b + 2;
      out.add(
        InlineToken(
          kind: InlineTokenKind.escape,
          span: InlineRange(b, b + 2),
          markers: const [],
          content: InlineRange(b + 1, b + 2),
        ),
      );
    }
    _findTags();
    _emphasis(start, end);
    for (final linkText in _linkTexts) {
      _emphasis(linkText.start, linkText.end);
    }
  }

  /// `#tag` tokens: the ranges `tag_grammar.dart` finds in the line, minus
  /// the ones that start inside a code span, wikilink, transclusion, link,
  /// image or escape the tokenizer found. A tag is an atom for emphasis; it
  /// has no markers and shows all of its characters.
  void _findTags() {
    for (final tag in findTagsInLine(text.substring(start, end))) {
      final from = start + tag.start;
      final to = start + tag.end;
      if (_atomEnd.entries.any((a) => a.key <= from && from < a.value)) {
        continue;
      }
      final span = InlineRange(from, to);
      _atomEnd[from] = to;
      out.add(
        InlineToken(
          kind: InlineTokenKind.tag,
          span: span,
          markers: const [],
          content: span,
        ),
      );
    }
  }

  int _runEnd(int from, int unit) {
    var i = from;
    while (i < end && text.codeUnitAt(i) == unit) {
      i++;
    }
    return i;
  }

  /// Code spans and backslash escapes, left to right: an escaped backtick
  /// opens nothing, and a backslash inside a code span is literal.
  void _scanCodeSpansAndEscapes() {
    var i = start;
    while (i < end) {
      final c = text.codeUnitAt(i);
      if (c == _backslash) {
        if (i + 1 < end && _isAsciiPunctuation(text.codeUnitAt(i + 1))) {
          _escapes.add(i);
          i += 2;
        } else {
          i++;
        }
      } else if (c == _backtick) {
        final openEnd = _runEnd(i, _backtick);
        final close = _closingBackticks(openEnd, openEnd - i);
        if (close < 0) {
          i = openEnd;
          continue;
        }
        final closeEnd = close + openEnd - i;
        final span = InlineRange(i, closeEnd);
        _codeSpans.add(span);
        _occupy(i, closeEnd, _inCode);
        _atomEnd[i] = closeEnd;
        out.add(
          InlineToken(
            kind: InlineTokenKind.codeSpan,
            span: span,
            markers: [InlineRange(i, openEnd), InlineRange(close, closeEnd)],
            content: InlineRange(openEnd, close),
          ),
        );
        i = closeEnd;
      } else {
        i++;
      }
    }
  }

  /// The start of the next backtick run exactly [length] long at or after
  /// [from], or -1.
  int _closingBackticks(int from, int length) {
    var i = from;
    while (i < end) {
      if (text.codeUnitAt(i) != _backtick) {
        i++;
        continue;
      }
      final runEnd = _runEnd(i, _backtick);
      if (runEnd - i == length) return i;
      i = runEnd;
    }
    return -1;
  }

  /// Transclusions, then wikilinks, in each stretch between code spans.
  void _findWikilinksAndTransclusions() {
    var gapStart = start;
    for (final code in [..._codeSpans, InlineRange(end, end)]) {
      if (code.start > gapStart) {
        final gap = text.substring(gapStart, code.start);
        var from = 0;
        for (final t in parseTransclusions(gap)) {
          _findWikilinks(gap, gapStart, from, t.start);
          _addTransclusion(gapStart + t.start, gapStart + t.end, t.date);
          from = t.end;
        }
        _findWikilinks(gap, gapStart, from, gap.length);
      }
      gapStart = code.end;
    }
  }

  void _addTransclusion(int from, int to, String date) {
    // `![[` + date + `#^from(..^to)?]]`.
    final dateRange = InlineRange(from + 3, from + 3 + date.length);
    _occupy(from, to, _inLinkLike);
    _atomEnd[from] = to;
    out.add(
      TransclusionLinkToken(
        span: InlineRange(from, to),
        markers: [
          InlineRange(from, dateRange.start),
          InlineRange(dateRange.end, to),
        ],
        content: dateRange,
        date: date,
      ),
    );
  }

  void _findWikilinks(String gap, int gapStart, int from, int to) {
    if (to <= from) return;
    final base = gapStart + from;
    for (final m in _wikilinkRe.allMatches(gap.substring(from, to))) {
      final at = base + m.start;
      final spanEnd = base + m.end;
      final title = m.namedGroup('title')!;
      final kind = m.namedGroup('kind');
      final alias = m.namedGroup('alias');
      final titleRange = InlineRange(at + 2, at + 2 + title.length);
      var cursor = titleRange.end;
      InlineRange? kindRange;
      if (kind != null) {
        kindRange = InlineRange(cursor + 1, cursor + 1 + kind.length);
        cursor = kindRange.end;
      }
      final aliasRange = alias == null
          ? null
          : InlineRange(cursor + 1, cursor + 1 + alias.length);
      final content = aliasRange ?? titleRange;
      _occupy(at, spanEnd, _inLinkLike);
      _atomEnd[at] = spanEnd;
      out.add(
        WikilinkToken(
          span: InlineRange(at, spanEnd),
          markers: [
            InlineRange(at, content.start),
            InlineRange(content.end, spanEnd),
          ],
          content: content,
          titleRange: titleRange,
          kindRange: kindRange,
          aliasRange: aliasRange,
          target: title.trim(),
        ),
      );
    }
  }

  /// Whether the code unit at [offset] is [unit], unescaped and not inside
  /// a code span, wikilink or transclusion.
  bool _isDelimiter(int offset, int unit) =>
      text.codeUnitAt(offset) == unit &&
      _occupied(offset) == _free &&
      !_escaped.contains(offset);

  /// `[text](url)` links and `![alt](url)` images (images give no token but
  /// stay opaque to emphasis).
  void _findLinks() {
    var i = start;
    while (i < end) {
      i = _linkAt(i) ?? i + 1;
    }
  }

  /// Records the link or image whose `[` is at [open]; returns its end, or
  /// null when there is none.
  int? _linkAt(int open) {
    if (!_isDelimiter(open, _openBracket)) return null;
    // The text: no unescaped brackets, code spans allowed whole.
    var close = open + 1;
    while (true) {
      if (close >= end) return null;
      final occupied = _occupied(close);
      if (occupied == _inCode) {
        close = _atomEnd[close]!;
        continue;
      }
      if (occupied != _free) return null;
      if (!_escaped.contains(close)) {
        final c = text.codeUnitAt(close);
        if (c == _openBracket) return null;
        if (c == _closeBracket) break;
      }
      close++;
    }
    if (close == open + 1) return null;
    final paren = close + 1;
    if (paren >= end || !_isDelimiter(paren, _openParen)) return null;
    // The URL: no whitespace, no unescaped parentheses, nothing occupied.
    var urlEnd = paren + 1;
    while (true) {
      if (urlEnd >= end || _occupied(urlEnd) != _free) return null;
      if (!_escaped.contains(urlEnd)) {
        final c = text.codeUnitAt(urlEnd);
        if (c == _closeParen) break;
        if (c == _openParen || _isWhitespace(c)) return null;
      }
      urlEnd++;
    }
    if (urlEnd == paren + 1) return null;
    final spanEnd = urlEnd + 1;
    final isImage = open > start && _isDelimiter(open - 1, _bang);
    if (isImage) {
      _atomEnd[open - 1] = spanEnd;
      return spanEnd;
    }
    final textRange = InlineRange(open + 1, close);
    final urlRange = InlineRange(paren + 1, urlEnd);
    _atomEnd[open] = spanEnd;
    _linkTexts.add(textRange);
    _linkUrls.add(urlRange);
    out.add(
      LinkToken(
        span: InlineRange(open, spanEnd),
        markers: [InlineRange(open, open + 1), InlineRange(close, spanEnd)],
        content: textRange,
        textRange: textRange,
        urlRange: urlRange,
        url: urlRange.of(text),
      ),
    );
    return spanEnd;
  }

  /// Emphasis and strike in `[from, to)`, stepping over atoms (CommonMark's
  /// delimiter-run algorithm, with `***` pairs as one bold italic token and
  /// only `~~` runs for strike).
  void _emphasis(int from, int to) {
    final delimiters = <_Delimiter>[];
    var i = from;
    while (i < to) {
      final atomEnd = _atomEnd[i];
      if (atomEnd != null) {
        i = atomEnd;
        continue;
      }
      final c = text.codeUnitAt(i);
      if (c != _star && c != _underscore && c != _tilde) {
        i++;
        continue;
      }
      var runEnd = i + 1;
      while (runEnd < to && text.codeUnitAt(runEnd) == c) {
        runEnd++;
      }
      final d = _delimiter(c, i, runEnd);
      if (d != null) delimiters.add(d);
      i = runEnd;
    }
    _matchDelimiters(delimiters);
  }

  _Delimiter? _delimiter(int unit, int from, int to) {
    if (unit == _tilde && to - from != 2) return null;
    final before = from > start ? text.codeUnitAt(from - 1) : _lf;
    final after = to < end ? text.codeUnitAt(to) : _lf;
    final beforeSpace = _isWhitespace(before);
    final afterSpace = _isWhitespace(after);
    final beforePunct = _isPunctuation(before);
    final afterPunct = _isPunctuation(after);
    final leftFlanking =
        !afterSpace && (!afterPunct || beforeSpace || beforePunct);
    final rightFlanking =
        !beforeSpace && (!beforePunct || afterSpace || afterPunct);
    final bool canOpen;
    final bool canClose;
    if (unit == _underscore) {
      canOpen = leftFlanking && (!rightFlanking || beforePunct);
      canClose = rightFlanking && (!leftFlanking || afterPunct);
    } else {
      canOpen = leftFlanking;
      canClose = rightFlanking;
    }
    if (!canOpen && !canClose) return null;
    return _Delimiter(unit, from, to, canOpen, canClose);
  }

  void _matchDelimiters(List<_Delimiter> delimiters) {
    for (var ci = 0; ci < delimiters.length; ci++) {
      final closer = delimiters[ci];
      if (!closer.canClose || closer.removed) continue;
      while (closer.count > 0) {
        var oi = ci - 1;
        while (oi >= 0 && !_canPair(delimiters[oi], closer)) {
          oi--;
        }
        if (oi < 0) break;
        final opener = delimiters[oi];
        final used = closer.unit == _tilde
            ? 2
            : opener.count >= 3 && closer.count >= 3
            ? 3
            : opener.count >= 2 && closer.count >= 2
            ? 2
            : 1;
        final openMarker = InlineRange(opener.hi - used, opener.hi);
        final closeMarker = InlineRange(closer.lo, closer.lo + used);
        opener.hi -= used;
        closer.lo += used;
        for (var k = oi + 1; k < ci; k++) {
          delimiters[k].removed = true;
        }
        out.add(
          InlineToken(
            kind: closer.unit == _tilde
                ? InlineTokenKind.strike
                : switch (used) {
                    3 => InlineTokenKind.boldItalic,
                    2 => InlineTokenKind.bold,
                    _ => InlineTokenKind.italic,
                  },
            span: InlineRange(openMarker.start, closeMarker.end),
            markers: [openMarker, closeMarker],
            content: InlineRange(openMarker.end, closeMarker.start),
          ),
        );
      }
    }
  }

  /// Whether [opener] may close with [closer], including CommonMark's
  /// rule of three for runs that can both open and close.
  bool _canPair(_Delimiter opener, _Delimiter closer) {
    if (opener.removed ||
        opener.count == 0 ||
        !opener.canOpen ||
        opener.unit != closer.unit) {
      return false;
    }
    if (closer.unit == _tilde) return true;
    final bothWays = opener.canClose || closer.canOpen;
    final sum = opener.length + closer.length;
    return !(bothWays &&
        sum % 3 == 0 &&
        !(opener.length % 3 == 0 && closer.length % 3 == 0));
  }
}
