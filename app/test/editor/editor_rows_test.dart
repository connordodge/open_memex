// WI #160 (A1): byte-exact editor rows (Spec #157 R9, R11, R12, R14, R21,
// R24, R39, R40; rulings D2, D4, D12, D17).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/markdown_lines.dart';
import 'package:open_memex_app/src/editor/segments.dart';

import '../support/markdown_fixtures.dart';

List<RowSpec> _rows(String text, {bool atSegmentStart = false}) =>
    splitRows(text, atSegmentStart: atSegmentStart);

/// `(kind, prefix, text, terminator)` of each row: the bytes before the
/// row's text, its text and its terminator.
List<(RowKind, String, String, String)> _shape(
  String text, {
  bool atSegmentStart = false,
}) => [
  for (final r in _rows(text, atSegmentStart: atSegmentStart))
    (
      r.kind,
      text.substring(r.start, r.textStart),
      text.substring(r.textStart, r.textEnd),
      text.substring(r.textEnd, r.end),
    ),
];

const _prose = RowKind.prose;
const _code = RowKind.code;
const _bullet = RowKind.bullet;
const _numbered = RowKind.numbered;
const _task = RowKind.task;
const _quote = RowKind.quote;

bool _isHigh(int c) => c >= 0xD800 && c <= 0xDBFF;
bool _isLow(int c) => c >= 0xDC00 && c <= 0xDFFF;

/// Whether [offset] falls between the two halves of a surrogate pair.
bool _splitsPair(String text, int offset) =>
    offset > 0 &&
    offset < text.length &&
    _isHigh(text.codeUnitAt(offset - 1)) &&
    _isLow(text.codeUnitAt(offset));

/// Every structural invariant of [rows] over [text] (R9, R14, R39, D4).
void _expectWellFormed(String text, List<RowSpec> rows, String label) {
  expect(rows, isNotEmpty, reason: '$label: at least one row');
  expect(rows.first.start, 0, reason: '$label: first row starts at 0');
  expect(rows.last.end, text.length, reason: '$label: last row ends at end');
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    final at = '$label row $i $r';
    if (i > 0) expect(r.start, rows[i - 1].end, reason: '$at: rows tile');
    expect(r.start <= r.textStart, isTrue, reason: at);
    expect(r.textStart <= r.textEnd, isTrue, reason: at);
    expect(r.textEnd <= r.end, isTrue, reason: at);
    final terminator = text.substring(r.textEnd, r.end);
    if (i < rows.length - 1) {
      expect(['\n', '\r\n'], contains(terminator), reason: at);
    } else {
      expect(terminator, '', reason: '$at: last row has no terminator');
    }
    if (r.isItem) {
      expect(
        text.substring(r.textStart, r.textEnd).contains('\n'),
        isFalse,
        reason: '$at: item text holds no terminator',
      );
    } else {
      expect(r.textStart, r.start, reason: '$at: prose/code text starts row');
    }
    if (i > 0) {
      expect(
        r.kind == _prose && rows[i - 1].kind == _prose,
        isFalse,
        reason: '$at: prose runs are maximal',
      );
    }
    for (final o in [r.start, r.textStart, r.textEnd, r.end]) {
      expect(_splitsPair(text, o), isFalse, reason: '$at: boundary $o');
    }
  }
  expect(joinRows(text, rows), text, reason: '$label: join reproduces text');
}

/// Every `content_md` string in the api_v1 wire fixtures (read-only).
List<String> _apiV1ContentMd() {
  final found = <String>[];
  void walk(Object? node) {
    if (node is Map) {
      for (final MapEntry(:key, :value) in node.entries) {
        if (key == 'content_md' && value is String) {
          found.add(value);
        } else {
          walk(value);
        }
      }
    } else if (node is List) {
      node.forEach(walk);
    }
  }

  // `flutter test` runs with the package root (`app/`) as cwd.
  final files =
      Directory('test/fixtures/api_v1')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    walk(jsonDecode(f.readAsStringSync()));
  }
  return found;
}

