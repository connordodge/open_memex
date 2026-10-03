// Pure-Dart segment model for the segmented note editor (Spec #1, WI #20).
//
// No Flutter imports. Mirrors the server's canonical daily body (contracts C3,
// architect D10) and transclusion parse (contracts C4, architect D13).

/// The Topics footer marker line (C3).
const String topicsMarker = '<!-- memex:topics -->';

/// A daily note body split at the Topics footer marker (C3).
class DailyBody {
  const DailyBody({required this.person, required this.chips});

  /// Everything above the marker, plus any stray text from below it (Q1).
  final String person;

  /// Footer chip titles, in order.
  final List<String> chips;
}

/// Splits a daily note body into the person section and footer chips (C3).
DailyBody splitDailyBody(String body) => throw UnimplementedError();

/// Assembles a daily note body from the person section and chips (C3).
String assembleDailyBody(String person, List<String> chips) =>
    throw UnimplementedError();

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

/// Finds every transclusion token in [text] (C4 regex), in order.
List<TransclusionToken> parseTransclusions(String text) =>
    throw UnimplementedError();

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
List<Segment> split(String markdown, {required bool isDaily}) =>
    throw UnimplementedError();

/// Joins segments back into one markdown string.
String join(List<Segment> segments) => throw UnimplementedError();
