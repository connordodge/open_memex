// WI #245 (A1): the Dart port of the inline `#tag` grammar (Spec #234 R4-R6,
// R20; rulings D17, TD4). The contract is `test/fixtures/tags/grammar.json`,
// shared with the Rust reference, `crates/memex-core/src/tags.rs`.
//
// The app never derives tags from a note: this is for styling and type-ahead
// only. Pure Dart, no Flutter imports. Every offset is a UTF-16 code-unit
// index, and no range boundary falls inside a surrogate pair.

import 'segments.dart' show parseTransclusions;

/// A tag found in one line: the half-open UTF-16 range `[start, end)` of the
/// `#` and the name as written (no trailing `-` or `_`), and its lowercase
/// [name] without the `#`.
final class TagRange {
  const TagRange(this.start, this.end, this.name);

  /// Offset of the `#`.
  final int start;

  /// One past the last code unit of the name as written.
  final int end;

  /// The lowercase name, without the `#`.
  final String name;

  @override
  bool operator ==(Object other) =>
      other is TagRange &&
      other.start == start &&
      other.end == end &&
      other.name == name;

  @override
  int get hashCode => Object.hash(start, end, name);

  @override
  String toString() => 'TagRange($start, $end, $name)';
}

/// The system tags (R20); `grammar.json` lists the same names (D17).
const List<String> _systemTags = ['inbox', 'agent-authored'];

/// True only for the system tags `inbox` and `agent-authored` (R20, D17):
/// the one list in `grammar.json`'s `system_tags`. Case-sensitive, as the
/// Rust predicate is.
bool isSystemTag(String name) => _systemTags.contains(name);

const int _hash = 0x23;
const int _backtick = 0x60;
const int _tilde = 0x7E;
const int _space = 0x20;
const int _tab = 0x09;
const int _dash = 0x2D;
const int _underscore = 0x5F;

/// Unicode `White_Space`, as Rust's `char::is_whitespace` has it.
bool _isWhitespace(int c) =>
    c == _space ||
    (c >= _tab && c <= 0x0D) ||
    c == 0x85 ||
    c == 0xA0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000;

/// Whether a `#` right after the code unit [previous] (null at the start of
/// a line) can start a tag: line start, Unicode whitespace, or one of
/// `( [ { " '`. The one `#` start test; type-ahead (#246) calls it too.
bool opensTag(int? previous) {
  if (previous == null) return true;
  return _isWhitespace(previous) ||
      previous == 0x28 || // (
      previous == 0x5B || // [
      previous == 0x7B || // {
      previous == 0x22 || // "
      previous == 0x27; // '
}

/// A tag name as written after `#`: a letter, then letters, marks, decimal
/// digits, `-` and `_`. Trailing `-`/`_` are trimmed separately.
final RegExp _nameRe = RegExp(r'\p{L}[\p{L}\p{M}\p{Nd}_-]*', unicode: true);

/// A URL, from its scheme up to the next whitespace.
final RegExp _urlRe = RegExp(
  r'[A-Za-z][A-Za-z0-9+.\-]*://[^\u0009-\u000D \u0085   -     　]*',
  unicode: true,
);

/// A markdown link or image: `[text](target)` / `![alt](target)`.
final RegExp _mdLinkRe = RegExp(r'\[[^\]\n]*\]\([^)\n]*\)', unicode: true);

/// The server's `WIKILINK_RE` (`link_extractor.rs:87-91`), verbatim.
final RegExp _wikilinkRe = RegExp(
  r'\[\[[^\[\]\n~|]+?(?:~[^\[\]\n|]+?)?(?:\|[^\[\]\n]+?)?\]\]',
  unicode: true,
);

/// The length of the name written at [from] (just after the `#`), without
/// trailing `-`/`_`; null when there is no name.
int? _nameLength(String text, int from) {
  final m = _nameRe.matchAsPrefix(text, from);
  if (m == null) return null;
  var end = m.end;
  while (end > from) {
    final c = text.codeUnitAt(end - 1);
    if (c != _dash && c != _underscore) break;
    end--;
  }
  return end - from;
}

/// Ranges of [line] where no tag can start: code spans, transclusion tokens,
/// wikilinks, markdown links and URLs.
List<(int, int)> _hiddenRanges(String line) {
  final hidden = <(int, int)>[..._codeSpans(line)];
  for (final t in parseTransclusions(line)) {
    hidden.add((t.start, t.end));
  }
  for (final re in [_wikilinkRe, _mdLinkRe, _urlRe]) {
    for (final m in re.allMatches(line)) {
      hidden.add((m.start, m.end));
    }
  }
  return hidden;
}

/// Code spans on one line: a backtick run up to the next run of the same
/// length. A run with no partner is plain text.
List<(int, int)> _codeSpans(String line) {
  final runs = <(int, int)>[]; // (start, length)
  var i = 0;
  while (i < line.length) {
    if (line.codeUnitAt(i) == _backtick) {
      final start = i;
      while (i < line.length && line.codeUnitAt(i) == _backtick) {
        i++;
      }
      runs.add((start, i - start));
    } else {
      i++;
    }
  }
  final spans = <(int, int)>[];
  var k = 0;
  while (k < runs.length) {
    final (start, len) = runs[k];
    var partner = -1;
    for (var j = k + 1; j < runs.length; j++) {
      if (runs[j].$2 == len) {
        partner = j;
        break;
      }
    }
    if (partner < 0) {
      k++;
    } else {
      spans.add((start, runs[partner].$1 + len));
      k = partner + 1;
    }
  }
  return spans;
}

