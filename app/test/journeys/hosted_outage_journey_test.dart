// WI #105 (F1) AC7 to AC10: a hosted vault's workspace when its server
// goes away and comes back (board A11, Req 50 to 53a, L7, L16, L17), end to
// end on the real app over the fake vault server and the FakeClock (2 s
// revision polls, 10 s request timeout):
// - unreachable: the banner, the loaded note stays, an unloaded note shows
//   the not-loaded state, typed text queues ("not saved yet"), and when the
//   server answers the banner clears and every queued save lands;
// - other writes while unreachable fail at once (refused) or after 10 s
//   (timed out) with their snackbar, and are never retried;
// - 401: the banner, revision polling stops, "update token" replaces the
//   token and polling resumes with it;
// - leaving with unsent text asks first; a vault deleted on the server
//   returns to the picker, whose row offers removal.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../robots/hosted_workspace_robot.dart';
import '../robots/picker_robot.dart';
import '../support/api_fixtures.dart';
import '../support/fake_vault_server.dart';
import '../support/hosted_harness.dart';
import '../support/journey_harness.dart';
import '../support/vault_picker_harness.dart' show wi97HoldFontFetches;

const _looseBody = 'Maybe the map folds like paper?\n';
const _pending = 'not saved yet · will save when nas is back';

/// The seed vault of nas open at launch, the Topics pane showing, and Loose
/// Thought then Broken Frontmatter opened (both loaded), Loose Thought
/// active. Saves of both answer with version 2. [extraServers] are saved
/// too (their vaults are in RECENT after seed).
Future<HostedWorkspaceRobot> _workspace(
  WidgetTester tester, {
  List<HostedServerFixture> extraServers = const [],
}) async {
  final nas = HostedServerFixture()
    ..serveSave(seedVaultName, seedLooseThoughtId)
    ..serveSave(seedVaultName, seedBrokenFrontmatterId);
  final app = await pumpJourneyApp(
    tester,
    servers: [nas, ...extraServers],
    recents: [seedHostedRef, for (final s in extraServers) s.ref('work')],
    lastVault: seedHostedRef,
  );
  final w = HostedWorkspaceRobot(app);
  expect(w.currentVault, seedHostedRef, reason: 'launch opened the vault');
  await w.showTopics();
  await w.openUnsorted(seedLooseThoughtId);
  await w.openUnsorted(seedBrokenFrontmatterId);
  await w.tap(w.noteTab(seedLooseThoughtId));
  expect(w.segmentText(0), _looseBody);
  return w;
}

/// The server stops answering (connection refused) and the next poll sees
/// it.
Future<void> _serverDown(HostedWorkspaceRobot w) async {
  w.app.first.server.failure = FakeServerFailure.refused;
  await w.app.pollTick();
}

/// The server answers again and the next poll sees it.
Future<void> _serverBack(HostedWorkspaceRobot w) async {
  w.app.first.server.failure = null;
  await w.app.pollTick();
  await w.app.settle();
}

Iterable<String> _paths(FakeVaultServer s, String method, String path) => [
  for (final q in s.requests)
    if (q.method == method && q.url.path == path) q.url.path,
];

List<String> _patchBodies(FakeVaultServer s, String noteId) => [
  for (final q in s.requests)
    if (q.method == 'PATCH' &&
        q.url.path == '/vaults/seed/api/v1/notes/$noteId')
      q.body,
];

