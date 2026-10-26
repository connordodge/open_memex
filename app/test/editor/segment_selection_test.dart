// WI #163 (A4): cross-row selection math (Spec #157 R23, R26, R27, R28;
// rulings D2, D4, D17).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/segment_selection.dart';

import '../support/markdown_fixtures.dart';

// ---------------------------------------------------------------------------
// Helpers.

/// A row built from run-time values (not `const`).
RowSpec _row(RowKind kind, int start, int textStart, int textEnd, int end) =>
    RowSpec(
      kind: kind,
      start: start,
      textStart: textStart,
      textEnd: textEnd,
      end: end,
    );

/// A selection built from run-time values (not `const`).
SegmentSelection _sel(int base, int extent) =>
    SegmentSelection(baseOffset: base, extentOffset: extent);

/// Applies [edit] to [text] without A1's `SegmentEdit.apply`, so these tests
/// exercise only A4.
String _apply(String text, SegmentEdit edit) =>
    text.replaceRange(edit.start, edit.end, edit.replacement);

List<RowSpec> _rowsOf(String text) => splitRows(text, atSegmentStart: false);

bool _isHigh(int c) => c >= 0xD800 && c <= 0xDBFF;
bool _isLow(int c) => c >= 0xDC00 && c <= 0xDFFF;

/// Whether [offset] falls between the two halves of a surrogate pair.
bool _splitsPair(String text, int offset) =>
    offset > 0 &&
    offset < text.length &&
    _isHigh(text.codeUnitAt(offset - 1)) &&
    _isLow(text.codeUnitAt(offset));

/// Whether [offset] falls between the `\r` and `\n` of a CRLF.
bool _splitsCrlf(String text, int offset) =>
    offset > 0 &&
    offset < text.length &&
    text.codeUnitAt(offset - 1) == 0x0D &&
    text.codeUnitAt(offset) == 0x0A;

/// Whether [offset] is a place the caret may stand: inside some row's text
/// (`textStart..textEnd`, never in a marker or a row terminator), not inside
/// a surrogate pair and not between `\r` and `\n`.
bool _isCaret(String text, List<RowSpec> rows, int offset) =>
    rows.any((r) => r.textStart <= offset && offset <= r.textEnd) &&
    !_splitsPair(text, offset) &&
    !_splitsCrlf(text, offset);

/// Every caret position of [text] in order.
List<int> _carets(String text, List<RowSpec> rows) => [
  for (var o = 0; o <= text.length; o++)
    if (_isCaret(text, rows, o)) o,
];

/// A random offset in `0..text.length` that doesn't split a surrogate pair.
int _safeOffset(Random rng, String text) {
  final o = rng.nextInt(text.length + 1);
  return _splitsPair(text, o) ? o - 1 : o;
}

bool _ascii(int c) => c < 0x80;

/// Whether [offset] is near a multi-code-point emoji cluster (ZWJ, a
/// variation selector or a skin-tone modifier), where a grapheme-cluster
/// step and a code-point step legitimately differ.
bool _nearCluster(String text, int offset) {
  for (var i = max(0, offset - 4); i < min(text.length, offset + 4); i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x200D || (c >= 0xFE00 && c <= 0xFE0F)) return true;
    if (c >= 0xDFFB &&
        c <= 0xDFFF &&
        i > 0 &&
        text.codeUnitAt(i - 1) == 0xD83C) {
      return true;
    }
  }
  return false;
}

typedef _Step = int Function(String text, List<RowSpec> rows, int offset);

const List<(String, _Step, _Step)> _stepPairs = [
  ('character', nextCharacterOffset, previousCharacterOffset),
  ('word', nextWordOffset, previousWordOffset),
];

/// Extra hand-written emoji texts: pairs at row edges, a skin-tone modifier
/// and a ZWJ flag sequence.
const List<String> _emojiTexts = [
  '😀\n- 👍🏽\n> 🏳️‍🌈x',
  '- 😀\n- 😀😀 😀\n1. 🔟\n',
  '😀😀\r\n- [ ] 🧪',
];

