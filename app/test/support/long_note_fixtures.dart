// WI #125 (Spec #122 Requirements 1, 2, 36): the synthetic long notes every
// #122 perf WI and #123's 0-count criteria assert on. Deterministic (no
// `Random`, no clock): a note is a pure function of its kind and variant.
// Invented text only: no real note text and no paths (the LEAK step).
//
// - N1 plain-120k: 3,000 lines, `Speaker <n>: <invented sentence>`, with a
//   `## Section <k>` heading every 50 lines (line 0, 50, 100, ...).
// - N2 bullets-120k: N1 with every non-heading line a `- ` item.
// - N3 plain-500k / N4 bullets-500k: N1 / N2 at 12,000 lines.
// - N5 plain-long-lines-120k: 550 plain lines of ~220 characters, with a
//   heading every 10 lines.
// - Variants (any kind): misspelled (one invented flagged word in every
//   10th line: lines 9, 19, ...), misspelled-heavy (one in every line,
//   headings included) and decorated (an inline code span and a
//   `[[wikilink]]` on lines 5, 15, ...; a quote line at line 22 and a rule
//   at line 77 of every 100).
//
// Lines are joined with `\n`, no trailing newline, so `split('\n')` gives
// exactly the line count. Flagged words are letters only (the fake checker
// matches whole words) and come from a small pool, so registering them with
// `FakeSpellingService.misspell` stays cheap ([seedMisspellings]).
import 'fake_spelling_service.dart';

/// Which synthetic note.
enum LongNoteKind {
  /// 3,000 plain lines.
  n1Plain120k,

  /// 3,000 lines, non-heading lines as `- ` items.
  n2Bullets120k,

  /// 12,000 plain lines.
  n3Plain500k,

  /// 12,000 lines, non-heading lines as `- ` items.
  n4Bullets500k,

  /// 550 plain lines of ~220 characters.
  n5PlainLongLines120k,
}

/// What is added to a note's plain text.
enum LongNoteVariant {
  /// Nothing.
  plain,

  /// One flagged word in every 10th line.
  misspelled,

  /// One flagged word in every line.
  misspelledHeavy,

  /// A code span and a wikilink every 10 lines, a quote and a rule every
  /// 100.
  decorated,
}

/// One generated note.
class LongNote {
  LongNote._({
    required this.kind,
    required this.variant,
    required this.lines,
    required this.flaggedLines,
    required this.flaggedWords,
  }) : text = lines.join('\n');

  final LongNoteKind kind;
  final LongNoteVariant variant;

  /// The note's lines (no line break in any).
  final List<String> lines;

  /// The whole text: [lines] joined with `\n`.
  final String text;

  /// The 0-based indices of the lines that hold a flagged word, in order;
  /// each holds exactly one.
  final List<int> flaggedLines;

  /// The flagged word of each of [flaggedLines], in the same order.
  final List<String> flaggedWords;

  /// The distinct flagged words, in first-use order.
  List<String> get flaggedPool => flaggedWords.toSet().toList();

  /// How many lines are headings (`## Section <k>`).
  int get headingCount => lines.where((l) => l.startsWith('## ')).length;
}

/// The invented words no sentence ever uses: what a variant flags.
const List<String> longNoteFlaggedPool = [
  'qwerblat',
  'zorplin',
  'fnarkle',
  'blorptic',
  'wumbleth',
  'snarfid',
  'krizzle',
  'plomberg',
];

const _adjectives = [
  'quiet',
  'brisk',
  'amber',
  'tall',
  'faint',
  'wooden',
  'bright',
  'narrow',
  'lazy',
  'mossy',
  'distant',
];
const _nouns = [
  'lamp',
  'river',
  'harbor',
  'kettle',
  'garden',
  'ladder',
  'window',
  'bridge',
  'orchard',
  'lantern',
  'meadow',
  'compass',
  'barn',
];
const _verbs = ['drifts', 'waits', 'hums', 'turns', 'glows', 'leans', 'rests'];
const _adverbs = [
  'slowly',
  'nearby',
  'again',
  'softly',
  'today',
  'closely',
  'alone',
  'upstairs',
  'warmly',
];

