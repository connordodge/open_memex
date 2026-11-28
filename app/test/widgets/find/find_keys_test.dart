// WI #80 (Spec #61 F1, TD8): the frozen Find in note Keys.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/widgets/find/find_keys.dart';

void main() {
  test('find_keys.dart Keys have exactly the frozen values', () {
    expect(findBarKey, const ValueKey<String>('find-bar'));
    expect(findBarFieldKey, const ValueKey<String>('find-bar-field'));
    expect(findBarCounterKey, const ValueKey<String>('find-bar-counter'));
    expect(findBarPreviousKey, const ValueKey<String>('find-bar-previous'));
    expect(findBarNextKey, const ValueKey<String>('find-bar-next'));
    expect(findBarCloseKey, const ValueKey<String>('find-bar-close'));
    expect(
      findHighlightsKey(3, 7),
      const ValueKey<String>('find-highlights-3-7'),
    );
    expect(
      findCardHighlightsKey(2, 0),
      const ValueKey<String>('find-highlights-card-2-0'),
    );
    expect(
      findGridHighlightsKey(4, 1, 2),
      const ValueKey<String>('find-highlights-grid-4-1-2'),
    );
    expect(
      findSourceHighlightsKey,
      const ValueKey<String>('find-highlights-source'),
    );
  });

  test('find_keys.dart overlay Keys take every index from their arguments', () {
    // Run-time indices, so no const folding hides a swapped argument.
    final n = DateTime(2026).year - 2016; // 10
    expect(findHighlightsKey(n, n + 1), Key('find-highlights-10-11'));
    expect(findCardHighlightsKey(n + 2, n), Key('find-highlights-card-12-10'));
    expect(
      findGridHighlightsKey(n, n + 3, n + 5),
      Key('find-highlights-grid-10-13-15'),
    );
  });

  test('find_keys.dart documents the box each Key sits on', () {
    final source = File(
      'lib/src/widgets/find/find_keys.dart',
    ).readAsStringSync();
    for (final box in ['floating box', 'TextField', 'overlay layer']) {
      expect(source, contains(box));
    }
  });
}
