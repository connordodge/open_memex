// WI #82 (Spec #61 F2; design pack packs/82.md): goldens of the Find bar at
// design boards B4.1 (body 532, box 372, full counter `2 of 12`) and B4.3
// (body 264, box 240, short counter `2/12`), field focused, over the editor
// body's surface1. Each golden is the body's top band (the box, its 10 px
// top inset and its shadow), in the fonts and Lucide icons the app ships.
//
// The implementer writes the golden files with
// `flutter test --update-goldens test/widgets/find/find_bar_golden_test.dart`
// and reports each golden's mismatch against its board crop
// (design/55-find-in-note/packs/82/b4.1.png, b4.3.png) in the PR body.
// The comparator allows a 0.5% pixel difference for text antialiasing
// across machines.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/find/find_bar.dart';

import '../../support/find_pump.dart';
import '../../support/font_fetch_hold.dart';
import 'find_bar_harness.dart';

const Key _wi82GoldenKey = ValueKey<String>('wi82-golden');

/// The band of the body the goldens capture: 10 px inset, 38 px box and
/// room below it for the menu shadow.
const double _wi82BandHeight = 80;

/// A local golden comparator that passes up to [tolerance] (a fraction of
/// pixels) of difference.
class _Wi82TolerantComparator extends LocalFileComparator {
  _Wi82TolerantComparator(super.testFile, this.tolerance);

  final double tolerance;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= tolerance) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}

Future<void> _wi82PumpBand(
  WidgetTester tester, {
  required double bodyWidth,
}) async {
  await pumpFind(
    tester,
    bodyWidth: bodyWidth,
    bodyHeight: _wi82BandHeight,
    sources: wi82Twelve,
    query: wi82Word,
    current: 1,
    child: RepaintBoundary(
      key: _wi82GoldenKey,
      child: ColoredBox(
        color: OmColors.surface1,
        child: Stack(
          children: [
            FindBarOverlay(
              bodyWidth: bodyWidth,
              onStep: (_) {},
              onClose: (_) {},
            ),
          ],
        ),
      ),
    ),
  );
  expect(wi82Box, findsOneWidget);
  await wi82FocusField(tester);
  // The caret at the end of the query, as the boards draw it.
  wi82Editable(tester).controller.selection = const TextSelection.collapsed(
    offset: wi82Word.length,
  );
  await wi82Settle(tester);
}

void main() {
  holdFontFetches();
  wi82LoadFonts(icons: true);

  GoldenFileComparator? previous;
  setUpAll(() {
    previous = goldenFileComparator;
    final local = goldenFileComparator as LocalFileComparator;
    goldenFileComparator = _Wi82TolerantComparator(
      Uri.parse('${local.basedir}find_bar_golden_test.dart'),
      0.005,
    );
  });
  tearDownAll(() => goldenFileComparator = previous!);

  testWidgets(
    'the find bar at body 532 with the full counter 2 of 12 matches its golden for board B4.1',
    (tester) async {
      await _wi82PumpBand(tester, bodyWidth: 532);
      expect(wi82CounterText(tester), '2 of 12');
      await expectLater(
        find.byKey(_wi82GoldenKey),
        matchesGoldenFile('goldens/find_bar_b4_1.png'),
      );
    },
  );

  testWidgets(
    'the find bar at body 264 with the short counter 2/12 matches its golden for board B4.3',
    (tester) async {
      await _wi82PumpBand(tester, bodyWidth: 264);
      expect(wi82CounterText(tester), '2/12');
      await expectLater(
        find.byKey(_wi82GoldenKey),
        matchesGoldenFile('goldens/find_bar_b4_3.png'),
      );
    },
  );
}
