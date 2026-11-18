// WI #68 (Spec #58 O2): the Outline tab inside the whole workspace. The
// entries follow the editor the person sees: typing in the live preview and
// in Source mode, a canvas zoomed into a note, and the no note states of a
// graph tab, an unzoomed canvas and the empty editor. The shared panel count
// colour (PanelHeader `· N`) is checked in the sidebar.
//
// Fonts are the flutter_test fallback at the harness text scale (0.5). Note
// content is invented. Test names use no apostrophes.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';
import '../support/canvas_seeds.dart';
import '../support/font_fetch_hold.dart';

/// The topic note body: one text segment with two headings.
const _wi68wBody = '# Player loop\nIntro line\n## Jump arc\nOutro line\n';
const _wi68wCanvas = 'cv-68-board';
const _wi68wNoNote = 'open a note to see its outline.';

Finder _wi68wRow(int i) => find.byKey(Key('outline-entry-$i'));

Finder _wi68wRowText(int i, String text) =>
    find.descendant(of: _wi68wRow(i), matching: find.text(text));

/// The workspace on the segmented vault, the topic note's body set to
/// [_wi68wBody], a canvas holding the topic note, and the topic note open.
Future<SegmentedEditorRobot> _wi68wLaunch(WidgetTester tester) async {
  final vault = seedSegmentedVault(topicBody: _wi68wBody);
  vault.db.seedCanvas(_wi68wCanvas, 'Loop board', updatedAt: 400);
  vault.db.seedCanvasNode(_wi68wCanvas, fixtureTopicId, x: 40, y: 40);
  final r = await launchSegmented(tester, vault: vault);
  await r.open(fixtureTopicId);
  return r;
}

/// Shows the Outline tab through its chip.
Future<void> _wi68wShowOutline(WidgetTester tester) async {
  final chip = find.byKey(const Key('outline-tab-chip'));
  expect(chip, findsOneWidget, reason: 'the outline chip');
  await tester.tap(chip);
  await pumpFrames(tester);
}

void _wi68wExpectTopicEntries() {
  expect(_wi68wRowText(0, 'Player loop'), findsOneWidget);
  expect(_wi68wRowText(1, 'Jump arc'), findsOneWidget);
  expect(_wi68wRow(2), findsNothing);
}

void main() {
  holdFontFetches();

  testWidgets(
    'typing a new level two heading in the editor adds an Outline entry without reopening the tab',
    (tester) async {
      final r = await _wi68wLaunch(tester);
      await _wi68wShowOutline(tester);
      _wi68wExpectTopicEntries();

      await r.typeInSegment(0, '$_wi68wBody## Coyote time\n');
      await tester.pump();

      expect(_wi68wRowText(2, 'Coyote time'), findsOneWidget);
      expect(
        r.h.read(rightPanelTabProvider),
        RightPanelTab.outline,
        reason: 'the tab was never reopened',
      );
      await r.waitForSave();
      expect(_wi68wRowText(2, 'Coyote time'), findsOneWidget);
    },
  );

  testWidgets('in Source mode the Outline still lists the note entries', (
    tester,
  ) async {
    final r = await _wi68wLaunch(tester);
    await _wi68wShowOutline(tester);
    await r.toggleSource();
    expect(r.sourceSurface, findsOneWidget, reason: 'fixture: Source mode');

    _wi68wExpectTopicEntries();

    await tester.enterText(r.sourceBody, '$_wi68wBody## Respawn\n');
    await tester.pump();
    expect(_wi68wRowText(2, 'Respawn'), findsOneWidget);
    await r.waitForSave();
  });

  testWidgets('a canvas zoomed into a note shows that note entries', (
    tester,
  ) async {
    final r = await _wi68wLaunch(tester);
    await _wi68wShowOutline(tester);

    r.h
        .read(tabsProvider.notifier)
        .navigate(const CanvasTab(_wi68wCanvas, zoomedNoteId: fixtureTopicId));
    await pumpFrames(tester, frames: 10);

    expect(
      r.activeTab,
      const CanvasTab(_wi68wCanvas, zoomedNoteId: fixtureTopicId),
    );
    _wi68wExpectTopicEntries();
    expect(find.text(_wi68wNoNote), findsNothing);
  });

  for (final (name, leave) in <(String, void Function(TabsNotifier))>[
    (
      'a graph tab shows the no note Outline copy',
      (tabs) => tabs.navigate(GraphTab(const GraphScope.topic(fixtureTopicId))),
    ),
    (
      'a canvas not zoomed into a note shows the no note Outline copy',
      (tabs) => tabs.navigate(const CanvasTab(_wi68wCanvas)),
    ),
    (
      'the empty editor with no tab open shows the no note Outline copy',
      (tabs) {
        while (tabs.state.tabs.isNotEmpty) {
          tabs.closeAt(0);
        }
      },
    ),
  ]) {
    testWidgets(name, (tester) async {
      final r = await _wi68wLaunch(tester);
      await _wi68wShowOutline(tester);
      _wi68wExpectTopicEntries();

      leave(r.h.read(tabsProvider.notifier));
      await pumpFrames(tester, frames: 10);

      expect(find.text(_wi68wNoNote), findsOneWidget);
      expect(find.text('OUTLINE · THIS NOTE'), findsOneWidget);
      expect(_wi68wRow(0), findsNothing);
      expect(find.text('Player loop'), findsNothing);
    });
  }

  testWidgets(
    'the sidebar vaults and canvases header counts are drawn in fg2',
    (tester) async {
      await _wi68wLaunch(tester);

      final counts = find.descendant(
        of: find.descendant(
          of: find.byType(Sidebar),
          matching: find.byType(PanelHeader),
        ),
        matching: find.byWidgetPredicate(
          (w) => w is Text && RegExp(r'^· \d+$').hasMatch(w.data ?? ''),
        ),
      );
      expect(counts.evaluate().length, 2, reason: 'vaults and canvases');
      for (final e in counts.evaluate()) {
        final para = e.renderObject! as RenderParagraph;
        expect(
          para.text.style!.color,
          OmColors.fg2,
          reason: (e.widget as Text).data,
        );
      }
    },
  );
}
