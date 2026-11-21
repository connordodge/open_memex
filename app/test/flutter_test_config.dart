// Runs around every test file (flutter_test picks this file up by name).
//
// Flutter 3.50 checks for leftover frame callbacks after tear-down
// (flutter/flutter#193476) instead of right after the test body. A file that
// does not call holdFontFetches() lets google_fonts load the bundled fonts on
// the first build; that real-time load used to finish after the check, but
// now finishes before it, and the engine's fontsChange message makes every
// mounted RenderParagraph schedule a frame, which the check reports as "An
// animation is still running even after the widget tree was disposed".
//
// So before a file's first test, with no widget tree mounted, load every
// bundled variant once and let the fontsChange message land. Tests then see
// the same real fonts from their first build that later tests in the file
// already saw. Files that call holdFontFetches() keep the fallback font.
import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'support/font_fetch_hold.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  var preloaded = false;
  setUp(() async {
    if (preloaded || fontFetchesHeld) return;
    preloaded = true;
    await _preloadBundledFonts();
  });
  await testMain();
}

/// Requests exactly the variants bundled under `assets/google_fonts/` (any
/// other variant would make google_fonts try HTTP), waits for the loads, then
/// yields so the engine's fontsChange message is handled while nothing is
/// mounted.
Future<void> _preloadBundledFonts() async {
  for (final weight in FontWeight.values) {
    GoogleFonts.interTight(fontWeight: weight);
    if (weight != FontWeight.w900) {
      GoogleFonts.jetBrainsMono(fontWeight: weight);
    }
    if (weight != FontWeight.w100 && weight != FontWeight.w900) {
      for (final style in FontStyle.values) {
        GoogleFonts.newsreader(fontWeight: weight, fontStyle: style);
      }
    }
  }
  await GoogleFonts.pendingFonts();
  await Future<void>.delayed(const Duration(milliseconds: 20));
}
