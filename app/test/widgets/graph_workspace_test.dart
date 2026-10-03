// WI #30 (A12): Graph tabs in the whole workspace — openGraph, the tab chip
// and body, opening a note from a node, and the note menu's Open graph item.
//
// Runs through the #18 harness (FakeVaultDb, FakeMemexCli, FakeClock). Never
// pumpAndSettle the workspace (OmDot pulses forever): pumpFrames only.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/graph_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';

import '../support/app_harness.dart';
import '../support/fake_vault_db.dart';
import '../support/graph_seeds.dart';

const _graphView = Key('graph-view');
const _menuButton = Key('note-menu-button');
const _menuDelete = Key('note-menu-delete');
const _menuOpenGraph = Key('note-menu-open-graph');

Key _graphTabChip(String scopeId) => Key('tab-graph-$scopeId');
Key _listItem(String id) => Key('note-list-item-$id');

/// The Workspace element is a ConsumerStatefulElement, which is a WidgetRef:
/// the same kind of ref #25's sidebar menus hand to openGraph.
WidgetRef _ref(WidgetTester tester) =>
    tester.element(find.byType(Workspace)) as WidgetRef;

Future<WorkspaceHarness> _pump(WidgetTester tester) {
  final db = FakeVaultDb.v5();
  seedGraphFixture(db);
  return pumpWorkspace(tester, db: db);
}

Future<void> _openGraph(WidgetTester tester, GraphScope scope) async {
  openGraph(_ref(tester), scope);
  await pumpFrames(tester);
}

Future<void> _openNoteMenuFor(WidgetTester tester, String noteId) async {
  // The sidebar opens in Days mode (#23); the note list is the Topics mode.
  await tester.tap(find.byKey(const Key('sidebar-mode-topics')));
  await pumpFrames(tester);
  await tester.tap(find.byKey(_listItem(noteId)));
  await pumpFrames(tester);
  await tester.tap(find.byKey(_menuButton));
  await pumpFrames(tester);
}

Future<void> _closeMenu(WidgetTester tester) async {
  // The menu button toggles: a second tap closes the open menu.
  await tester.tap(find.byKey(_menuButton));
  await pumpFrames(tester);
  expect(find.byKey(const Key('note-menu')), findsNothing);
}

Finder _chipText(String scopeId, String text) => find.descendant(
  of: find.byKey(_graphTabChip(scopeId)),
  matching: find.text(text),
);

