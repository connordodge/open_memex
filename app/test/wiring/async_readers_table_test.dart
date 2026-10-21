// WI #105 (F1) AC "no synchronous facade remains": the readers that read a
// D14a facade until F1 (the days pane, the sidebar canvases rail, the right
// panel Connections and Activity tabs) read the async provider directly and
// render it like VaultAsyncView (Req 33, Spec Technical Decisions > App data
// layer):
// - a local vault's first load shows today's empty state, never a spinner;
// - a hosted vault's first load shows the loading state
//   (`vault-async-loading`) in place of the reader rows or empty state (the
//   days pane and the canvases rail);
// - a reload (vault revision bump) keeps the previous rows on screen with no
//   loading state until the new read answers.
// The real app runs over the journey harness; the hosted reads go to the
// fake vault server, held while a load is in flight.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/vault_async_view.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';

import '../robots/hosted_workspace_robot.dart';
import '../robots/picker_robot.dart';
import '../support/app_harness.dart';
import '../support/fake_vault_db.dart';
import '../support/hosted_harness.dart';
import '../support/journey_harness.dart';
import '../support/font_fetch_hold.dart';

const _economyDesignId = '01M5DQAYZ47QW55S90ZF0A56AH';
const _pacingOutLinkId = '01M5DQAYZDBGZSDQ7X3PJT783V';
const _economyChangeId = '01M5DQAYZJKNYY386G5CXYKNMX';

final _loading = find.byKey(vaultAsyncLoadingKey);
Finder _inSidebar(Finder f) =>
    find.descendant(of: find.byType(Sidebar), matching: f);
Finder _inRightPanel(Finder f) =>
    find.descendant(of: find.byType(RightPanel), matching: f);

/// One converted reader: where it renders, its rows once the seed vault's
/// data loaded, its local empty state, and the right panel tab and note it
/// needs.
typedef _Reader = ({
  Finder Function(Finder) scope,
  Finder rows,
  Finder localEmpty,
  RightPanelTab? tab,
  String? noteId,
});

final _days = (
  scope: _inSidebar,
  rows: find.byKey(const Key('days-row-2026-10-18')),
  localEmpty: find.byKey(const Key('days-empty')),
  tab: null,
  noteId: null,
);
final _canvases = (
  scope: _inSidebar,
  rows: find.byKey(const Key('canvas-row-$seedCanvasId')),
  localEmpty: find.text('no canvases yet.'),
  tab: null,
  noteId: null,
);
final _connections = (
  scope: _inRightPanel,
  rows: find.byKey(const Key('outgoing-link-$_pacingOutLinkId')),
  localEmpty: find.text('select a note to see its connections.'),
  tab: RightPanelTab.connections,
  noteId: seedPacingNotesId,
);
final _activity = (
  scope: _inRightPanel,
  rows: find.byKey(const Key('activity-entry-$_economyChangeId')),
  localEmpty: find.byKey(const Key('activity-empty')),
  tab: RightPanelTab.activity,
  noteId: _economyDesignId,
);

/// The seed vault of nas opened from its RECENT row, with every read after
/// the open held at the fake server (a hosted first load in flight). The
/// right panel shows the reader's tab for its note.
Future<(JourneyApp, HostedWorkspaceRobot)> _hostedFirstLoad(
  WidgetTester tester,
  _Reader reader,
) async {
  final nas = HostedServerFixture();
  final app = await pumpJourneyApp(
    tester,
    servers: [nas],
    recents: [seedHostedRef],
  );
  app.container.listen(currentVaultProvider, (_, next) {
    if (next == seedHostedRef) nas.server.hold();
  });
  await PickerRobot(app).tap(PickerRobot(app).recentRow(0));
  expect(app.read(currentVaultProvider), seedHostedRef);
  final w = HostedWorkspaceRobot(app);
  if (reader.tab case final tab?) {
    app.read(rightPanelTabProvider.notifier).state = tab;
    await w.openNoteTab(reader.noteId!);
  }
  return (app, w);
}

void main() {
  holdFontFetches();

  group('a local first load shows the empty state with no spinner', () {
    for (final (name, reader) in <(String, _Reader)>[
      ('the days pane shows its empty state on a local first load', _days),
      (
        'the canvases rail shows its empty state on a local first load',
        _canvases,
      ),
      (
        'the Connections tab shows its empty state on a local first load',
        _connections,
      ),
      (
        'the Activity tab shows its empty state on a local first load',
        _activity,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final h = await pumpWorkspace(tester, db: FakeVaultDb.v5());
        if (reader.tab != null) {
          h.container.read(rightPanelTabProvider.notifier).state = reader.tab!;
        }
        await pumpFrames(tester, frames: 1);

        expect(reader.scope(reader.localEmpty), findsOneWidget);
        expect(_loading, findsNothing);
      });
    }
  });

  // The right panel tabs are left out of this group: their selected-note
  // read always has a previous value (no note selected) when a note is
  // picked, and their content reads' hosted loading state is #90's
  // (right_panel_async_test).
  group('a hosted first load shows the loading state', () {
    for (final (name, reader) in <(String, _Reader)>[
      ('the days pane shows the loading state on a hosted first load', _days),
      (
        'the canvases rail shows the loading state on a hosted first load',
        _canvases,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final (app, _) = await _hostedFirstLoad(tester, reader);

        expect(reader.scope(_loading), findsWidgets);
        expect(reader.scope(reader.localEmpty), findsNothing);
        expect(reader.rows, findsNothing);

        app.first.server.release();
        await app.settle();

        expect(reader.rows, findsOneWidget);
        expect(_loading, findsNothing);
      });
    }
  });

  group('a reload keeps the previous value on screen', () {
    for (final (name, reader) in <(String, _Reader)>[
      ('the days pane keeps its rows during a reload', _days),
      ('the canvases rail keeps its rows during a reload', _canvases),
      ('the Connections tab keeps its rows during a reload', _connections),
      ('the Activity tab keeps its rows during a reload', _activity),
    ]) {
      testWidgets(name, (tester) async {
        final (app, _) = await _hostedFirstLoad(tester, reader);
        app.first.server.release();
        await app.settle();
        expect(reader.rows, findsOneWidget);

        app.first.server.hold();
        app.read(vaultRevisionProvider.notifier).state++;
        await app.settle();

        expect(reader.rows, findsOneWidget);
        expect(_loading, findsNothing);

        app.first.server.release();
        await app.settle();
        expect(reader.rows, findsOneWidget);
      });
    }
  });
}
