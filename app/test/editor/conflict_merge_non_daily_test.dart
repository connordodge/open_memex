// WI #16 (Spec #7 Req 34a, D20): the three-way line merge of a non-daily
// note's person section after a save conflict. `base` is the body at the
// editor's base version, `local` the editor's body, `server` the refetched
// body. Disjoint changes merge; a line changed on both sides, or different
// insertions into the same base gap, is an overlap. The footer always comes
// from the server.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/conflict_merge.dart';

const _footer = '<!-- memex:topics -->\n[[Player Loop~about]]\n';
const _footerMore =
    '<!-- memex:topics -->\n[[Player Loop~about]]\n[[Combat~about]]\n';

/// The base of the disjoint-change table rows that do not merge onto
/// `Alpha\nBravo\nCharlie\n`.
const _baseOf = {
  'several disjoint changes on both sides merge in base order':
      'Alpha\nBravo\nCharlie\nDelta\nEcho\nFoxtrot\n',
  'changes in paragraphs separated by blank lines merge':
      'Intro\n\nMiddle\n\nEnd\n',
  'a last line without a newline merges': 'Alpha\nBravo\nCharlie',
};

NonDailyMergeResult _merge(String base, String local, String server) =>
    mergeNonDaily(base: base, local: local, server: server);

/// The merged text, failing the test when the merge overlapped.
String _merged(String base, String local, String server) {
  final result = _merge(base, local, server);
  expect(result, isA<NonDailyMerged>(), reason: 'expected a merge');
  return (result as NonDailyMerged).text;
}

void _expectOverlap(String base, String local, String server) {
  expect(_merge(base, local, server), isA<NonDailyOverlap>());
}

