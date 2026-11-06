// WI #96 (H2, D19, D17, D13, Req 34, 47, 49, 53, 53a, L9, L18, L21): the
// hosted open path. `openVault(HostedVaultRef)` probes the saved server
// (`GET /api/v1/info`), reads the vault info, and only then makes the ref
// current; `vaultAccessProvider` gives the hosted composite; every failure
// is a typed outcome that opens nothing; launch reopens a hosted last vault;
// a vault that goes away while open returns to the picker. Driven through
// FakeVaultServers and a FakeTokenStore (test/support/hosted_harness.dart);
// no network, never the real Keychain.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/sidebar_mode_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:path/path.dart' as p;

import '../support/api_fixtures.dart';
import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_server.dart';
import '../support/font_fetch_hold.dart';
import '../support/hosted_harness.dart';
import '../support/token_store_fakes.dart';
import '../support/vault_folders.dart';

// Spec copy (Req 47, L9, L18; #97 ruling for not-memex).
const _l9Nas =
    "nas runs memex 0.9.0, which this app can't use. update the app or memex "
    'on the server so both are the same release.';
const _schemaText = 'schema version unsupported: db=7, app=5';

// Seed fixture ids (test/fixtures/api_v1/seed_vault.sql).
const _wi96PlayerLoop = '01M5DQAYZ3WP7H0NXZZV9M2315';
const _wi96Loose = '01M5DQAYZ4RYSGA8T0YEEF8QRS';

/// A second saved server, with the fixture rows served as vault [vault].
HostedServerFixture _studio({
  String url = 'http://studio.local:9000',
  String vault = 'work',
}) => HostedServerFixture(
  id: 'srv-studio',
  name: 'studio',
  url: url,
  token: 'studio-token-96',
  vaultName: vault,
);

/// Lets the fake server's futures and the settings writes land.
Future<void> _drain() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

TypeMatcher<T> _failed<T extends VaultOpenFailure>(String message) =>
    isA<T>().having((o) => o.message, 'message', message);

String _line(dynamic r) => '${r.method} ${r.url}';