/// Sentence [s] of line [i]: four words from the lists, then a period.
List<String> _sentenceWords(int i, int s) => [
  _adjectives[(i * 5 + s * 3) % _adjectives.length],
  _nouns[(i * 7 + s * 11 + 1) % _nouns.length],
  _verbs[(i * 3 + s * 5 + 2) % _verbs.length],
  _adverbs[(i * 11 + s * 7 + 3) % _adverbs.length],
];

/// The body text of line [i]: one sentence, or (for [minLength] > 0) whole
/// sentences until the body is at least [minLength] long. [flagged], when
/// given, becomes the second word of the first sentence.
String _body(int i, {int minLength = 0, String? flagged}) {
  final sentences = <String>[];
  var length = 0;
  var s = 0;
  do {
    final words = _sentenceWords(i, s);
    if (s == 0 && flagged != null) words.insert(1, flagged);
    final sentence = '${words.join(' ')}.';
    sentences.add(sentence);
    length += sentence.length + (s == 0 ? 0 : 1);
    s++;
  } while (length < minLength);
  return sentences.join(' ');
}

/// Builds the note [kind] with [variant].
LongNote longNote(
  LongNoteKind kind, {
  LongNoteVariant variant = LongNoteVariant.plain,
}) {
  final (count, bullets, longLines, headingEvery) = switch (kind) {
    LongNoteKind.n1Plain120k => (3000, false, false, 50),
    LongNoteKind.n2Bullets120k => (3000, true, false, 50),
    LongNoteKind.n3Plain500k => (12000, false, false, 50),
    LongNoteKind.n4Bullets500k => (12000, true, false, 50),
    LongNoteKind.n5PlainLongLines120k => (550, false, true, 10),
  };
  final lines = <String>[];
  final flaggedLines = <int>[];
  final flaggedWords = <String>[];
  for (var i = 0; i < count; i++) {
    final heading = i % headingEvery == 0;
    final flag = switch (variant) {
      LongNoteVariant.misspelled => i % 10 == 9,
      LongNoteVariant.misspelledHeavy => true,
      _ => false,
    };
    final word = flag
        ? longNoteFlaggedPool[(i * 3 + i ~/ 10) % longNoteFlaggedPool.length]
        : null;
    if (word != null) {
      flaggedLines.add(i);
      flaggedWords.add(word);
    }
    if (heading) {
      final base = '## Section ${i ~/ headingEvery + 1}';
      lines.add(word == null ? base : '$base $word');
      continue;
    }
    if (variant == LongNoteVariant.decorated) {
      if (i % 100 == 22) {
        lines.add('> Quoted remark ${_body(i)}');
        continue;
      }
      if (i % 100 == 77) {
        lines.add('***');
        continue;
      }
    }
    final minLength = longLines ? 210 + (i * 13) % 21 : 0;
    var body = _body(i, minLength: minLength, flagged: word);
    if (variant == LongNoteVariant.decorated && i % 10 == 5) {
      body = '$body Run `step${i ~/ 10}` then open [[Note ${i ~/ 10}]].';
    }
    lines.add(bullets ? '- Speaker $i: $body' : 'Speaker $i: $body');
  }
  return LongNote._(
    kind: kind,
    variant: variant,
    lines: lines,
    flaggedLines: flaggedLines,
    flaggedWords: flaggedWords,
  );
}

/// Registers every flagged word of [note] with [spelling] (a no-op for a
/// note with none), so the fake checker reports exactly those words.
void seedMisspellings(
  FakeSpellingService spelling,
  LongNote note, {
  List<String> corrections = const ['sound'],
}) {
  for (final word in note.flaggedPool) {
    spelling.misspell(word, corrections: corrections);
  }
}
