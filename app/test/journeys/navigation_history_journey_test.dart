// WI #271 (N8, Spec #232): the navigation journey, run through the real
// workspace with real mouse presses. One tab follows a footer topic chip, a
// wikilink and a graph node, then steps Back and Forward with each note back at
// the scroll position it was left at (R1, R17, R26); a Cmd click opens a second
// tab and leaves the first tab's history alone (R2); a canvas zooms into a
// note and out again with Back and Forward, with the right panel following the
// zoomed note (R29, R31, TD5); and deleting a note shown in two tabs closes both
// (R33).
//
// The app runs on a FakeVaultDb with a FakeClock and a fake `memex` CLI; the
// editor clicks run under macOS (`macOnly`), where Cmd is the real meta key.
// Never pumpAndSettle the workspace (OmDot pulses forever): pumpFrames only.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/canvas_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../robots/navigation_robot.dart';
import '../support/app_harness.dart';
import '../support/canvas_seeds.dart';
import '../support/daily_seed.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/graph_seeds.dart';
import '../support/mac_editing.dart';
import '../support/note_cli_fakes.dart';
import '../support/today_cli_fakes.dart';

// The harness clock's date, so the daily note is the launch tab.
const _dayId = 'daily-2026-10-03';
const _alphaId = 'n271-alpha';
const _betaId = 'n271-beta';
const _gammaId = 'n271-gamma';
const _day = NoteTab(_dayId);
const _alpha = NoteTab(_alphaId);
const _beta = NoteTab(_betaId);
const _gamma = NoteTab(_gammaId);
final _betaGraph = GraphTab(const GraphScope.topic(_betaId));

const _lines = 300;

/// [lines] numbered lines, line [linkAt] replaced by [link].
String _body(String tag, {int linkAt = 150, String? link}) => [
  for (var i = 0; i < _lines; i++)
    i == linkAt && link != null ? link : '$tag $i',
].join('\n');

/// The vault: today's daily note with a long body and a footer chip to Alpha;
/// Alpha, a long topic note with a wikilink to Beta in the middle; Beta, a long
/// topic note; Gamma. Alpha links to Beta and Beta to Gamma, so Beta's Graph
/// view holds both.
FakeVaultDb _vault() {
  final db = FakeVaultDb.v5();
  db.seedNote(
    id: _dayId,
    title: '2026-10-03',
    role: 'daily',
    version: 2,
    content: assembleDailyBody(_body('Day line'), const ['Alpha']),
  );
  db.seedNote(
    id: _alphaId,
    title: 'Alpha',
    role: 'topic',
    content: '${_body('Alpha line', link: 'Go and read [[Beta]] next')}\n',
  );
  db.seedNote(
    id: _betaId,
    title: 'Beta',
    role: 'topic',
    content: '${_body('Beta line')}\n',
  );
  db.seedNote(id: _gammaId, title: 'Gamma', role: 'topic', content: 'Gamma\n');
  db.seedFooterChip(_dayId, _alphaId, origin: 'person');
  db.seedLink(_alphaId, _betaId, id: 'l-alpha-beta', linkText: 'Beta');
  db.seedLink(_betaId, _gammaId, id: 'l-beta-gamma', linkText: 'Gamma');
  return db;
}

FakeMemexCli _cli(FakeVaultDb db) => FakeMemexCli()
  ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
  ..onUpdateWrites(db)
  ..onRm(db);

Future<NavigationRobot> _launch(
  WidgetTester tester, {
  FakeVaultDb? db,
  bool onDay = true,
  List<Override> overrides = const [],
}) async {
  final vault = db ?? _vault();
  final h = await pumpWorkspace(
    tester,
    db: vault,
    cli: _cli(vault),
    overrides: overrides,
  );
  final r = NavigationRobot(tester, h);
  if (onDay) r.expectOnNote(_dayId);
  await pumpFrames(tester);
  return r;
}

