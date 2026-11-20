// WI #80 (Spec #61 F1): the Find in note model and its pure rules: matching
// (Reqs 1-10), hidden matches and their outline (Reqs 4, 26), the current
// match rules (Reqs 15, 18-21, 37-39) and the Find bar counter (Reqs 10,
// 29, 32-34). F2 (Find bar), F3 (highlight painter), F5 (native menu) and
// F6 (editor integration) build on these shapes: they are frozen.
//
// Pure Dart: no Flutter imports and no `dart:ui` (lesson #435). Every offset
// is a UTF-16 code-unit index into its source's text (source-local), never a
// byte offset (rulings D2, D3).

import 'dart:math' show max, min;

import 'markdown_inline.dart' show InlineToken, tokenizeInline;

/// A half-open UTF-16 range `[start, end)` in one source's text.
final class FindRange {
  const FindRange(this.start, this.end);

  /// First code unit of the range.
  final int start;

  /// One past the last code unit of the range.
  final int end;

  @override
  bool operator ==(Object other) =>
      other is FindRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'FindRange($start, $end)';
}

/// What a [FindSource] is.
enum FindSourceKind {
  /// A live-preview text segment of the note body (tables included: a
  /// table is row text inside its text segment, Req 3).
  body,

  /// An excerpt card's rendered text (`RenderedExcerpt.text`, Req 1).
  card,

  /// The whole Source-mode field as it shows it (Req 2).
  source,
}

/// One searchable run: a live-preview text segment, an excerpt card's text,
/// or the whole Source field.
final class FindSource {
  const FindSource({
    required this.segment,
    required this.kind,
    required this.text,
    this.hidden = const [],
  });

  /// The `split()` index of the segment (`segments.dart`); 0 for the Source
  /// field.
  final int segment;

  /// What this source is.
  final FindSourceKind kind;

  /// body: the segment's text; card: `RenderedExcerpt.text`; source: the
  /// whole field.
  final String text;

  /// The UTF-16 ranges of [text] that render hidden (zero width) in live
  /// preview (`livePreviewHiddenRanges`); empty for the Source field.
  final List<FindRange> hidden;
}

/// One match of the query in one source (D20: every field F3 needs to paint
/// it without probing glyphs).
final class FindMatch {
  const FindMatch({
    required this.segment,
    required this.kind,
    required this.start,
    required this.end,
    this.hidden = false,
    this.outline,
  });

  /// The [FindSource.segment] of the source it lies in.
  final int segment;

  /// The [FindSource.kind] of the source it lies in.
  final FindSourceKind kind;

  /// First code unit, UTF-16, source-local.
  final int start;

  /// One past the last code unit, UTF-16, source-local.
  final int end;

  /// Every code unit of the match lies in the source's hidden ranges. Only
  /// body matches are ever hidden: a wholly hidden card match is dropped
  /// (Req 4).
  final bool hidden;

  /// Body only, when [hidden]: the visible text of the inline element that
  /// hides the match (the link label for a match in a link URL, the bold
  /// text for a match on its `**`), source-local. Null when there is no
  /// visible owner, and always null when not [hidden] (Req 26).
  final FindRange? outline;

  @override
  bool operator ==(Object other) =>
      other is FindMatch &&
      other.segment == segment &&
      other.kind == kind &&
      other.start == start &&
      other.end == end &&
      other.hidden == hidden &&
      other.outline == outline;

  @override
  int get hashCode => Object.hash(segment, kind, start, end, hidden, outline);

  @override
  String toString() =>
      'FindMatch($segment, ${kind.name}, $start-$end'
      '${hidden ? ', hidden' : ''}${outline == null ? '' : ', outline $outline'})';
}

