// WI #13 (Spec #7 A1, D16): this file deliberately does NOT call
// `holdFontFetches()`. `pumpAgentEdits` must then fail fast instead of laying
// the widget out in the bundled fonts (flutter_test always installs some
// `HttpOverrides`, so only `fontFetchesHeld` tells the two apart).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/agent_edits_fakes.dart';
import '../support/font_fetch_hold.dart' show fontFetchesHeld;

void main() {
  testWidgets('pumpAgentEdits throws when holdFontFetches is not in place', (
    tester,
  ) async {
    expect(fontFetchesHeld, isFalse);
    await expectLater(
      pumpAgentEdits(tester, const SizedBox()),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('holdFontFetches()'),
        ),
      ),
    );
  });
}