void main() {
  group('openGraph (AC6)', () {
    testWidgets('openGraph opens and activates a Graph tab', (tester) async {
      final h = await _pump(tester);
      expect(find.byKey(_graphView), findsNothing);
      // The tabs the app launched with (#22's Today tab).
      final launch = h.read(tabsProvider).tabs;

      await _openGraph(tester, const GraphScope.topic(G.alpha));

      final tabs = h.read(tabsProvider);
      expect(tabs.tabs, [...launch, GraphTab(const GraphScope.topic(G.alpha))]);
      expect(tabs.activeTab, GraphTab(const GraphScope.topic(G.alpha)));
      expect(find.byKey(_graphTabChip('topic:${G.alpha}')), findsOneWidget);
      expect(find.byKey(_graphView), findsOneWidget);
    });

    testWidgets(
      'calling openGraph again with the same scope focuses the existing tab',
      (tester) async {
        final h = await _pump(tester);
        // The tabs the app launched with (#22's Today tab).
        final launch = h.read(tabsProvider).tabs;
        await _openGraph(tester, const GraphScope.topic(G.alpha));
        h.read(tabsProvider.notifier).openOrFocus(const NoteTab(G.beta));
        await pumpFrames(tester);
        expect(h.read(tabsProvider).activeTab, const NoteTab(G.beta));
        expect(find.byKey(_graphView), findsNothing);

        await _openGraph(tester, const GraphScope.topic(G.alpha));

        final tabs = h.read(tabsProvider);
        expect(tabs.tabs, [
          ...launch,
          GraphTab(const GraphScope.topic(G.alpha)),
          const NoteTab(G.beta),
        ]);
        expect(tabs.activeIndex, launch.length);
        expect(tabs.activeTab, GraphTab(const GraphScope.topic(G.alpha)));
        expect(find.byKey(_graphTabChip('topic:${G.alpha}')), findsOneWidget);
        expect(find.byKey(_graphView), findsOneWidget);
      },
    );

    testWidgets('openGraph with a different scope opens a second Graph tab', (
      tester,
    ) async {
      final h = await _pump(tester);
      // The tabs the app launched with (#22's Today tab).
      final launch = h.read(tabsProvider).tabs;
      await _openGraph(tester, const GraphScope.topic(G.alpha));
      await _openGraph(tester, const GraphScope.day(G.alpha));

      final tabs = h.read(tabsProvider);
      expect(tabs.tabs, [
        ...launch,
        GraphTab(const GraphScope.topic(G.alpha)),
        GraphTab(const GraphScope.day(G.alpha)),
      ]);
      expect(tabs.activeIndex, launch.length + 1);
    });

    testWidgets('a topic Graph tab chip reads Graph · and the note title', (
      tester,
    ) async {
      await _pump(tester);
      await _openGraph(tester, const GraphScope.topic(G.alpha));
      expect(_chipText('topic:${G.alpha}', 'Graph · Alpha'), findsOneWidget);
    });

    testWidgets('a day Graph tab chip reads Graph · and the date', (
      tester,
    ) async {
      await _pump(tester);
      await _openGraph(tester, const GraphScope.day(G.day0905));
      expect(
        _chipText('day:${G.day0905}', 'Graph · 2026-09-05'),
        findsOneWidget,
      );
    });

    testWidgets(
      'a Smart Folder Graph tab chip reads Graph · and the folder name',
      (tester) async {
        await _pump(tester);
        await _openGraph(tester, const GraphScope.folder(G.projects));
        expect(
          _chipText('folder:${G.projects}', 'Graph · Projects'),
          findsOneWidget,
        );
        expect(find.byKey(_graphView), findsOneWidget);
      },
    );

    testWidgets('the Whole vault Graph tab chip reads Graph · Whole vault', (
      tester,
    ) async {
      await _pump(tester);
      await _openGraph(tester, const GraphScope.vault());
      expect(_chipText('vault:all', 'Graph · Whole vault'), findsOneWidget);
      expect(find.byKey(_graphView), findsOneWidget);
    });
  });

  group('opening a node (AC10)', () {
    testWidgets('tapping a graph node opens that note as the active tab', (
      tester,
    ) async {
      final h = await _pump(tester);
      await _openGraph(tester, const GraphScope.topic(G.alpha));
      await pumpFrames(tester, frames: 20);

      await tester.tap(find.byKey(const Key('graph-node-${G.beta}')));
      await pumpFrames(tester);

      final tabs = h.read(tabsProvider);
      expect(tabs.activeTab, const NoteTab(G.beta));
      expect(tabs.tabs, contains(GraphTab(const GraphScope.topic(G.alpha))));
      expect(find.byKey(_graphView), findsNothing);
    });

    testWidgets('tapping a daily node opens the daily note as the active tab', (
      tester,
    ) async {
      final h = await _pump(tester);
      await _openGraph(tester, const GraphScope.topic(G.alpha));
      await pumpFrames(tester, frames: 20);

      await tester.tap(find.byKey(const Key('graph-node-${G.day0905}')));
      await pumpFrames(tester);

      expect(h.read(tabsProvider).activeTab, const NoteTab(G.day0905));
    });
  });

  group('note menu Open graph (AC13)', () {
    testWidgets(
      'the note menu shows Open graph for a topic note and opens its topic scope',
      (tester) async {
        final h = await _pump(tester);
        await _openNoteMenuFor(tester, G.alpha);

        final item = find.byKey(_menuOpenGraph);
        expect(item, findsOneWidget);
        expect(tester.widget(item), isA<MenuItemButton>());
        expect(
          find.descendant(of: item, matching: find.text('Open graph')),
          findsOneWidget,
        );
        expect(
          tester.getTopLeft(item).dy,
          greaterThan(tester.getTopLeft(find.byKey(_menuDelete)).dy),
          reason: 'Open graph comes after Delete note',
        );

        await tester.tap(item);
        await pumpFrames(tester);

        expect(
          h.read(tabsProvider).activeTab,
          GraphTab(const GraphScope.topic(G.alpha)),
        );
        expect(find.byKey(_graphView), findsOneWidget);
      },
    );

    testWidgets(
      'the note menu shows Open graph for a daily note and opens its day scope',
      (tester) async {
        final h = await _pump(tester);
        await _openNoteMenuFor(tester, G.day0905);

        expect(find.byKey(_menuOpenGraph), findsOneWidget);
        await tester.tap(find.byKey(_menuOpenGraph));
        await pumpFrames(tester);

        expect(
          h.read(tabsProvider).activeTab,
          GraphTab(const GraphScope.day(G.day0905)),
        );
        expect(find.byKey(_graphView), findsOneWidget);
      },
    );

    testWidgets(
      'the note menu has no Open graph item for a role-less note but has one for a topic',
      (tester) async {
        await _pump(tester);
        await _openNoteMenuFor(tester, G.loose);

        expect(find.byKey(const Key('note-menu')), findsOneWidget);
        expect(find.byKey(_menuDelete), findsOneWidget);
        expect(find.byKey(_menuOpenGraph), findsNothing);

        await _closeMenu(tester);
        await _openNoteMenuFor(tester, G.gamma);
        expect(find.byKey(_menuOpenGraph), findsOneWidget);
      },
    );

    testWidgets(
      'the note menu has no Open graph item for a note with another role but has one for a day',
      (tester) async {
        await _pump(tester);
        await _openNoteMenuFor(tester, G.otherRole);

        expect(find.byKey(_menuDelete), findsOneWidget);
        expect(find.byKey(_menuOpenGraph), findsNothing);

        await _closeMenu(tester);
        await _openNoteMenuFor(tester, G.day0906);
        expect(find.byKey(_menuOpenGraph), findsOneWidget);
      },
    );
  });
}
