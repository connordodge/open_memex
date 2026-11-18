// WI #64 (53-T, Spec #57 AC9): the heading caret after a trailing space,
// measured in the shipped JetBrains Mono instead of the test font. The test
// font draws every glyph a full em wide at any weight; the real face has its
// own advances and bold metrics, which is what Spec TD1 says the terminator
// must follow. The bundled files (assets/google_fonts/) are registered under
// the families OmType falls back to, as version_label_fit_test.dart does;
// holdFontFetches() still keeps google_fonts from loading or fetching.
//
// The scenarios and the caret oracle are the typing test's own; what stays
// manual is only the live macOS engine.
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/font_fetch_hold.dart';
import 'heading_caret_typing_test.dart' show wi64TypeAc9Cases;

const Map<int, String> _wi64FontWeights = {
  100: 'Thin',
  200: 'ExtraLight',
  300: 'Light',
  400: 'Regular',
  500: 'Medium',
  600: 'SemiBold',
  700: 'Bold',
  800: 'ExtraBold',
  900: 'Black',
};

/// Registers each bundled upright weight of [family] under the name
/// google_fonts gives its TextStyles (`<family>_regular`, `<family>_500`...).
Future<void> _wi64LoadFamily(String family) async {
  for (final MapEntry(key: weight, value: word) in _wi64FontWeights.entries) {
    final file = File('assets/google_fonts/$family-$word.ttf');
    if (!file.existsSync()) continue;
    final name = weight == 400 ? '${family}_regular' : '${family}_$weight';
    final loader = FontLoader(name)
      ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    await loader.load();
  }
}

void main() {
  holdFontFetches();

  setUpAll(() async {
    await _wi64LoadFamily('JetBrainsMono');
    await _wi64LoadFamily('InterTight');
  });

  testWidgets(
    'in the bundled JetBrains Mono typing a heading above another line draws the caret after every typed character and further right after each space',
    (tester) async {
      // The font really loaded: a mono `#` is 0.6 em wide, not the test
      // font's full em.
      final painter = TextPainter(
        text: const TextSpan(
          text: '#',
          style: TextStyle(fontFamily: 'JetBrainsMono_regular', fontSize: 100),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final width = painter.width;
      painter.dispose();
      expect(width, lessThan(80), reason: 'JetBrains Mono is loaded');
      await wi64TypeAc9Cases(tester);
    },
  );
}
