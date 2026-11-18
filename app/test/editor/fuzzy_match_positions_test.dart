// WI #76 (56-A2, Spec #59 req 15): fuzzyMatchPositions returns the character
// indices fuzzyScore matched, taking fuzzyScore's own branch (prefix, then
// substring at its first occurrence, then the greedy left-to-right
// subsequence). An empty needle has nothing to draw: [] although fuzzyScore
// scores it 1. fuzzyScore itself is unchanged (fuzzy_score_test.dart).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/fuzzy_score.dart';

/// Every literal `fuzzyScore('<hay>', '<needle>')` pair in
/// fuzzy_score_test.dart, read from its source so a case added there is
/// covered here too.
List<(String, String)> _scoreTestCases() {
  final source = File('test/editor/fuzzy_score_test.dart').readAsStringSync();
  final call = RegExp(r"fuzzyScore\(\s*'([^']*)',\s*'([^']*)',?\s*\)");
  return [for (final m in call.allMatches(source)) (m.group(1)!, m.group(2)!)];
}

void main() {
  test('fuzzyMatchPositions of pricing model and pri is 0 1 2', () {
    expect(fuzzyMatchPositions('pricing model', 'pri'), [0, 1, 2]);
  });

  test('fuzzyMatchPositions of a prefix is every needle index', () {
    expect(fuzzyMatchPositions('pricing', 'pricing'), [0, 1, 2, 3, 4, 5, 6]);
    expect(fuzzyMatchPositions('backups', 'back'), [0, 1, 2, 3]);
    // A prefix wins over a later substring: "a" also occurs at 3.
    expect(fuzzyMatchPositions('ab a', 'a'), [0]);
  });

  test('fuzzyMatchPositions of a substring is its first occurrence', () {
    expect(fuzzyMatchPositions('the pricing', 'pric'), [4, 5, 6, 7]);
    expect(fuzzyMatchPositions('pricing', 'cin'), [3, 4, 5]);
    expect(fuzzyMatchPositions('feedback log', 'back'), [4, 5, 6, 7]);
    // "ba" occurs at 1 and 3: the first one, as indexOf finds it.
    expect(fuzzyMatchPositions('ababa', 'ba'), [1, 2]);
    // Substring beats subsequence: "ab" is contiguous at 4, while a greedy
    // subsequence would take a at 0 and b at 2.
    expect(fuzzyMatchPositions('axbxab', 'ab'), [4, 5]);
  });

  test(
    'fuzzyMatchPositions of a subsequence is the greedy in-order indices',
    () {
      expect(fuzzyMatchPositions('pricing', 'prc'), [0, 1, 3]);
      expect(fuzzyMatchPositions('pa radio inc', 'pri'), [0, 3, 6]);
      expect(fuzzyMatchPositions('a_b_c', 'abc'), [0, 2, 4]);
      expect(fuzzyMatchPositions('ab_c_', 'abc'), [0, 1, 3]);
      // Greedy takes the first a (0), not the later one (1).
      expect(fuzzyMatchPositions('aaxb', 'ab'), [0, 3]);
      expect(fuzzyMatchPositions('show right panel', 'srp'), [0, 5, 11]);
    },
  );

  test('fuzzyMatchPositions of no match is empty', () {
    // A match on the same hay proves it is scorable.
    expect(fuzzyMatchPositions('pricing', 'prc'), [0, 1, 3]);
    expect(fuzzyMatchPositions('pricing', 'xyz'), isEmpty);
    expect(fuzzyMatchPositions('pricing', 'cpr'), isEmpty);
    expect(fuzzyMatchPositions('ab', 'abc'), isEmpty);
    expect(fuzzyMatchPositions('pricing', 'prz'), isEmpty);
    expect(fuzzyMatchPositions('', 'a'), isEmpty);
    // Compared as given: the caller lowercases.
    expect(fuzzyMatchPositions('Pricing', 'pri'), isEmpty);
  });

  test('fuzzyMatchPositions of an empty needle is empty', () {
    expect(fuzzyMatchPositions('pricing', ''), isEmpty);
    expect(fuzzyMatchPositions('', ''), isEmpty);
    // One letter is a match.
    expect(fuzzyMatchPositions('pricing', 'p'), [0]);
  });

  test('fuzzyMatchPositions handles runtime built strings', () {
    final hay = ['pri', 'cing', ' model'].join();
    final needle = String.fromCharCodes([0x70, 0x63]); // "pc"
    expect(fuzzyMatchPositions(hay, needle), [0, 3]);
  });

  test(
    'fuzzyMatchPositions is empty exactly when fuzzyScore is 0 for every fuzzy_score_test case',
    () {
      final cases = _scoreTestCases();
      // The scan really reads the score tests: they have well over 20 calls.
      expect(cases.length, greaterThan(20));
      expect(cases, contains(('pricing', 'prc')));
      for (final (hay, needle) in cases) {
        final positions = fuzzyMatchPositions(hay, needle);
        final score = fuzzyScore(hay, needle);
        if (needle.isEmpty) {
          // Nothing to draw for an empty needle, though it scores 1.
          expect(positions, isEmpty, reason: '($hay, $needle)');
          continue;
        }
        expect(
          positions.isEmpty,
          score == 0,
          reason: '($hay, $needle): score $score, positions $positions',
        );
        if (positions.isNotEmpty) {
          expect(positions.length, needle.length, reason: '($hay, $needle)');
          for (var k = 0; k < positions.length; k++) {
            expect(hay[positions[k]], needle[k], reason: '($hay, $needle) #$k');
            if (k > 0) {
              expect(
                positions[k],
                greaterThan(positions[k - 1]),
                reason: '($hay, $needle) ascending',
              );
            }
          }
        }
      }
    },
  );
}