void main() {
  holdFontFetches();

  group('hosted open path (AC2)', () {
    test(
      'opening a hosted ref probes the server then reads the vault info with the bearer token and utc offset',
      () async {
        final token = ['tok', 'from', 'store', '96'].join('-');
        final h = await hostedContainer(
          servers: [HostedServerFixture(token: token)],
        );

        final outcome = await h.controller.openVault(seedHostedRef);

        expect(
          outcome,
          isA<VaultOpened>().having((o) => o.vault, 'vault', seedHostedRef),
        );
        final reqs = h.first.server.requests;
        expect(reqs.length, greaterThanOrEqualTo(2));
        expect(reqs.take(2).map(_line), [
          'GET http://nas.local:7878/api/v1/info',
          'GET http://nas.local:7878/vaults/seed/api/v1/info',
        ]);
        for (final r in reqs.take(2)) {
          expect(r.headers['authorization'], 'Bearer $token');
          expect(r.headers['x-memex-utc-offset'], '+02:00');
        }
        expect(h.tokens.calls, contains('read $fakeServerId'));
      },
    );

    test(
      'a successful hosted open makes the ref current and puts it first in recent as the last vault',
      () async {
        final local = createVaultFolder('om96_recent_');
        final studio = _studio();
        final h = await hostedContainer(
          servers: [HostedServerFixture(), studio],
          recents: [LocalVaultRef(local.path), studio.ref('work')],
          lastVault: LocalVaultRef(local.path),
        );

        await h.controller.openVault(seedHostedRef);

        expect(h.read(currentVaultProvider), seedHostedRef);
        final settings = h.read(settingsProvider);
        expect(settings.recentRefs, [
          seedHostedRef,
          LocalVaultRef(local.path),
          studio.ref('work'),
        ]);
        expect(settings.lastVaultRef, seedHostedRef);
        // Persisted: a relaunch reads the same recents and last vault.
        final relaunched = await relaunchSettings(tokenStore: h.tokens);
        expect(relaunched.state.lastVaultRef, seedHostedRef);
        expect(relaunched.state.recentRefs.first, seedHostedRef);
      },
    );

    test(
      'a hosted open with a vault already open replaces it and records no row outcome',
      () async {
        final studio = _studio();
        final h = await hostedContainer(
          servers: [HostedServerFixture(), studio],
        );
        await h.controller.openVault(seedHostedRef);

        final outcome = await h.controller.openVault(studio.ref('work'));

        expect(outcome, isA<VaultOpened>());
        expect(h.read(currentVaultProvider), studio.ref('work'));
        expect(h.read(recentRowOutcomeProvider(studio.ref('work'))), isNull);
        expect(h.read(recentRowOutcomeProvider(seedHostedRef)), isNull);
      },
    );

    test(
      'while a hosted open runs its row outcome is opening and the vault is not yet current',
      () async {
        final h = await hostedContainer();
        h.first.server.hold();

        final open = h.controller.openVault(seedHostedRef);
        await _drain();

        expect(
          h.read(recentRowOutcomeProvider(seedHostedRef)),
          isA<RecentRowOpening>(),
        );
        expect(h.read(currentVaultProvider), isNull);

        h.first.server.release();
        await open;
        expect(h.read(currentVaultProvider), seedHostedRef);
        expect(h.read(recentRowOutcomeProvider(seedHostedRef)), isNull);
      },
    );

    test(
      'a hosted ref on an unsaved server fails, reads no token and sends no request',
      () async {
        final h = await hostedContainer();

        final outcome = await h.controller.openVault(
          HostedVaultRef(['srv', 'gone'].join('-'), 'seed'),
        );

        expect(outcome, isA<VaultOpenFailure>());
        expect(h.read(currentVaultProvider), isNull);
        expect(h.tokens.calls, isEmpty);
        expect(h.router.sent, isEmpty);
        expect(h.read(settingsProvider).recentRefs, isEmpty);
      },
    );

    test(
      'a saved server with no stored token gives token rejected and sends no request',
      () async {
        final h = await hostedContainer(
          servers: [HostedServerFixture(storeToken: false)],
        );

        final outcome = await h.controller.openVault(seedHostedRef);

        expect(
          outcome,
          _failed<HostedTokenRejected>('nas rejected the access token'),
        );
        expect(h.router.sent, isEmpty);
        expect(h.read(currentVaultProvider), isNull);
      },
    );

    testWidgets(
      'an opened hosted vault shows the workspace and its composite serves the fake server notes',
      (tester) async {
        final h = await pumpHostedApp(tester);
        expect(find.byType(VaultPickerScreen), findsOneWidget);

        await pumpWhile(tester, () => h.controller.openVault(seedHostedRef));

        expect(find.byType(Workspace), findsOneWidget);
        expect(find.byType(VaultPickerScreen), findsNothing);
        final notes = await pumpWhile(
          tester,
          () => h.read(vaultAccessProvider)!.notes.listNotes(),
        );
        expect(
          notes.map((n) => n.title),
          containsAll(['2026-10-17', '2026-10-18', '2026-10-19']),
        );
      },
    );
  });

  group('hosted composite (AC3)', () {
    test(
      'for a hosted ref vaultAccessProvider gives a composite whose every domain calls that server vault routes',
      () async {
        final studio = _studio(url: 'http://studio.local:9000/memex');
        final h = await hostedContainer(
          servers: [HostedServerFixture(), studio],
        );
        await h.controller.openVault(studio.ref('work'));

        final access = h.read(vaultAccessProvider);
        expect(access, isA<HostedVaultAccess>());
        access!;
        const prefix = 'http://studio.local:9000/memex/vaults/work/api/v1/';
        final calls = <String, Future<Object?> Function()>{
          'notes': () => access.notes.listNotes(),
          'daily': () => access.daily.dailyNotes(),
          'topics': () => access.topics.smartFolders(),
          'canvas': () => access.canvas.listCanvases(),
          'graph': () => access.graph.graphNotes(),
          'revision': access.revision,
          'schemaVersion': access.schemaVersion,
        };
        for (final MapEntry(key: domain, value: call) in calls.entries) {
          final before = h.router.sent.length;
          await call();
          final sent = h.router.sent.skip(before).toList();
          expect(sent, isNotEmpty, reason: '$domain sends a request');
          for (final r in sent) {
            expect('${r.url}', startsWith(prefix), reason: domain);
            expect(r.headers['authorization'], 'Bearer studio-token-96');
          }
        }
        expect(h.first.server.requests, isEmpty, reason: 'nas is untouched');
        expect(await access.schemaVersion(), 6);
        expect(access.canWrite, isTrue);
      },
    );

    test(
      'switching to another hosted ref disposes the old composite so it sends no request',
      () async {
        final studio = _studio();
        final h = await hostedContainer(
          servers: [HostedServerFixture(), studio],
        );
        await h.controller.openVault(seedHostedRef);
        final old = h.read(vaultAccessProvider)!;
        await old.revision();

        await h.controller.openVault(studio.ref('work'));
        final next = h.read(vaultAccessProvider);

        expect(next, isA<HostedVaultAccess>());
        expect(identical(next, old), isFalse);
        final before = h.router.sent.length;
        await expectLater(old.notes.listNotes(), throwsA(anything));
        await expectLater(old.revision(), throwsA(anything));
        expect(h.router.sent.length, before);
        // The new composite still works.
        expect(await next!.revision(), isNotEmpty);
      },
    );

    test(
      'switching to a local ref disposes the old composite so it sends no request',
      () async {
        final local = createVaultFolder('om96_local_');
        final h = await hostedContainer();
        await h.controller.openVault(seedHostedRef);
        final old = h.read(vaultAccessProvider)!;

        h.read(currentVaultProvider.notifier).state = LocalVaultRef(local.path);
        expect(h.read(vaultAccessProvider), isNot(isA<HostedVaultAccess>()));

        final before = h.router.sent.length;
        await expectLater(old.graph.graphNotes(), throwsA(anything));
        expect(h.router.sent.length, before);
      },
    );
  });

  group('hosted open failures (AC4)', () {
    // Each case: the setup, the outcome it must give, and whether the vault
    // info route may be read (a failed probe never reads it).
    final cases =
        <
          (String, void Function(HostedServerFixture s), Matcher, bool infoRead)
        >[
          (
            'a refused connection gives unreachable and opens nothing',
            (s) => s.server.failure = FakeServerFailure.refused,
            _failed<HostedServerUnreachable>("can't reach nas"),
            false,
          ),
          (
            'a 401 gives token rejected and opens nothing',
            (s) => s.server.token = 'rotated-on-the-server',
            _failed<HostedTokenRejected>('nas rejected the access token'),
            false,
          ),
          (
            'an api version other than 1 gives api mismatch carrying the server version',
            (s) => s.server.route(
              'GET',
              '/api/v1/info',
              json: {'api_version': 2, 'server_version': '0.9.0'},
            ),
            _failed<HostedApiMismatch>(
              _l9Nas,
            ).having((o) => o.serverVersion, 'serverVersion', '0.9.0'),
            false,
          ),
          (
            'a vault not found gives vault gone and opens nothing',
            (s) => s.server.removeVault(seedVaultName),
            _failed<HostedVaultGone>('seed is no longer on nas'),
            true,
          ),
          (
            'a server refusing the vault schema gives schema refused carrying the server error text',
            (s) => s.server.route(
              'GET',
              '/vaults/seed/api/v1/info',
              status: 500,
              json: {
                'error': {'code': 'internal', 'message': _schemaText},
              },
            ),
            _failed<HostedSchemaRefused>(_schemaText),
            true,
          ),
          (
            'a server that is not memex gives not memex and opens nothing',
            (s) => s.server.servesHtml = true,
            _failed<HostedNotMemexServer>(
              "http://nas.local:7878 isn't a memex vault server",
            ),
            false,
          ),
        ];

    for (final (name, setUp, matcher, infoRead) in cases) {
      test(name, () async {
        final local = createVaultFolder('om96_keep_');
        final h = await hostedContainer(
          recents: [LocalVaultRef(local.path), seedHostedRef],
          lastVault: LocalVaultRef(local.path),
        );
        setUp(h.first);

        final outcome = await h.controller.openVault(seedHostedRef);

        expect(outcome, matcher);
        expect(outcome, isA<HostedVaultOpenFailure>());
        outcome as HostedVaultOpenFailure;
        expect(outcome.vault, seedHostedRef);
        expect(outcome.serverName, 'nas');
        expect(h.read(currentVaultProvider), isNull);
        expect(h.read(vaultAccessProvider), isNull);
        final settings = h.read(settingsProvider);
        expect(settings.recentRefs, [LocalVaultRef(local.path), seedHostedRef]);
        expect(settings.lastVaultRef, LocalVaultRef(local.path));
        expect(
          h.read(recentRowOutcomeProvider(seedHostedRef)),
          isA<RecentRowFailed>().having((r) => r.failure, 'failure', outcome),
        );
        final infoReads = h.first.server.requests
            .where((r) => r.url.path == '/vaults/seed/api/v1/info')
            .length;
        if (!infoRead) expect(infoReads, 0, reason: 'probe failed first');
      });
    }

    test(
      'no response within 10 seconds gives unreachable and opens nothing',
      () async {
        final h = await hostedContainer();
        h.first.server.failure = FakeServerFailure.timeout;

        VaultOpenOutcome? outcome;
        unawaited(
          h.controller.openVault(seedHostedRef).then((o) => outcome = o),
        );
        await _drain();
        h.clock.advance(const Duration(seconds: 9));
        await _drain();
        expect(outcome, isNull, reason: 'still waiting at 9 s');

        h.clock.advance(const Duration(seconds: 1));
        await _drain();

        expect(outcome, _failed<HostedServerUnreachable>("can't reach nas"));
        expect(h.read(currentVaultProvider), isNull);
        expect(h.read(settingsProvider).recentRefs, isEmpty);
      },
    );

    test(
      'a failed open keeps the hosted vault that was already open',
      () async {
        final studio = _studio();
        final h = await hostedContainer(
          servers: [HostedServerFixture(), studio],
        );
        await h.controller.openVault(seedHostedRef);
        final access = h.read(vaultAccessProvider);
        studio.server.failure = FakeServerFailure.refused;

        final outcome = await h.controller.openVault(studio.ref('work'));

        expect(outcome, _failed<HostedServerUnreachable>("can't reach studio"));
        expect(h.read(currentVaultProvider), seedHostedRef);
        expect(identical(h.read(vaultAccessProvider), access), isTrue);
        expect(h.read(settingsProvider).lastVaultRef, seedHostedRef);
      },
    );
  });

  group('launch reopen of a hosted last vault (AC5)', () {
    test(
      'launchReopen with a hosted last vault opens it through the hosted open path',
      () async {
        final h = await hostedContainer(
          recents: [seedHostedRef],
          lastVault: seedHostedRef,
        );
        expect(h.read(currentVaultProvider), isNull);

        final outcome = await h.controller.launchReopen();

        expect(
          outcome,
          isA<VaultOpened>().having((o) => o.vault, 'vault', seedHostedRef),
        );
        expect(h.read(currentVaultProvider), seedHostedRef);
        expect(h.first.server.requests.take(2).map(_line), [
          'GET http://nas.local:7878/api/v1/info',
          'GET http://nas.local:7878/vaults/seed/api/v1/info',
        ]);
        expect(h.read(vaultAccessProvider), isA<HostedVaultAccess>());
      },
    );

    test(
      'while launch reopen runs the hosted row outcome is opening',
      () async {
        final h = await hostedContainer(
          recents: [seedHostedRef],
          lastVault: seedHostedRef,
        );
        h.first.server.hold();

        final reopen = h.controller.launchReopen();
        await _drain();
        expect(
          h.read(recentRowOutcomeProvider(seedHostedRef)),
          isA<RecentRowOpening>(),
        );

        h.first.server.release();
        await reopen;
        expect(h.read(recentRowOutcomeProvider(seedHostedRef)), isNull);
      },
    );

    test(
      'a hosted last vault that cannot open leaves no vault open with the row outcome recorded',
      () async {
        final h = await hostedContainer(
          recents: [seedHostedRef],
          lastVault: seedHostedRef,
        );
        h.first.server.token = 'rotated-on-the-server';

        final outcome = await h.controller.launchReopen();

        expect(outcome, isA<HostedTokenRejected>());
        expect(h.read(currentVaultProvider), isNull);
        expect(
          h.read(recentRowOutcomeProvider(seedHostedRef)),
          isA<RecentRowFailed>().having(
            (r) => r.failure,
            'failure',
            isA<HostedTokenRejected>(),
          ),
        );
        // Launch writes no settings: the hosted entry stays the last vault.
        expect(h.read(settingsProvider).lastVaultRef, seedHostedRef);
        expect(h.read(settingsProvider).recentRefs, [seedHostedRef]);
      },
    );

    testWidgets('at launch a hosted last vault opens the workspace', (
      tester,
    ) async {
      final h = await pumpHostedApp(
        tester,
        recents: [seedHostedRef],
        lastVault: seedHostedRef,
      );
      await pumpFrames(tester, frames: 10);

      expect(h.read(currentVaultProvider), seedHostedRef);
      expect(find.byType(Workspace), findsOneWidget);
    });

    testWidgets(
      'at launch a hosted last vault that cannot be reached shows the picker with the row outcome recorded',
      (tester) async {
        final server = HostedServerFixture();
        server.server.failure = FakeServerFailure.refused;
        final h = await pumpHostedApp(
          tester,
          servers: [server],
          recents: [seedHostedRef],
          lastVault: seedHostedRef,
        );
        await pumpFrames(tester, frames: 10);

        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(find.byType(Workspace), findsNothing);
        expect(h.read(currentVaultProvider), isNull);
        expect(
          server.server.requests.map((r) => r.url.path),
          contains('/api/v1/info'),
          reason: 'launch ran the hosted open path',
        );
        expect(
          h.read(recentRowOutcomeProvider(seedHostedRef)),
          isA<RecentRowFailed>().having(
            (r) => r.failure,
            'failure',
            _failed<HostedServerUnreachable>("can't reach nas"),
          ),
        );
      },
    );
  });

  group('no memex binary (AC6, Req 34)', () {
    test(
      'a hosted vault opens lists opens saves and creates notes with no memex binary',
      () async {
        final h = await hostedContainer(cli: null);
        h.first.serveSave(seedVaultName, _wi96Loose);
        expect(h.read(memexCliProvider), isNull);

        final outcome = await h.controller.openVault(seedHostedRef);
        expect(outcome, isA<VaultOpened>());
        final access = h.read(vaultAccessProvider)!;
        expect(access.canWrite, isTrue);

        final list = await access.notes.listNotes();
        expect(list, isNotEmpty);
        final note = await access.notes.getNote(_wi96PlayerLoop);
        expect(note, isNotNull);
        final saved = await access.notes.updateNote(
          noteId: _wi96Loose,
          expectedVersion: 1,
          contentMd: 'Maybe the map folds like paper?\n\nOr like a fan.\n',
        );
        expect(saved.noteId, _wi96Loose);
        final created = await access.notes.addNote(
          title: 'Fresh Idea',
          tags: const ['idea', 'new'],
          contentMd: 'A fresh idea worth keeping.\n',
        );
        expect(created, isNotEmpty);
        expect(
          h.first.server.requests.map((r) => r.method),
          containsAll(['GET', 'PATCH', 'POST']),
        );
      },
    );

    testWidgets(
      'with a FakeMemexCli present a hosted session records zero CLI calls',
      (tester) async {
        final cli = FakeMemexCli()
          ..on(
            'settings get',
            (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout),
          )
          ..on('vault check', (_) => FakeMemexCli.ok());
        final h = await pumpHostedApp(tester, cli: cli);
        h.first.serveSave(seedVaultName, _wi96Loose);

        await pumpWhile(tester, () => h.controller.openVault(seedHostedRef));
        expect(find.byType(Workspace), findsOneWidget);
        final access = h.read(vaultAccessProvider)!;
        await pumpWhile(tester, () => access.notes.listNotes());
        await pumpWhile(tester, () => access.notes.getNote(_wi96PlayerLoop));
        await pumpWhile(
          tester,
          () => access.notes.updateNote(
            noteId: _wi96Loose,
            expectedVersion: 1,
            contentMd: 'Maybe the map folds like paper?\n\nOr like a fan.\n',
          ),
        );
        await pumpWhile(
          tester,
          () => access.notes.addNote(
            title: 'Fresh Idea',
            tags: const ['idea', 'new'],
            contentMd: 'A fresh idea worth keeping.\n',
          ),
        );
        await pumpFrames(tester);

        expect(cli.calls, isEmpty);
      },
    );
  });

  group('no schema check for hosted vaults (AC7, Req 53)', () {
    testWidgets(
      'a hosted vault below schema 5 opens with no settings get no schema check and no outdated banner',
      (tester) async {
        final server = HostedServerFixture();
        server.serveVault(seedVaultName, schemaVersion: 4);
        final cli = FakeMemexCli()
          ..on(
            'settings get',
            (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout),
          );
        final h = await pumpHostedApp(tester, servers: [server], cli: cli);

        final outcome = await pumpWhile(
          tester,
          () => h.controller.openVault(seedHostedRef),
        );
        expect(outcome, isA<VaultOpened>());
        final open = await pumpWhile(
          tester,
          () => h.read(vaultOpenProvider.future),
        );
        await pumpFrames(tester);

        expect(open.schemaOutdated, isFalse);
        expect(cli.callsFor('settings get'), isEmpty);
        expect(cli.calls, isEmpty);
        expect(find.byKey(const Key('vault-schema-outdated')), findsNothing);
        expect(find.byType(Workspace), findsOneWidget);
        // The server does report 4: the app just does not check it.
        final reported = await pumpWhile(
          tester,
          () => h.read(vaultAccessProvider)!.schemaVersion(),
        );
        expect(reported, 4);
      },
    );

    test(
      'a hosted vault reads as V5 ready since the server owns its migrations',
      () async {
        final h = await hostedContainer();
        await h.controller.openVault(seedHostedRef);

        expect(h.read(vaultV5ReadyProvider), isTrue);
      },
    );
  });

  group('vault gone while open (AC11, Req 53a)', () {
    testWidgets(
      'a vault not found on any request while open returns to the picker at once with the row in its vault gone state',
      (tester) async {
        final h = await pumpHostedApp(tester, recents: [seedHostedRef]);
        await pumpWhile(tester, () => h.controller.openVault(seedHostedRef));
        expect(find.byType(Workspace), findsOneWidget);
        final start = h.clock.now();

        h.first.server.removeVault(seedVaultName);
        await pumpWhile(tester, () async {
          try {
            await h.read(vaultAccessProvider)!.notes.getNote(_wi96PlayerLoop);
          } on Object {
            // vault_not_found reaches the caller as an error too.
          }
          return true;
        });
        await pumpFrames(tester);

        expect(h.clock.now(), start, reason: 'no timer: the clock never moved');
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(find.byType(Workspace), findsNothing);
        expect(h.read(currentVaultProvider), isNull);
        expect(
          h.read(recentRowOutcomeProvider(seedHostedRef)),
          isA<RecentRowFailed>().having(
            (r) => r.failure,
            'failure',
            _failed<HostedVaultGone>('seed is no longer on nas'),
          ),
        );
      },
    );
  });

  group('the access token stays secret (AC12)', () {
    testWidgets(
      'after opening editing and closing a hosted vault the token is in no ref recents prefs ui state file or rendered text',
      (tester) async {
        final token = ['ZQ96', 'secret', 'token', 'value'].join('-');
        final h = await pumpHostedApp(
          tester,
          servers: [HostedServerFixture(token: token)],
          overrides: [
            leaveVaultGuardProvider.overrideWithValue((_) async => true),
          ],
        );
        final seen = <String>[];

        await pumpWhile(tester, () => h.controller.openVault(seedHostedRef));
        expect(find.byType(Workspace), findsOneWidget);
        seen.add('${h.read(currentVaultProvider)}');
        h.read(tabsProvider.notifier).openOrFocus(const NoteTab(_wi96Loose));
        // Unawaited, as the sidebar does; settleHosted lets the write land.
        h.read(sidebarModeProvider.notifier).select(SidebarMode.topics);
        h.first.serveSave(seedVaultName, _wi96Loose);
        await pumpWhile(
          tester,
          () => h
              .read(vaultAccessProvider)!
              .notes
              .updateNote(
                noteId: _wi96Loose,
                expectedVersion: 1,
                contentMd:
                    'Maybe the map folds like paper?\n\nOr like a fan.\n',
              ),
        );
        await settleHosted(tester);
        expect(find.textContaining(token), findsNothing);

        final context = tester.element(find.byType(Workspace));
        await pumpWhile(tester, () => h.controller.leaveVault(context));
        await settleHosted(tester);
        expect(find.byType(VaultPickerScreen), findsOneWidget);

        final settings = h.read(settingsProvider);
        seen
          ..add('${h.read(currentVaultProvider)}')
          ..addAll(settings.recentRefs.map((r) => '$r'))
          ..add('${settings.lastVaultRef}')
          ..addAll(
            settings.savedServers.map((s) => '${s.id} ${s.name} ${s.url}'),
          );
        for (final text in seen) {
          expect(text, isNot(contains(token)));
        }
        final prefs = await tester.runAsync(
          () => prefsEntriesContaining(token),
        );
        expect(prefs, isEmpty);
        final files = h.appSupportFiles();
        expect(files, isNotEmpty, reason: 'the session wrote its UI state');
        for (final f in files) {
          final body = File(p.join(h.appSupport.path, f)).readAsStringSync();
          expect(body, isNot(contains(token)), reason: f);
        }
        expect(find.textContaining(token), findsNothing);
        for (final t in h.windowTitle.titles) {
          expect(t, isNot(contains(token)));
        }
      },
    );
  });

  group('native window title (Lead decision L21)', () {
    testWidgets(
      'the window title reads vault and server for a hosted vault the folder name for a local vault and memex on the picker',
      (tester) async {
        final local = createVaultFolder('om96_title_');
        final cli = FakeMemexCli()
          ..on('vault check', (_) => FakeMemexCli.ok())
          ..on(
            'settings get',
            (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout),
          );
        final h = await pumpHostedApp(
          tester,
          cli: cli,
          recents: [LocalVaultRef(local.path)],
          overrides: [
            leaveVaultGuardProvider.overrideWithValue((_) async => true),
          ],
        );
        expect(h.windowTitle.current, 'memex');

        await pumpWhile(tester, () => h.controller.openVault(seedHostedRef));
        expect(h.windowTitle.current, 'seed · nas');

        await pumpWhile(
          tester,
          () => h.controller.openVault(LocalVaultRef(local.path)),
        );
        expect(h.read(currentVaultProvider), LocalVaultRef(local.path));
        expect(h.windowTitle.current, p.basename(local.path));

        final context = tester.element(find.byType(Workspace));
        await pumpWhile(tester, () => h.controller.leaveVault(context));
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(h.windowTitle.current, 'memex');
        for (final t in h.windowTitle.titles) {
          expect(t, isNot(contains('●')));
        }
      },
    );
  });
}
