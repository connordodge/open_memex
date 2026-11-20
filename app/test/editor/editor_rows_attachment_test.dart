// WI #143 (Spec #123 V3: R23, R32; rulings D1): `splitRows` carves
// `RowKind.attachment` rows out of prose runs.
//
// - A line that is exactly one attachment reference (R4), leading and
//   trailing spaces aside, in image or link form, is its own attachment row.
// - Any other line stays prose: text around the reference, two references,
//   a web image, a malformed destination.
// - A list item, a quote, and a line in a fence, a table or leading
//   frontmatter holding the same text is not an attachment row.
// - An attachment row ends a numbered run and an item parent search like a
//   prose row (editor_rows.dart: runs end at a non-item row).
// - Rows still tile the text and round-trip through `joinRows`.
// - A grammar break on the focused attachment row keeps its continuation
//   (`matchRows`, #122 Req 33).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/attachment_ref.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';

/// 64 lowercase hex characters whose first two are the `<h2>` folder `9b`.
const _t143Hash =
    '9b1e0000000000000000000000000000000000000000000000000000000000aa';

/// The reference markdown of [name] (R3): image form for an inline image
/// name unless [link], link form otherwise.
String _t143Ref(String name, {bool? image}) {
  final bang = (image ?? isInlineImageName(name)) ? '!' : '';
  return '$bang[$name](objects/9b/$_t143Hash/${encodeAttachmentName(name)})';
}

List<RowSpec> _t143Rows(String text, {bool atSegmentStart = false}) =>
    splitRows(text, atSegmentStart: atSegmentStart);

List<RowKind> _t143Kinds(String text, {bool atSegmentStart = false}) => [
  for (final r in _t143Rows(text, atSegmentStart: atSegmentStart)) r.kind,
];

/// The rows of [text] tile it (each starts where the previous ends, the
/// first at 0, the last at its end) and `joinRows` rebuilds it byte for
/// byte.
void _t143ExpectTiles(String text, {bool atSegmentStart = false}) {
  final rows = _t143Rows(text, atSegmentStart: atSegmentStart);
  expect(rows, isNotEmpty);
  expect(rows.first.start, 0, reason: text);
  for (var i = 1; i < rows.length; i++) {
    expect(rows[i].start, rows[i - 1].end, reason: '$text row $i');
  }
  expect(rows.last.end, text.length, reason: text);
  expect(joinRows(text, rows), text);
}

const _prose = RowKind.prose;
const _attachment = RowKind.attachment;