/// Every match of [query] in [sources], in document order: by
/// [FindSource.segment], then by offset (Req 8).
///
/// - Literal, case folding only: accents and punctuation must match exactly
///   (Req 5).
/// - Non-overlapping, left to right: the next search starts at the end of
///   the previous match. A query of only spaces matches spaces (Req 6).
/// - No cap (Req 10). An empty query has no matches (Req 29).
/// - A card match wholly inside the card's hidden ranges is dropped; one
///   partly inside counts, not hidden (Req 4).
/// - A body match wholly inside hidden ranges counts, [FindMatch.hidden]
///   true, with its [FindMatch.outline] (Req 26, `tokenizeInline`).
List<FindMatch> findMatches(List<FindSource> sources, String query) {
  if (query.isEmpty) return const [];
  final needle = _fold(query);
  final ordered = [...sources]..sort((a, b) => a.segment.compareTo(b.segment));
  final out = <FindMatch>[];
  for (final source in ordered) {
    final haystack = _fold(source.text);
    final hidden = source.kind == FindSourceKind.source
        ? const <FindRange>[]
        : ([...source.hidden]..sort((a, b) => a.start.compareTo(b.start)));
    List<InlineToken>? tokens;
    // Hidden ranges ending at or before a match can hold no later match.
    var from = 0;
    var at = haystack.indexOf(needle);
    while (at >= 0) {
      final end = at + needle.length;
      while (from < hidden.length && hidden[from].end <= at) {
        from++;
      }
      final wholly = _covered(hidden, from, at, end);
      if (!wholly) {
        out.add(
          FindMatch(
            segment: source.segment,
            kind: source.kind,
            start: at,
            end: end,
          ),
        );
      } else if (source.kind == FindSourceKind.body) {
        tokens ??= tokenizeInline(source.text);
        out.add(
          FindMatch(
            segment: source.segment,
            kind: source.kind,
            start: at,
            end: end,
            hidden: true,
            outline: _outline(tokens, at, end),
          ),
        );
      }
      at = haystack.indexOf(needle, end);
    }
  }
  return out;
}

/// Test-only work counter (WI #130, Spec #122 TD8; ruling D9: a plain int):
/// incremented once for every [FindMatch] a per-field match lookup reads:
/// each match a [FindMatchIndex] lookup compares, and each match
/// `findFieldDecoration` and `findPaintRanges` visit for one field. Tests
/// read deltas to prove a Find change reads matches by index, not rows x
/// matches. Never read by production code.
int debugFindMatchReads = 0;

/// The matches of one Find in note state, looked up by source and offset
/// (WI #130, Spec #122 Requirement 22a): [matches] in document order, as
/// [findMatches] gives them (by segment, then by offset, non-overlapping),
/// so the matches of one source touching a range are one run of it.
final class FindMatchIndex {
  FindMatchIndex(this.matches);

  /// The indexed matches, in document order.
  final List<FindMatch> matches;

  /// The run `[from, to)` of indices into [matches] of the matches of
  /// source ([segment], [kind]) that touch `[start, end)`: `m.start < end`
  /// and `m.end > start`, the rule `findFieldDecoration` and
  /// `findPaintRanges` clip by. `from == to` when none does.
  ///
  /// A binary search by offset: it reads O(log n) matches, never every
  /// match ([debugFindMatchReads] counts each one it compares).
  ({int from, int to}) touching({
    required int segment,
    required FindSourceKind kind,
    required int start,
    required int end,
  }) => (from: 0, to: 0);
}

/// [text] with case folded code unit for code unit, so every offset into
/// the result is the same offset into [text]. A character whose lower case
/// changes its length (`İ`) keeps its own case.
String _fold(String text) {
  final lower = text.toLowerCase();
  if (lower.length == text.length) return lower;
  final out = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    final folded = char.toLowerCase();
    out.write(folded.length == char.length ? folded : char);
  }
  return out.toString();
}

/// Whether every code unit of `[start, end)` lies in [sorted] (ranges by
/// start, read from index [from]; adjacent and overlapping ranges join).
bool _covered(List<FindRange> sorted, int from, int start, int end) {
  var reach = start;
  for (final range in sorted.skip(from)) {
    if (range.start > reach) break;
    reach = max(reach, range.end);
    if (reach >= end) return true;
  }
  return false;
}

/// The content of the innermost inline token whose span holds the hidden
/// match `[start, end)`, or null when no token holds it (Req 26).
/// [tokenizeInline] lists nested tokens too, by strictly increasing start,
/// and tokens that both hold the match nest: the last one is innermost.
FindRange? _outline(List<InlineToken> tokens, int start, int end) {
  InlineToken? owner;
  for (final token in tokens) {
    if (token.start > start) break;
    if (token.end >= end) owner = token;
  }
  if (owner == null) return null;
  return FindRange(owner.content.start, owner.content.end);
}

/// A caret anchor: an offset in the body text segment [segment] (in Source
/// mode, segment 0 and the Source field's offset).
final class FindCaret {
  const FindCaret(this.segment, this.offset);

  /// The `split()` index of the segment holding the caret.
  final int segment;

  /// UTF-16, segment-local.
  final int offset;

