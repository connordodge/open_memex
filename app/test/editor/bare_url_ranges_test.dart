// WI #435 (392-E2): bareUrlRanges finds bare http, https and mailto URLs for
// the spell checker (Spec #392 requirement 2; ruling D23).
//
// Every test also holds a positive expectation, so none of them passes against
// a function that returns nothing.

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/markdown_inline.dart';

/// The text each reported range covers.
List<String> _urls(String text) => [
  for (final r in bareUrlRanges(text)) text.substring(r.start, r.end),
];

void main() {
  group('schemes', () {
    test('finds an http URL as the whole text', () {
      expect(bareUrlRanges('http://a.example'), const [InlineRange(0, 16)]);
    });

    test('finds an https URL inside prose with exact offsets', () {
      const text = 'go to https://x.example/z now';
      expect(bareUrlRanges(text), const [InlineRange(6, 25)]);
      expect(_urls(text), ['https://x.example/z']);
    });

    test('finds a mailto URL', () {
      expect(_urls('mail mailto:me@x.example ok'), ['mailto:me@x.example']);
    });

    test('finds http, https and mailto URLs in order', () {
      const text =
          'http://a.example then https://b.example and mailto:c@d.example';
      expect(_urls(text), [
        'http://a.example',
        'https://b.example',
        'mailto:c@d.example',
      ]);
      final ranges = bareUrlRanges(text);
      expect(ranges[0].start, 0);
      expect(ranges[1].start, text.indexOf('https'));
      expect(ranges[2].start, text.indexOf('mailto'));
    });

    test('a URL ends at whitespace', () {
      expect(_urls('https://x.example/a b'), ['https://x.example/a']);
      expect(_urls('https://x.example/a\nnext'), ['https://x.example/a']);
      expect(_urls('https://x.example/a\tnext'), ['https://x.example/a']);
    });

    test('keeps internal punctuation, query and fragment', () {
      expect(_urls('see https://x.example/a.b?c=1&d=2#e,f ok'), [
        'https://x.example/a.b?c=1&d=2#e,f',
      ]);
    });
  });

  group('trailing punctuation', () {
    for (final p in ['.', ',', ';', ':', '!', '?']) {
      test('drops a trailing $p', () {
        final text = 'see https://x.example/p$p next';
        expect(_urls(text), ['https://x.example/p']);
        final r = bareUrlRanges(text).single;
        expect(r.start, 4);
        expect(r.end, 4 + 'https://x.example/p'.length);
      });
    }

    test('drops a run of trailing punctuation', () {
      expect(_urls('is it https://x.example/a?!'), ['https://x.example/a']);
      expect(_urls('so https://x.example/a.,;'), ['https://x.example/a']);
    });

    test('drops a trailing period at the end of the text', () {
      const text = 'https://x.example/a.';
      expect(bareUrlRanges(text), const [InlineRange(0, 19)]);
    });

    test('keeps punctuation that is followed by more URL', () {
      expect(_urls('https://x.example/a.b, c'), ['https://x.example/a.b']);
    });
  });

  group('closing parenthesis', () {
    test('drops an unmatched closing parenthesis', () {
      expect(_urls('(see https://x.example/a) ok'), ['https://x.example/a']);
    });

    test('drops a closing parenthesis when no opening one is inside', () {
      expect(_urls('https://x.example/a)'), ['https://x.example/a']);
    });

    test('keeps a closing parenthesis that matches an opening one inside', () {
      expect(_urls('see https://x.example/wiki/Foo_(bar) ok'), [
        'https://x.example/wiki/Foo_(bar)',
      ]);
    });

    test('keeps a matched pair at the very end of the text', () {
      expect(_urls('https://x.example/(a)'), ['https://x.example/(a)']);
    });

    test('drops the extra closing parenthesis after a matched pair', () {
      expect(_urls('(https://x.example/a_(b))'), ['https://x.example/a_(b)']);
      expect(_urls('https://x.example/(a))'), ['https://x.example/(a)']);
    });

    test('drops punctuation after a matched pair', () {
      expect(_urls('see https://x.example/a_(b).'), [
        'https://x.example/a_(b)',
      ]);
    });

    test(
      'drops an unmatched parenthesis and then the punctuation before it',
      () {
        expect(_urls('(see https://x.example/a.) ok'), ['https://x.example/a']);
        expect(_urls('(see https://x.example/a).'), ['https://x.example/a']);
      },
    );

    test('keeps an unclosed opening parenthesis inside the URL', () {
      expect(_urls('https://x.example/(a b'), ['https://x.example/(a']);
    });
  });

  group('markdown links', () {
    test('reports only the bare URL next to a link', () {
      const text = '[t](https://x.example) and https://y.example';
      expect(_urls(text), ['https://y.example']);
      expect(bareUrlRanges(text).single.start, text.lastIndexOf('https'));
    });

    test('never reports the url of a link, with a bare URL before it', () {
      const text = 'https://a.example [t](https://b.example/c.) end';
      expect(_urls(text), ['https://a.example']);
    });

    test('never reports the url of an image link', () {
      expect(_urls('![img](https://x.example/i.png) then mailto:a@b.example'), [
        'mailto:a@b.example',
      ]);
    });

    test('a link spanning two lines is not a link', () {
      const text = '[t](\nhttps://x.example)';
      expect(_urls(text), ['https://x.example']);
    });

    test('a bare URL in parentheses after plain text is reported', () {
      const text = 'text (https://x.example/a) more';
      expect(_urls(text), ['https://x.example/a']);
    });

    test(
      'a bracket then a URL in parentheses is reported only when it is no link',
      () {
        // `[t] (url)` has a space, so it is not a link.
        const text = '[t] (https://x.example/a)';
        expect(_urls(text), ['https://x.example/a']);
      },
    );
  });

  group('offsets', () {
    test('stay correct after an emoji', () {
      const text = '😀 https://x.example/a, 🎉 mailto:a@b.example.';
      final ranges = bareUrlRanges(text);
      expect(ranges, [
        InlineRange(3, 3 + 'https://x.example/a'.length),
        InlineRange(
          text.indexOf('mailto'),
          text.indexOf('mailto') + 'mailto:a@b.example'.length,
        ),
      ]);
      expect(_urls(text), ['https://x.example/a', 'mailto:a@b.example']);
    });

    test('are built from run time values', () {
      final prefix = List.filled(7, 'x').join();
      final text = '$prefix https://x.example!';
      final ranges = bareUrlRanges(text);
      expect(ranges, hasLength(1));
      final r = ranges.first;
      expect(r.start, 8);
      expect(r.end, text.length - 1);
      expect(r.isEmpty, isFalse);
    });
  });

  group('verify pins', () {
    test('a URL cut down to its scheme is not reported', () {
      expect(_urls('see http://. and https://?! and mailto:; ok'), isEmpty);
      expect(_urls('see http://. and https://x.example'), [
        'https://x.example',
      ]);
    });

    test('a scheme in capitals is a URL', () {
      expect(_urls('go HTTPS://X.EXAMPLE/A now'), ['HTTPS://X.EXAMPLE/A']);
    });

    test('a closing parenthesis is dropped once per missing opening one', () {
      expect(_urls('https://x.example/a))))'), ['https://x.example/a']);
      expect(_urls('https://x.example/(a)))'), ['https://x.example/(a)']);
    });

    test('a URL used as link text stops at the closing bracket', () {
      const text = '[https://a.example/x](https://b.example) tail';
      expect(bareUrlRanges(text), const [InlineRange(1, 20)]);
      expect(_urls(text), ['https://a.example/x']);
      expect(_urls('go [see https://a.example/x](https://b.example) ok'), [
        'https://a.example/x',
      ]);
    });
  });

  group('link and image boundaries', () {
    test('a URL stops at the start of a link that follows it directly', () {
      const text = 'see https://a.example/x[t](https://b.example) ok';
      expect(_urls(text), ['https://a.example/x']);
      expect(bareUrlRanges(text), const [InlineRange(4, 23)]);
    });

    test('a URL stops at the start of an image that follows it directly', () {
      const text = 'x https://a.b/c![a](u) y';
      expect(_urls(text), ['https://a.b/c']);
      expect(bareUrlRanges(text), const [InlineRange(2, 15)]);
      const withImageUrl = 'https://a.example/x![i](https://i.example/p.png) e';
      expect(_urls(withImageUrl), ['https://a.example/x']);
    });

    test('a bare URL directly after a link url is found by the rescan', () {
      const text = '[t](https://b.example)https://c.example';
      expect(_urls(text), ['https://c.example']);
      expect(bareUrlRanges(text), const [InlineRange(22, 39)]);
    });

    test('a bare URL directly after an image url is found by the rescan', () {
      const text = '![a](https://i.example/p.png)https://c.example';
      expect(_urls(text), ['https://c.example']);
    });

    test('a URL as link text is reported and the link url is not', () {
      const text = '[https://a.example](https://b.example)';
      expect(bareUrlRanges(text), const [InlineRange(1, 18)]);
    });

    test('a URL in the text of a later link stops at that link text end', () {
      const text = '[a](u) go [see https://x.example/y](v) z';
      expect(_urls(text), ['https://x.example/y']);
      expect(bareUrlRanges(text).single.start, text.indexOf('https'));
    });

    test('URLs between and after several links and images are all found', () {
      const text =
          'a https://p.example/1 [t](u) b https://q.example/2 ![i](v.png) '
          'https://r.example/3 [s](w) https://s.example/4';
      expect(_urls(text), [
        'https://p.example/1',
        'https://q.example/2',
        'https://r.example/3',
        'https://s.example/4',
      ]);
    });

    test('a link between two URLs does not hide either of them', () {
      const text = 'https://a.example [t](https://u.example) https://b.example';
      expect(_urls(text), ['https://a.example', 'https://b.example']);
      expect(bareUrlRanges(text).last.start, text.lastIndexOf('https'));
    });

    test('a scheme directly before a link or image is not reported', () {
      expect(_urls('see https://[t](u) and https://x.example'), [
        'https://x.example',
      ]);
      expect(_urls('see mailto:![i](v) and mailto:a@b.example'), [
        'mailto:a@b.example',
      ]);
    });

    test('a scheme followed by whitespace is not reported', () {
      expect(_urls('https:// foo https://x.example'), ['https://x.example']);
      expect(_urls('go http://'), isEmpty);
      expect(_urls('go http://\nhttps://x.example'), ['https://x.example']);
    });

    test('an image url is left out unless includeImageUrls is set', () {
      const text = 'a ![i](https://i.example/p.png) b https://y.example';
      expect(_urls(text), ['https://y.example']);
      expect(bareUrlRanges(text, includeImageUrls: false), bareUrlRanges(text));
    });

    test(
      'includeImageUrls reports image urls among the bare ones in order',
      () {
        const text =
            'see ![alt](https://x.example/i.png) and https://y.example '
            '![b](dir/b.png) then mailto:a@b.example';
        final ranges = bareUrlRanges(text, includeImageUrls: true);
        expect(
          [for (final r in ranges) text.substring(r.start, r.end)],
          [
            'https://x.example/i.png',
            'https://y.example',
            'dir/b.png',
            'mailto:a@b.example',
          ],
        );
        expect(ranges.first.start, text.indexOf('https://x.example'));
        final starts = [for (final r in ranges) r.start];
        expect([...starts]..sort(), starts);
      },
    );

    test('includeImageUrls reports a relative image path and nothing else', () {
      const text = 'a ![i](dir/teh.png) b';
      expect(bareUrlRanges(text), isEmpty);
      expect(bareUrlRanges(text, includeImageUrls: true), const [
        InlineRange(7, 18),
      ]);
    });

    test('includeImageUrls does not report a link url or text twice', () {
      const text = '[t](https://b.example) ![i](https://i.example/p.png)';
      final ranges = bareUrlRanges(text, includeImageUrls: true);
      expect(ranges, hasLength(1));
      expect(
        text.substring(ranges.single.start, ranges.single.end),
        ('https://i.example/p.png'),
      );
    });
  });

  group('whitespace set', () {
    // A URL ends at exactly the code units a regex \s matches.
    const spaces = [
      0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0xa0, 0x1680, 0x2000, 0x2005,
      0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff, //
    ];
    const notSpaces = [
      0x08, 0x0e, 0x1f, 0x21, 0x7f, 0x85, 0x180e, 0x1fff, 0x200b, 0x2027,
      0x202a, 0x202e, 0x205e, 0x2060, 0x2fff, 0x3001, 0xfefe, 0xff00, //
    ];

    for (final unit in spaces) {
      test('code unit 0x${unit.toRadixString(16)} ends a URL', () {
        final ch = String.fromCharCode(unit);
        final text = 'https://x.example/a${ch}b';
        expect(bareUrlRanges(text), const [InlineRange(0, 19)]);
      });
    }

    for (final unit in notSpaces) {
      test('code unit 0x${unit.toRadixString(16)} does not end a URL', () {
        final ch = String.fromCharCode(unit);
        final text = 'https://x.example/a${ch}b';
        expect(bareUrlRanges(text), [InlineRange(0, text.length)]);
      });
    }
  });

  group('cost', () {
    // The bound is about 100x what a linear scan needs and far below what a
    // quadratic one takes on this text (about 40 s), so load cannot flip it.
    test('a long line that mixes URLs with links and images is linear', () {
      final text = 'https://x[a](b)' * 20000;
      final watch = Stopwatch()..start();
      final ranges = bareUrlRanges(text);
      final imaged = bareUrlRanges(text, includeImageUrls: true);
      watch.stop();
      expect(ranges, hasLength(20000));
      expect(imaged, hasLength(20000));
      expect(ranges.first, const InlineRange(0, 9));
      expect(ranges[1], const InlineRange(15, 24));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('a long line of URLs without whitespace is linear', () {
      final text = 'https://x[a]![b](c)' * 15000;
      final watch = Stopwatch()..start();
      final ranges = bareUrlRanges(text);
      watch.stop();
      expect(ranges, hasLength(15000));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });
}
