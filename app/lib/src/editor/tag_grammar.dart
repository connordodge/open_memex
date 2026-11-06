// WI #245 (A1): the Dart port of the inline `#tag` grammar (Spec #234 R4-R6,
// R20; rulings D17, TD4). The contract is `test/fixtures/tags/grammar.json`,
// shared with the Rust reference, `crates/memex-core/src/tags.rs`.
//
// The app never derives tags from a note: this is for styling and type-ahead
// only. Pure Dart, no Flutter imports. Every offset is a UTF-16 code-unit
// index, and no range boundary falls inside a surrogate pair.

import 'editor_rows.dart' show RowSpec;
import 'markdown_lines.dart' show MdLine, MdLineKind, classifyLines;
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
///
/// [before] is the code unit that precedes [line] in its real line, when
/// [line] is only a stretch of it (a table cell, or the text after a quote
/// marker): the server tests the character before a `#` in the whole line,
/// so `|#x|` holds no tag. Null means [line] starts its line.
List<TagRange> findTagsInLine(String line, {int? before}) {
  if (!line.contains('#')) return const [];
  final hidden = _hiddenRanges(line);
  final out = <TagRange>[];
  for (var i = 0; i < line.length; i++) {
    if (line.codeUnitAt(i) != _hash) continue;
    if (!opensTag(i == 0 ? before : line.codeUnitAt(i - 1))) continue;
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
    // Not `String.trim`: it also strips U+FEFF, which the server keeps.
    return run >= length &&
        trimmed.substring(run).codeUnits.every(_isWhitespace);
  }
}

/// For each of [lines] in order (one line of text each, no `\n`), whether it
/// is fenced code as the server reads it: a fence's opening line, a line
/// inside it, or its closing line. An unclosed fence runs to the last line.
List<bool> fencedLines(List<String> lines) {
  final out = <bool>[];
  _Fence? fence;
  for (final line in lines) {
    final open = fence;
    if (open != null) {
      if (open.closedBy(line)) fence = null;
      out.add(true);
    } else {
      fence = _Fence.openedBy(line);
      out.add(fence != null);
    }
  }
  return out;
}

/// [fencedLines] of [lines], the `classifyLines` result for [text]. Frontmatter
/// is not in the text the server scans, so its lines open no fence.
List<bool> fencedMdLines(String text, List<MdLine> lines) => fencedLines([
  for (final line in lines)
    line.kind == MdLineKind.frontmatter
        ? ''
        : text.substring(line.start, line.contentEnd),
]);

/// For each of [rows] (`splitRows(text, atSegmentStart: true)`), which of its
/// lines are fenced code as the server reads the whole of [text]. Item, code
/// and table rows split a tilde fence that the line grammar calls plain, so
/// no row can tell this from its own text. An item row's line is judged with
/// its marker, as the server does. A trailing empty line has no entry.
List<List<bool>> fencedRowLines(String text, List<RowSpec> rows) {
  final lines = classifyLines(text, atSegmentStart: true);
  final fenced = fencedMdLines(text, lines);
  final out = <List<bool>>[];
  var next = 0;
  for (final row in rows) {
    final first = next;
    while (next < lines.length && lines[next].start < row.end) {
      next++;
    }
    out.add(fenced.sublist(first, next));
  }
  return out;
}

/// The lowercase names of the tags in [personText] (any number of lines,
/// split on `\n`), sorted by name, one per name, nothing inside fenced code.
List<String> extractTagNames(String personText) {
  final found = <String>{};
  final lines = personText.split('\n');
  final fenced = fencedLines(lines);
  for (final (i, line) in lines.indexed) {
    if (fenced[i]) continue;
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