  @override
  bool operator ==(Object other) =>
      other is FindCaret && other.segment == segment && other.offset == offset;

  @override
  int get hashCode => Object.hash(segment, offset);

  @override
  String toString() => 'FindCaret($segment, $offset)';
}

/// The index of the first match at or after [caret]: in a later segment, or
/// in the caret's segment starting at or after its offset. A null [caret]
/// (never placed in this note) gives the first match. With no match at or
/// after the caret it wraps to the first match. Null when [matches] is
/// empty (Req 18).
int? firstAtOrAfter(List<FindMatch> matches, FindCaret? caret) {
  if (matches.isEmpty) return null;
  if (caret == null) return 0;
  final at = matches.indexWhere(
    (m) => _atOrAfter(m, caret.segment, caret.offset),
  );
  return at < 0 ? 0 : at;
}

/// Whether [m] starts at or after offset [offset] of segment [segment].
bool _atOrAfter(FindMatch m, int segment, int offset) =>
    m.segment > segment || (m.segment == segment && m.start >= offset);

/// The index of the last match before [caret]: in an earlier segment, or in
/// the caret's segment starting before its offset. A null [caret] and no
/// match before the caret both wrap to the last match. Null when [matches]
/// is empty (Req 15).
int? lastBefore(List<FindMatch> matches, FindCaret? caret) {
  if (matches.isEmpty) return null;
  if (caret == null) return matches.length - 1;
  final at = matches.lastIndexWhere(
    (m) => !_atOrAfter(m, caret.segment, caret.offset),
  );
  return at < 0 ? matches.length - 1 : at;
}

/// The index one step from [current] among [total] matches, wrapping from
/// the last to the first ([forward]) and from the first to the last
/// (Req 19).
int stepIndex(int current, int total, {required bool forward}) =>
    (current + (forward ? 1 : total - 1)) % total;

/// The current match after a text change (Reqs 37-38): [before] and [after]
/// are the sources around the change, [oldMatches] / [newMatches] their
/// matches (from `findMatches`) and [oldCurrent] the index into
/// [oldMatches].
///
/// The sources are read as one text in document order, so a segment added
/// or removed by the change (renumbering the later `split()` indices) moves
/// no match. The old current match's start is carried through the change
/// of that text, code unit by code unit: before the changed run it stays,
/// after it it shifts by the change in length, and inside it it keeps its
/// distance from the run's start, clamped to the new run. The changed run
/// is the text between the longest common prefix and, after it, the longest
/// common suffix, so an insertion that repeats the text next to it is read
/// as after the earlier text.
///
/// The current match is then the first match at or after the carried
/// start: the same match when it survives, otherwise the first match after
/// its old position, wrapping to the first match. Null when [newMatches] is
/// empty, and when [oldCurrent] is null (no current match to carry: the
/// caller takes one from the caret).
int? carryCurrent({
  required List<FindSource> before,
  required List<FindMatch> oldMatches,
  required int? oldCurrent,
  required List<FindSource> after,
  required List<FindMatch> newMatches,
}) {
  if (oldCurrent == null || newMatches.isEmpty) return null;
  final was = _Flat(before);
  final now = _Flat(after);
  final carried = _carryThrough(
    was.text,
    now.text,
    was.startOf(oldMatches[oldCurrent]),
  );
  final next = newMatches.indexWhere((m) => now.startOf(m) >= carried);
  return next < 0 ? 0 : next;
}

/// Sources as one text in document order (the order of `findMatches`):
/// each source's text followed by a separator.
final class _Flat {
  _Flat(List<FindSource> sources) {
    final ordered = [...sources]
      ..sort((a, b) => a.segment.compareTo(b.segment));
    final buffer = StringBuffer();
    for (final source in ordered) {
      _starts[(source.segment, source.kind)] = buffer.length;
      buffer
        ..write(source.text)
        ..writeCharCode(0);
    }
    text = buffer.toString();
  }

  late final String text;
  final _starts = <(int, FindSourceKind), int>{};

  /// Where [match] starts in [text]; its source must be in these sources.
  int startOf(FindMatch match) =>
      _starts[(match.segment, match.kind)]! + match.start;
}

