// WI #395 (U1): markdownPreviewText, the plain-text block preview (Spec #393
// requirement 7, Testing Strategy "Unit tests", ruling D10, lead ruling LR4).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/markdown_preview_text.dart';

String _show(String s) => s.replaceAll('\n', r'\n').replaceAll('\r', r'\r');

/// Expects `markdownPreviewText(input) == expected` for every entry.
void _expectPreviews(Map<String, String> cases) {
  for (final MapEntry(key: input, value: expected) in cases.entries) {
    expect(
      markdownPreviewText(input),
      expected,
      reason: 'input: ${_show(input)}',
    );
  }
}

void main() {
  group('plain text', () {
    test('markdownPreviewText returns a plain paragraph as written', () {
      // The exact public signature #391's echo rows call (ruling D10).
      const String Function(String) preview = markdownPreviewText;
      expect(preview('Hello world, plain text.'), 'Hello world, plain text.');
      _expectPreviews({
        'One sentence. Another one?': 'One sentence. Another one?',
        'Unicode stays: café, 日本語, 😀.': 'Unicode stays: café, 日本語, 😀.',
      });
    });
  });

  group('line breaks (LR4)', () {
    test('a line break becomes one space', () {
      _expectPreviews({
        'one\ntwo': 'one two',
        'one\ntwo\nthree': 'one two three',
        'one\r\ntwo': 'one two',
        'one\r\ntwo\r\nthree': 'one two three',
      });
    });

    test('blank lines add no extra space', () {
      _expectPreviews({
        'one\n\ntwo': 'one two',
        'one\n\n\n\ntwo': 'one two',
        'one\r\n\r\ntwo': 'one two',
        'one\n   \n\t\ntwo': 'one two',
        'one\n\ntwo\n\nthree': 'one two three',
      });
    });

    test('the result has no leading or trailing whitespace', () {
      _expectPreviews({
        '\n\none\n\n': 'one',
        '  one  ': 'one',
        '\r\n one \r\n': 'one',
        'one\n': 'one',
        '\none': 'one',
        'one\n- ': 'one',
        '> \none': 'one',
        '': '',
        '\n \n\t\n': '',
      });
    });

    test('the result never holds a line terminator', () {
      const inputs = [
        'a\nb',
        'a\r\nb',
        '- a\n  b\n- c',
        '```\na\n\nb\n```',
        '# H\n\n> q\r\n1. n',
      ];
      for (final input in inputs) {
        final out = markdownPreviewText(input);
        expect(out, isNotEmpty, reason: 'input: ${_show(input)}');
        expect(out, isNot(contains('\n')), reason: 'input: ${_show(input)}');
        expect(out, isNot(contains('\r')), reason: 'input: ${_show(input)}');
      }
    });
  });

  group('fenced code', () {
    test(
      'a fenced code block shows its inner lines joined by single spaces without the fences',
      () {
        _expectPreviews({
          '```\nfirst line\nsecond line\n```': 'first line second line',
          '```dart\nvar x = 1;\nprint(x);\n```': 'var x = 1; print(x);',
          '```\r\nfirst\r\nsecond\r\n```': 'first second',
          '```\na\n\nb\n```': 'a b',
        });
      },
    );

    test('markdown inside a fenced code block is not reduced', () {
      _expectPreviews({
        '```\n**x**\n```': '**x**',
        '```\n_a_ ~~b~~ `c` [t](u) [[T|a]] \\* #tag\n```':
            '_a_ ~~b~~ `c` [t](u) [[T|a]] \\* #tag',
        '```\n- item\n> quote\n# head\n1. one\n- [ ] task\n```':
            '- item > quote # head 1. one - [ ] task',
        '```\n![[2026-11-10#^abc]]\n```': '![[2026-11-10#^abc]]',
      });
    });

    test('prose around a fenced code block is still reduced', () {
      _expectPreviews({
        '**Before**\n```\n**x**\n```\n_after_': 'Before **x** after',
        '- item\n```\n- raw\n```\n- next': 'item - raw next',
      });
    });

    test('an unclosed fence keeps the rest of the block unreduced', () {
      _expectPreviews({
        'see\n```\n**x**\n- y': 'see **x** - y',
        '```\n**only**': '**only**',
      });
    });
  });

  group('line markers', () {
    test('bullet markers are dropped at the start of a line', () {
      _expectPreviews({
        '- dash': 'dash',
        '* star': 'star',
        '+ plus': 'plus',
        '- a\n* b\n+ c': 'a b c',
      });
    });

    test('an ordered marker is dropped', () {
      _expectPreviews({
        '1. first': 'first',
        '1. first\n2. second\n10. tenth': 'first second tenth',
        '007. bond': 'bond',
      });
    });

    test('task markers are dropped', () {
      _expectPreviews({
        '- [ ] open': 'open',
        '- [x] done': 'done',
        '- [X] Done': 'Done',
        '* [ ] star task\n+ [x] plus task': 'star task plus task',
        '- [ ]': '',
      });
    });

    test('quote markers are dropped', () {
      _expectPreviews({
        '> quoted': 'quoted',
        '> quoted\n> more': 'quoted more',
        'a\n>\nb': 'a b',
      });
    });

    test('heading markers are dropped', () {
      _expectPreviews({
        '# One': 'One',
        '### Three': 'Three',
        '###### Six': 'Six',
        '## Title\nbody': 'Title body',
      });
    });

    test(
      'a multi-line list item drops markers and indentation on its continuation lines',
      () {
        _expectPreviews({
          '- first line\n  continues here': 'first line continues here',
          '- first line\n\tcontinues here': 'first line continues here',
          '1. first\n   continues': 'first continues',
          '- [ ] task\n  continues': 'task continues',
          '- parent\n  - child\n    - [ ] grandchild task\n  1. numbered child':
              'parent child grandchild task numbered child',
        });
      },
    );

    test('markers after a quote marker are dropped too', () {
      _expectPreviews({
        '> > x': 'x',
        '> > > x': 'x',
        '> > x\n> y': 'x y',
        '> - x': 'x',
        '> * x': 'x',
        '> 1. x': 'x',
        '> - [ ] x': 'x',
        '> - [x] x': 'x',
        '> # h': 'h',
        '> ## h': 'h',
        '> > # h': 'h',
        '> > - [ ] x': 'x',
        '> - a\n> - b': 'a b',
        '> **bold** and [t](u)': 'bold and t',
        '> > _a_ [[T|alias]]': 'a alias',
        'before\n> - x\nafter': 'before x after',
      });
    });

    test('a quote marker on an indented continuation line is dropped', () {
      _expectPreviews({
        '- a\n  > q': 'a q',
        '- a\n\t> q': 'a q',
        '- a\n   > q': 'a q',
        '1. a\n   > q': 'a q',
        '- a\n  > > q': 'a q',
        '- a\n  > - q': 'a q',
        '- a\n  > # q': 'a q',
        '- a\n  > q\n  > r': 'a q r',
        '- [ ] a\n  > **q**': 'a q',
      });
    });

    test('a marker after a quote marker stays when it is no real marker', () {
      _expectPreviews({
        '> -x': '-x',
        '> #tag stays': '#tag stays',
        '> 1) x': '1) x',
        '> a > b': 'a > b',
        '> a - b': 'a - b',
        '> [ ] x': '[ ] x',
        '- a\n  text > not a quote': 'a text > not a quote',
        '- a\n  -x': 'a -x',
      });
    });

    test('a marker in the middle of a line stays', () {
      _expectPreviews({
        'a - b > c 1. d': 'a - b > c 1. d',
        'x * y + z': 'x * y + z',
        'see # not a heading': 'see # not a heading',
      });
    });

    test('text that only looks like a marker stays', () {
      _expectPreviews({
        '-dash': '-dash',
        '1) paren': '1) paren',
        '>close': '>close',
      });
    });
  });

  group('links', () {
    test('a link shows its text', () {
      _expectPreviews({
        '[text](https://example.com)': 'text',
        'see [the docs](https://x.y/z?a=1) now': 'see the docs now',
        '[The Quiet Compromise](https://example.com/essay)':
            'The Quiet Compromise',
      });
    });

    test('a wikilink shows its title', () {
      _expectPreviews({
        '[[Title]]': 'Title',
        'go to [[My Topic]] now': 'go to My Topic now',
      });
    });

    test('a wikilink alias shows the alias', () {
      _expectPreviews({
        '[[Title|alias]]': 'alias',
        'see [[Long Title|short]] here': 'see short here',
      });
    });

    test('a kind wikilink shows its title', () {
      _expectPreviews({
        '[[Ann Lee~person]]': 'Ann Lee',
        'met [[Ann Lee~person]] today': 'met Ann Lee today',
      });
    });

    test('a kind wikilink with an alias shows the alias', () {
      _expectPreviews({
        '[[Ann Lee~person|Ann]]': 'Ann',
        'met [[Ann Lee~person|Ann]] today': 'met Ann today',
      });
    });
  });

  group('emphasis and code', () {
    test('bold markers are dropped and their content kept', () {
      _expectPreviews({
        '**bold**': 'bold',
        'a **b** c': 'a b c',
        '**😀 ok**': '😀 ok',
      });
    });

    test('underscore emphasis markers are dropped and their content kept', () {
      _expectPreviews({
        '_under_': 'under',
        '__double__': 'double',
        '_under_ and __double__': 'under and double',
        'snake_case_name stays': 'snake_case_name stays',
      });
    });

    test('italic star markers are dropped and their content kept', () {
      _expectPreviews({'*italic*': 'italic', 'a *b* c': 'a b c'});
    });

    test('bold italic markers are dropped and their content kept', () {
      _expectPreviews({'***both***': 'both', 'a ***b*** c': 'a b c'});
    });

    test('strike markers are dropped and their content kept', () {
      _expectPreviews({'~~gone~~': 'gone', 'a ~~b~~ c': 'a b c'});
    });

    test('nested emphasis drops every marker', () {
      _expectPreviews({
        '**a *b* c**': 'a b c',
        '~~a **b** c~~': 'a b c',
        '*a ~~b~~ c*': 'a b c',
      });
    });

    test('code span backticks are dropped and the code is kept unreduced', () {
      _expectPreviews({
        '`code`': 'code',
        'run `a*b*` now': 'run a*b* now',
        '``a`b``': 'a`b',
        '`[t](u)` and `**x**`': '[t](u) and **x**',
        '`\\*`': '\\*',
      });
    });

    test('unclosed delimiters stay literal', () {
      _expectPreviews({
        '**open': '**open',
        'a * b': 'a * b',
        '[text](no close': '[text](no close',
        '[[no close': '[[no close',
        '`tick': '`tick',
      });
    });
  });

  group('escapes', () {
    test('a backslash escape shows the escaped character only', () {
      _expectPreviews({
        '\\*': '*',
        '\\*not italic\\*': '*not italic*',
        '\\[x\\]': '[x]',
        'a\\\\b': 'a\\b',
        '\\# not a heading': '# not a heading',
        '\\- not a bullet': '- not a bullet',
      });
    });

    test('a backslash before a letter stays', () {
      _expectPreviews({'C:\\dir': 'C:\\dir', 'a \\n b': 'a \\n b'});
    });
  });

  group('tags', () {
    test('inline tags stay as written', () {
      _expectPreviews({
        '#work': '#work',
        '#work at the start': '#work at the start',
        'a #work b': 'a #work b',
        '#my_tag_x stays': '#my_tag_x stays',
        '*a #x*': 'a #x',
        '- #todo item': '#todo item',
      });
    });
  });

  group('transclusions', () {
    test('a transclusion shows an arrow and its date', () {
      _expectPreviews({
        '![[2026-11-10#^abc]]': '↪ 2026-11-10',
        '![[2026-11-10#^ab..^cd]]': '↪ 2026-11-10',
        'see ![[2026-01-02#^a1]] here': 'see ↪ 2026-01-02 here',
        'one\n![[2026-11-10#^abc]]\ntwo': 'one ↪ 2026-11-10 two',
      });
    });
  });

  group('nested and edge cases', () {
    test('a link inside bold shows the link text', () {
      _expectPreviews({
        '**see [docs](https://x.y)**': 'see docs',
        '[**bold** text](https://x.y)': 'bold text',
        '~~[old](https://x.y)~~': 'old',
      });
    });

    test('a wikilink inside emphasis shows its alias or title', () {
      _expectPreviews({
        '**[[Title|alias]]**': 'alias',
        '_[[Ann Lee~person]]_': 'Ann Lee',
      });
    });

    test('a task marker followed by a link shows the link text', () {
      _expectPreviews({
        '- [ ] [Read this](https://x.y) later': 'Read this later',
        '- [x] [[Topic~project|the project]] done': 'the project done',
      });
    });

    test('a mixed block reduces to one plain line', () {
      _expectPreviews({
        '- My body of work\n  includes #work and [[Essay~essay|my essay]]\n\n'
                '> **Note:** see `x`':
            'My body of work includes #work and my essay Note: see x',
      });
    });
  });
}
