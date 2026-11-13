// Req 60 conflict rebuild as a pure function (Spec #1, WI #20).

import 'dart:math';
import 'dart:typed_data';

import 'segments.dart';

/// A server `blocks` row, as far as the conflict merge needs it.
class ServerBlock {
  const ServerBlock({
    required this.source,
    required this.createdVersion,
    required this.ord,
    required this.text,
  });

  /// `person`, `agent` or `quick-entry`.
  final String source;

  /// The notes.version of the write that created the block.
  final int createdVersion;
  final int ord;
  final String text;
}

/// Rebuilds a daily note body after a save conflict (Req 60).
///
/// Returns `assembleDailyBody(localPerson + appended,
/// splitDailyBody(serverBody).chips)`, where `appended` is every `agent` or
/// `quick-entry` block newer than [baseVersion] whose text isn't already in
/// [localPerson], in `ord` order, blank-line separated (C3.1).
String mergeConflict({
  required String localPerson,
  required int baseVersion,
  required String serverBody,
  required List<ServerBlock> serverBlocks,
}) {
  final appended =
      serverBlocks
          .where(
            (block) =>
                _appendableSources.contains(block.source) &&
                block.createdVersion > baseVersion &&
                !localPerson.contains(block.text),
          )
          .toList()
        ..sort((a, b) => a.ord.compareTo(b.ord));
  var person = localPerson;
  for (final block in appended) {
    person = appendToPerson(person, block.text);
  }
  return assembleDailyBody(person, splitDailyBody(serverBody).chips);
}

/// Block sources whose newer blocks are re-appended on conflict (Req 60).
const Set<String> _appendableSources = {'agent', 'quick-entry'};

/// Appends [text] to a daily person section with the C3.1 separator: when
/// [person] is non-empty it is first padded to end with a blank line (`\n\n`),
/// then `text + "\n"` is appended.
///
/// The app's one C3.1 append: the conflict merge (Req 60) and the virtual
/// Today note's `daily_note_exists` path (#22) both use it.
String appendToPerson(String person, String text) {
  final String padded;
  if (person.isEmpty || person.endsWith('\n\n')) {
    padded = person;
  } else if (person.endsWith('\n')) {
    padded = '$person\n';
  } else {
    padded = '$person\n\n';
  }
  return '$padded$text\n';
}

/// The outcome of [mergeNonDaily].
sealed class NonDailyMergeResult {
  const NonDailyMergeResult();
}

/// The person's and the server's changes touch different lines: [text] is
/// the merged body, holding both, with the server's footer.
final class NonDailyMerged extends NonDailyMergeResult {
  const NonDailyMerged(this.text);

  final String text;
}

/// A line was changed on both sides (or both sides inserted different text
/// into the same gap of the base): nothing merges.
final class NonDailyOverlap extends NonDailyMergeResult {
  const NonDailyOverlap();
}

/// Three-way line merge of a non-daily note's person section after a save
/// conflict (Spec #7 Req 34a, D20). [base] is the body at the editor's base
/// version, [local] the editor's body and [server] the refetched body. Only
/// the person section ([splitNoteBody]) merges; the footer always comes from
/// [server].
///
/// The merge is line based (D20): each side's changes are the hunks of a
/// line diff against [base]. Hunks of the two sides whose base ranges share
/// a line, or two insertions into the same gap of the base, overlap, unless
/// both sides made exactly the same change, which is applied once. Any other
/// hunks merge in base order, an insertion going before an edit that starts
/// at the same line.
NonDailyMergeResult mergeNonDaily({
  required String base,
  required String local,
  required String server,
}) {
  final serverPerson = _aboveFooter(server);
  final footer = server.substring(serverPerson.length);
  final merged = _mergeLines(
    _linesOf(_aboveFooter(base)),
    _linesOf(_aboveFooter(local)),
    _linesOf(serverPerson),
  );
  if (merged == null) return const NonDailyOverlap();
  final person = merged.join();
  final separator =
      footer.isNotEmpty && person.isNotEmpty && !person.endsWith('\n')
      ? '\n'
      : '';
  return NonDailyMerged('$person$separator$footer');
}

/// The text of non-daily note [body] above its Note footer's marker line
/// ([splitNoteBody]), or all of [body] without a footer. Text a footer
/// holds below the marker stays with the footer.
String _aboveFooter(String body) {
  final person = splitNoteBody(body).person;
  if (person == body) return body;
  // The person section starts with the text above the footer's marker
  // line: the last marker line start whose preceding text it starts with.
  var at = 0;
  for (
    var i = body.indexOf(topicsMarker);
    i >= 0;
    i = body.indexOf(topicsMarker, i + 1)
  ) {
    if (i > 0 && body.codeUnitAt(i - 1) != 0x0A) continue;
    if (!person.startsWith(body.substring(0, i))) break;
    at = i;
  }
  return body.substring(0, at);
}

/// [text]'s lines, each with its `\n` (the last one without, when [text]
/// does not end with one). Joined, they are [text] again.
List<String> _linesOf(String text) {
  final lines = <String>[];
  var start = 0;
  while (start < text.length) {
    final newline = text.indexOf('\n', start);
    final end = newline < 0 ? text.length : newline + 1;
    lines.add(text.substring(start, end));
    start = end;
  }
  return lines;
}