/// Grammar-shaped pieces the generated sweep draws from.
const _pieces = [
  '- ', '* ', '+ ', '1. ', '10. ', '[ ] ', '[x] ', '[X]', '> ', '>', '# ', //
  '##', '```', '~~~', '---', '***', '___', '\n', '\n', '\n', '\r\n', //
  '\r\n', '\r', '\t', '  ', ' ', 'a', 'word', '😀', '👍🏽', '1)', '#tag', //
  '_', '`', '![[2026-09-05#^b7k2m9]]', '[[Note]]', '-', '9.', //
];

String _generate(Random rng, int maxPieces) {
  final out = StringBuffer();
  final n = rng.nextInt(maxPieces + 1);
  for (var i = 0; i < n; i++) {
    out.write(_pieces[rng.nextInt(_pieces.length)]);
  }
  return out.toString();
}

/// A random offset in `0..text.length` that doesn't split a surrogate pair.
int _safeOffset(Random rng, String text) {
  var o = rng.nextInt(text.length + 1);
  if (_splitsPair(text, o)) o--;
  return o;
}

/// A random edit of [text] with the caret after the replacement.
SegmentEdit _randomEdit(Random rng, String text) {
  final a = _safeOffset(rng, text);
  final b = _safeOffset(rng, text);
  final start = min(a, b);
  final end = rng.nextInt(3) == 0 ? start : max(a, b);
  final replacement = _generate(rng, 4);
  return SegmentEdit(
    start: start,
    end: end,
    replacement: replacement,
    selection: SegmentSelection.collapsed(start + replacement.length),
  );
}

