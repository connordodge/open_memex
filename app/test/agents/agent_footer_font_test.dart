// WI #456 (390-A5) review round 1: the disconnected hint in the real
// bundled JetBrains Mono at the sidebar's real width.
//
// agent_footer_test.dart runs on the flutter_test fallback font (every glyph
// 1em wide), which hides how the two hint lines wrap in the real font, so
// this file deliberately does not call holdFontFetches(): it lays the footer
// out in the bundled font, 267 px wide (the sidebar's 268 px less its 1 px
// border), and checks that both hint lines stay on screen at text scale 1.0
// and 1.3.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/font_setup.dart';
import 'package:open_memex_app/src/vault_access/agents_access.dart';
import 'package:open_memex_app/src/widgets/agents/agent_footer.dart';

import '../support/agents_fakes.dart';
import '../support/fake_clock.dart';

const _hint1 = 'wire memex serve into Claude Desktop';
const _hint2 = 'to see live activity here';

/// Waits for every google_fonts load a testWidgets build started: their I/O
/// completes in real time but their continuations run in the fake-async
/// zone, so alternate a short real-time yield with a pump.
Future<void> _wi456SettleFonts(WidgetTester tester) async {
  var settled = false;
  Object? error;
  GoogleFonts.pendingFonts().then<void>(
    (_) => settled = true,
    onError: (Object e) {
      error = e;
      settled = true;
    },
  );
  for (var i = 0; i < 500 && !settled; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  expect(settled, isTrue, reason: 'font loads did not settle');
  expect(error, isNull, reason: 'a font failed to load');
}

Future<void> _pumpReal(
  WidgetTester tester, {
  required double scale,
  required AgentActivity activity,
  double? height,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  configureFonts();
  Future<void> pumpTree(Key key) => tester.pumpWidget(
    ProviderScope(
      key: key,
      overrides: agentsOverrides(
        access: FakeAgentsAccess(script: [activity]),
        clock: FakeClock(),
      ),
      child: MaterialApp(
        theme: buildOmTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          backgroundColor: OmColors.surface1,
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 267,
              height: height,
              child: const AgentFooter(),
            ),
          ),
        ),
      ),
    ),
  );
  // The first build lays out in the fallback font and starts the font
  // loads: let them finish, drop what the fallback layout reported (the
  // header is wider than 267 px in it), then lay a fresh tree out in the
  // bundled font.
  await pumpTree(const ValueKey('first'));
  await _wi456SettleFonts(tester);
  tester.takeException();
  await pumpTree(const ValueKey('second'));
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

RenderParagraph _paragraph(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(find.text(text));

void main() {
  const empty = AgentActivity(agents: [], recent: [], available: true);

  testWidgets(
    'in the bundled mono font at text scale 1.0 both hint lines fit on one line each',
    (tester) async {
      await _pumpReal(tester, scale: 1.0, activity: empty);

      expect(find.text(_hint1), findsOneWidget);
      expect(find.text(_hint2), findsOneWidget);
      final p1 = _paragraph(tester, _hint1);
      final p2 = _paragraph(tester, _hint2);
      // The real font is loaded: 36 mono glyphs of 0.6 em at 10.5 px.
      expect(p1.getMaxIntrinsicWidth(double.infinity), closeTo(226.8, 2));
      expect(p1.didExceedMaxLines, isFalse);
      expect(p2.didExceedMaxLines, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'in the bundled mono font at text scale 1.3 the disconnected hint still shows both lines and the second is not cut off',
    (tester) async {
      await _pumpReal(tester, scale: 1.3, activity: empty);

      expect(find.text('no agents connected'), findsOneWidget);
      expect(find.text(_hint1), findsOneWidget);
      expect(
        find.text(_hint2),
        findsOneWidget,
        reason: 'the second hint line is rendered, not pushed out',
      );
      final p1 = _paragraph(tester, _hint1);
      final p2 = _paragraph(tester, _hint2);
      expect(p1.getMaxIntrinsicWidth(double.infinity), closeTo(226.8 * 1.3, 3));
      // Line 1 (294.8 px) is wider than the 243 px content width, so it wraps
      // to two lines instead of losing "Desktop"; line 2 stays one line.
      const line = 10.5 * 1.3 * 1.6;
      expect(p1.size.height, closeTo(2 * line, 0.5));
      expect(
        p1.didExceedMaxLines,
        isFalse,
        reason: 'wire memex serve into Claude Desktop is not ellipsized',
      );
      expect(p2.size.height, closeTo(line, 0.5));
      expect(
        tester.getTopLeft(find.text(_hint2)).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(find.text(_hint1)).dy - 0.01),
      );
      expect(
        p2.didExceedMaxLines,
        isFalse,
        reason: 'to see live activity here is not ellipsized',
      );
      expect(
        tester.getSize(find.byKey(const Key('agent-footer'))).height,
        lessThanOrEqualTo(AgentFooter.maxFooterHeight),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'at text scale 1.3 when the wrapped three line hint does not fit the whole hint drops and nothing overflows',
    (tester) async {
      await _pumpReal(tester, scale: 1.3, activity: empty);
      final full = tester.getSize(find.byKey(const Key('agent-footer'))).height;
      expect(find.text(_hint1), findsOneWidget);

      // Room for the hint as two lines (the old budget) but not for the
      // three lines it measures at this width: the hint goes whole.
      const line = 10.5 * 1.3 * 1.6;
      await _pumpReal(
        tester,
        scale: 1.3,
        activity: empty,
        height: full - line / 2,
      );

      expect(find.text('no agents connected'), findsOneWidget);
      expect(find.text(_hint1), findsNothing);
      expect(find.text(_hint2), findsNothing);
      expect(
        tester.getSize(find.byKey(const Key('agent-footer'))).height,
        lessThanOrEqualTo(full - line / 2 + 0.01),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'at text scale 1.0 a hint that fits on one line each still needs only two lines of room',
    (tester) async {
      await _pumpReal(tester, scale: 1.0, activity: empty);
      final full = tester.getSize(find.byKey(const Key('agent-footer'))).height;

      // Exactly the full height: both single-line hints stay.
      await _pumpReal(tester, scale: 1.0, activity: empty, height: full);
      expect(find.text(_hint1), findsOneWidget);
      expect(find.text(_hint2), findsOneWidget);

      // One line less: the hint drops whole.
      const line = 10.5 * 1.6;
      await _pumpReal(tester, scale: 1.0, activity: empty, height: full - line);
      expect(find.text(_hint1), findsNothing);
      expect(find.text(_hint2), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
