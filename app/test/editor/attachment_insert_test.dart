// WI #146 (Spec #123 A4, R12; L2, L14): the pure insertion planner.
//
// Every case runs `planAttachmentInsert` on a body and checks the edited body
// (the plan's range replaced) and the caret, never the plan's exact range:
// several ranges give the same text.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/attachment_insert.dart';
import 'package:open_memex_app/src/editor/segments.dart';

const _wi146Mock = '![mock.png](objects/aa/1111/mock.png)';
const _wi146Spec = '[spec.pdf](objects/aa/2222/spec.pdf)';
const _wi146Group = [_wi146Mock, _wi146Spec];
const _wi146One = '[notes.txt](objects/aa/3333/notes.txt)';

/// The body [plan] makes of [body], and the caret it leaves.
({String text, int caret}) _wi146Apply(String body, AttachmentInsertPlan plan) {
  expect(plan.start, inInclusiveRange(0, body.length), reason: 'start fits');
  expect(plan.end, inInclusiveRange(plan.start, body.length), reason: 'end');
  final text = body.replaceRange(plan.start, plan.end, plan.replacement);
  return (text: text, caret: plan.caret);
}

({String text, int caret}) _wi146Plan(
  String body, {
  required int? anchorLine,
  List<String> lines = _wi146Group,
  bool daily = false,
}) => _wi146Apply(
  body,
  planAttachmentInsert(
    body: body,
    anchorLine: anchorLine,
    lines: lines,
    daily: daily,
  ),
);

/// The paragraph blocks of [text] the way `blocks.rs` splits them: runs of
/// non-blank lines between blank (empty or whitespace-only) lines.
List<String> _wi146Blocks(String text) {
  final blocks = <String>[];
  final current = <String>[];
  for (final line in text.split('\n')) {
    if (line.trim().isEmpty) {
      if (current.isNotEmpty) blocks.add(current.join('\n'));
      current.clear();
    } else {
      current.add(line);
    }
  }
  if (current.isNotEmpty) blocks.add(current.join('\n'));
  return blocks;
}