void main() {
  group('splitRows shapes (R9, R39)', () {
    test('an empty segment gives exactly one empty prose row', () {
      final rows = _rows('');
      expect(rows, hasLength(1));
      final r = rows.single;
      expect(r.kind, _prose);
      expect((r.start, r.textStart, r.textEnd, r.end), (0, 0, 0, 0));
    });

    test(
      'a segment with no item lines and no fence gives exactly one prose row',
      () {
        const text = 'p1\n\n# h\n---\np2';
        expect(_shape(text), [(_prose, '', text, '')]);
        expect(_shape('a\n'), [(_prose, '', 'a\n', '')]);
        expect(_shape('only text'), [(_prose, '', 'only text', '')]);
        // Frontmatter at the segment start is prose, so its list line is not
        // an item row.
        expect(_shape('---\n- a\n---\nb', atSegmentStart: true), [
          (_prose, '', '---\n- a\n---\nb', ''),
        ]);
      },
    );

    test(
      'each item line is its own row whose text excludes indent marker separator and terminator',
      () {
        const text = '  - a\r\n1. b\n- [x] c\n> d';
        expect(_shape(text), [
          (_bullet, '  - ', 'a', '\r\n'),
          (_numbered, '1. ', 'b', '\n'),
          (_task, '- [x] ', 'c', '\n'),
          (_quote, '> ', 'd', ''),
        ]);
        final first = _rows(text).first;
        expect(
          (first.start, first.textStart, first.textEnd, first.end),
          (0, 4, 5, 7),
        );
        // Two spaces after the marker: the second belongs to the text.
        expect(_shape('-  a'), [(_bullet, '- ', ' a', '')]);
        // An empty item and an empty task at end of line.
        expect(_shape('- \n- [ ]'), [
          (_bullet, '- ', '', '\n'),
          (_task, '- [ ]', '', ''),
        ]);
      },
    );

    test(
      'maximal runs of other lines are one prose row keeping interior terminators',
      () {
        expect(_shape('p1\np2\n\n- a\n# h\n---\n- b'), [
          (_prose, '', 'p1\np2\n', '\n'),
          (_bullet, '- ', 'a', '\n'),
          (_prose, '', '# h\n---', '\n'),
          (_bullet, '- ', 'b', ''),
        ]);
        expect(_shape('- a\r\n\r\n- b'), [
          (_bullet, '- ', 'a', '\r\n'),
          (_prose, '', '', '\r\n'),
          (_bullet, '- ', 'b', ''),
        ]);
      },
    );

    test(
      'a fenced block is one code row with its fence lines and list-like lines inside',
      () {
        expect(_shape('p\n```\n- x\n1. y\n```\n- z'), [
          (_prose, '', 'p', '\n'),
          (_code, '', '```\n- x\n1. y\n```', '\n'),
          (_bullet, '- ', 'z', ''),
        ]);
        expect(_shape('```\na\n```\n```\nb\n```'), [
          (_code, '', '```\na\n```', '\n'),
          (_code, '', '```\nb\n```', ''),
        ]);
      },
    );

    test('an unclosed fence runs to the segment end as one code row', () {
      expect(_shape('- a\n  ```\n- in\n\nmore\n'), [
        (_bullet, '- ', 'a', '\n'),
        (_code, '', '  ```\n- in\n\nmore\n', ''),
      ]);
    });

    test(
      'a segment ending in a terminator after an item or a closed fence ends in an empty prose row',
      () {
        expect(_shape('- a\n'), [
          (_bullet, '- ', 'a', '\n'),
          (_prose, '', '', ''),
        ]);
        final rows = _rows('- a\n');
        expect((rows.last.start, rows.last.end), (4, 4));
        expect(_shape('```\nx\n```\r\n'), [
          (_code, '', '```\nx\n```', '\r\n'),
          (_prose, '', '', ''),
        ]);
        expect(_shape('p\n- a\n'), [
          (_prose, '', 'p', '\n'),
          (_bullet, '- ', 'a', '\n'),
          (_prose, '', '', ''),
        ]);
      },
    );

    test('leading frontmatter rows are prose only at segment start', () {
      const text = '---\n- a\n---\n- b';
      expect(_shape(text, atSegmentStart: true), [
        (_prose, '', '---\n- a\n---', '\n'),
        (_bullet, '- ', 'b', ''),
      ]);
      expect(_shape(text), [
        (_prose, '', '---', '\n'),
        (_bullet, '- ', 'a', '\n'),
        (_prose, '', '---', '\n'),
        (_bullet, '- ', 'b', ''),
      ]);
    });

    test('item rows carry indent done flag and number as written', () {
      final rows = _rows('\t- [X] a\n  007. b\n- [ ] c');
      expect(rows[0].kind, _task);
      expect(rows[0].indent, 4);
      expect(rows[0].done, isTrue);
      expect(rows[1].kind, _numbered);
      expect(rows[1].indent, 2);
      expect(rows[1].number, '007');
      expect(rows[2].done, isFalse);
      expect(rows[2].number, isNull);
    });
  });

  group('byte-exact round trip (R14, D17)', () {
    test('joinRows reproduces every markdown fixture byte for byte', () {
      // The fixture list holds every shape D17 requires.
      final texts = markdownFixtures.values.toList();
      expect(texts, contains(''));
      expect(texts.any((t) => t.contains('\r\n')), isTrue, reason: 'CRLF');
      expect(texts.any((t) => t.contains('\t')), isTrue, reason: 'tabs');
      expect(texts.any((t) => t.contains(' \n')), isTrue, reason: 'trailing');
      expect(
        texts.any((t) => t.isNotEmpty && !t.endsWith('\n')),
        isTrue,
        reason: 'no final newline',
      );
      expect(texts.any((t) => t.contains('\n  - ')), isTrue, reason: 'nested');
      expect(texts.any((t) => t.contains('\n10. ')), isTrue, reason: 'ten');
      expect(
        texts.any((t) => t.contains('```') && t.contains('```\n- ')),
        isTrue,
        reason: 'fence holding a list-like line',
      );
      expect(texts.any((t) => t.startsWith('> ')), isTrue, reason: 'quotes');
      expect(
        texts.any((t) => parseTransclusions(t).isNotEmpty),
        isTrue,
        reason: 'transclusions',
      );
      expect(
        texts.any((t) => t.startsWith('---\n')),
        isTrue,
        reason: 'frontmatter',
      );
      expect(
        texts.any((t) => t.codeUnits.any(_isHigh)),
        isTrue,
        reason: 'surrogate pairs',
      );

      for (final MapEntry(key: name, value: text) in markdownFixtures.entries) {
        for (final atStart in [false, true]) {
          final rows = _rows(text, atSegmentStart: atStart);
          expect(joinRows(text, rows), text, reason: name);
          _expectWellFormed(text, rows, '$name atSegmentStart $atStart');
        }
      }
    });

    test('joinRows reproduces every api_v1 content_md byte for byte', () {
      final texts = _apiV1ContentMd();
      expect(texts.length, greaterThanOrEqualTo(40), reason: 'sweep is real');
      for (final (i, text) in texts.indexed) {
        for (final atStart in [false, true]) {
          final rows = _rows(text, atSegmentStart: atStart);
          expect(joinRows(text, rows), text, reason: 'content_md $i');
          _expectWellFormed(
            text,
            rows,
            'content_md $i atSegmentStart $atStart',
          );
        }
      }
    });

    test('joinRows reproduces a seeded sweep of 1500 generated strings', () {
      final rng = Random(160);
      for (var i = 0; i < 1500; i++) {
        final text = _generate(rng, 30);
        final atStart = rng.nextBool();
        final rows = _rows(text, atSegmentStart: atStart);
        expect(
          joinRows(text, rows),
          text,
          reason: 'sweep $i ${text.codeUnits}',
        );
        _expectWellFormed(text, rows, 'sweep $i ${text.codeUnits}');
      }
    });

    test(
      'rows re-derived after random segment edits still round-trip without splitting a surrogate pair',
      () {
        final rng = Random(1600);
        for (final MapEntry(key: name, value: fixture)
            in markdownFixtures.entries) {
          var text = fixture;
          for (var step = 0; step < 40; step++) {
            final edit = _randomEdit(rng, text);
            final next = edit.apply(text);
            expect(
              next,
              text.replaceRange(edit.start, edit.end, edit.replacement),
              reason: '$name step $step $edit',
            );
            text = next;
            final rows = _rows(text, atSegmentStart: step.isEven);
            _expectWellFormed(text, rows, '$name step $step ${text.codeUnits}');
          }
        }
      },
    );
  });

  group('SegmentEdit (D2)', () {
    test(
      'SegmentEdit apply replaces the range and keeps the rest byte for byte',
      () {
        const text = '- a\r\n';
        expect(
          const SegmentEdit(start: 2, end: 3, replacement: 'xy').apply(text),
          '- xy\r\n',
        );
        expect(
          const SegmentEdit(start: 0, end: 0, replacement: '> ').apply(text),
          '> - a\r\n',
        );
        expect(
          const SegmentEdit(start: 3, end: 5, replacement: '').apply(text),
          '- a',
        );
        expect(
          () =>
              const SegmentEdit(start: 2, end: 9, replacement: '').apply(text),
          throwsRangeError,
        );
        expect(
          () =>
              const SegmentEdit(start: 3, end: 2, replacement: '').apply(text),
          throwsRangeError,
        );
        // Built from run-time values, selection kept.
        final caret = text.length - 1;
        final edit = SegmentEdit(
          start: caret,
          end: caret,
          replacement: 'b' * 2,
          selection: SegmentSelection.collapsed(caret + 2),
        );
        expect(edit.apply(text), '- a\rbb\n');
        expect(edit.selection, const SegmentSelection.collapsed(6));
      },
    );

    test(
      'SegmentEdit diff is the smallest splice and never splits a surrogate pair',
      () {
        expect(
          SegmentEdit.diff('- a', '- a more'),
          const SegmentEdit(start: 3, end: 3, replacement: ' more'),
        );
        expect(
          SegmentEdit.diff('p\n- a\n', '- a\n'),
          const SegmentEdit(start: 0, end: 2, replacement: ''),
        );
        final same = SegmentEdit.diff('abc', 'abc');
        expect(same.start, same.end);
        expect(same.replacement, '');
        // Same high surrogate, different low: the shared high half stays in.
        expect(
          SegmentEdit.diff('x😀y', 'x😃y'),
          const SegmentEdit(start: 1, end: 3, replacement: '😃'),
        );
        // Same low surrogate (U+1F600 vs U+10600), different high.
        expect(
          SegmentEdit.diff('😀', '\u{10600}'),
          const SegmentEdit(start: 0, end: 2, replacement: '\u{10600}'),
        );
        expect(SegmentEdit.diff('a', 'b').selection, isNull);

        final rng = Random(16);
        final texts = markdownFixtures.values.toList();
        for (var i = 0; i < 300; i++) {
          final before = texts[rng.nextInt(texts.length)];
          final after = _randomEdit(rng, before).apply(before);
          final edit = SegmentEdit.diff(before, after);
          expect(edit.apply(before), after, reason: 'diff $i');
          for (final o in [edit.start, edit.end]) {
            expect(_splitsPair(before, o), isFalse, reason: 'diff $i at $o');
          }
        }
      },
    );
  });

  group('value types', () {
    test(
      'selections slices and edits compare by value and hash consistently',
      () {
        final caret = '- a'.length;
        final a = SegmentSelection(baseOffset: caret, extentOffset: caret + 2);
        const b = SegmentSelection(baseOffset: 3, extentOffset: 5);
        expect(a, b);
        expect(a.hashCode, b.hashCode);
        expect({a, b, const SegmentSelection.collapsed(3)}, hasLength(2));
        expect(
          a,
          isNot(const SegmentSelection(baseOffset: 5, extentOffset: 3)),
        );
        expect(a.toString(), contains('3'));

        final s = RowSlice(row: caret - 2, start: 0, end: caret);
        expect(s, const RowSlice(row: 1, start: 0, end: 3));
        expect(s.hashCode, const RowSlice(row: 1, start: 0, end: 3).hashCode);
        expect({s, const RowSlice(row: 1, start: 0, end: 2)}, hasLength(2));
        expect(s.toString(), contains('0..3'));

        final e = SegmentEdit(
          start: caret,
          end: caret,
          replacement: 'x' * 2,
          selection: SegmentSelection.collapsed(caret + 2),
        );
        const same = SegmentEdit(
          start: 3,
          end: 3,
          replacement: 'xx',
          selection: SegmentSelection.collapsed(5),
        );
        expect(e, same);
        expect(e.hashCode, same.hashCode);
        expect({
          e,
          same,
          const SegmentEdit(start: 3, end: 3, replacement: 'xx'),
        }, hasLength(2));
        expect(e.toString(), contains('3..3'));

        final row = _rows('- a').single;
        expect(row.toString(), contains('RowKind.bullet'));
        expect(
          classifyLines('# h', atSegmentStart: false).single.toString(),
          contains('MdLineKind.heading'),
        );
      },
    );
  });

  group('depth and parent (R12)', () {
    test(
      'depth and parent follow the nearest earlier item with a smaller indent',
      () {
        final rows = _rows('- a\n  - b\n    - c\n  - d\n- e\n\t- f\n  - g');
        expect(
          [for (final r in rows) (r.depth, r.parent)],
          [(0, null), (1, 0), (2, 1), (1, 0), (0, null), (1, 4), (1, 4)],
        );
        expect([for (final r in rows) r.indent], [0, 2, 4, 2, 0, 4, 2]);
      },
    );

    test('a tab counts as four columns when finding the parent', () {
      final rows = _rows('  - a\n\t- b\n     - c');
      expect([for (final r in rows) r.indent], [2, 4, 5]);
      expect(
        [for (final r in rows) (r.depth, r.parent)],
        [(0, null), (1, 0), (2, 1)],
      );
    });

    test('the parent search stops at a prose row', () {
      final rows = _rows('- a\n\n  - b\np\n  - c');
      expect(
        [for (final r in rows) r.kind],
        [_bullet, _prose, _bullet, _prose, _bullet],
      );
      expect(
        [for (final r in rows) (r.depth, r.parent)],
        [(0, null), (0, null), (0, null), (0, null), (0, null)],
      );
      // A code row ends the search the same way.
      final fenced = _rows('- a\n```\nx\n```\n  - b');
      expect([for (final r in fenced) r.kind], [_bullet, _code, _bullet]);
      expect(
        [for (final r in fenced) (r.depth, r.parent)],
        [(0, null), (0, null), (0, null)],
      );
      // Numbered and task rows are items too.
      final mixed = _rows('1. a\n   - [ ] b\n     * c');
      expect(
        [for (final r in mixed) (r.depth, r.parent)],
        [(0, null), (1, 0), (2, 1)],
      );
    });
  });

  group('numbered runs (R11)', () {
    test('a numbered run reports its widest digit count', () {
      final rows = _rows('8. a\n9. b\n10. c');
      expect(
        [for (final r in rows) (r.numberedRun, r.runDigits)],
        [(0, 2), (0, 2), (0, 2)],
      );
      final written = _rows('9. a\n010. b');
      expect([for (final r in written) r.runDigits], [3, 3]);
    });

    test('a blank line starts a new numbered run', () {
      final rows = _rows('9. a\n10. b\n\n1. c\n2. d');
      expect(
        [for (final r in rows) r.kind],
        [_numbered, _numbered, _prose, _numbered, _numbered],
      );
      expect(
        [for (final r in rows) (r.numberedRun, r.runDigits)],
        [(0, 2), (0, 2), (null, 0), (3, 1), (3, 1)],
      );
    });

    test(
      'a same depth bullet or a code row between numbered items starts a new run',
      () {
        final bullet = _rows('1. a\n- b\n2. c\n3. d');
        expect([for (final r in bullet) r.depth], [0, 0, 0, 0]);
        expect([for (final r in bullet) r.numberedRun], [0, null, 2, 2]);
        final task = _rows('10. a\n- [ ] b\n2. c');
        expect(
          [for (final r in task) (r.numberedRun, r.runDigits)],
          [(0, 2), (null, 0), (2, 1)],
        );
        final code = _rows('10. a\n```\nx\n```\n2. b');
        expect([for (final r in code) r.kind], [_numbered, _code, _numbered]);
        expect(
          [for (final r in code) (r.numberedRun, r.runDigits)],
          [(0, 2), (null, 0), (2, 1)],
        );
      },
    );

    test('deeper items stay in the run and a shallower item ends it', () {
      final rows = _rows(
        '1. a\n   - x\n2. b\n- y\n  3. c\n  4. d\n- z\n  5. e',
      );
      expect([for (final r in rows) r.depth], [0, 1, 0, 0, 1, 1, 0, 1]);
      expect(
        [for (final r in rows) r.numberedRun],
        [0, null, 0, null, 4, 4, null, 7],
      );
      expect([for (final r in rows) r.runDigits], [1, 0, 1, 0, 1, 1, 0, 1]);
    });
  });

  group('offsets and slices (R26)', () {
    test(
      'toLocal and toSegment convert between segment and row offsets with clamping',
      () {
        const text = '- ab\n  1. cd\np';
        final rows = _rows(text);
        final n = rows[1];
        expect((n.start, n.textStart, n.textEnd, n.end), (5, 10, 12, 13));
        expect(n.textLength, 2);
        expect(
          [
            for (final o in [0, 7, 10, 11, 12, 13, 14]) n.toLocal(o),
          ],
          [0, 0, 0, 1, 2, 2, 2],
        );
        expect(
          [
            for (final o in [0, 1, 2]) n.toSegment(o),
          ],
          [10, 11, 12],
        );
        final p = rows[2];
        expect(p.toLocal(14), 1);
        expect(p.toSegment(0), 13);
      },
    );

    test(
      'rowSlices maps a selection spanning three rows to each row local slice',
      () {
        const text = 'intro\n- ab\n- cd\n- ef\nend';
        final rows = _rows(text);
        expect(rows, hasLength(5));
        const forward = SegmentSelection(baseOffset: 9, extentOffset: 19);
        const expected = [
          null,
          RowSlice(row: 1, start: 1, end: 2),
          RowSlice(row: 2, start: 0, end: 2),
          RowSlice(row: 3, start: 0, end: 1),
          null,
        ];
        expect(rowSlices(rows, forward), expected);
        const backward = SegmentSelection(baseOffset: 19, extentOffset: 9);
        expect(rowSlices(rows, backward), expected);

        // A caret gives only the row holding it a (collapsed) slice.
        expect(rowSlices(rows, const SegmentSelection.collapsed(14)), [
          null,
          null,
          const RowSlice(row: 2, start: 1, end: 1),
          null,
          null,
        ]);

        // Inside a multi-line prose row, the slice keeps its terminators.
        final prose = _rows('a\nb\n- c');
        expect(
          rowSlices(
            prose,
            const SegmentSelection(baseOffset: 1, extentOffset: 3),
          ),
          [const RowSlice(row: 0, start: 1, end: 3), null],
        );
      },
    );
  });

  group('matchRows (R40, R21)', () {
    test('matchRows keeps the focused row when its text changes', () {
      const before = '- a\n- b';
      const edit = SegmentEdit(
        start: 7,
        end: 7,
        replacement: 'c',
        selection: SegmentSelection.collapsed(8),
      );
      final match = matchRows(
        _rows(before),
        _rows(edit.apply(before)),
        edit: edit,
        focused: 1,
      );
      expect(match, [0, 1]);
    });

    test('matchRows keeps the focused row when a polled append extends it', () {
      const before = 'p\n- a';
      const after = 'p\n- a more\n- new';
      final edit = SegmentEdit.diff(before, after);
      expect(matchRows(_rows(before), _rows(after), edit: edit, focused: 1), [
        0,
        1,
      ]);
      // A capture appended below a list lands in the empty trailing prose
      // row the caret is on.
      const tail = '- a\n';
      const appended = '- a\ncaptured line\n';
      expect(
        matchRows(
          _rows(tail),
          _rows(appended),
          edit: SegmentEdit.diff(tail, appended),
          focused: 1,
        ),
        [0, 1],
      );
    });

    test('matchRows keeps the focused row when a bullet becomes a task', () {
      const before = 'p\n- [ ';
      const edit = SegmentEdit(
        start: 6,
        end: 6,
        replacement: ']',
        selection: SegmentSelection.collapsed(7),
      );
      final afterRows = _rows(edit.apply(before));
      expect([for (final r in _rows(before)) r.kind], [_prose, _bullet]);
      expect([for (final r in afterRows) r.kind], [_prose, _task]);
      expect(matchRows(_rows(before), afterRows, edit: edit, focused: 1), [
        0,
        1,
      ]);
    });

    test(
      'matchRows keeps the focused row when a prose line becomes a bullet',
      () {
        const before = 'p\nfoo';
        const edit = SegmentEdit(
          start: 2,
          end: 2,
          replacement: '- ',
          selection: SegmentSelection.collapsed(4),
        );
        final afterRows = _rows(edit.apply(before));
        expect([for (final r in afterRows) r.kind], [_prose, _bullet]);
        // The caret's line became the bullet, so the focused prose row
        // continues as the bullet row.
        expect(matchRows(_rows(before), afterRows, edit: edit, focused: 0), [
          1,
        ]);

        const single = 'foo';
        const typed = SegmentEdit(
          start: 0,
          end: 0,
          replacement: '- ',
          selection: SegmentSelection.collapsed(2),
        );
        expect(
          matchRows(
            _rows(single),
            _rows(typed.apply(single)),
            edit: typed,
            focused: 0,
          ),
          [0],
        );
      },
    );

    test(
      'matchRows keeps the focused row when rows before it are inserted or removed',
      () {
        const before = '- a\n- b';
        const insert = SegmentEdit(start: 0, end: 0, replacement: '- new\n');
        expect(
          matchRows(
            _rows(before),
            _rows(insert.apply(before)),
            edit: insert,
            focused: 1,
          ),
          [1, 2],
        );

        const longer = 'p\n- a\n- b';
        const remove = SegmentEdit(start: 0, end: 2, replacement: '');
        expect(
          matchRows(
            _rows(longer),
            _rows(remove.apply(longer)),
            edit: remove,
            focused: 2,
          ),
          [null, 0, 1],
        );
      },
    );

    test(
      'matchRows gives no continuation to an unfocused row whose kind changed',
      () {
        // A server write strips the first row marker while row 1 has focus:
        // rows match by kind and order, so the bullet row does not continue
        // as the prose row (R40); only the focused row may change kind.
        const before = '- a\n- b';
        const after = 'a\n- b';
        final edit = SegmentEdit.diff(before, after);
        final afterRows = _rows(after);
        expect([for (final r in afterRows) r.kind], [_prose, _bullet]);
        expect(matchRows(_rows(before), afterRows, edit: edit, focused: 1), [
          null,
          1,
        ]);

        // The same holds for an unfocused row after the focused one.
        const tail = 'p\n- a\n- b';
        const stripped = 'p\n- a\nb';
        expect(
          matchRows(
            _rows(tail),
            _rows(stripped),
            edit: SegmentEdit.diff(tail, stripped),
            focused: 1,
          ),
          [0, 1, null],
        );
      },
    );

    test(
      'matchRows keeps unchanged rows and is injective and ordered over random edits',
      () {
        final rng = Random(40);
        final texts = markdownFixtures.values.toList();
        for (var i = 0; i < 400; i++) {
          final text = texts[rng.nextInt(texts.length)];
          final edit = _randomEdit(rng, text);
          final before = _rows(text);
          final after = _rows(edit.apply(text));
          // The focused row is the one being typed in: it holds the edit
          // start.
          final focused = before.lastIndexWhere((r) => r.start <= edit.start);
          final match = matchRows(before, after, edit: edit, focused: focused);
          final at = 'case $i ${text.codeUnits} $edit focused $focused';
          expect(match, hasLength(before.length), reason: at);
          int? last;
          for (final j in match.whereType<int>()) {
            expect(j >= 0 && j < after.length, isTrue, reason: at);
            if (last != null) expect(j > last, isTrue, reason: '$at ordered');
            last = j;
          }
          final delta = edit.replacement.length - (edit.end - edit.start);
          for (final (k, old) in before.indexed) {
            // A row wholly before the edit, or wholly after it, that is still
            // there with the same kind and range keeps its identity.
            final int shift;
            if (old.end < edit.start) {
              shift = 0;
            } else if (old.start > edit.end) {
              shift = delta;
            } else {
              continue;
            }
            final same = after.indexWhere(
              (r) =>
                  r.kind == old.kind &&
                  r.start == old.start + shift &&
                  r.textStart == old.textStart + shift &&
                  r.textEnd == old.textEnd + shift &&
                  r.end == old.end + shift,
            );
            if (same >= 0 && k != focused) {
              expect(match[k], same, reason: '$at row $k');
            }
          }
        }
      },
    );
  });

  group('toggleTask (R24, D12)', () {
    test('toggleTask checks an open task', () {
      const text = '- [ ] a';
      final edit = toggleTask(text, _rows(text).single)!;
      expect(edit.apply(text), '- [x] a');
      expect(edit.end - edit.start, 1);
      expect(edit.replacement, 'x');
      expect(edit.selection, isNull);
    });

    test('toggleTask unchecks a done task in lower or upper case', () {
      for (final (text, toggled) in [
        ('- [x] a', '- [ ] a'),
        ('* [X] a', '* [ ] a'),
      ]) {
        final edit = toggleTask(text, _rows(text).single)!;
        expect(edit.apply(text), toggled, reason: text);
        expect(edit.replacement, ' ', reason: text);
      }
    });

    test('toggleTask keeps indentation and terminator', () {
      const text = 'p\r\n  - [ ] a\r\n+ [x]\r\n- b';
      final rows = _rows(text);
      expect([for (final r in rows) r.kind], [_prose, _task, _task, _bullet]);
      expect(
        toggleTask(text, rows[1])!.apply(text),
        'p\r\n  - [x] a\r\n+ [x]\r\n- b',
      );
      expect(
        toggleTask(text, rows[2])!.apply(text),
        'p\r\n  - [ ] a\r\n+ [ ]\r\n- b',
      );
      const keep = SegmentSelection(baseOffset: 2, extentOffset: 9);
      expect(toggleTask(text, rows[1], selection: keep)!.selection, keep);
    });

    test(
      'toggleTask returns null for bullet numbered prose quote and code rows',
      () {
        const text = '- a\n1. [ ] b\np\n> q\n```\nx\n```';
        final rows = _rows(text);
        expect(
          [for (final r in rows) r.kind],
          [_bullet, _numbered, _prose, _quote, _code],
        );
        for (final r in rows) {
          expect(toggleTask(text, r), isNull, reason: '$r');
        }
      },
    );
  });

  group('purity (D2)', () {
    test(
      'markdown_lines and editor_rows import nothing from package flutter',
      () {
        // `flutter test` runs with the package root (`app/`) as cwd.
        for (final (path, symbol) in [
          ('lib/src/editor/markdown_lines.dart', 'classifyLines'),
          ('lib/src/editor/editor_rows.dart', 'splitRows'),
        ]) {
          final source = File(path).readAsStringSync();
          expect(source, contains(symbol), reason: '$path was read');
          final imports = [
            for (final line in const LineSplitter().convert(source))
              if (RegExp(r'^\s*(import|export|part)\s').hasMatch(line)) line,
          ];
          for (final line in imports) {
            expect(line, isNot(contains('package:flutter')), reason: path);
            expect(line, isNot(contains('dart:ui')), reason: path);
          }
        }
      },
    );
  });
}
