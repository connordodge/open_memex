// WI #67 (54-O1): the Outline's heading entries from the note text
// (Spec #58 R5-R9, R11, R16, TD2). All content here is invented.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/outline.dart';
import 'package:open_memex_app/src/editor/segments.dart';

const _marker = topicsMarker;
const _card = '![[2026-09-05#^b7k2m9]]\n';
const _rangeCard = '![[2026-09-05#^b7k2m9..^c3d4e5]]\n';

/// `(level, depth, text)` of each entry.
List<(int, int, String)> _sig(List<OutlineEntry> entries) => [
  for (final e in entries) (e.level, e.depth, e.text),
];

/// The depths of [content]'s entries.
List<int> _depths(String content) => [
  for (final e in outlineEntries(content)) e.depth,
];

/// The heading line an entry points at: the text of its segment from
/// `local` to the end of that line, terminator excluded.
String _lineAt(String content, OutlineEntry e, {String? role}) {
  final segments = split(
    content,
    isDaily: role == 'daily',
    noteFooter: role != 'guide',
  );
  final text = (segments[e.segment] as TextSegment).text;
  final rest = text.substring(e.local);
  final end = rest.indexOf('\n');
  final line = end < 0 ? rest : rest.substring(0, end);
  return line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
}

void main() {
  group('entries', () {
    test('every heading level one to six is an entry in document order', () {
      const body =
          '# One\n## Two\n### Three\n#### Four\n##### Five\n###### Six\n';
      expect(_sig(outlineEntries(body)), [
        (1, 0, 'One'),
        (2, 1, 'Two'),
        (3, 2, 'Three'),
        (4, 3, 'Four'),
        (5, 4, 'Five'),
        (6, 5, 'Six'),
      ]);
    });

    test('lines that are not headings are not entries', () {
      const body =
          'intro\n'
          '#nospace\n'
          '####### seven marks\n'
          '> # quoted\n'
          '- # item\n'
          '#tagline words\n'
          '## Real\n';
      expect(_sig(outlineEntries(body)), [(2, 0, 'Real')]);
    });

    test('a note with no headings, or no text, has no entries', () {
      expect(outlineEntries('just words\nmore words\n'), isEmpty);
      expect(outlineEntries(''), isEmpty);
      expect(outlineEntries('just words\n# Then one\n'), hasLength(1));
    });

    test('a heading line with CRLF endings has no carriage return in text', () {
      final entries = outlineEntries('# Title\r\ntext\r\n## Next\r\n');
      expect(_sig(entries), [(1, 0, 'Title'), (2, 1, 'Next')]);
      expect(entries[1].local, 15);
    });

    test('heading text is trimmed of surrounding spaces', () {
      expect(_sig(outlineEntries('#  Padded words   \n')), [
        (1, 0, 'Padded words'),
      ]);
    });

    test('a heading with no text after the marker is not an entry', () {
      const body = '# \n#\n###    \n## Kept\n';
      expect(_sig(outlineEntries(body)), [(2, 0, 'Kept')]);
    });

    test('an empty heading does not take part in the depth rule', () {
      expect(_sig(outlineEntries('# A\n## \n### B\n')), [
        (1, 0, 'A'),
        (3, 1, 'B'),
      ]);
    });

    test('the example heading gives plain text', () {
      final entries = outlineEntries(
        '## Seeds to order from **Hillside Seeds** and [[Seed swap 2026|the swap]]\n',
      );
      expect(
        entries.single.text,
        'Seeds to order from Hillside Seeds and the swap',
      );
      expect(entries.single.level, 2);
    });

    test('a title heading on the first line is an entry', () {
      expect(_sig(outlineEntries('# Garden plan\n\nbody\n')), [
        (1, 0, 'Garden plan'),
      ]);
    });

    test('two headings with the same text are two entries', () {
      const body = '# Same\ntext\n# Same\n';
      final entries = outlineEntries(body);
      expect(_sig(entries), [(1, 0, 'Same'), (1, 0, 'Same')]);
      expect(entries[0].local, 0);
      expect(entries[1].local, 12);
      expect(entries[0], isNot(entries[1]));
    });
  });

  group('exclusions', () {
    test('a heading line inside a fenced code block is not an entry', () {
      const body =
          '# Before\n'
          '```dart\n'
          '# not a heading\n'
          '## also not\n'
          '```\n'
          '## After\n';
      expect(_sig(outlineEntries(body)), [(1, 0, 'Before'), (2, 1, 'After')]);
    });

    test('a heading line inside an unclosed fence is not an entry', () {
      expect(_sig(outlineEntries('# Top\n```\n# lost\n## lost too\n')), [
        (1, 0, 'Top'),
      ]);
    });

    test('frontmatter lines are not entries', () {
      const body = '---\ntitle: plan\n# not a heading\n---\n# Real\n';
      final entries = outlineEntries(body);
      expect(_sig(entries), [(1, 0, 'Real')]);
      expect(entries.single.local, 36);
    });

    test('a pair of rule lines that is not at the start is no frontmatter', () {
      const body = '# First\n---\n## Between\n---\n## Last\n';
      expect(_sig(outlineEntries(body)), [
        (1, 0, 'First'),
        (2, 1, 'Between'),
        (2, 1, 'Last'),
      ]);
    });

    test('frontmatter at the start of a segment after a card is excluded', () {
      const body =
          '# Head\n'
          '$_card'
          '---\n'
          'title: shown as text\n'
          '# inside frontmatter\n'
          '---\n'
          '## After\n';
      final entries = outlineEntries(body);
      expect(_sig(entries), [(1, 0, 'Head'), (2, 1, 'After')]);
      expect(entries[1].segment, 2);
    });

    test('headings around a transcluded card are entries, the card is not', () {
      const body = '# Before\ntext\n$_card## After\n';
      final entries = outlineEntries(body);
      expect(_sig(entries), [(1, 0, 'Before'), (2, 1, 'After')]);
      expect(entries.map((e) => e.segment), [0, 2]);
      expect(entries[1].local, 0);
    });

    test('adjacent range cards leave the empty text between them out', () {
      const body = '# One\n$_card$_rangeCard## Two\n';
      final entries = outlineEntries(body);
      expect(_sig(entries), [(1, 0, 'One'), (2, 1, 'Two')]);
      expect(entries.map((e) => e.segment), [0, 4]);
    });

    test('footer content below the marker is not an entry', () {
      const body =
          '# Plan\n'
          'text\n'
          '$_marker\n'
          '# Footer heading\n'
          '[[Pricing~about]]\n'
          '#memex\n';
      expect(_sig(outlineEntries(body)), [(1, 0, 'Plan')]);
      expect(_sig(outlineEntries(body, role: 'note')), [(1, 0, 'Plan')]);
    });

    test('a marker line inside a fence does not start the footer', () {
      const body = '# Plan\n```\n$_marker\n```\n## After\n';
      expect(_sig(outlineEntries(body)), [(1, 0, 'Plan'), (2, 1, 'After')]);
    });

    test(
      'in a guide note a marker line is text and headings after it count',
      () {
        const body = '# Guide\n$_marker\n## After marker\n';
        expect(_sig(outlineEntries(body, role: 'guide')), [
          (1, 0, 'Guide'),
          (2, 1, 'After marker'),
        ]);
        expect(_sig(outlineEntries(body)), [(1, 0, 'Guide')]);
      },
    );

    test('a daily note footer of chips adds no entries', () {
      const body = '# Today\nnotes\n$_marker\n[[Heading~about]]\n';
      expect(_sig(outlineEntries(body, role: 'daily')), [(1, 0, 'Today')]);
    });
  });

  group('depth', () {
    test('the first heading is depth zero at any level', () {
      expect(_depths('### Deep start\n'), [0]);
      expect(_depths('## A\n### B\n'), [0, 1]);
    });

    test('H1 then H3 gives 0 and 1', () {
      expect(_depths('# A\n### B\n'), [0, 1]);
    });

    test('H1, H3, then H2 gives 0, 1, 1', () {
      expect(_depths('# A\n### B\n## C\n'), [0, 1, 1]);
    });

    test('H2 then H4 gives 0 and 1', () {
      expect(_depths('## A\n#### B\n'), [0, 1]);
    });

    test('a later H1 resets to zero', () {
      expect(_depths('# A\n## B\n### C\n# D\n## E\n'), [0, 1, 2, 0, 1]);
    });

    test('a heading of the same level is a sibling at the same depth', () {
      expect(_depths('## A\n## B\n'), [0, 0]);
      expect(_depths('# A\n## B\n## C\n'), [0, 1, 1]);
    });

    test('a heading shallower than every earlier one is depth zero', () {
      expect(_depths('## A\n# B\n'), [0, 0]);
      expect(_depths('### A\n## B\n'), [0, 0]);
    });

    test('the nearest preceding shallower heading sets the depth', () {
      expect(_depths('# A\n### B\n##### C\n#### D\n'), [0, 1, 2, 2]);
      expect(_depths('## A\n#### B\n### C\n'), [0, 1, 1]);
      expect(_depths('# A\n## B\n### C\n## D\n'), [0, 1, 2, 1]);
    });

    test('depth continues across a transcluded card', () {
      expect(_depths('# A\n$_card## B\n'), [0, 1]);
    });
  });

  group('OutlineEntry text form', () {
    test('toString names every field', () {
      const e = OutlineEntry(
        level: 2,
        depth: 1,
        text: 'Seed swap',
        segment: 3,
        local: 17,
      );
      final s = e.toString();
      expect(s, contains('2'));
      expect(s, contains('1'));
      expect(s, contains('Seed swap'));
      expect(s, contains('3'));
      expect(s, contains('17'));
    });
  });

  group('outlineText', () {
    const cases = <(String, String, String)>[
      ('strips bold with stars', '**bold** word', 'bold word'),
      ('strips bold with underscores', '__bold__ word', 'bold word'),
      ('strips italic with a star', '*slanted* word', 'slanted word'),
      ('strips italic with an underscore', '_slanted_ word', 'slanted word'),
      ('strips strikethrough', '~~gone~~ word', 'gone word'),
      (
        'strips a code span to its content',
        'run `make all` now',
        'run make all now',
      ),
      ('keeps markers inside a code span', '`**raw**` text', '**raw** text'),
      (
        'maps an aliased wikilink to the alias',
        '[[Seed swap|the swap]]',
        'the swap',
      ),
      (
        'maps a plain wikilink to the title',
        'see [[Seed swap]] now',
        'see Seed swap now',
      ),
      ('maps a kind wikilink to the title', '[[Seed swap~about]]', 'Seed swap'),
      (
        'maps kind and alias to the alias',
        '[[Seed swap~about|the swap]]',
        'the swap',
      ),
      (
        'maps a markdown link to its text',
        'read [the guide](https://example.com/g) now',
        'read the guide now',
      ),
      ('keeps a tag as written', 'Plan #garden items', 'Plan #garden items'),
      ('trims the result', '   spaced out   ', 'spaced out'),
      ('leaves plain text alone', 'Plain heading', 'Plain heading'),
      (
        'handles several rules in one heading',
        '**Big** and _small_ and [[A|b]] and `c` and ~~d~~',
        'Big and small and b and c and d',
      ),
      ('strips bold italic to its content', '***both*** word', 'both word'),
      (
        'maps a wikilink inside bold to its alias',
        '**bold [[A|alias]] end**',
        'bold alias end',
      ),
      ('strips italic nested inside bold', '**a *b* c**', 'a b c'),
      (
        'strips bold inside a link text',
        '[**bold** link](https://e.com)',
        'bold link',
      ),
      ('keeps a tag inside bold', '**plan #garden**', 'plan #garden'),
      ('keeps text after a nested token', '**a _b_** tail', 'a b tail'),
    ];
    for (final (name, input, expected) in cases) {
      test('outlineText $name', () {
        expect(outlineText(input), expected);
      });
    }

    test('an entry text comes from outlineText of the heading text', () {
      const raw = '**Bold** and [[Seed swap~about|the swap]] #tag';
      final entries = outlineEntries('## $raw\n');
      expect(entries.single.text, outlineText(raw));
      expect(entries.single.text, 'Bold and the swap #tag');
    });
  });

  group('position', () {
    test('segment and local point at the heading line start', () {
      const body = 'intro\n# One\nmore\n## Two\n';
      final entries = outlineEntries(body);
      expect(entries.map((e) => e.segment), [0, 0]);
      expect(entries.map((e) => e.local), [6, 17]);
      expect([for (final e in entries) _lineAt(body, e)], ['# One', '## Two']);
    });

    test('a heading after a card is local to the text after the card', () {
      const body = 'lead\n$_card\n# After\ntail\n## Later\n';
      final entries = outlineEntries(body);
      expect(entries.map((e) => e.segment), [2, 2]);
      // The text after the card starts with the blank line.
      expect(entries.map((e) => e.local), [1, 14]);
      expect(
        [for (final e in entries) _lineAt(body, e)],
        ['# After', '## Later'],
      );
    });

    test('headings on both sides of a card index their own segments', () {
      const body = '# Top\n$_card${_rangeCard}text\n## Last\n';
      final entries = outlineEntries(body);
      expect(entries.map((e) => e.segment), [0, 4]);
      expect(entries.map((e) => e.local), [0, 5]);
    });

    test('an emoji earlier in the note counts as two UTF-16 units', () {
      const body = 'Party \u{1F389} time\n# After\n';
      final entries = outlineEntries(body);
      expect(entries.single.local, 14);
      expect(_lineAt(body, entries.single), '# After');
    });

    test('an emoji in the heading text is kept and later offsets shift', () {
      const body = '# \u{1F389} Party\n## Next\n';
      final entries = outlineEntries(body);
      expect(_sig(entries), [(1, 0, '\u{1F389} Party'), (2, 1, 'Next')]);
      expect(entries[1].local, 11);
      expect(_lineAt(body, entries[1]), '## Next');
    });

    test('a daily note person segment is segment zero with local offsets', () {
      const body =
          'Intro \u{1F389}\n## Plan\ntext\n### Step\n$_marker\n[[Topic~about]]\n';
      final entries = outlineEntries(body, role: 'daily');
      expect(entries.map((e) => e.segment), [0, 0]);
      expect(entries.map((e) => e.local), [9, 22]);
      expect(
        [for (final e in entries) _lineAt(body, e, role: 'daily')],
        ['## Plan', '### Step'],
      );
    });

    test(
      'a heading in stray daily footer text is found in the person text',
      () {
        const body = '# Top\n$_marker\n[[Topic~about]]\n## Stray head\n';
        final entries = outlineEntries(body, role: 'daily');
        expect(_sig(entries), [(1, 0, 'Top'), (2, 1, 'Stray head')]);
        expect(entries.map((e) => e.segment), [0, 0]);
        expect(entries[1].local, 6);
        expect(_lineAt(body, entries[1], role: 'daily'), '## Stray head');
        // The same text on a non-daily note is footer content.
        expect(_sig(outlineEntries(body)), [(1, 0, 'Top')]);
      },
    );
  });

  group('OutlineEntry', () {
    OutlineEntry make({
      int level = 2,
      int depth = 1,
      String text = 'Seeds',
      int segment = 0,
      int local = 7,
    }) => OutlineEntry(
      level: level,
      depth: depth,
      text: text,
      segment: segment,
      local: local,
    );

    test('equality and hashCode are by value', () {
      final a = make(text: ['See', 'ds'].join());
      final b = make(text: 'Seeds');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('entries differing in any one field are not equal', () {
      final base = make();
      expect(base, make());
      expect(base, isNot(make(level: 3)));
      expect(base, isNot(make(depth: 2)));
      expect(base, isNot(make(text: 'Other')));
      expect(base, isNot(make(segment: 2)));
      expect(base, isNot(make(local: 8)));
    });

    test('entries from separate calls on the same text are equal', () {
      const body = '# A\n## B\n';
      final again = String.fromCharCodes(body.codeUnits);
      expect(outlineEntries(body), hasLength(2));
      expect(outlineEntries(body), outlineEntries(again));
    });
  });
}