void main() {
  group('attachment rows (AC1)', () {
    test(
      'splitRows gives attachment rows only for lines that are exactly one attachment reference',
      () {
        final image = _t143Ref('chart.png');
        final card = _t143Ref('Q3 report.pdf');
        final cases = <(String, List<RowKind>)>[
          // Exactly one reference: an image row or a file card.
          (image, [_attachment]),
          (card, [_attachment]),
          ('  $image   ', [_attachment]),
          ('\t$card ', [_attachment]),
          ('Intro line\n$image\nOutro line', [_prose, _attachment, _prose]),
          ('Intro line\n$card\nOutro line', [_prose, _attachment, _prose]),
          // A link-form png and an image-form pdf are references too.
          (_t143Ref('chart.png', image: false), [_attachment]),
          (_t143Ref('scan.heic', image: true), [_attachment]),
          // Two reference lines are two rows.
          ('$image\n$card', [_attachment, _attachment]),
          // A reference line ending the segment's text in a terminator.
          ('$image\n', [_attachment, _prose]),
          // Anything else on the line keeps it prose.
          ('See $image', [_prose]),
          ('$card here', [_prose]),
          ('$image $card', [_prose]),
          ('# $image', [_prose]),
          ('![chart.png](https://example.com/chart.png)', [_prose]),
          ('![chart.png](objects/9b/abc/chart.png)', [_prose]),
          ('Intro line\nSee $card\nOutro line', [_prose]),
        ];
        for (final (text, kinds) in cases) {
          expect(_t143Kinds(text), kinds, reason: text);
          _t143ExpectTiles(text);
        }
      },
    );

    test('an attachment row holds its reference line as its text', () {
      final image = _t143Ref('chart.png');
      final text = 'Intro line\n  $image  \nOutro line';
      final rows = _t143Rows(text);
      expect([for (final r in rows) r.kind], [_prose, _attachment, _prose]);
      final row = rows[1];
      final rowText = text.substring(row.textStart, row.textEnd);
      expect(rowText.trim(), image);
      expect(parseAttachmentReference(rowText.trim()), isNotNull);
      expect(text.substring(row.textEnd, row.end), '\n');
      expect(
        text.substring(rows[0].textStart, rows[0].textEnd),
        'Intro line',
        reason: 'the prose run before it ends at the line before',
      );
      expect(text.substring(rows[0].textEnd, rows[0].end), '\n');
      expect(text.substring(rows[2].textStart, rows[2].textEnd), 'Outro line');
      expect(row.depth, 0);
      expect(row.parent, isNull);
      expect(row.numberedRun, isNull);
      expect(row.isItem, isFalse);
    });

    test(
      'an attachment reference in a list item quote fence table or frontmatter is not an attachment row',
      () {
        final image = _t143Ref('chart.png');
        // A name holding a pipe, so the same line can be a table body line.
        final piped = _t143Ref('x | y.pdf');
        final cases = <(String, List<RowKind>, bool)>[
          // Each case ends with the same reference alone on a line, which is
          // an attachment row, so the carve-out is live in the same text.
          ('- $image\n$image', [RowKind.bullet, _attachment], false),
          ('* $image\n$image', [RowKind.bullet, _attachment], false),
          ('1. $image\n$image', [RowKind.numbered, _attachment], false),
          ('- [ ] $image\n$image', [RowKind.task, _attachment], false),
          ('> $image\n$image', [RowKind.quote, _attachment], false),
          ('```\n$image\n```\n$image', [RowKind.code, _attachment], false),
          (
            '| a | b |\n|---|---|\n$piped\n\n$piped',
            [RowKind.table, _prose, _attachment],
            false,
          ),
          ('---\ntitle: x\n$image\n---\n$image', [_prose, _attachment], true),
        ];
        for (final (text, kinds, atStart) in cases) {
          expect(
            _t143Kinds(text, atSegmentStart: atStart),
            kinds,
            reason: text,
          );
          _t143ExpectTiles(text, atSegmentStart: atStart);
        }
        // An unclosed fence holds the reference line too.
        expect(_t143Kinds('```\n$image'), [RowKind.code]);
        // Outside the segment start the same `---` lines are no
        // frontmatter, so the reference line is an attachment row.
        expect(_t143Kinds('---\ntitle: x\n$image\n---'), [
          _prose,
          _attachment,
          _prose,
        ]);
      },
    );

    test('an attachment row ends a numbered run like a prose row', () {
      final image = _t143Ref('chart.png');
      final card = _t143Ref('Q3 report.pdf');
      for (final ref in [image, card]) {
        final text = '1. one\n2. two\n$ref\n3. three\n4. four';
        final rows = _t143Rows(text);
        expect(
          [for (final r in rows) r.kind],
          [
            RowKind.numbered,
            RowKind.numbered,
            _attachment,
            RowKind.numbered,
            RowKind.numbered,
          ],
          reason: text,
        );
        expect(rows[0].numberedRun, 0);
        expect(rows[1].numberedRun, 0);
        expect(rows[3].numberedRun, 3, reason: 'a new run starts after it');
        expect(rows[4].numberedRun, 3);
        // As a prose line in its place does.
        final prose = _t143Rows('1. one\n2. two\nplain\n3. three\n4. four');
        expect(
          [for (final r in rows) r.numberedRun],
          [for (final r in prose) r.numberedRun],
        );
      }
      // An item after it never takes an item before it as its parent.
      final nested = _t143Rows('- a\n$image\n  - b');
      expect(
        [for (final r in nested) r.kind],
        [RowKind.bullet, _attachment, RowKind.bullet],
      );
      expect(nested[2].parent, isNull);
      expect(nested[2].depth, 0);
    });

    test(
      'matchRows keeps the focused attachment row when an edit breaks its grammar',
      () {
        final image = _t143Ref('chart.png');
        final before = 'Intro line\n$image\nOutro line';
        final rowsBefore = _t143Rows(before);
        expect(
          [for (final r in rowsBefore) r.kind],
          [_prose, _attachment, _prose],
        );
        // Typing `x` at the start of the reference line.
        final at = rowsBefore[1].textStart;
        final edit = SegmentEdit(
          start: at,
          end: at,
          replacement: 'x',
          selection: SegmentSelection.collapsed(at + 1),
        );
        final after = edit.apply(before);
        final rowsAfter = _t143Rows(after);
        expect([for (final r in rowsAfter) r.kind], [_prose]);
        final matched = matchRows(
          rowsBefore,
          rowsAfter,
          edit: edit,
          focused: 1,
        );
        expect(matched[1], 0, reason: 'the focused row continues as prose');

        // Undoing it makes the line an attachment row again, still focused.
        final undo = SegmentEdit(
          start: at,
          end: at + 1,
          replacement: '',
          selection: SegmentSelection.collapsed(at),
        );
        final again = _t143Rows(undo.apply(after));
        expect([for (final r in again) r.kind], [_prose, _attachment, _prose]);
        expect(matchRows(rowsAfter, again, edit: undo, focused: 0)[0], 1);
      },
    );
  });
}