/// One side's change against the base: base lines [start] to [end]
/// (exclusive) become [lines]. An insertion has `start == end`.
class _Hunk {
  const _Hunk(this.start, this.end, this.lines);

  final int start;
  final int end;
  final List<String> lines;

  bool get isInsertion => start == end;

  /// The same change as [other]: the same base lines become the same lines.
  bool sameAs(_Hunk other) =>
      start == other.start &&
      end == other.end &&
      _sameLines(lines, other.lines);

  /// This hunk and [other] (of the other side) touch the same base text:
  /// their base ranges share a line, or both insert into the same gap.
  bool overlaps(_Hunk other) =>
      (start < other.end && other.start < end) ||
      (isInsertion && other.isInsertion && start == other.start);
}

bool _sameLines(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The three-way merge of [local] and [server] against [base], as lines;
/// null on an overlap.
List<String>? _mergeLines(
  List<String> base,
  List<String> local,
  List<String> server,
) {
  final ours = _hunks(base, local);
  final theirs = _hunks(base, server);
  final out = <String>[];
  var at = 0;
  void apply(_Hunk hunk) {
    out
      ..addAll(base.sublist(at, hunk.start))
      ..addAll(hunk.lines);
    at = hunk.end;
  }

  var i = 0;
  var j = 0;
  while (i < ours.length || j < theirs.length) {
    if (j == theirs.length) {
      apply(ours[i++]);
      continue;
    }
    if (i == ours.length) {
      apply(theirs[j++]);
      continue;
    }
    final a = ours[i];
    final b = theirs[j];
    if (a.overlaps(b)) {
      if (!a.sameAs(b)) return null;
      apply(a);
      i++;
      j++;
    } else if (a.start < b.start || (a.start == b.start && a.isInsertion)) {
      apply(a);
      i++;
    } else {
      apply(b);
      j++;
    }
  }
  out.addAll(base.sublist(at));
  return out;
}

/// The hunks turning [base] into [side], in base order, from a longest
/// common subsequence of their lines. Neighbouring changed lines form one
/// hunk.
List<_Hunk> _hunks(List<String> base, List<String> side) {
  // Lines both ends share are never part of a hunk.
  var prefix = 0;
  final shorter = min(base.length, side.length);
  while (prefix < shorter && base[prefix] == side[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < shorter - prefix &&
      base[base.length - 1 - suffix] == side[side.length - 1 - suffix]) {
    suffix++;
  }
  final n = base.length - prefix - suffix;
  final m = side.length - prefix - suffix;
  // lcs[x * (m + 1) + y]: the longest common subsequence length of the
  // middle base lines from x and the middle side lines from y.
  final lcs = Uint32List((n + 1) * (m + 1));
  for (var x = n - 1; x >= 0; x--) {
    for (var y = m - 1; y >= 0; y--) {
      lcs[x * (m + 1) + y] = base[prefix + x] == side[prefix + y]
          ? lcs[(x + 1) * (m + 1) + y + 1] + 1
          : max(lcs[(x + 1) * (m + 1) + y], lcs[x * (m + 1) + y + 1]);
    }
  }
  final hunks = <_Hunk>[];
  int? hunkStart;
  var lines = <String>[];
  var x = 0;
  var y = 0;
  void close() {
    final start = hunkStart;
    if (start == null) return;
    hunks.add(_Hunk(prefix + start, prefix + x, lines));
    hunkStart = null;
    lines = <String>[];
  }

  while (x < n || y < m) {
    if (x < n && y < m && base[prefix + x] == side[prefix + y]) {
      close();
      x++;
      y++;
    } else if (y == m ||
        (x < n && lcs[(x + 1) * (m + 1) + y] >= lcs[x * (m + 1) + y + 1])) {
      hunkStart ??= x;
      x++;
    } else {
      hunkStart ??= x;
      lines.add(side[prefix + y]);
      y++;
    }
  }
  close();
  return hunks;
}

/// Where [offset] of [before] lands in [after], a text the server rewrote
/// (a merged save, Spec #7 Req 34a): on a line both texts share it keeps
/// its line and column, so the caret stays on the person's line when lines
/// above it were added, removed or lengthened. In a changed run of lines it
/// keeps its distance from the run's start, clamped to the new run.
int carryOffset(String before, String after, int offset) {
  final from = _linesOf(before);
  var oldAt = 0;
  var newAt = 0;
  var line = 0;
  for (final hunk in _hunks(from, _linesOf(after))) {
    final same = _lengthOf(from.sublist(line, hunk.start));
    if (offset < oldAt + same) return newAt + offset - oldAt;
    oldAt += same;
    newAt += same;
    final removed = _lengthOf(from.sublist(hunk.start, hunk.end));
    final added = _lengthOf(hunk.lines);
    if (offset < oldAt + removed) return newAt + min(offset - oldAt, added);
    oldAt += removed;
    newAt += added;
    line = hunk.end;
  }
  return min(newAt + max(offset - oldAt, 0), after.length);
}

int _lengthOf(List<String> lines) =>
    lines.fold(0, (sum, line) => sum + line.length);