/// Every fixture text plus the hand-written emoji texts, labelled.
Iterable<(String, String)> _allTexts() sync* {
  for (final MapEntry(key: name, value: text) in markdownFixtures.entries) {
    yield (name, text);
  }
  for (final (i, text) in _emojiTexts.indexed) {
    yield ('emoji text $i', text);
  }
}

// `para\n- ab\n- cd`: prose `para`, bullets `ab` and `cd`.
const _para = 'para\n- ab\n- cd';
List<RowSpec> _paraRows() => [
  _row(RowKind.prose, 0, 0, 4, 5),
  _row(RowKind.bullet, 5, 7, 9, 10),
  _row(RowKind.bullet, 10, 12, 14, 14),
];

// `- a\n- b`: two bullets; `a` is 2..3, `b` is 6..7.
const _ab = '- a\n- b';
List<RowSpec> _abRows() => [
  _row(RowKind.bullet, 0, 2, 3, 4),
  _row(RowKind.bullet, 4, 6, 7, 7),
];

void main() {
  group('copyText (R27, D17)', () {
    test(
      'copyText equals substring for every selection in a seeded sweep over markdown fixtures',
      () {
        final rng = Random(163);
        var itemToItem = 0;
        for (final (name, text) in _allTexts()) {
          // Arbitrary offsets, surrogate halves included: copyText is always
          // the substring (D17).
          for (var i = 0; i < 200; i++) {
            final base = rng.nextInt(text.length + 1);
            final extent = rng.nextInt(text.length + 1);
            final s = _sel(base, extent);
            expect(
              copyText(text, s),
              text.substring(min(base, extent), max(base, extent)),
              reason: '$name $s',
            );
          }
          expect(copyText(text, _sel(0, text.length)), text, reason: name);
          expect(copyText(text, _sel(text.length, 0)), text, reason: name);

          // Ranges from inside one row's text to inside a later row's text.
          final rows = _rowsOf(text);
          for (var a = 0; a < rows.length; a++) {
            for (var b = a + 1; b < rows.length; b++) {
              final ra = rows[a];
              final rb = rows[b];
              final from = ra.textStart + rng.nextInt(ra.textLength + 1);
              final to = rb.textStart + rng.nextInt(rb.textLength + 1);
              if (ra.isItem && rb.isItem) itemToItem++;
              for (final s in [_sel(from, to), _sel(to, from)]) {
                expect(
                  copyText(text, s),
                  text.substring(from, to),
                  reason: '$name rows $a..$b $s',
                );
              }
            }
          }
        }
        expect(itemToItem, greaterThan(100), reason: 'sweep is real');
      },
    );

    test(
      'copyText from inside one item text to inside another keeps markers indentation and newlines',
      () {
        final tasks = markdownFixtures['tasks']!;
        final tFrom = tasks.indexOf('pen');
        final tTo = tasks.indexOf('one\n');
        expect(copyText(tasks, _sel(tFrom, tTo)), 'pen\n- [x] d');
        expect(copyText(tasks, _sel(tTo, tFrom)), 'pen\n- [x] d');

        final crlf = markdownFixtures['crlf']!;
        final cFrom = crlf.indexOf('ne\r\n');
        final cTo = crlf.indexOf('sted');
        expect(copyText(crlf, _sel(cFrom, cTo)), 'ne\r\n- two\r\n  - ne');

        final tabs = markdownFixtures['tabs']!;
        final bFrom = tabs.indexOf('bullet');
        final bTo = tabs.indexOf('tabs\n') + 2;
        expect(copyText(tabs, _sel(bFrom, bTo)), 'bullet\n\t\t- two ta');

        expect(copyText(_para, _sel(8, 8)), '');
      },
    );
  });

  group('deleteRange (R27)', () {
    test(
      'deleteRange over para ab cd from after a to after c gives para ad with the caret after a',
      () {
        final edit = deleteRange(_para, _paraRows(), _sel(8, 13));
        expect(
          edit,
          SegmentEdit(
            start: 8,
            end: 13,
            replacement: '',
            selection: const SegmentSelection.collapsed(8),
          ),
        );
        expect(_apply(_para, edit), 'para\n- ad');
      },
    );

    test('deleteRange with a reversed selection gives the same edit', () {
      final forward = deleteRange(_para, _paraRows(), _sel(8, 13));
      final backward = deleteRange(_para, _paraRows(), _sel(13, 8));
      expect(backward, forward);
      expect(backward.selection, const SegmentSelection.collapsed(8));
      expect(_apply(_para, backward), 'para\n- ad');
    });

    test('deleteRange of a collapsed selection is a no-op edit', () {
      for (var o = 0; o <= _para.length; o++) {
        final edit = deleteRange(_para, _paraRows(), _sel(o, o));
        expect(edit.replacement, '', reason: 'at $o');
        expect(edit.end, edit.start, reason: 'at $o');
        expect(_apply(_para, edit), _para, reason: 'at $o');
        expect(
          edit.selection,
          SegmentSelection.collapsed(o),
          reason: 'caret stays at $o',
        );
      }
    });

    test(
      'deleteRange removes the raw range with markers in a seeded sweep over markdown fixtures',
      () {
        final rng = Random(1630);
        for (final (name, text) in _allTexts()) {
          final rows = _rowsOf(text);
          for (var i = 0; i < 60; i++) {
            final s = _sel(_safeOffset(rng, text), _safeOffset(rng, text));
            final edit = deleteRange(text, rows, s);
            expect(
              edit,
              SegmentEdit(
                start: s.start,
                end: s.end,
                replacement: '',
                selection: SegmentSelection.collapsed(s.start),
              ),
              reason: '$name $s',
            );
            expect(
              _apply(text, edit),
              text.substring(0, s.start) + text.substring(s.end),
              reason: '$name $s',
            );
          }
        }
      },
    );

    test(
      'deleteRange of the whole segment leaves it empty with the caret at 0',
      () {
        final text = markdownFixtures['nested lists']!;
        final edit = deleteRange(text, _rowsOf(text), _sel(text.length, 0));
        expect(_apply(text, edit), '');
        expect(edit.selection, const SegmentSelection.collapsed(0));
      },
    );
  });

  group('replaceRange (R27)', () {
    test(
      'replaceRange with X over para ab cd gives para aXd with the caret after X',
      () {
        final edit = replaceRange(_para, _paraRows(), _sel(8, 13), 'X');
        expect(
          edit,
          SegmentEdit(
            start: 8,
            end: 13,
            replacement: 'X',
            selection: const SegmentSelection.collapsed(9),
          ),
        );
        expect(_apply(_para, edit), 'para\n- aXd');
        expect(
          replaceRange(_para, _paraRows(), _sel(13, 8), 'X'),
          edit,
          reason: 'reversed selection',
        );
      },
    );

    test(
      'replaceRange with a pasted multi line string puts the caret after its last character',
      () {
        for (final pasted in [
          '1\n- two\r\n> 😀',
          'line\n',
          '\r\n',
          '- [ ] a\n  - b\n',
        ]) {
          final edit = replaceRange(_para, _paraRows(), _sel(8, 13), pasted);
          expect(
            edit,
            SegmentEdit(
              start: 8,
              end: 13,
              replacement: pasted,
              selection: SegmentSelection.collapsed(8 + pasted.length),
            ),
            reason: '${pasted.codeUnits}',
          );
          expect(
            _apply(_para, edit),
            'para\n- a${pasted}d',
            reason: '${pasted.codeUnits}',
          );
        }
      },
    );

    test('replaceRange over a collapsed selection inserts at the caret', () {
      final edit = replaceRange(_para, _paraRows(), _sel(8, 8), 'XY');
      expect(
        edit,
        SegmentEdit(
          start: 8,
          end: 8,
          replacement: 'XY',
          selection: const SegmentSelection.collapsed(10),
        ),
      );
      expect(_apply(_para, edit), 'para\n- aXYb\n- cd');
    });

    test(
      'replaceRange is plain replacement of the raw range in a seeded sweep over markdown fixtures',
      () {
        final rng = Random(1631);
        const inserts = ['', 'X', '😀', 'a\nb', '- c\r\n', '\t- [x] z'];
        for (final (name, text) in _allTexts()) {
          final rows = _rowsOf(text);
          for (var i = 0; i < 60; i++) {
            final s = _sel(_safeOffset(rng, text), _safeOffset(rng, text));
            final inserted = inserts[rng.nextInt(inserts.length)];
            final edit = replaceRange(text, rows, s, inserted);
            expect(
              edit,
              SegmentEdit(
                start: s.start,
                end: s.end,
                replacement: inserted,
                selection: SegmentSelection.collapsed(
                  s.start + inserted.length,
                ),
              ),
              reason: '$name $s ${inserted.codeUnits}',
            );
            expect(
              _apply(text, edit),
              text.substring(0, s.start) + inserted + text.substring(s.end),
              reason: '$name $s',
            );
          }
        }
      },
    );
  });

  group('clampToSegment (R28)', () {
    test(
      'clampToSegment clamps both ends into the segment and keeps direction',
      () {
        for (final (text, base, extent, wantBase, wantExtent) in [
          ('abc', -3, 50, 0, 3),
          ('abc', 50, -3, 3, 0),
          ('abc', 1, 2, 1, 2),
          ('abc', 2, 1, 2, 1),
          ('abc', 3, 0, 3, 0),
          ('abc', 0, 3, 0, 3),
          ('abc', 5, 5, 3, 3),
          ('abc', -1, -1, 0, 0),
          ('abc', 4, 2, 3, 2),
          ('abc', 1, -9, 1, 0),
          ('', 2, -2, 0, 0),
          ('', 0, 0, 0, 0),
          (_para, 99, 8, 14, 8),
          (_para, 8, 14, 8, 14),
          (_para, 15, 14, 14, 14),
        ]) {
          final got = clampToSegment(_sel(base, extent), text);
          expect(
            (got.baseOffset, got.extentOffset),
            (wantBase, wantExtent),
            reason: '${text.codeUnits} ($base, $extent)',
          );
        }
      },
    );

    test(
      'clampToSegment leaves every in range selection unchanged over markdown fixtures',
      () {
        final rng = Random(1632);
        for (final (name, text) in _allTexts()) {
          for (var i = 0; i < 60; i++) {
            final s = _sel(_safeOffset(rng, text), _safeOffset(rng, text));
            expect(clampToSegment(s, text), s, reason: '$name $s');
          }
        }
      },
    );
  });

  group('steps at row edges (R23, R26)', () {
    test(
      'a character step right from the end of a row text lands at the next row text start and back',
      () {
        final rows = _abRows();
        expect(nextCharacterOffset(_ab, rows, 3), 6, reason: 'to b');
        expect(previousCharacterOffset(_ab, rows, 6), 3, reason: 'after a');
      },
    );

    test(
      'a word step right from the end of a row text lands at the next row text start and back',
      () {
        final rows = _abRows();
        expect(nextWordOffset(_ab, rows, 3), 6, reason: 'to b');
        expect(previousWordOffset(_ab, rows, 6), 3, reason: 'after a');
      },
    );

    test('steps stop at the first and last row of the segment', () {
      final rows = _abRows();
      for (final (kind, next, previous) in _stepPairs) {
        expect(previous(_ab, rows, 2), 2, reason: '$kind left at start');
        expect(next(_ab, rows, 7), 7, reason: '$kind right at end');
        expect(next(_ab, rows, 6), 7, reason: '$kind right inside b');
        expect(previous(_ab, rows, 3), 2, reason: '$kind left inside a');
      }
      final empty = [_row(RowKind.prose, 0, 0, 0, 0)];
      for (final (kind, next, previous) in _stepPairs) {
        expect(next('', empty, 0), 0, reason: '$kind right in empty');
        expect(previous('', empty, 0), 0, reason: '$kind left in empty');
      }
    });

    test(
      'steps cross a prose row and its CRLF terminator without landing in it',
      () {
        const text = 'para\r\n- b';
        final rows = [
          _row(RowKind.prose, 0, 0, 4, 6),
          _row(RowKind.bullet, 6, 8, 9, 9),
        ];
        for (final (kind, next, previous) in _stepPairs) {
          expect(next(text, rows, 4), 8, reason: '$kind right');
          expect(previous(text, rows, 8), 4, reason: '$kind left');
        }
      },
    );

    test('steps stop once at a row whose text is empty', () {
      const text = '- a\n- \n- b';
      final rows = [
        _row(RowKind.bullet, 0, 2, 3, 4),
        _row(RowKind.bullet, 4, 6, 6, 7),
        _row(RowKind.bullet, 7, 9, 10, 10),
      ];
      for (final (kind, next, previous) in _stepPairs) {
        expect(next(text, rows, 3), 6, reason: '$kind right into empty');
        expect(next(text, rows, 6), 9, reason: '$kind right out of empty');
        expect(previous(text, rows, 9), 6, reason: '$kind left into empty');
        expect(previous(text, rows, 6), 3, reason: '$kind left out of empty');
      }
    });

    test(
      'every row text end steps right to the next row text start over markdown fixtures',
      () {
        var edges = 0;
        for (final (name, text) in _allTexts()) {
          final rows = _rowsOf(text);
          for (final (kind, next, previous) in _stepPairs) {
            for (var i = 0; i + 1 < rows.length; i++) {
              final a = rows[i];
              final b = rows[i + 1];
              expect(
                next(text, rows, a.textEnd),
                b.textStart,
                reason: '$name $kind right from row $i $a',
              );
              expect(
                previous(text, rows, b.textStart),
                a.textEnd,
                reason: '$name $kind left from row ${i + 1} $b',
              );
              edges++;
            }
            expect(
              previous(text, rows, rows.first.textStart),
              rows.first.textStart,
              reason: '$name $kind left at the segment start',
            );
            expect(
              next(text, rows, rows.last.textEnd),
              rows.last.textEnd,
              reason: '$name $kind right at the segment end',
            );
          }
        }
        expect(edges, greaterThan(100), reason: 'sweep is real');
      },
    );

    test('a character step inside a row moves one character', () {
      const item = '- abc';
      final itemRows = [_row(RowKind.bullet, 0, 2, 5, 5)];
      expect(nextCharacterOffset(item, itemRows, 2), 3);
      expect(nextCharacterOffset(item, itemRows, 3), 4);
      expect(nextCharacterOffset(item, itemRows, 4), 5);
      expect(previousCharacterOffset(item, itemRows, 5), 4);
      expect(previousCharacterOffset(item, itemRows, 4), 3);
      expect(previousCharacterOffset(item, itemRows, 3), 2);

      // A prose row keeps its interior terminators as text.
      const lf = 'a\nb';
      final lfRows = [_row(RowKind.prose, 0, 0, 3, 3)];
      expect(nextCharacterOffset(lf, lfRows, 1), 2);
      expect(previousCharacterOffset(lf, lfRows, 2), 1);

      // An interior CRLF is one step: never between its two code units.
      const crlf = 'a\r\nb';
      final crlfRows = [_row(RowKind.prose, 0, 0, 4, 4)];
      expect(nextCharacterOffset(crlf, crlfRows, 1), 3);
      expect(previousCharacterOffset(crlf, crlfRows, 3), 1);
    });

    test(
      'a character step left undoes a character step right over markdown fixtures',
      () {
        for (final (name, text) in _allTexts()) {
          final rows = _rowsOf(text);
          for (final o in _carets(text, rows)) {
            if (_nearCluster(text, o)) continue;
            final right = nextCharacterOffset(text, rows, o);
            if (right != o) {
              expect(
                previousCharacterOffset(text, rows, right),
                o,
                reason: '$name left from $right after right from $o',
              );
            }
            final left = previousCharacterOffset(text, rows, o);
            if (left != o) {
              expect(
                nextCharacterOffset(text, rows, left),
                o,
                reason: '$name right from $left after left from $o',
              );
            }
          }
        }
      },
    );
  });

  group('word steps inside a row (R23, R26)', () {
    test('inside a row word steps match the row text word boundaries', () {
      const prose = 'foo bar';
      final proseRows = [_row(RowKind.prose, 0, 0, 7, 7)];
      expect(nextWordOffset(prose, proseRows, 0), 3, reason: 'after foo');
      expect(nextWordOffset(prose, proseRows, 3), 7, reason: 'after bar');
      expect(nextWordOffset(prose, proseRows, 1), 3, reason: 'inside foo');
      expect(previousWordOffset(prose, proseRows, 7), 4, reason: 'before bar');
      expect(previousWordOffset(prose, proseRows, 4), 0, reason: 'before foo');
      expect(previousWordOffset(prose, proseRows, 5), 4, reason: 'inside bar');

      // The same words behind a marker: boundaries come from the row text.
      const item = '- foo bar';
      final itemRows = [_row(RowKind.bullet, 0, 2, 9, 9)];
      expect(nextWordOffset(item, itemRows, 2), 5, reason: 'after foo');
      expect(nextWordOffset(item, itemRows, 5), 9, reason: 'after bar');
      expect(nextWordOffset(item, itemRows, 3), 5, reason: 'inside foo');
      expect(previousWordOffset(item, itemRows, 9), 6, reason: 'before bar');
      expect(previousWordOffset(item, itemRows, 6), 2, reason: 'before foo');
      expect(previousWordOffset(item, itemRows, 7), 6, reason: 'inside bar');
    });

    test('word steps skip a run of spaces inside a row', () {
      const text = 'foo   bar';
      final rows = [_row(RowKind.prose, 0, 0, 9, 9)];
      expect(nextWordOffset(text, rows, 0), 3);
      expect(nextWordOffset(text, rows, 3), 9);
      expect(nextWordOffset(text, rows, 4), 9);
      expect(previousWordOffset(text, rows, 9), 6);
      expect(previousWordOffset(text, rows, 6), 0);
      expect(previousWordOffset(text, rows, 5), 0);
    });

    test(
      'a word step from inside a row text stays in that row over markdown fixtures',
      () {
        for (final (name, text) in _allTexts()) {
          final rows = _rowsOf(text);
          for (final (i, r) in rows.indexed) {
            for (final o in _carets(text, rows)) {
              if (o < r.textStart || o > r.textEnd) continue;
              if (o < r.textEnd) {
                final right = nextWordOffset(text, rows, o);
                expect(
                  right > o && right <= r.textEnd,
                  isTrue,
                  reason: '$name row $i right from $o got $right',
                );
              }
              if (o > r.textStart) {
                final left = previousWordOffset(text, rows, o);
                expect(
                  left < o && left >= r.textStart,
                  isTrue,
                  reason: '$name row $i left from $o got $left',
                );
              }
            }
          }
        }
      },
    );
  });

  group('surrogate pairs (D4)', () {
    test('character steps move over a whole surrogate pair', () {
      const pairs = '- 😀😀';
      final pairRows = [_row(RowKind.bullet, 0, 2, 6, 6)];
      expect(nextCharacterOffset(pairs, pairRows, 2), 4);
      expect(nextCharacterOffset(pairs, pairRows, 4), 6);
      expect(previousCharacterOffset(pairs, pairRows, 6), 4);
      expect(previousCharacterOffset(pairs, pairRows, 4), 2);

      const edge = '- a\n- 😀';
      final edgeRows = [
        _row(RowKind.bullet, 0, 2, 3, 4),
        _row(RowKind.bullet, 4, 6, 8, 8),
      ];
      expect(nextCharacterOffset(edge, edgeRows, 3), 6);
      expect(nextCharacterOffset(edge, edgeRows, 6), 8);
      expect(previousCharacterOffset(edge, edgeRows, 8), 6);
      expect(previousCharacterOffset(edge, edgeRows, 6), 3);
    });

    test(
      'no step result falls inside a surrogate pair or a marker over the emoji fixtures',
      () {
        var checked = 0;
        for (final (name, text) in _allTexts()) {
          final rows = _rowsOf(text);
          final first = rows.first.textStart;
          final last = rows.last.textEnd;
          for (final o in _carets(text, rows)) {
            for (final (kind, next, previous) in _stepPairs) {
              final right = next(text, rows, o);
              final left = previous(text, rows, o);
              expect(
                _isCaret(text, rows, right),
                isTrue,
                reason: '$name $kind right from $o got $right',
              );
              expect(
                _isCaret(text, rows, left),
                isTrue,
                reason: '$name $kind left from $o got $left',
              );
              expect(
                o == last ? right == o : right > o,
                isTrue,
                reason: '$name $kind right from $o got $right',
              );
              expect(
                o == first ? left == o : left < o,
                isTrue,
                reason: '$name $kind left from $o got $left',
              );
              checked++;
            }
            // Plain ASCII inside a row text is one code unit per step.
            final r = rows.firstWhere(
              (r) => r.textStart <= o && o <= r.textEnd,
            );
            if (o < r.textEnd &&
                _ascii(text.codeUnitAt(o)) &&
                (o + 1 >= text.length || _ascii(text.codeUnitAt(o + 1))) &&
                !_splitsCrlf(text, o + 1)) {
              expect(
                nextCharacterOffset(text, rows, o),
                o + 1,
                reason: '$name right from $o over ascii',
              );
            }
            if (o > r.textStart &&
                _ascii(text.codeUnitAt(o - 1)) &&
                !_splitsCrlf(text, o - 1)) {
              expect(
                previousCharacterOffset(text, rows, o),
                o - 1,
                reason: '$name left from $o over ascii',
              );
            }
          }
        }
        expect(checked, greaterThan(1000), reason: 'sweep is real');
      },
    );

    test('clampToSegment never leaves an end inside a surrogate pair', () {
      for (final (name, text) in _allTexts()) {
        for (var o = 0; o < text.length; o++) {
          if (!_splitsPair(text, o)) continue;
          final got = clampToSegment(_sel(o, text.length + 5), text);
          expect(
            got.baseOffset == o - 1 || got.baseOffset == o + 1,
            isTrue,
            reason: '$name base $o got ${got.baseOffset}',
          );
          expect(got.extentOffset, text.length, reason: name);
          final back = clampToSegment(_sel(-5, o), text);
          expect(back.baseOffset, 0, reason: name);
          expect(
            back.extentOffset == o - 1 || back.extentOffset == o + 1,
            isTrue,
            reason: '$name extent $o got ${back.extentOffset}',
          );
        }
      }
    });

    test(
      'deleteRange and replaceRange carets never fall inside a surrogate pair over the emoji fixtures',
      () {
        final rng = Random(1633);
        for (final (name, text) in _allTexts()) {
          final rows = _rowsOf(text);
          for (var i = 0; i < 60; i++) {
            final s = _sel(_safeOffset(rng, text), _safeOffset(rng, text));
            final deleted = deleteRange(text, rows, s);
            final afterDelete = _apply(text, deleted);
            expect(
              _splitsPair(afterDelete, deleted.selection!.extentOffset),
              isFalse,
              reason: '$name delete $s',
            );
            final replaced = replaceRange(text, rows, s, '🧪');
            final afterReplace = _apply(text, replaced);
            expect(
              _splitsPair(afterReplace, replaced.selection!.extentOffset),
              isFalse,
              reason: '$name replace $s',
            );
          }
        }
      },
    );
  });

  group('purity (D2)', () {
    test('segment_selection imports nothing from package flutter', () {
      // `flutter test` runs with the package root (`app/`) as cwd.
      const path = 'lib/src/editor/segment_selection.dart';
      final source = File(path).readAsStringSync();
      expect(source, contains('copyText'), reason: '$path was read');
      final imports = [
        for (final line in const LineSplitter().convert(source))
          if (RegExp(r'^\s*(import|export|part)\s').hasMatch(line)) line,
      ];
      for (final line in imports) {
        expect(line, isNot(contains('package:flutter')), reason: path);
        expect(line, isNot(contains('dart:ui')), reason: path);
      }
    });
  });
}
