// WI #244 (A0, Spec #234 R23, R24, TD7): fuzzyScore is the wikilink
// autocomplete's scorer moved out unchanged to editor/fuzzy_score.dart.
// Every expected integer below is the old private scorer's result, worked
// out by hand from its formula, so a pure move keeps them all.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/fuzzy_score.dart';

void main() {
  test('fuzzyScore of an empty needle is 1 for any hay', () {
    expect(fuzzyScore('pricing', ''), 1);
    expect(fuzzyScore('', ''), 1);
  });

  test('fuzzyScore of a prefix is 1000 minus the hay length', () {
    expect(fuzzyScore('pricing', 'pri'), 993);
    expect(fuzzyScore('pricing', 'pricing'), 993);
  });

  test('fuzzyScore of a substring is 500 minus the hay length', () {
    expect(fuzzyScore('the pricing', 'pric'), 489);
    expect(fuzzyScore('pricing', 'cin'), 493);
  });

  test('fuzzyScore finds in-order letters such as prc in pricing', () {
    // p (+2), r (+4), i breaks the run, c (+2): 100 + 8 - 7.
    expect(fuzzyScore('pricing', 'prc'), 101);
  });

  test('fuzzyScore rewards consecutive letters over scattered ones', () {
    // Same hay length 5: a_b_c scores a +2, b +2, c +2; ab_c_ scores a +2,
    // b +4, c +2.
    expect(fuzzyScore('a_b_c', 'abc'), 101);
    expect(fuzzyScore('ab_c_', 'abc'), 103);
  });

  test('fuzzyScore ranks a shorter hay above a longer one', () {
    expect(fuzzyScore('pricing', 'pri'), 993);
    expect(fuzzyScore('pricing plan', 'pri'), 988);
    expect(fuzzyScore('the pricing', 'pric'), 489);
    expect(fuzzyScore('the pricing page', 'pric'), 484);
    expect(fuzzyScore('pricing', 'prc'), 101);
    expect(fuzzyScore('pricing plan', 'prc'), 96);
  });

  test('fuzzyScore ranks prefix above substring above in-order', () {
    expect(fuzzyScore('pricing', 'pri'), 993);
    expect(fuzzyScore('the pricing', 'pri'), 489);
    expect(fuzzyScore('pa radio inc', 'pri'), 94);
  });

  test('fuzzyScore returns 0 when the letters are not all found in order', () {
    // A positive score for the matching needle proves the hay is scorable.
    expect(fuzzyScore('pricing', 'prc'), greaterThan(0));
    expect(fuzzyScore('pricing', 'xyz'), 0);
    // Letters exist but not in order.
    expect(fuzzyScore('pricing', 'cpr'), 0);
    // Needle longer than hay.
    expect(fuzzyScore('ab', 'abc'), 0);
    // One letter short of a match.
    expect(fuzzyScore('pricing', 'prz'), 0);
  });

  test('fuzzyScore does not lowercase, the caller does', () {
    expect(fuzzyScore('pricing', 'pri'), 993);
    expect(fuzzyScore('Pricing', 'pri'), 0);
    expect(fuzzyScore('pricing', 'PRI'), 0);
  });

  test('fuzzyScore handles runtime built strings the same as literals', () {
    final hay = ['pri', 'cing'].join();
    final needle = String.fromCharCodes([0x70, 0x72, 0x69]);
    expect(fuzzyScore(hay, needle), 993);
  });

  test('wikilink autocomplete has no private scorer left', () {
    final source = File(
      'lib/src/widgets/wikilink_autocomplete.dart',
    ).readAsStringSync();
    expect(source.contains('_fuzzyScore'), isFalse);
    expect(source.contains('fuzzyScore('), isTrue);
    expect(source.contains('editor/fuzzy_score.dart'), isTrue);
  });
}