void main() {
  group('disjoint changes merge', () {
    test(
      'changes on different lines return the merged text holding both changes',
      () {
        expect(
          _merged(
            'Alpha\nBravo\nCharlie\nDelta\n',
            'Alpha\nBravo mine\nCharlie\nDelta\n',
            'Alpha\nBravo\nCharlie\nDelta theirs\n',
          ),
          'Alpha\nBravo mine\nCharlie\nDelta theirs\n',
        );
      },
    );

    test('a change only on the local side returns the local text', () {
      expect(
        _merged('Alpha\nBravo\n', 'Alpha\nBravo mine\n', 'Alpha\nBravo\n'),
        'Alpha\nBravo mine\n',
      );
    });

    test('a change only on the server side returns the server text', () {
      expect(
        _merged('Alpha\nBravo\n', 'Alpha\nBravo\n', 'Alpha theirs\nBravo\n'),
        'Alpha theirs\nBravo\n',
      );
    });

    test('no change on either side returns the base text', () {
      expect(
        _merged('Alpha\nBravo\n', 'Alpha\nBravo\n', 'Alpha\nBravo\n'),
        'Alpha\nBravo\n',
      );
    });

    for (final (name, local, server, merged) in [
      (
        'an edit of the first line on one side and the last line on the other merge',
        'Alpha mine\nBravo\nCharlie\n',
        'Alpha\nBravo\nCharlie theirs\n',
        'Alpha mine\nBravo\nCharlie theirs\n',
      ),
      (
        'an edit of the last line on one side and the first line on the other merge',
        'Alpha\nBravo\nCharlie mine\n',
        'Alpha theirs\nBravo\nCharlie\n',
        'Alpha theirs\nBravo\nCharlie mine\n',
      ),
      (
        'edits of adjacent lines on the two sides merge',
        'Alpha\nBravo mine\nCharlie\n',
        'Alpha\nBravo\nCharlie theirs\n',
        'Alpha\nBravo mine\nCharlie theirs\n',
      ),
      (
        'insertions into different gaps of the base merge',
        'Alpha\nMine\nBravo\nCharlie\n',
        'Alpha\nBravo\nTheirs\nCharlie\n',
        'Alpha\nMine\nBravo\nTheirs\nCharlie\n',
      ),
      (
        'an insertion at the start on one side and an edit of the first line on the other merge',
        'Mine\nAlpha\nBravo\nCharlie\n',
        'Alpha theirs\nBravo\nCharlie\n',
        'Mine\nAlpha theirs\nBravo\nCharlie\n',
      ),
      (
        'an insertion after a line the other side edited merges',
        'Alpha\nBravo mine\nCharlie\n',
        'Alpha\nBravo\nTheirs\nCharlie\n',
        'Alpha\nBravo mine\nTheirs\nCharlie\n',
      ),
      (
        'an insertion before a line the other side edited merges',
        'Alpha\nMine\nBravo\nCharlie\n',
        'Alpha\nBravo theirs\nCharlie\n',
        'Alpha\nMine\nBravo theirs\nCharlie\n',
      ),
      (
        'an insertion at the end on one side and an edit of the last line on the other merge',
        'Alpha\nBravo\nCharlie mine\n',
        'Alpha\nBravo\nCharlie\nTheirs\n',
        'Alpha\nBravo\nCharlie mine\nTheirs\n',
      ),
      (
        'several disjoint changes on both sides merge in base order',
        'Alpha mine\nBravo\nCharlie\nDelta mine\nEcho\nFoxtrot\n',
        'Alpha\nBravo theirs\nCharlie\nDelta\nEcho\nFoxtrot theirs\n',
        'Alpha mine\nBravo theirs\nCharlie\nDelta mine\nEcho\nFoxtrot theirs\n',
      ),
      (
        'changes in paragraphs separated by blank lines merge',
        'Intro mine\n\nMiddle\n\nEnd\n',
        'Intro\n\nMiddle\n\nEnd theirs\n',
        'Intro mine\n\nMiddle\n\nEnd theirs\n',
      ),
      (
        'a last line without a newline merges',
        'Alpha mine\nBravo\nCharlie',
        'Alpha\nBravo\nCharlie theirs',
        'Alpha mine\nBravo\nCharlie theirs',
      ),
    ]) {
      test(name, () {
        final base = _baseOf[name] ?? 'Alpha\nBravo\nCharlie\n';
        expect(_merged(base, local, server), merged);
        // Merging is symmetric in which side made which change.
        expect(_merged(base, server, local), merged);
      });
    }
  });

  group('a line changed on both sides is an overlap', () {
    test('a line changed differently on both sides returns an overlap', () {
      _expectOverlap(
        'Alpha\nBravo\nCharlie\n',
        'Alpha\nBravo mine\nCharlie\n',
        'Alpha\nBravo theirs\nCharlie\n',
      );
    });

    for (final (name, base, local, server) in [
      (
        'the first line changed differently on both sides returns an overlap',
        'Alpha\nBravo\n',
        'Alpha mine\nBravo\n',
        'Alpha theirs\nBravo\n',
      ),
      (
        'the last line changed differently on both sides returns an overlap',
        'Alpha\nBravo\n',
        'Alpha\nBravo mine\n',
        'Alpha\nBravo theirs\n',
      ),
      (
        'a change of two lines that one edit on the other side shares returns an overlap',
        'Alpha\nBravo\nCharlie\nDelta\n',
        'Alpha\nBravo mine\nCharlie mine\nDelta\n',
        'Alpha\nBravo\nCharlie theirs\nDelta\n',
      ),
      (
        'one overlapping line among disjoint changes returns an overlap',
        'Alpha\nBravo\nCharlie\nDelta\n',
        'Alpha mine\nBravo\nCharlie mine\nDelta\n',
        'Alpha\nBravo theirs\nCharlie theirs\nDelta\n',
      ),
    ]) {
      test(name, () {
        _expectOverlap(base, local, server);
        _expectOverlap(base, server, local);
      });
    }

    test(
      'two different insertions into the same gap of the base return an overlap',
      () {
        _expectOverlap(
          'Alpha\nBravo\n',
          'Alpha\nMine\nBravo\n',
          'Alpha\nTheirs\nBravo\n',
        );
      },
    );

    for (final (name, local, server) in [
      (
        'two different insertions at the start of the base return an overlap',
        'Mine\nAlpha\nBravo\n',
        'Theirs\nAlpha\nBravo\n',
      ),
      (
        'two different insertions at the end of the base return an overlap',
        'Alpha\nBravo\nMine\n',
        'Alpha\nBravo\nTheirs\n',
      ),
    ]) {
      test(name, () {
        _expectOverlap('Alpha\nBravo\n', local, server);
      });
    }
  });

  group('the same change on both sides', () {
    test('the same change made on both sides is applied once', () {
      expect(
        _merged(
          'Alpha\nBravo\nCharlie\n',
          'Alpha\nBravo both\nCharlie\n',
          'Alpha\nBravo both\nCharlie\n',
        ),
        'Alpha\nBravo both\nCharlie\n',
      );
    });

    for (final (name, base, local, server, merged) in [
      (
        'the same insertion made on both sides is applied once',
        'Alpha\nBravo\n',
        'Alpha\nBoth\nBravo\n',
        'Alpha\nBoth\nBravo\n',
        'Alpha\nBoth\nBravo\n',
      ),
      (
        'the same deletion made on both sides is applied once',
        'Alpha\nBravo\nCharlie\n',
        'Alpha\nCharlie\n',
        'Alpha\nCharlie\n',
        'Alpha\nCharlie\n',
      ),
      (
        'the same change on both sides beside disjoint changes merges',
        'Alpha\nBravo\nCharlie\nDelta\nEcho\n',
        'Alpha mine\nBravo\nCharlie both\nDelta\nEcho\n',
        'Alpha\nBravo\nCharlie both\nDelta\nEcho theirs\n',
        'Alpha mine\nBravo\nCharlie both\nDelta\nEcho theirs\n',
      ),
    ]) {
      test(name, () {
        expect(_merged(base, local, server), merged);
      });
    }
  });

  group('deletions', () {
    test(
      'a deletion on one side combined with an edit of another line on the other side merges',
      () {
        expect(
          _merged(
            'Alpha\nBravo\nCharlie\n',
            'Bravo\nCharlie\n',
            'Alpha\nBravo\nCharlie theirs\n',
          ),
          'Bravo\nCharlie theirs\n',
        );
      },
    );

    for (final (name, base, local, server, merged) in [
      (
        'a server deletion combined with a local edit of another line merges',
        'Alpha\nBravo\nCharlie\n',
        'Alpha mine\nBravo\nCharlie\n',
        'Alpha\nBravo\n',
        'Alpha mine\nBravo\n',
      ),
      (
        'a deletion next to a line the other side edited merges',
        'Alpha\nBravo\nCharlie\n',
        'Alpha\nCharlie\n',
        'Alpha\nBravo\nCharlie theirs\n',
        'Alpha\nCharlie theirs\n',
      ),
      (
        'deletions of different lines on the two sides merge',
        'Alpha\nBravo\nCharlie\nDelta\n',
        'Alpha\nCharlie\nDelta\n',
        'Alpha\nBravo\nCharlie\n',
        'Alpha\nCharlie\n',
      ),
    ]) {
      test(name, () {
        expect(_merged(base, local, server), merged);
        expect(_merged(base, server, local), merged);
      });
    }

    test('a deletion of a line the other side edited returns an overlap', () {
      _expectOverlap(
        'Alpha\nBravo\nCharlie\n',
        'Alpha\nCharlie\n',
        'Alpha\nBravo theirs\nCharlie\n',
      );
      _expectOverlap(
        'Alpha\nBravo\nCharlie\n',
        'Alpha\nBravo mine\nCharlie\n',
        'Alpha\nCharlie\n',
      );
    });
  });

  group('an empty base', () {
    test('an empty base works', () {
      expect(_merged('', 'Mine\n', ''), 'Mine\n');
      expect(_merged('', '', 'Theirs\n'), 'Theirs\n');
      expect(_merged('', 'Both\n', 'Both\n'), 'Both\n');
      expect(_merged('', '', ''), '');
      _expectOverlap('', 'Mine\n', 'Theirs\n');
    });

    test(
      'an empty base with a server footer keeps the local text above it',
      () {
        expect(_merged('', 'Mine\n', _footer), 'Mine\n$_footer');
      },
    );
  });

  group('the footer comes from the server', () {
    test(
      'a footer that changed only on the server keeps the server footer',
      () {
        expect(
          _merged(
            'Alpha\nBravo\n$_footer',
            'Alpha mine\nBravo\n$_footer',
            'Alpha\nBravo\n$_footerMore',
          ),
          'Alpha mine\nBravo\n$_footerMore',
        );
      },
    );

    test(
      'a server footer change beside disjoint person changes is not an overlap',
      () {
        expect(
          _merged(
            'Alpha\nBravo\nCharlie\n$_footer',
            'Alpha mine\nBravo\nCharlie\n$_footer',
            'Alpha\nBravo\nCharlie theirs\n$_footerMore',
          ),
          'Alpha mine\nBravo\nCharlie theirs\n$_footerMore',
        );
      },
    );

    test(
      'the footer comes from the server even when the local footer differs',
      () {
        expect(
          _merged(
            'Alpha\nBravo\n$_footer',
            'Alpha\nBravo mine\n$_footerMore',
            'Alpha\nBravo\n$_footer',
          ),
          'Alpha\nBravo mine\n$_footer',
        );
      },
    );

    test('a footer the server added is kept below the merged person text', () {
      expect(
        _merged(
          'Alpha\nBravo\n',
          'Alpha mine\nBravo\n',
          'Alpha\nBravo\n$_footer',
        ),
        'Alpha mine\nBravo\n$_footer',
      );
    });

    test('a footer the server removed is left out', () {
      expect(
        _merged(
          'Alpha\nBravo\n$_footer',
          'Alpha mine\nBravo\n$_footer',
          'Alpha\nBravo\n',
        ),
        'Alpha mine\nBravo\n',
      );
    });

    test(
      'a topics marker inside fenced code is person text and merges as a line',
      () {
        const fenced = '```\n<!-- memex:topics -->\n```\n';
        expect(
          _merged(
            'Alpha\n$fenced${'Bravo\n'}$_footer',
            'Alpha mine\n$fenced${'Bravo\n'}$_footer',
            'Alpha\n$fenced${'Bravo theirs\n'}$_footerMore',
          ),
          'Alpha mine\n$fenced${'Bravo theirs\n'}$_footerMore',
        );
      },
    );
  });
}
