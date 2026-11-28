// WI #38 (Spec #31 req 17, D15; architecture risk "`· update ready` may
// overflow the sidebar brand row"): at the sidebar's width (fixed 268) and
// the app's text scale (1.0), the brand row fits `v<current> · update ready`
// without overflowing.
//
// The fallback test font draws every glyph a full em wide, so at text scale
// 1.0 other sidebar rows overflow under it. This file therefore registers the
// bundled Inter Tight and JetBrains Mono files (assets/google_fonts/) under
// the families OmType falls back to, so the row is measured with the fonts
// the app ships. holdFontFetches() still keeps google_fonts itself from
// loading or fetching anything.
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/app_version.dart';
import 'package:open_memex_app/src/updater/update_controller.dart';
import 'package:open_memex_app/src/updater/update_seams.dart';
import 'package:open_memex_app/src/updater/update_state.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';

import '../support/font_fetch_hold.dart';
import '../support/updater_fakes.dart';
import '../support/wi362_modal.dart';

/// google_fonts' file-name weight words, by weight.
const _wi38Weights = {
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
/// google_fonts gives its TextStyles (`<family>_regular`, `<family>_500`,
/// ...), so OmType text lays out in the shipped font.
Future<void> _wi38LoadFamily(String family) async {
  for (final MapEntry(key: weight, value: word) in _wi38Weights.entries) {
    final file = File('assets/google_fonts/$family-$word.ttf');
    if (!file.existsSync()) continue;
    final name = weight == 400 ? '${family}_regular' : '${family}_$weight';
    final loader = FontLoader(name)
      ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    await loader.load();
  }
}

/// The Row holding the Text `open memex` inside the sidebar.
Finder _wi38BrandRow() => find
    .ancestor(
      of: find.descendant(
        of: find.byType(Sidebar),
        matching: find.text('open memex'),
      ),
      matching: find.byType(Row),
    )
    .first;

void main() {
  holdFontFetches();

  setUpAll(() async {
    await _wi38LoadFamily('JetBrainsMono');
    await _wi38LoadFamily('InterTight');
  });

  testWidgets(
    'the sidebar brand row fits the update ready label at the sidebar width',
    (tester) async {
      final controller = FakeUpdateController(
        UpdateReady(
          testAppcastItem(shortVersionString: ['1', '4', '0'].join('.')),
          dmgPath: '/updater-test/wi38-fit.dmg',
        ),
      );
      await wi362PumpLocal(
        tester,
        extraOverrides: [
          appVersionProvider.overrideWithValue(['1', '2', '3'].join('.')),
          updatesEnabledProvider.overrideWithValue(true),
          updateControllerProvider.overrideWith(() => controller),
        ],
      );
      // The harness draws at half text scale; the app runs at 1.0.
      tester.platformDispatcher.textScaleFactorTestValue = 1.0;
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(tester.takeException(), isNull, reason: 'nothing overflows');
      final label = find.byKey(const Key('sidebar-version-label'));
      expect(label, findsOneWidget);
      expect(tester.widget<Text>(label).data, 'v1.2.3 · update ready');

      final sidebar = tester.getRect(find.byType(Sidebar));
      expect(sidebar.width, 268, reason: 'the sidebar is fixed at 268');
      final row = _wi38BrandRow();
      expect(
        tester.getTopRight(label).dx,
        lessThanOrEqualTo(tester.getTopRight(row).dx),
        reason: 'the label stays inside the brand row',
      );
      expect(tester.getTopRight(row).dx, lessThanOrEqualTo(sidebar.right));

      final flex = tester.renderObject<RenderFlex>(row);
      var used = 0.0;
      var child = flex.firstChild;
      while (child != null) {
        used += child.size.width;
        child = (child.parentData! as FlexParentData).nextSibling;
      }
      expect(
        used,
        lessThanOrEqualTo(flex.size.width),
        reason: 'the brand row does not overflow',
      );
    },
  );

  testWidgets(
    'the sidebar brand row fits the plain version label at the sidebar width',
    (tester) async {
      await wi362PumpLocal(
        tester,
        extraOverrides: [
          appVersionProvider.overrideWithValue(['1', '2', '3'].join('.')),
          updateControllerProvider.overrideWith(FakeUpdateController.new),
        ],
      );
      tester.platformDispatcher.textScaleFactorTestValue = 1.0;
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(tester.takeException(), isNull);
      final label = find.byKey(const Key('sidebar-version-label'));
      expect(tester.widget<Text>(label).data, 'v1.2.3');
      expect(
        tester.getTopRight(label).dx,
        tester.getTopRight(_wi38BrandRow()).dx,
        reason: 'pushed to the row end by the Spacer',
      );
    },
  );

  testWidgets(
    'the sidebar brand row narrows its gap and end padding only while ready',
    (tester) async {
      final controller = FakeUpdateController();
      await wi362PumpLocal(
        tester,
        extraOverrides: [
          appVersionProvider.overrideWithValue(['1', '2', '3'].join('.')),
          updatesEnabledProvider.overrideWithValue(true),
          updateControllerProvider.overrideWith(() => controller),
        ],
      );
      tester.platformDispatcher.textScaleFactorTestValue = 1.0;
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      final label = find.byKey(const Key('sidebar-version-label'));
      final title = find.descendant(
        of: find.byType(Sidebar),
        matching: find.text('open memex'),
      );
      bool clipped() => tester
          .renderObject<RenderParagraph>(
            find.descendant(of: label, matching: find.byType(RichText)),
          )
          .didExceedMaxLines;

      final idleTitleLeft = tester.getTopLeft(title).dx;
      final idleLabelRight = tester.getTopRight(label).dx;
      expect(clipped(), isFalse, reason: 'the plain label is not clipped');

      controller.emit(
        UpdateReady(
          testAppcastItem(shortVersionString: ['1', '4', '0'].join('.')),
          dmgPath: '/updater-test/wi38-gap.dmg',
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
      expect(tester.widget<Text>(label).data, 'v1.2.3 · update ready');
      expect(
        clipped(),
        isFalse,
        reason: 'the whole update ready label fits, no ellipsis',
      );
      expect(
        tester.getTopLeft(title).dx,
        idleTitleLeft - 3,
        reason: 'the logo-to-title gap goes from 9 to 6 while ready',
      );
      expect(
        tester.getTopRight(label).dx,
        idleLabelRight + 5,
        reason: 'the end padding goes from 14 to 9 while ready',
      );

      controller.emit(const UpdateIdle());
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.getTopLeft(title).dx, idleTitleLeft);
      expect(tester.getTopRight(label).dx, idleLabelRight);
    },
  );

  testWidgets(
    'at a larger text scale the update ready label ellipsizes inside the row',
    (tester) async {
      // Other sidebar rows overflow at this scale under the test fonts (see
      // the file header); only the brand row is asserted here.
      final previous = FlutterError.onError;
      FlutterError.onError = (_) {};
      addTearDown(() => FlutterError.onError = previous);
      await wi362PumpLocal(
        tester,
        extraOverrides: [
          appVersionProvider.overrideWithValue(['1', '2', '3'].join('.')),
          updatesEnabledProvider.overrideWithValue(true),
          updateControllerProvider.overrideWith(
            () => FakeUpdateController(
              UpdateReady(
                testAppcastItem(shortVersionString: ['1', '4', '0'].join('.')),
                dmgPath: '/updater-test/wi38-scale.dmg',
              ),
            ),
          ),
        ],
      );
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      final label = find.byKey(const Key('sidebar-version-label'));
      final text = tester.widget<Text>(label);
      expect(text.maxLines, 1);
      expect(text.softWrap, isFalse);
      expect(text.overflow, TextOverflow.ellipsis);
      final flex = tester.renderObject<RenderFlex>(_wi38BrandRow());
      var used = 0.0;
      var child = flex.firstChild;
      while (child != null) {
        used += child.size.width;
        child = (child.parentData! as FlexParentData).nextSibling;
      }
      expect(used, lessThanOrEqualTo(flex.size.width), reason: 'no overflow');
    },
  );
}