/// Where [offset] of [before] lands in [after]: unchanged before the
/// changed run, shifted by the change in length after it, and inside it
/// at its distance from the run's start, clamped to the new run.
int _carryThrough(String before, String after, int offset) {
  final shorter = min(before.length, after.length);
  var prefix = 0;
  while (prefix < shorter &&
      before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
    prefix++;
  }
  if (offset < prefix) return offset;
  var suffix = 0;
  while (suffix < shorter - prefix &&
      before.codeUnitAt(before.length - 1 - suffix) ==
          after.codeUnitAt(after.length - 1 - suffix)) {
    suffix++;
  }
  if (offset >= before.length - suffix) {
    return offset + after.length - before.length;
  }
  return prefix + min(offset - prefix, after.length - suffix - prefix);
}

/// The current match after toggling Source mode (Req 39): [from] are the
/// matches in the mode being left, [current] an index into them, [to] the
/// matches in the mode being entered.
///
/// [tokenOffset] gives the Source-field offset where `split()` segment
/// `segment` starts (for a card, its transclusion token). A match's Source
/// position is its start for a source match, `tokenOffset(segment) + start`
/// for a body match and `tokenOffset(segment)` for a card match. The match
/// in [to] at the same position keeps current (a body match keeps its
/// offsets); otherwise the first match in [to] at or after that position,
/// wrapping to the first. Null when [current] is null or [to] is empty.
int? mapCurrentAcrossMode({
  required List<FindMatch> from,
  required int? current,
  required List<FindMatch> to,
  required int Function(int segment) tokenOffset,
}) {
  if (current == null || to.isEmpty) return null;
  int position(FindMatch m) => switch (m.kind) {
    FindSourceKind.source => m.start,
    FindSourceKind.body => tokenOffset(m.segment) + m.start,
    FindSourceKind.card => tokenOffset(m.segment),
  };
  final at = position(from[current]);
  final same = to.indexWhere((m) => position(m) == at);
  if (same >= 0) return same;
  final next = to.indexWhere((m) => position(m) >= at);
  return next < 0 ? 0 : next;
}

/// The Find bar's width over a note body [bodyWidth] wide:
/// `min(372, bodyWidth - 24)` (Req 30).
double findBoxWidth(double bodyWidth) => min(372.0, bodyWidth - 24);

/// Which counter the Find bar shows (Req 32).
enum FindCounterForm {
  /// `3 of 12`, `No matches`.
  full,

  /// `3/12`, `None`.
  short,

  /// No counter.
  hidden,
}

/// The counter form for a Find bar [boxWidth] wide whose short counter text
/// measures [shortTextWidth] (Req 32): full at 300 px and wider; short below
/// 300; hidden below 240, and also when a short text wider than its 34 px
/// minimum slot would push the field under its 96 px floor. The field is
/// `boxWidth - 110 - max(34.0, shortTextWidth)` wide beside a short counter
/// (design B4, packs/82.md; lead ruling Q1).
FindCounterForm findCounterForm({
  required double boxWidth,
  required double shortTextWidth,
}) {
  if (boxWidth >= 300) return FindCounterForm.full;
  if (boxWidth < 240) return FindCounterForm.hidden;
  final field = boxWidth - 110 - max(34, shortTextWidth);
  return field < 96 ? FindCounterForm.hidden : FindCounterForm.short;
}

/// The counter text in [form] (Reqs 10, 29, 32): [current] is the 0-based
/// index of the current match among [total]. Full: `3 of 12`, `1 of 2,431`
/// (thousands separator), `No matches`. Short: `3/12`, `None`. Null for an
/// empty [query] and for [FindCounterForm.hidden]. A null [current] among
/// matches (never while the bar is open) shows as 0.
String? findCounterText({
  required int? current,
  required int total,
  required String query,
  required FindCounterForm form,
}) {
  if (query.isEmpty) return null;
  final shown = current == null ? 0 : current + 1;
  return switch (form) {
    FindCounterForm.hidden => null,
    FindCounterForm.full =>
      total == 0 ? 'No matches' : '${_grouped(shown)} of ${_grouped(total)}',
    FindCounterForm.short =>
      total == 0 ? 'None' : '${_grouped(shown)}/${_grouped(total)}',
  };
}

/// [n] with a comma every three digits: `2,431`.
String _grouped(int n) {
  final digits = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// The Find field's semantics value (Req 34): always the full counter text
/// (`3 of 12`, `No matches`), whatever form the counter shows; empty for an
/// empty [query].
String findSemanticsValue({
  required int? current,
  required int total,
  required String query,
}) =>
    findCounterText(
      current: current,
      total: total,
      query: query,
      form: FindCounterForm.full,
    ) ??
    '';