void main() {
  group('the R12 example (AC1)', () {
    test(
      'caret after Review the draft with mock.png and spec.pdf gives the R12 example and the caret at the start of the blank line after the group',
      () {
        const body = 'Review the draft\nNext steps';
        final r = _wi146Plan(body, anchorLine: 0);
        const want =
            'Review the draft\n\n$_wi146Mock\n$_wi146Spec\n\nNext steps';
        expect(r.text, want);
        expect(
          r.caret,
          want.indexOf('\n\nNext steps') + 1,
          reason: 'the start of the blank line after the group',
        );
      },
    );

    test('the group is its own paragraph block in the R12 example', () {
      const body = 'Review the draft\nNext steps';
      final r = _wi146Plan(body, anchorLine: 0);
      expect(_wi146Blocks(r.text), [
        'Review the draft',
        '$_wi146Mock\n$_wi146Spec',
        'Next steps',
      ]);
    });

    test('one line from a single file gets the same blank line separation', () {
      final r = _wi146Plan(
        'Review the draft\nNext steps',
        anchorLine: 0,
        lines: const [_wi146One],
      );
      expect(r.text, 'Review the draft\n\n$_wi146One\n\nNext steps');
      expect(r.caret, r.text.indexOf('\n\nNext steps') + 1);
    });

    test('the lines keep the order they are given in', () {
      final r = _wi146Plan(
        'A\nB',
        anchorLine: 0,
        lines: const [_wi146Spec, _wi146One, _wi146Mock],
      );
      expect(r.text, 'A\n\n$_wi146Spec\n$_wi146One\n$_wi146Mock\n\nB');
    });
  });

  group('a line is never split (AC2)', () {
    const body = 'First line\nSecond line here\nThird line';
    for (final (name, anchor) in const [
      ('an anchor on the first line keeps every line whole', 0),
      ('an anchor on a middle line keeps every line whole', 1),
      ('an anchor on the last line keeps every line whole', 2),
    ]) {
      test(name, () {
        final r = _wi146Plan(body, anchorLine: anchor);
        final kept = [
          for (final l in r.text.split('\n'))
            if (l.isNotEmpty && !_wi146Group.contains(l)) l,
        ];
        expect(kept, body.split('\n'), reason: 'original lines, whole');
        final lines = r.text.split('\n');
        final at = lines.indexOf(_wi146Mock);
        expect(lines[at + 1], _wi146Spec, reason: 'consecutive lines');
        expect(
          lines[at - 2],
          body.split('\n')[anchor],
          reason: 'after the anchor line and one blank line',
        );
      });
    }
  });

  group('an empty anchor line is replaced (AC2)', () {
    test('an empty anchor line at the top is replaced by the group', () {
      final r = _wi146Plan('\nNext steps', anchorLine: 0);
      expect(r.text, '$_wi146Mock\n$_wi146Spec\n\nNext steps');
      expect(r.caret, r.text.indexOf('\n\nNext steps') + 1);
    });

    test('a whitespace only anchor line is replaced by the group', () {
      final r = _wi146Plan('Intro\n  \t \nOutro', anchorLine: 1);
      expect(r.text, 'Intro\n\n$_wi146Mock\n$_wi146Spec\n\nOutro');
    });

    test('an empty body is replaced by the group with no blank lines', () {
      final r = _wi146Plan('', anchorLine: 0);
      expect(r.text, '$_wi146Mock\n$_wi146Spec');
      expect(r.caret, r.text.length, reason: 'nothing follows the group');
    });
  });

  group('blank lines around the group (AC2)', () {
    test('no blank line is added above when the line above is blank', () {
      final r = _wi146Plan('Intro\n\n\nOutro', anchorLine: 2);
      expect(r.text, 'Intro\n\n$_wi146Mock\n$_wi146Spec\n\nOutro');
    });

    test('no blank line is added below when the next line is blank', () {
      final r = _wi146Plan('Review\n\nNext', anchorLine: 0);
      expect(r.text, 'Review\n\n$_wi146Mock\n$_wi146Spec\n\nNext');
      expect(
        r.caret,
        r.text.indexOf('\n\nNext') + 1,
        reason: 'the existing blank line after the group',
      );
    });

    test(
      'no blank line is added above when the group starts the person section',
      () {
        final r = _wi146Plan('\n\nLater', anchorLine: 0);
        expect(r.text, '$_wi146Mock\n$_wi146Spec\n\nLater');
      },
    );

    test(
      'no blank line is added below when the group ends the person section',
      () {
        final r = _wi146Plan('Review', anchorLine: 0);
        expect(r.text, 'Review\n\n$_wi146Mock\n$_wi146Spec');
      },
    );
  });

  group('frontmatter, fences and tables (AC2)', () {
    const frontmatter = '---\ntitle: Plan\n---\nBody';
    const fence = '```\ncode\n```\nAfter';
    const table = '| a | b |\n| - | - |\n| 1 | 2 |\nAfter';
    for (final (name, body, anchor, want) in [
      (
        'an anchor on the opening frontmatter line puts the group after its closing line',
        frontmatter,
        0,
        '---\ntitle: Plan\n---\n\n$_wi146Mock\n$_wi146Spec\n\nBody',
      ),
      (
        'an anchor inside frontmatter puts the group after its closing line',
        frontmatter,
        1,
        '---\ntitle: Plan\n---\n\n$_wi146Mock\n$_wi146Spec\n\nBody',
      ),
      (
        'an anchor on the opening fence line puts the group after the closing fence',
        fence,
        0,
        '```\ncode\n```\n\n$_wi146Mock\n$_wi146Spec\n\nAfter',
      ),
      (
        'an anchor inside a fence puts the group after the closing fence',
        fence,
        1,
        '```\ncode\n```\n\n$_wi146Mock\n$_wi146Spec\n\nAfter',
      ),
      (
        'an anchor on the closing fence line puts the group after it',
        fence,
        2,
        '```\ncode\n```\n\n$_wi146Mock\n$_wi146Spec\n\nAfter',
      ),
      (
        'an empty line inside a fence is not replaced and the group goes after the fence',
        '```\n\n```\nAfter',
        1,
        '```\n\n```\n\n$_wi146Mock\n$_wi146Spec\n\nAfter',
      ),
      (
        'an anchor on a table header puts the group after the last table line',
        table,
        0,
        '| a | b |\n| - | - |\n| 1 | 2 |\n\n$_wi146Mock\n$_wi146Spec\n\nAfter',
      ),
      (
        'an anchor on a table delimiter puts the group after the last table line',
        table,
        1,
        '| a | b |\n| - | - |\n| 1 | 2 |\n\n$_wi146Mock\n$_wi146Spec\n\nAfter',
      ),
      (
        'an anchor on a table body line puts the group after the last table line',
        '| a | b |\n| - | - |\n| 1 | 2 |\n| 3 | 4 |\nAfter',
        2,
        '| a | b |\n| - | - |\n| 1 | 2 |\n| 3 | 4 |\n\n$_wi146Mock\n$_wi146Spec\n\nAfter',
      ),
    ]) {
      test(name, () {
        final r = _wi146Plan(body, anchorLine: anchor);
        expect(r.text, want);
        expect(r.caret, want.lastIndexOf('\n\n') + 1);
      });
    }

    test(
      'a fence that ends the body gets the group after it with the caret at the end',
      () {
        const body = 'Top\n```\ncode\n```';
        final r = _wi146Plan(body, anchorLine: 2);
        expect(r.text, '$body\n\n$_wi146Mock\n$_wi146Spec');
        expect(r.caret, r.text.length);
      },
    );
  });

  group('the footer (AC2)', () {
    test(
      'an anchor on the Topics footer of a daily note puts the group at the end of the person section',
      () {
        final body = assembleDailyBody('Morning\n', const ['Work']);
        for (final anchor in const [1, 2]) {
          final r = _wi146Plan(body, anchorLine: anchor, daily: true);
          expect(
            r.text,
            'Morning\n\n$_wi146Mock\n$_wi146Spec\n$topicsMarker\n[[Work~about]]\n',
            reason: 'anchor $anchor',
          );
          final split = splitDailyBody(r.text);
          expect(split.chips, ['Work'], reason: 'the footer is untouched');
          expect(split.person, contains(_wi146Spec));
        }
      },
    );

    test(
      'no anchor in a daily note puts the group above the Topics footer',
      () {
        final body = assembleDailyBody('Morning\nEvening\n', const ['Work']);
        final r = _wi146Plan(body, anchorLine: null, daily: true);
        expect(
          r.text,
          'Morning\nEvening\n\n$_wi146Mock\n$_wi146Spec\n'
          '$topicsMarker\n[[Work~about]]\n',
        );
      },
    );

    test(
      'an anchor on the Note footer of another note puts the group at the end of the person section',
      () {
        const body = 'Plan\n$topicsMarker\n[[Work~about]]\n';
        final r = _wi146Plan(body, anchorLine: 2);
        expect(
          r.text,
          'Plan\n\n$_wi146Mock\n$_wi146Spec\n$topicsMarker\n[[Work~about]]\n',
        );
        expect(splitNoteBody(r.text).chips, ['Work']);
      },
    );

    test(
      'a marker line inside a fence of another note is body text and the group goes after the anchor',
      () {
        const body = '```\n$topicsMarker\n```\nEnd';
        final r = _wi146Plan(body, anchorLine: 3);
        expect(r.text, '$body\n\n$_wi146Mock\n$_wi146Spec');
      },
    );

    test(
      'an unclosed fence above the Topics footer of a daily note keeps the group out of the footer',
      () {
        // splitDailyBody ignores fences, so the marker is still the footer
        // while the block skip from the fence runs to the end of the body.
        const body = '```\ncode\n$topicsMarker\n[[Work~about]]\n';
        for (final anchor in const [0, 1]) {
          final r = _wi146Plan(body, anchorLine: anchor, daily: true);
          final split = splitDailyBody(r.text);
          expect(split.chips, ['Work'], reason: 'footer kept, anchor $anchor');
          expect(split.person, contains(_wi146Spec), reason: 'in the person');
          expect(
            r.text,
            '```\ncode\n\n$_wi146Mock\n$_wi146Spec\n'
            '$topicsMarker\n[[Work~about]]\n',
            reason: 'anchor $anchor',
          );
        }
      },
    );

    test('the group is its own block above the footer of a daily note', () {
      final body = assembleDailyBody('Morning\nEvening\n', const ['Work']);
      final r = _wi146Plan(body, anchorLine: 0, daily: true);
      final person = splitDailyBody(r.text).person;
      expect(_wi146Blocks(person), [
        'Morning',
        '$_wi146Mock\n$_wi146Spec',
        'Evening',
      ]);
    });
  });

  group('no anchor and the caret at the end (AC2)', () {
    test('no anchor puts the group at the end of the person section', () {
      final r = _wi146Plan('Review the draft\nNext steps', anchorLine: null);
      expect(
        r.text,
        'Review the draft\nNext steps\n\n$_wi146Mock\n$_wi146Spec',
      );
      expect(r.caret, r.text.length);
    });

    test(
      'with nothing after the group the caret goes to the end of its last line',
      () {
        final r = _wi146Plan('Review the draft', anchorLine: 0);
        expect(r.text, 'Review the draft\n\n$_wi146Mock\n$_wi146Spec');
        expect(r.caret, r.text.length);
        expect(r.text.substring(0, r.caret), endsWith(_wi146Spec));
      },
    );

    test(
      'no anchor on a body ending in a newline gives a group after one blank line with only blank lines after it',
      () {
        const body = 'Review\nNext\n';
        final r = _wi146Plan(body, anchorLine: null);
        final lines = r.text.split('\n');
        final at = lines.indexOf(_wi146Mock);
        expect(at, greaterThan(1));
        expect(lines.sublist(0, at - 1), ['Review', 'Next']);
        expect(lines[at - 1], '', reason: 'one blank line above');
        expect(lines[at + 1], _wi146Spec);
        expect(
          lines.sublist(at + 2).every((l) => l.isEmpty),
          isTrue,
          reason: 'nothing but blank lines after the group',
        );
      },
    );

    test(
      'an anchor on a body ending in a newline keeps the existing text after the group',
      () {
        final r = _wi146Plan('Review\nNext\n', anchorLine: 0);
        expect(r.text, 'Review\n\n$_wi146Mock\n$_wi146Spec\n\nNext\n');
        expect(r.caret, r.text.indexOf('\n\nNext') + 1);
      },
    );
  });
  group('anchors and bodies at the edges (AC2)', () {
    test(
      'an anchor line past the end of the body puts the group at the end of the person section',
      () {
        final r = _wi146Plan('Review\nNext', anchorLine: 99);
        expect(r.text, 'Review\nNext\n\n$_wi146Mock\n$_wi146Spec');
        expect(r.caret, r.text.length);
      },
    );

    test(
      'a daily note whose first line is the Topics marker gets the group above the footer',
      () {
        final body = assembleDailyBody('', const ['Work']);
        expect(body, startsWith(topicsMarker), reason: 'the footer is first');
        for (final anchor in const [0, 1, null]) {
          final r = _wi146Plan(body, anchorLine: anchor, daily: true);
          expect(
            r.text,
            '$_wi146Mock\n$_wi146Spec\n$body',
            reason: 'anchor $anchor',
          );
          expect(
            r.caret,
            '$_wi146Mock\n$_wi146Spec'.length,
            reason: 'the end of the group line',
          );
        }
      },
    );

    test(
      'an unclosed fence puts the group after its last line with the caret at the end',
      () {
        const body = 'Top\n```\ncode\nmore';
        final r = _wi146Plan(body, anchorLine: 1);
        expect(r.text, '$body\n\n$_wi146Mock\n$_wi146Spec');
        expect(r.caret, r.text.length);
      },
    );

    test(
      'a CRLF body keeps its terminators and puts the caret at the start of the blank line after the group',
      () {
        const body = 'Review\r\n\r\nNext';
        final r = _wi146Plan(body, anchorLine: 0);
        expect(r.text, 'Review\n\n$_wi146Mock\n$_wi146Spec\r\n\r\nNext');
        expect(r.text.substring(r.caret), startsWith('\r\nNext'));
      },
    );

    test('a whitespace only line away from the anchor is left as it is', () {
      final r = _wi146Plan('Intro\n \nOutro', anchorLine: 2);
      expect(r.text, 'Intro\n \nOutro\n\n$_wi146Mock\n$_wi146Spec');
    });
  });

  group('carrying the anchor line through an edit (AC4)', () {
    test('an unchanged body keeps the line', () {
      expect(carryAttachmentAnchor('A\nB\nC', 'A\nB\nC', 1), 1);
    });

    test('a line inserted above moves the anchor down by one', () {
      expect(carryAttachmentAnchor('A\nB\nC', 'New\nA\nB\nC', 1), 2);
    });

    test('several lines inserted above move the anchor down by that many', () {
      expect(carryAttachmentAnchor('A\nB\nC', 'N1\nN2\nA\nB\nC', 2), 4);
    });

    test('a line removed above moves the anchor up by one', () {
      expect(carryAttachmentAnchor('A\nB\nC', 'B\nC', 2), 1);
    });

    test('text changed on a line above keeps the anchor index', () {
      expect(carryAttachmentAnchor('A\nB\nC', 'A!\nB\nC', 2), 2);
    });

    test('an edit below the anchor keeps its index', () {
      expect(carryAttachmentAnchor('A\nB\nC', 'A\nB\nC\nD', 1), 1);
      expect(carryAttachmentAnchor('A\nB\nC', 'A\nB\nC!', 0), 0);
    });

    test('a line added at the end below the anchor keeps its index', () {
      expect(carryAttachmentAnchor('A\nB', 'A\nB\nC', 0), 0);
    });

    test('typing on the anchor line keeps its index', () {
      expect(carryAttachmentAnchor('A\nB\nC', 'A\nB!\nC', 1), 1);
    });

    test('Enter inside the anchor line keeps the index of its first half', () {
      expect(carryAttachmentAnchor('A\nBC\nD', 'A\nB\nC\nD', 1), 1);
    });

    test('removing the anchor line gives no line', () {
      expect(carryAttachmentAnchor('A\nB\nC', 'A\nC', 1), isNull);
    });

    test('replacing the anchor line along with the next gives no line', () {
      expect(carryAttachmentAnchor('A\nB\nC\nD', 'A\nX\nD', 1), isNull);
      expect(carryAttachmentAnchor('A\nB\nC\nD', 'A\nX\nD', 2), isNull);
    });

    test('a line below a removed line moves up past it', () {
      expect(carryAttachmentAnchor('A\nB\nC\nD', 'A\nD', 3), 1);
    });
  });
}
