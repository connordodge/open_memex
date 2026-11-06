// Pure-Dart segment model for the segmented note editor (Spec #1, WI #20).
//
// No Flutter imports. Mirrors the server's canonical daily body (contracts C3,
// architect D10) and transclusion parse (contracts C4, architect D13).

/// The Topics footer marker line (C3).
const String topicsMarker = '<!-- memex:topics -->';

/// A daily note body split at the Topics footer marker (C3).
class DailyBody {
  const DailyBody({
    required this.person,
    required this.chips,
    this.tags = const [],
  });

  /// Everything above the marker, plus any stray text from below it (Q1).
  final String person;

  /// Footer chip titles, in order.
  final List<String> chips;

  /// Footer tag names as written after `#` on a footer tag line (a line below
  /// the marker starting with `#` and then a character other than a space or
  /// `#`), trailing spaces and `\r` trimmed, in order (Spec #234 R12, D13).
  /// Saves drop them: the server renders tag lines from its rows.
  final List<String> tags;
}

/// A footer chip line, matched after trimming trailing spaces and `\r` (C3).
final RegExp _chipLine = RegExp(r'^\[\[(.+)~about\]\]$');

/// Splits a daily note body into the person section and the footer (C3).
///
/// Splits at the first marker line. Below it, chip lines become
/// [DailyBody.chips] and footer tag lines [DailyBody.tags], each in order;
/// blank lines and further marker lines are dropped, and any other line is
/// stray text moved to the end of the person section (Q1).
DailyBody splitDailyBody(String body) {
  for (final line in _lines(body)) {
    if (_trimLineEnd(line.content) == topicsMarker) {
      return _splitAtMarker(body, line.start);
    }
  }
  return DailyBody(person: body, chips: const []);
}

/// Splits a non-daily note body into the person section and the Note footer
/// (Spec #234 R11-R13, D13): like [splitDailyBody], except that a marker line
/// inside fenced code is body text, so only the first marker line outside
/// fenced code starts the footer. Without one the whole body is person.
DailyBody splitNoteBody(String body) {
  _Fence? fence;
  for (final line in _lines(body)) {
    final open = fence;
    if (open != null) {
      if (open.closedBy(line.content)) fence = null;
    } else if (_trimLineEnd(line.content) == topicsMarker) {
      return _splitAtMarker(body, line.start);
    } else {
      fence = _Fence.openedBy(line.content);
    }
  }
  return DailyBody(person: body, chips: const []);
}

/// The name of a footer tag line (Spec #234 R12): `#` followed by a character
/// other than a space or `#`, the name being everything after the `#`.
/// [content] is already trimmed of trailing spaces and `\r`.
String? _footerTagName(String content) {
  if (content.length < 2 || !content.startsWith('#')) return null;
  final next = content[1];
  return next == ' ' || next == '#' ? null : content.substring(1);
}

/// Splits [body] at the marker line starting at [markerStart] (C3, R12).
DailyBody _splitAtMarker(String body, int markerStart) {
  final newline = body.indexOf('\n', markerStart);
  final markerEnd = newline < 0 ? body.length : newline + 1;
  var person = body.substring(0, markerStart);
  final chips = <String>[];
  final tags = <String>[];
  final stray = <String>[];
  for (final line in body.substring(markerEnd).split('\n')) {
    final content = _trimLineEnd(line);
    if (content.isEmpty || content == topicsMarker) continue;
    final chip = _chipLine.firstMatch(content);
    final tag = _footerTagName(content);
    if (chip != null) {
      chips.add(chip.group(1)!);
    } else if (tag != null) {
      tags.add(tag);
    } else {
      stray.add(line);
    }
  }
  if (stray.isNotEmpty) {
    final out = StringBuffer(person);
    if (person.isNotEmpty && !person.endsWith('\n')) out.write('\n');
    for (final s in stray) {
      out
        ..write(s)
        ..write('\n');
    }
    person = out.toString();
  }
  return DailyBody(person: person, chips: chips, tags: tags);
}

/// An open fenced code block: its fence character and run length. Mirrors
/// the Rust `tags::Fence` behind `daily::split_note_body`.
class _Fence {
  const _Fence(this.char, this.length);

  final String char;
  final int length;

  /// The fence [line] opens: three or more backticks or tildes after any
  /// indentation. A backtick fence's info string holds no backtick.
  static _Fence? openedBy(String line) {
    final trimmed = _trimIndent(line);
    if (trimmed.isEmpty) return null;
    final c = trimmed[0];
    if (c != '`' && c != '~') return null;
    final length = _runLength(trimmed, c);
    if (length < 3) return null;
    if (c == '`' && trimmed.substring(length).contains('`')) return null;
    return _Fence(c, length);
  }

  /// Whether [line] closes this fence: the same character, at least as many
  /// times, after any indentation, and nothing but whitespace after it.
  bool closedBy(String line) {
    final trimmed = _trimIndent(line);
    final run = _runLength(trimmed, char);
    return run >= length && trimmed.substring(run).trim().isEmpty;
  }

  /// [line] without its leading spaces and tabs.
  static String _trimIndent(String line) {
    var i = 0;
    while (i < line.length && (line[i] == ' ' || line[i] == '\t')) {
      i++;
    }
    return line.substring(i);
  }

