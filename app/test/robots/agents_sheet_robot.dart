import 'dart:ui' show Tristate;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/journey_harness.dart';
import '../support/window_menu_fakes.dart';

/// Robot for the Agents sheet entry-point journey (WI #408, Spec #394
/// testing strategy "Journey test"). Finds widgets by Key only:
/// - the sidebar footer link (#408 on #390's footer): `agent-footer-open`;
/// - the editor status bar button (#407): `status-bar-agents`;
/// - the sheet (#407): `agents-sheet`, its close `x` `agents-sheet-close`,
///   and the tab chips `agents-tab-<live|connect|tools|recall>`.
/// Window ▸ Agents… is played through [FakeWindowMenuHost.simulateOpenAgents].
class AgentsSheetRobot {
  AgentsSheetRobot(this.app, this.menu);

  final JourneyApp app;

  /// Behind `windowMenuHostProvider`.
  final FakeWindowMenuHost menu;

  WidgetTester get tester => app.tester;

  // ---------------------------------------------------------------- finders

  Finder key(String k) => find.byKey(Key(k));

  Finder get footerOpen => key('agent-footer-open');
  Finder get statusBarButton => key('status-bar-agents');
  Finder get sheet => key('agents-sheet');
  Finder get closeButton => key('agents-sheet-close');
  Finder tab(String name) => key('agents-tab-$name');

  // ------------------------------------------------------------------ reads

  /// The one tab chip announced as selected, by its Key name
  /// (`live`, `connect`, `tools`, `recall`).
  String get activeTab {
    final selected = [
      for (final name in const ['live', 'connect', 'tools', 'recall'])
        if (tester.getSemantics(tab(name)).flagsCollection.isSelected ==
            Tristate.isTrue)
          name,
    ];
    expect(selected, hasLength(1), reason: 'one selected tab: $selected');
    return selected.single;
  }

  // ---------------------------------------------------------------- actions

  Future<void> _tap(Finder f) async {
    expect(f, findsOneWidget, reason: '$f shows');
    await tester.ensureVisible(f);
    await tester.tap(f);
    await tester.pump();
  }

  /// Past the sheet's 300 ms opening-tab decision, then expects one sheet.
  Future<void> _expectOpened(String via) async {
    await app.advance(const Duration(milliseconds: 300));
    expect(sheet, findsOneWidget, reason: '$via opens agents-sheet');
  }

  /// Taps the footer `OPEN ↗` link.
  Future<void> openFromFooter() async {
    await _tap(footerOpen);
    await _expectOpened('the footer OPEN ↗ link');
  }

  /// Taps the status bar `agents ⇧⌘A` button.
  Future<void> openFromStatusBar() async {
    await _tap(statusBarButton);
    await _expectOpened('the status bar button');
  }

  /// Window ▸ Agents… (or ⇧⌘A reaching the menu): `openAgents`.
  Future<void> openFromWindowMenu() async {
    menu.simulateOpenAgents();
    await tester.pump();
    await _expectOpened('Window ▸ Agents…');
  }

  /// The sheet's `x`.
  Future<void> closeSheet() async {
    await _tap(closeButton);
    await app.settle();
    expect(sheet, findsNothing, reason: 'the x closes agents-sheet');
  }
}