void main() {
  group('one tab follows a chip, a wikilink and a graph node', () {
    testWidgets(
      'the journey follows a wikilink a footer topic chip and a graph node in one tab then steps Back and Forward with the scroll position restored',
      (tester) async {
        final r = await _launch(tester);
        expect(r.tabs.tabs, [_day], reason: 'one tab');

        // The footer topic chip, at the foot of a long daily note.
        await r.tester.ensureVisible(r.footerChip(_alphaId));
        await tester.pump();
        final dayAt = r.scrolled;
        expect(
          dayAt,
          greaterThan(0),
          reason: 'the day was scrolled to its foot',
        );
        await r.clickFooterChip(_alphaId);
        r.expectOnNote(_alphaId, title: 'Alpha');
        await r.expectAtTop();

        // A wikilink in the middle of Alpha.
        await r.scrollToText(0, '[[Beta]]');
        final alphaAt = r.scrolled;
        expect(alphaAt, greaterThan(0));
        await r.clickLink(0, 'Beta');
        r.expectOnNote(_betaId, title: 'Beta');
        await r.expectAtTop();

        // A graph node: the Graph view of Beta, then its Gamma node.
        await r.scrollTo(300);
        await r.openGraphFromNoteMenu();
        expect(r.active, _betaGraph);
        expect(r.graphView, findsOneWidget);
        await r.clickGraphNode(_gammaId);
        r.expectOnNote(_gammaId, title: 'Gamma');

        expect(r.tabs.tabs, [_gamma], reason: 'still one tab');
        expect(r.tabs.canGoBack, isTrue);
        expect(r.tabs.canGoForward, isFalse);

        // Back, through every entry, each note where it was left.
        await r.tapBack();
        expect(r.active, _betaGraph);
        expect(r.graphView, findsOneWidget);
        await r.tapBack();
        r.expectOnNote(_betaId);
        await r.expectScrolledTo(300);
        await r.tapBack();
        r.expectOnNote(_alphaId);
        await r.expectScrolledTo(alphaAt);
        await r.tapBack();
        r.expectOnNote(_dayId);
        await r.expectScrolledTo(dayAt);
        expect(r.tabs.canGoBack, isFalse, reason: 'the start of the history');
        expect(r.tabs.tabs, [_day], reason: 'Back adds no tab');

        // Forward, through every entry, the same way.
        await r.tapForward();
        r.expectOnNote(_alphaId);
        await r.expectScrolledTo(alphaAt);
        await r.tapForward();
        r.expectOnNote(_betaId);
        await r.expectScrolledTo(300);
        await r.tapForward();
        expect(r.active, _betaGraph);
        await r.tapForward();
        r.expectOnNote(_gammaId);
        expect(r.tabs.canGoForward, isFalse, reason: 'the end of the history');
        expect(r.tabs.tabs, [_gamma]);

        // The Today row and a right panel link navigate this tab as well.
        await r.click(r.todayRow);
        r.expectOnNote(_dayId);
        expect(r.tabs.tabs, [_day], reason: 'the Today row added no tab');
        await r.tapBack();
        r.expectOnNote(_gammaId);
        await r.click(r.backlink(_betaId, 'l-beta-gamma'));
        r.expectOnNote(_betaId, title: 'Beta');
        expect(r.tabs.tabs, [_beta], reason: 'the panel added no tab');
        await r.expectAtTop();
        await r.tapBack();
        r.expectOnNote(_gammaId);
      },
      variant: macOnly,
    );
  });

  group('a Cmd click opens a second tab', () {
    testWidgets(
      'the journey Cmd clicks to a second tab leaving the first tab history alone',
      (tester) async {
        final r = await _launch(tester);
        await r.clickFooterChip(_alphaId); // [alpha*], the day behind it
        r.expectOnNote(_alphaId);
        await r.scrollToText(0, '[[Beta]]');
        final alphaAt = r.scrolled;

        await r.clickLink(0, 'Beta', cmd: true);

        expect(r.tabs.tabs, [_alpha, _beta], reason: 'a tab at the end');
        expect(r.tabs.activeIndex, 1);
        r.expectOnNote(_betaId, title: 'Beta');
        expect(r.tabs.canGoBack, isFalse, reason: 'its history holds Beta');
        await r.expectAtTop();

        // The first tab is where it was, with its history and its scroll.
        await tester.tap(r.chip(_alpha));
        await r.pump();
        r.expectOnNote(_alphaId);
        expect(r.tabs.activeIndex, 0);
        expect(r.tabs.canGoBack, isTrue, reason: 'the day is behind it');
        expect(r.tabs.canGoForward, isFalse, reason: 'it did not navigate');
        await r.expectScrolledTo(alphaAt);
        await r.tapBack();
        r.expectOnNote(_dayId);
        expect(r.tabs.tabs, [_day, _beta]);

        // A Cmd click on a note another tab shows focuses that tab.
        await r.tapForward();
        await r.clickLink(0, 'Beta', cmd: true);
        expect(r.tabs.tabs, [_alpha, _beta], reason: 'no third tab');
        expect(r.tabs.activeIndex, 1);

        // So do the Today row and a right panel link, with Cmd held.
        await r.click(r.todayRow, cmd: true);
        expect(r.tabs.tabs, [_alpha, _beta, _day], reason: 'a tab at the end');
        expect(r.tabs.activeIndex, 2);
        expect(r.tabs.canGoBack, isFalse);
        await tester.tap(r.chip(_beta));
        await r.pump();
        await r.click(r.backlink(_alphaId, 'l-alpha-beta'), cmd: true);
        expect(r.tabs.tabs, [_alpha, _beta, _day], reason: 'it focused one');
        expect(r.tabs.activeIndex, 0);
        expect(r.tabs.canGoBack, isTrue, reason: 'its history is untouched');
      },
      variant: macOnly,
    );
  });

  group('a canvas zooms into a note and out', () {
    testWidgets(
      'the journey zooms into a note on a canvas and zooms out with Back and Forward and the right panel follows the zoomed note',
      (tester) async {
        final db = seedCanvasFixture(FakeVaultDb.v5());
        final r = await _launch(
          tester,
          db: db,
          onDay: false,
          overrides: [
            canvasAnimationConfigProvider.overrideWithValue(
              const CanvasAnimationConfig(zoomDuration: Duration.zero),
            ),
          ],
        );
        r.h.read(rightPanelOpenProvider.notifier).state = true;
        r.notifier.navigate(const CanvasTab(C89.newer));
        await pumpFrames(tester);
        await pumpFrames(tester);
        const canvas = CanvasTab(C89.newer);
        const zoomed = CanvasTab(C89.newer, zoomedNoteId: C89.alpha);
        expect(r.canvasView(C89.newer), findsOneWidget);

        await r.doubleClick(C89.alpha);

        expect(r.active, zoomed);
        expect(r.zoomedView(C89.alpha), findsOneWidget);
        expect(r.editor.title, 'Alpha');
        expect(r.h.read(selectedNoteIdProvider), C89.alpha);

        // The right panel shows the zoomed note's connections: its link to
        // Beta follows in this tab, and Back returns to the zoomed note.
        final link = r.outgoingLink(C89.link);
        expect(link, findsOneWidget, reason: 'the zoomed note is in the panel');
        await r.click(link);
        expect(r.active, const NoteTab(C89.beta));
        expect(r.tabs.tabs.length, 1, reason: 'the canvas tab navigated');
        await r.tapBack();
        expect(r.active, zoomed, reason: 'the first Back is the zoomed note');
        expect(r.zoomedView(C89.alpha), findsOneWidget);
        await r.tapBack();
        expect(r.active, canvas, reason: 'the next Back zooms out');
        expect(r.canvasView(C89.newer), findsOneWidget);
        expect(r.zoomedView(C89.alpha), findsNothing);
        expect(r.h.read(selectedNoteIdProvider), isNull);

        await r.tapForward();
        expect(r.active, zoomed, reason: 'Forward zooms back in');
        expect(r.zoomedView(C89.alpha), findsOneWidget);
        expect(r.editor.title, 'Alpha');
      },
    );
  });

  group('deleting a note shown in two tabs', () {
    testWidgets(
      'the journey deletes a note shown in two tabs and both tabs close',
      (tester) async {
        final r = await _launch(tester);
        await r.clickFooterChip(_alphaId); // [alpha*], the day behind it
        r.notifier.openOrFocus(_gamma); // [alpha] [gamma*]
        await r.pump();
        r.notifier.openOrFocus(_beta); // [alpha] [gamma] [beta*]
        await r.pump();
        expect(r.tabs.tabs, [_alpha, _gamma, _beta]);

        // Beta follows Alpha through the right panel: a second tab on Alpha.
        r.notifier.setActive(2);
        await r.pump();
        await r.click(r.backlink(_alphaId, 'l-alpha-beta'));
        expect(r.tabs.tabs, [_alpha, _gamma, _alpha]);
        expect(r.tabs.activeIndex, 2);
        r.expectOnNote(_alphaId);

        await r.deleteShownNote();

        expect(r.tabs.tabs, [_gamma], reason: 'both tabs on Alpha closed');
        r.expectOnNote(_gammaId);
        expect(r.tabs.canGoBack, isFalse, reason: 'their histories went too');
        expect(r.h.db.getNote(_alphaId), isNull);

        await r.flushStore();
        expect(r.persistedTabs(), ['note:$_gammaId']);
      },
    );
  });
}