  /// How many times [c] repeats at the start of [s].
  static int _runLength(String s, String c) {
    var i = 0;
    while (i < s.length && s[i] == c) {
      i++;
    }
    return i;
  }
}

/// Assembles a daily note body from the person section and chips (C3).
String assembleDailyBody(String person, List<String> chips) {
  final out = StringBuffer(person);
  if (person.isNotEmpty && !person.endsWith('\n')) out.write('\n');
  out
    ..write(topicsMarker)
    ..write('\n');
  for (final title in chips) {
    out.write('[[$title~about]]\n');
  }
  return out.toString();
}

/// One transclusion token found in a string (C4).
///
/// [start] and [end] are UTF-16 code-unit offsets into the parsed string.
class TransclusionToken {
  const TransclusionToken({
    required this.date,
    required this.from,
    required this.to,
    required this.start,
    required this.end,
  });

  final String date;
  final String from;
  final String? to;
  final int start;
  final int end;
}

/// The C4 transclusion regex, identical to the server's (D13).
final RegExp _transclusion = RegExp(
  r'!\[\[(\d{4}-\d{2}-\d{2})#\^([0-9a-z]{1,26})(?:\.\.\^([0-9a-z]{1,26}))?\]\]',
);

/// Finds every transclusion token in [text] (C4 regex), in order.
List<TransclusionToken> parseTransclusions(String text) => [
  for (final m in _transclusion.allMatches(text))
    TransclusionToken(
      date: m.group(1)!,
      from: m.group(2)!,
      to: m.group(3),
      start: m.start,
      end: m.end,
    ),
];

/// One segment of a note body.
sealed class Segment {
  const Segment();
}

/// An editable run of markdown.
class TextSegment extends Segment {
  const TextSegment(this.text);

  final String text;
}

/// A read-only excerpt card: one line that is exactly one transclusion token.
class TransclusionSegment extends Segment {
  const TransclusionSegment({
    required this.raw,
    required this.date,
    required this.from,
    this.to,
  });

  /// The raw line, including its line terminator when it has one.
  final String raw;
  final String date;
  final String from;

  /// The range end block id, or null for a single-block card.
  final String? to;
}

/// The daily note's Topics footer chip row.
class FooterSegment extends Segment {
  const FooterSegment(this.chips);

  final List<String> chips;
}

/// Splits [markdown] into segments.
///
/// Daily notes give exactly `[TextSegment(person), FooterSegment(chips)]`.
///
/// Other notes give text segments around read-only cards: a line whose content
/// (trailing spaces and `\r` ignored) is exactly one transclusion token becomes
/// a [TransclusionSegment] that keeps its raw line. A [TextSegment], possibly
/// empty, always sits at the start, at the end and between adjacent cards.
List<Segment> split(String markdown, {required bool isDaily}) {
  if (isDaily) {
    final daily = splitDailyBody(markdown);
    return [TextSegment(daily.person), FooterSegment(daily.chips)];
  }
  final segments = <Segment>[];
  var textStart = 0;
  for (final line in _lines(markdown)) {
    final content = _trimLineEnd(line.content);
    final tokens = parseTransclusions(content);
    if (tokens.length != 1 ||
        tokens.single.start != 0 ||
        tokens.single.end != content.length) {
      continue;
    }
    final token = tokens.single;
    segments
      ..add(TextSegment(markdown.substring(textStart, line.start)))
      ..add(
        TransclusionSegment(
          raw: markdown.substring(line.start, line.end),
          date: token.date,
          from: token.from,
          to: token.to,
        ),
      );
    textStart = line.end;
  }
  segments.add(TextSegment(markdown.substring(textStart)));
  return segments;
}

/// Joins segments back into one markdown string.
///
/// When [segments] hold a [FooterSegment] the result is the canonical daily
/// body: the other segments' text as the person section, then the footer
/// ([assembleDailyBody]). Otherwise the segments' raw text is concatenated, so
/// `join(split(s, isDaily: false)) == s`.
String join(List<Segment> segments) {
  final out = StringBuffer();
  List<String>? chips;
  for (final segment in segments) {
    switch (segment) {
      case TextSegment(:final text):
        out.write(text);
      case TransclusionSegment(:final raw):
        out.write(raw);
      case FooterSegment(chips: final footerChips):
        chips = footerChips;
    }
  }
  final person = out.toString();
  return chips == null ? person : assembleDailyBody(person, chips);
}

/// One line of a string: [content] excludes the `\n` terminator; [start] and
/// [end] bound the whole line including it.
typedef _Line = ({String content, int start, int end});

/// The lines of [s], each with its UTF-16 bounds. A trailing `\n` doesn't start
/// an extra empty line.
Iterable<_Line> _lines(String s) sync* {
  var start = 0;
  while (start < s.length) {
    final newline = s.indexOf('\n', start);
    if (newline < 0) {
      yield (content: s.substring(start), start: start, end: s.length);
      return;
    }
    yield (
      content: s.substring(start, newline),
      start: start,
      end: newline + 1,
    );
    start = newline + 1;
  }
}

/// Trims trailing spaces and `\r` only (C3, segment rules).
String _trimLineEnd(String line) {
  var end = line.length;
  while (end > 0) {
    final c = line.codeUnitAt(end - 1);
    if (c != 0x20 && c != 0x0D) break;
    end--;
  }
  return line.substring(0, end);
}