void main() {
  wi97HoldFontFetches();

  group('unreachable then recovery (AC7)', () {
    testWidgets(
      'when nas cannot be reached the banner shows retrying the loaded note stays and retry now asks the server once',
      (tester) async {
        final w = await _workspace(tester);

        await _serverDown(w);

        expect(w.unreachableBanner, findsOneWidget);
        expect(
          find.descendant(
            of: w.unreachableBanner,
            matching: find.text("can't reach nas — retrying…"),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: w.retryNow, matching: find.text('retry now')),
          findsOneWidget,
        );
        expect(w.segmentText(0), _looseBody);
        expect(w.notLoaded, findsNothing);

        final infos = _paths(w.app.first.server, 'GET', '/api/v1/info').length;
        await w.tap(w.retryNow);
        expect(
          _paths(w.app.first.server, 'GET', '/api/v1/info'),
          hasLength(infos + 1),
          reason: 'retry now sends one request to the server',
        );
      },
    );

    testWidgets(
      'opening a note that is not loaded while nas cannot be reached shows the not loaded state',
      (tester) async {
        final w = await _workspace(tester);
        await _serverDown(w);

        await w.openNoteTab(seedPacingNotesId);

        expect(w.notLoaded, findsOneWidget);
        expect(
          find.text("Pacing Notes isn't loaded and nas can't be reached."),
          findsOneWidget,
        );
        expect(find.text('it opens as soon as nas answers.'), findsOneWidget);
      },
    );

    testWidgets(
      'typing while nas cannot be reached shows not saved yet and switching notes and typing leaves both tabs not saved yet',
      (tester) async {
        final w = await _workspace(tester);
        await _serverDown(w);

        await w.typeAndSave('loose thought typed offline\n');

        expect(w.pendingLabel, findsOneWidget);
        expect(find.text(_pending), findsOneWidget);
        expect(w.noteTabRing(seedLooseThoughtId), findsOneWidget);

        await w.tap(w.noteTab(seedBrokenFrontmatterId));
        await w.typeAndSave('broken frontmatter typed offline\n');

        expect(find.text(_pending), findsOneWidget);
        expect(w.noteTabRing(seedLooseThoughtId), findsOneWidget);
        expect(w.noteTabRing(seedBrokenFrontmatterId), findsOneWidget);
        expect(
          tester
              .widget<Tooltip>(
                find.ancestor(
                  of: w.noteTabRing(seedLooseThoughtId),
                  matching: find.byType(Tooltip),
                ),
              )
              .message,
          'not saved yet',
        );

        await w.tap(w.noteTab(seedLooseThoughtId));
        expect(w.segmentText(0), 'loose thought typed offline\n');
      },
    );

    testWidgets(
      'when nas answers again the banner clears and both queued saves land with no conflict state',
      (tester) async {
        final w = await _workspace(tester);
        await _serverDown(w);
        await w.typeAndSave('loose thought typed offline\n');
        await w.tap(w.noteTab(seedBrokenFrontmatterId));
        await w.typeAndSave('broken frontmatter typed offline\n');

        await _serverBack(w);

        expect(w.unreachableBanner, findsNothing);
        final server = w.app.first.server;
        expect(
          _patchBodies(server, seedLooseThoughtId).last,
          contains('loose thought typed offline'),
        );
        expect(
          _patchBodies(server, seedBrokenFrontmatterId).last,
          contains('broken frontmatter typed offline'),
        );
        expect(w.noteTabRing(seedLooseThoughtId), findsNothing);
        expect(w.noteTabRing(seedBrokenFrontmatterId), findsNothing);
        expect(w.pendingLabel, findsNothing);
        expect(w.saveIndicatorShows('conflict'), isFalse);
        expect(w.saveIndicatorShows('save failed'), isFalse);
        expect(w.segmentText(0), 'broken frontmatter typed offline\n');
      },
    );
  });

  group('writes while unreachable (AC8)', () {
    testWidgets(
      'a refused new Smart Folder shows couldnt reach nas try again and is never retried',
      (tester) async {
        final w = await _workspace(tester);
        await _serverDown(w);
        final server = w.app.first.server;

        await w.newSmartFolder('Offline Folder');

        expect(find.text("couldn't reach nas. try again."), findsOneWidget);
        expect(
          _paths(server, 'POST', '/vaults/seed/api/v1/smart-folders'),
          hasLength(1),
        );

        await _serverBack(w);
        await w.app.pollTick();
        expect(
          _paths(server, 'POST', '/vaults/seed/api/v1/smart-folders'),
          hasLength(1),
          reason: 'a refused write is not queued or retried',
        );
      },
    );

    testWidgets(
      'a timed out new Smart Folder shows couldnt confirm with nas and is never retried',
      (tester) async {
        final w = await _workspace(tester);
        final server = w.app.first.server;
        server.failure = FakeServerFailure.timeout;

        await w.newSmartFolder('Maybe Folder');
        await w.app.advance(const Duration(seconds: 9));
        expect(
          find.text("couldn't confirm with nas — check before trying again"),
          findsNothing,
        );
        await w.app.advance(const Duration(seconds: 1));

        expect(
          find.text("couldn't confirm with nas — check before trying again"),
          findsOneWidget,
        );
        expect(
          _paths(server, 'POST', '/vaults/seed/api/v1/smart-folders'),
          hasLength(1),
        );

        await _serverBack(w);
        await w.app.pollTick();
        expect(
          _paths(server, 'POST', '/vaults/seed/api/v1/smart-folders'),
          hasLength(1),
          reason: 'a timed out write is not queued or retried',
        );
      },
    );
  });

  group('401 (AC9)', () {
    testWidgets(
      'a rejected token shows the banner and stops revision polling and update token with a new token clears it and polling resumes',
      (tester) async {
        final w = await _workspace(tester);
        final server = w.app.first.server;
        server.token = 'rotated-token-105';
        await w.app.pollTick();

        expect(w.unauthorizedBanner, findsOneWidget);
        expect(
          find.descendant(
            of: w.unauthorizedBanner,
            matching: find.text('nas rejected the access token'),
          ),
          findsOneWidget,
        );
        const revision = '/vaults/seed/api/v1/revision';
        final polls = _paths(server, 'GET', revision).length;
        await w.app.pollTick();
        await w.app.pollTick();
        expect(
          _paths(server, 'GET', revision),
          hasLength(polls),
          reason: 'revision polling stops on 401',
        );

        await w.tap(w.bannerUpdateToken);
        final r = PickerRobot(w.app);
        r.expectEditServerDialog('nas', fakeServerUrl);
        await r.enter(r.connectToken, 'rotated-token-105');
        await r.tap(r.connectSubmit);

        expect(r.connectDialog, findsNothing);
        expect(w.app.tokens.tokens[fakeServerId], 'rotated-token-105');
        await w.app.pollTick();
        expect(w.unauthorizedBanner, findsNothing);
        final resumed = [
          for (final q in server.requests)
            if (q.url.path == revision) q,
        ].skip(polls).toList();
        expect(resumed, isNotEmpty, reason: 'revision polling resumes');
        expect(
          resumed.last.headers['authorization'],
          'Bearer rotated-token-105',
        );
      },
    );
  });

  group('leaving with unsent text (AC10)', () {
    for (final (name, verb) in [
      (
        'closing the window with unsent text asks close anyway and cancel keeps the vault and text',
        'close',
      ),
      (
        'quitting with unsent text asks quit anyway and cancel keeps the vault and text',
        'quit',
      ),
      (
        'switching vault with unsent text asks switch anyway and cancel keeps the vault and text',
        'switch',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final studio = journeyStudio();
        final w = await _workspace(tester, extraServers: [studio]);
        await _serverDown(w);
        await w.typeAndSave('typed before leaving\n');
        expect(w.noteTabRing(seedLooseThoughtId), findsOneWidget);

        final exit = w.app.exitHost;
        switch (verb) {
          case 'close':
            journeyFire(exit.requestClose());
          case 'quit':
            journeyFire(exit.requestQuit());
          default:
            await tester.tap(w.pill(studio.id, 'work'));
        }
        await w.app.settle();

        expect(w.leaveConfirm, findsOneWidget);
        expect(
          find.text("unsaved changes couldn't reach nas. $verb anyway?"),
          findsOneWidget,
        );
        expect(find.text('Loose Thought'), findsWidgets);
        await w.tap(w.leaveCancel);

        expect(w.leaveConfirm, findsNothing);
        expect(w.currentVault, seedHostedRef);
        expect(w.segmentText(0), 'typed before leaving\n');
        if (verb == 'close') expect(exit.closeAnswers, [false]);
        if (verb == 'quit') expect(exit.quitAnswers.single.name, 'cancel');
      });
    }

    testWidgets('with nothing unsent closing the window asks nothing', (
      tester,
    ) async {
      final w = await _workspace(tester);
      final exit = w.app.exitHost;

      journeyFire(exit.requestClose());
      await w.app.settle();

      expect(w.leaveConfirm, findsNothing);
      expect(exit.closeAnswers, [true]);
    });
  });

  group('vault deleted on the server (AC10)', () {
    testWidgets(
      'the vault deleted on the server while open returns to the picker whose row says it is no longer on nas and offers removal',
      (tester) async {
        final w = await _workspace(tester);

        w.app.first.server.removeVault('seed');
        await w.app.pollTick();
        await w.app.settle();

        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(w.currentVault, isNull);
        final r = PickerRobot(w.app);
        expect(
          r.inside('recent-row-0', find.text('seed is no longer on nas')),
          findsOneWidget,
        );
        expect(r.recentRemoveFromRecents(0), findsOneWidget);

        await r.tap(r.recentRemoveFromRecents(0));

        expect(w.app.settings.recentRefs, isEmpty);
        expect(w.app.read(currentVaultProvider), isNull);
      },
    );
  });
}