/// The tags in [line], one line of prose (no `\n`), in order of position,
/// outside code spans, transclusions, wikilinks, markdown links and URLs.
/// Never call it on a fenced line: fences are the caller's.
List<TagRange> findTagsInLine(String line) {
  if (!line.contains('#')) return const [];
  final hidden = _hiddenRanges(line);
  final out = <TagRange>[];
  for (var i = 0; i < line.length; i++) {
    if (line.codeUnitAt(i) != _hash) continue;
    if (!opensTag(i == 0 ? null : line.codeUnitAt(i - 1))) continue;
    if (hidden.any((r) => r.$1 <= i && i < r.$2)) continue;
    final length = _nameLength(line, i + 1);
    if (length == null) continue;
    final end = i + 1 + length;
    out.add(TagRange(i, end, line.substring(i + 1, end).toLowerCase()));
  }
  return out;
}

/// An open fenced code block: its fence character and run length.
final class _Fence {
  const _Fence(this.ch, this.length);

  final int ch;
  final int length;

  static String _indentTrimmed(String line) {
    var i = 0;
    while (i < line.length) {
      final c = line.codeUnitAt(i);
      if (c != _space && c != _tab) break;
      i++;
    }
    return line.substring(i);
  }

  static int _runLength(String text, int ch) {
    var i = 0;
    while (i < text.length && text.codeUnitAt(i) == ch) {
      i++;
    }
    return i;
  }

  /// The fence [line] opens: three or more backticks or tildes after any
  /// indentation. A backtick fence's info string holds no backtick.
  static _Fence? openedBy(String line) {
    final trimmed = _indentTrimmed(line);
    if (trimmed.isEmpty) return null;
    final ch = trimmed.codeUnitAt(0);
    if (ch != _backtick && ch != _tilde) return null;
    final length = _runLength(trimmed, ch);
    final info = trimmed.substring(length);
    if (length < 3) return null;
    if (ch == _backtick && info.contains('`')) return null;
    return _Fence(ch, length);
  }

  /// Whether [line] closes this fence: the same character, at least as many
  /// times, after any indentation, and nothing but whitespace after it.
  bool closedBy(String line) {
    final trimmed = _indentTrimmed(line);
    final run = _runLength(trimmed, ch);
    return run >= length && trimmed.substring(run).trim().isEmpty;
  }
}

/// A tag being typed: the `#` at [start] of the text and the [query] written
/// from it up to the caret. The query may be empty (a bare `#`) and may end in
/// `-` or `_`.
final class TagQuery {
  const TagQuery(this.start, this.lineStart, this.query);

  /// Offset of the `#`.
  final int start;

  /// Offset of the first code unit of the `#`'s line.
  final int lineStart;

  /// The text between the `#` and the caret, as written.
  final String query;

  /// [query] without its trailing `-`/`_`: the name as a note would write it.
  String get name => query.substring(0, _nameLength(query, 0) ?? 0);
}

/// The tag being typed at [caret] in [text] (any number of lines, split on
/// `\n`), or null where none can be. The last `#` of the caret's line before
/// the caret must pass [opensTag], the text from it to the caret must be a tag
/// name prefix, and it must lie outside fenced code and everything
/// [findTagsInLine] skips. For type-ahead (#246), which adds its own rules.
TagQuery? tagQueryAt(String text, int caret) {
  final before = text.substring(0, caret);
  final lineStart = before.lastIndexOf('\n') + 1;
  final hash = before.lastIndexOf('#');
  if (hash < lineStart) return null;
  if (!opensTag(hash == lineStart ? null : text.codeUnitAt(hash - 1))) {
    return null;
  }
  final query = before.substring(hash + 1);
  if (query.isNotEmpty && _nameRe.matchAsPrefix(query)?.end != query.length) {
    return null;
  }
  final lineEnd = text.indexOf('\n', caret);
  final line = text.substring(lineStart, lineEnd < 0 ? text.length : lineEnd);
  final offset = hash - lineStart;
  if (_hiddenRanges(line).any((r) => r.$1 <= offset && offset < r.$2)) {
    return null;
  }
  if (_isFenced(before.substring(0, lineStart), line)) return null;
  return TagQuery(hash, lineStart, query);
}

/// Whether [line] is fenced code: [above], the text before it, leaves a fence
/// open, or [line] opens one.
bool _isFenced(String above, String line) {
  _Fence? fence;
  for (final previous in above.split('\n')) {
    final open = fence;
    if (open == null) {
      fence = _Fence.openedBy(previous);
    } else if (open.closedBy(previous)) {
      fence = null;
    }
  }
  return fence != null || _Fence.openedBy(line) != null;
}

/// The lowercase names of the tags in [personText] (any number of lines,
/// split on `\n`), sorted by name, one per name, nothing inside fenced code.
List<String> extractTagNames(String personText) {
  final found = <String>{};
  _Fence? fence;
  for (final line in personText.split('\n')) {
    final open = fence;
    if (open != null) {
      if (open.closedBy(line)) fence = null;
      continue;
    }
    fence = _Fence.openedBy(line);
    if (fence != null) continue;
    for (final tag in findTagsInLine(line)) {
      found.add(tag.name);
    }
  }
  return found.toList()..sort();
}

/// `Some(lowercase)` only when the whole [input] is one valid tag name.
String? normalizeTagName(String input) {
  final length = _nameLength(input, 0);
  if (length == null || length != input.length) return null;
  return input.toLowerCase();
}
