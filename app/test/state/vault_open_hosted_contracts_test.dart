// WI #96 (verify mode): the contracts of the hosted open path that the
// implementer handoff listed as unpinned, plus the lead rulings on vault
// gone and concurrent opens. The composite (HostedVaultAccess) refuses every
// request once disposed and reports vault_not_found from any domain; the
// hosted branch of vaultAccessProvider, vaultOpenProvider, uiStateStoreProvider
// and windowTitleTextProvider; the typed failures the handoff named.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/app_support_dir.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/token_store.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_client.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:path/path.dart' as p;

import '../support/api_fixtures.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_server.dart';
import '../support/hosted_harness.dart';
import '../support/token_store_fakes.dart';
import '../support/vault_folders.dart';

const _wi96Unsaved =
    'this vault server is no longer saved. add it again to open its vaults.';

HostedServerFixture _wi96Studio() => HostedServerFixture(
  id: 'srv-studio',
  name: 'studio',
  url: 'http://studio.local:9000',
  token: 'studio-token-96',
  vaultName: 'work',
);

/// A token store whose reads fail (a locked Keychain).
class _Wi96ThrowingTokenStore extends FakeTokenStore {
  _Wi96ThrowingTokenStore(super.initial);

  @override
  Future<String?> read(String serverId) async {
    calls.add('read $serverId');
    throw StateError('keychain locked');
  }
}

Future<void> _wi96Drain() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// One request per domain of [a], plus the shared client's own calls.
Map<String, Future<Object?> Function()> _wi96Calls(HostedVaultAccess a) => {
  'notes': () => a.notes.listNotes(),
  'daily': () => a.daily.dailyNotes(),
  'topics': () => a.topics.smartFolders(),
  'canvas': () => a.canvas.listCanvases(),
  'graph': () => a.graph.graphNotes(),
  'revision': a.revision,
  'schemaVersion': a.schemaVersion,
};

/// A composite over the default fake server (nas, vault seed), counting
/// onVaultGone calls in [gone].
Future<(HostedHarness, HostedVaultAccess)> _wi96Composite(
  List<int> gone, {
  bool withCallback = true,
}) async {
  final h = await hostedContainer();
  final access = HostedVaultAccess(
    client: h.first.server.connect(h.container),
    vaultName: seedVaultName,
    onVaultGone: withCallback ? () => gone.add(1) : null,
  );
  return (h, access);
}

void main() {
  group('the hosted composite (handoff contracts)', () {
    test(
      'every domain of one composite shares one client that forwards the server id and name',
      () async {
        final (_, a) = await _wi96Composite([]);
        final client = a.notes.client;
        for (final c in [
          a.daily.client,
          a.topics.client,
          a.canvas.client,
          a.graph.client,
        ]) {
          expect(identical(c, client), isTrue);
        }
        expect(client.serverId, fakeServerId);
        expect(client.serverName, fakeServerName);
        expect(a.vaultName, seedVaultName);
      },
    );

    test(
      'a live composite forwards probeServer and serverRequest to the open client',
      () async {
        final (h, a) = await _wi96Composite([]);

        final probe = await a.notes.client.probeServer();
        final info = await a.notes.client.serverRequest(
          'GET',
          '/info',
          operation: 'probe',
        );
        final vault = await a.notes.client.vaultRequest(
          'GET',
          seedVaultName,
          '/info',
          operation: 'info',
        );

        expect(probe.kind, ServerProbeKind.connected);
        expect(info['api_version'], 1);
        expect(vault['name'], seedVaultName);
        expect(h.first.server.requests.map((r) => r.url.path), [
          '/api/v1/info',
          '/api/v1/info',
          '/vaults/seed/api/v1/info',
        ]);
      },
    );

    test(
      'a disposed composite refuses every request with a StateError and sends nothing',
      () async {
        final (h, a) = await _wi96Composite([]);
        a.dispose();
        final calls = {
          ..._wi96Calls(a),
          'probeServer': () => a.notes.client.probeServer(),
          'serverRequest': () =>
              a.notes.client.serverRequest('GET', '/info', operation: 'probe'),
          'vaultRequest': () => a.notes.client.vaultRequest(
            'GET',
            seedVaultName,
            '/info',
            operation: 'info',
          ),
        };
        for (final MapEntry(key: name, value: call) in calls.entries) {
          await expectLater(
            call(),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                contains('this hosted vault is no longer open'),
              ),
            ),
            reason: name,
          );
        }
        expect(h.first.server.requests, isEmpty);
      },
    );

    final domains = <(String, String)>[
      (
        'notes',
        'a vault not found from the notes domain calls onVaultGone once and still reaches the caller',
      ),
      (
        'daily',
        'a vault not found from the daily domain calls onVaultGone once and still reaches the caller',
      ),
      (
        'topics',
        'a vault not found from the topics domain calls onVaultGone once and still reaches the caller',
      ),
      (
        'canvas',
        'a vault not found from the canvas domain calls onVaultGone once and still reaches the caller',
      ),
      (
        'graph',
        'a vault not found from the graph domain calls onVaultGone once and still reaches the caller',
      ),
      (
        'revision',
        'a vault not found from the revision call calls onVaultGone once and still reaches the caller',
      ),
      (
        'schemaVersion',
        'a vault not found from the schema version call calls onVaultGone once and still reaches the caller',
      ),
    ];
    for (final (domain, name) in domains) {
      test(name, () async {
        final gone = <int>[];
        final (h, a) = await _wi96Composite(gone);
        h.first.server.removeVault(seedVaultName);

        await expectLater(
          _wi96Calls(a)[domain]!(),
          throwsA(
            isA<MemexException>().having(
              (e) => e.code,
              'code',
              vaultNotFoundCode,
            ),
          ),
        );
        expect(gone, hasLength(1));
      });
    }

    test('a vault not found on a server request calls onVaultGone', () async {
      final gone = <int>[];
      final (h, a) = await _wi96Composite(gone);
      h.first.server.route(
        'GET',
        '/api/v1/odd',
        status: 404,
        json: {
          'error': {'code': vaultNotFoundCode, 'message': 'no such vault'},
        },
      );

      await expectLater(
        a.notes.client.serverRequest('GET', '/odd', operation: 'odd'),
        throwsA(isA<MemexException>()),
      );
      expect(gone, hasLength(1));
    });

    test('other errors from a live composite never call onVaultGone', () async {
      final gone = <int>[];
      final (h, a) = await _wi96Composite(gone);

      // 401: a MemexException with another code.
      h.first.server.token = 'rotated-on-the-server';
      for (final MapEntry(key: name, value: call) in _wi96Calls(a).entries) {
        await expectLater(
          call(),
          throwsA(
            isA<MemexException>().having(
              (e) => e.code,
              'code',
              isNot(vaultNotFoundCode),
            ),
          ),
          reason: name,
        );
      }
      // A refused connection: not a MemexException at all.
      h.first.server.failure = FakeServerFailure.refused;
      await expectLater(
        a.notes.listNotes(),
        throwsA(isA<VaultUnreachableException>()),
      );
      expect(gone, isEmpty);
    });

    test(
      'a vault not found answered after dispose does not call onVaultGone',
      () async {
        final gone = <int>[];
        final (h, a) = await _wi96Composite(gone);
        h.first.server
          ..removeVault(seedVaultName)
          ..hold();

        final inFlight = a.notes.listNotes();
        await _wi96Drain();
        a.dispose();
        h.first.server.release();

        await expectLater(inFlight, throwsA(isA<MemexException>()));
        expect(gone, isEmpty);
      },
    );

    test(
      'a composite with no onVaultGone still rethrows a vault not found',
      () async {
        final (h, a) = await _wi96Composite([], withCallback: false);
        h.first.server.removeVault(seedVaultName);

        await expectLater(
          a.graph.graphNotes(),
          throwsA(
            isA<MemexException>().having(
              (e) => e.code,
              'code',
              vaultNotFoundCode,
            ),
          ),
        );
      },
    );
  });

  group('the hosted branch of vaultAccessProvider (handoff contracts)', () {
    test(
      'vaultAccessProvider gives null for a hosted ref with no session or a session of another vault',
      () async {
        final studio = _wi96Studio();
        final h = await hostedContainer(
          servers: [HostedServerFixture(), studio],
        );
        h.read(currentVaultProvider.notifier).state = seedHostedRef;
        expect(h.read(hostedSessionProvider), isNull);
        expect(h.read(vaultAccessProvider), isNull);

        await h.controller.openVault(studio.ref('work'));
        expect(h.read(vaultAccessProvider), isA<HostedVaultAccess>());

        // The session is the studio open's; seed has none of its own.
        h.read(currentVaultProvider.notifier).state = seedHostedRef;
        expect(h.read(hostedSessionProvider)!.vault, studio.ref('work'));
        expect(h.read(vaultAccessProvider), isNull);
      },
    );

    test(
      'reopening the open hosted vault replaces the session and disposes the old composite',
      () async {
        final h = await hostedContainer();
        await h.controller.openVault(seedHostedRef);
        final session = h.read(hostedSessionProvider);
        final old = h.read(vaultAccessProvider)!;

        await h.controller.openVault(seedHostedRef);

        expect(identical(h.read(hostedSessionProvider), session), isFalse);
        final next = h.read(vaultAccessProvider)!;
        expect(identical(next, old), isFalse);
        final before = h.router.sent.length;
        await expectLater(old.revision(), throwsA(isA<StateError>()));
        expect(h.router.sent.length, before);
        expect(await next.revision(), isNotEmpty);
      },
    );

    test(
      'reopening the open hosted vault with an equal ref does not notify currentVaultProvider listeners',
      () async {
        final h = await hostedContainer();
        await h.controller.openVault(seedHostedRef);
        final changes = <VaultRef?>[];
        h.container.listen(
          currentVaultProvider,
          (_, next) => changes.add(next),
        );

        final equal = HostedVaultRef(fakeServerId, ['se', 'ed'].join());
        expect(identical(equal, seedHostedRef), isFalse);
        final outcome = await h.controller.openVault(equal);

        expect(outcome, isA<VaultOpened>());
        expect(changes, isEmpty);
        expect(h.read(currentVaultProvider), seedHostedRef);
      },
    );

    test(
      'the session string names the vault but never the access token',
      () async {
        final h = await hostedContainer();
        await h.controller.openVault(seedHostedRef);

        final text = '${h.read(hostedSessionProvider)}';
        expect(text, contains(seedVaultName));
        expect(text, isNot(contains(fakeServerToken)));
      },
    );
  });

  group('hosted open failures (handoff contracts)', () {
    test(
      'an unsaved server open records a plain failure row with the no longer saved copy',
      () async {
        final h = await hostedContainer();
        const gone = HostedVaultRef('srv-gone', 'seed');

        final outcome = await h.controller.openVault(gone);

        expect(
          outcome,
          isA<VaultOpenFailure>()
              .having((o) => o.message, 'message', _wi96Unsaved)
              .having((o) => o is HostedVaultOpenFailure, 'hosted', isFalse),
        );
        expect(
          h.read(recentRowOutcomeProvider(gone)),
          isA<RecentRowFailed>().having((r) => r.failure, 'failure', outcome),
        );
      },
    );

    test(
      'a token store read that throws gives token rejected and sends no request',
      () async {
        final h = await hostedContainer(
          overrides: [
            tokenStoreProvider.overrideWithValue(
              _Wi96ThrowingTokenStore({fakeServerId: fakeServerToken}),
            ),
          ],
        );

        final outcome = await h.controller.openVault(seedHostedRef);

        expect(
          outcome,
          isA<HostedTokenRejected>().having(
            (o) => o.message,
            'message',
            'nas rejected the access token',
          ),
        );
        expect(h.router.sent, isEmpty);
        expect(h.read(currentVaultProvider), isNull);
      },
    );

    test(
      'an empty stored token gives token rejected and sends no request',
      () async {
        final h = await hostedContainer(
          servers: [HostedServerFixture(storedToken: '')],
        );

        final outcome = await h.controller.openVault(seedHostedRef);

        expect(outcome, isA<HostedTokenRejected>());
        expect(h.router.sent, isEmpty);
      },
    );

    final nonC1 = <(String, int, String, String, String)>[
      (
        'a non C1 5xx on the vault info route gives schema refused with the HTTP status',
        502,
        '<html>bad gateway</html>',
        'text/html',
        'HTTP 502',
      ),
      (
        'a non object body on the vault info route gives schema refused with that error text',
        200,
        '[1, 2]',
        'application/json',
        'the server response is not a JSON object',
      ),
    ];
    for (final (name, status, body, type, text) in nonC1) {
      test(name, () async {
        final h = await hostedContainer();
        h.first.server.route(
          'GET',
          '/vaults/seed/api/v1/info',
          status: status,
          body: body,
          contentType: type,
        );

        final outcome = await h.controller.openVault(seedHostedRef);

        expect(
          outcome,
          isA<HostedSchemaRefused>().having((o) => o.message, 'message', text),
        );
        expect(h.read(currentVaultProvider), isNull);
      });
    }

    test(
      'a 401 on the vault info route after a connected probe gives token rejected',
      () async {
        final h = await hostedContainer();
        h.first.server.route(
          'GET',
          '/vaults/seed/api/v1/info',
          status: 401,
          json: {
            'error': {'code': 'unauthorized', 'message': 'token revoked'},
          },
        );

        final outcome = await h.controller.openVault(seedHostedRef);

        expect(
          outcome,
          isA<HostedTokenRejected>().having(
            (o) => o.message,
            'message',
            'nas rejected the access token',
          ),
        );
        expect(h.first.server.requests.map((r) => r.url.path), [
          '/api/v1/info',
          '/vaults/seed/api/v1/info',
        ]);
      },
    );

    test(
      'a vault info read that cannot reach the server after a connected probe gives unreachable',
      () async {
        final h = await hostedContainer();
        // The response hook marks nas connected after the probe; the info
        // read that follows is refused.
        h.container.listen(hostedConnectionStatusProvider(fakeServerId), (
          _,
          status,
        ) {
          if (status == HostedConnectionStatus.connected) {
            h.first.server.failure = FakeServerFailure.refused;
          }
        });

        final outcome = await h.controller.openVault(seedHostedRef);

        expect(
          outcome,
          isA<HostedServerUnreachable>().having(
            (o) => o.message,
            'message',
            "can't reach nas",
          ),
        );
        expect(h.first.server.requests.map((r) => r.url.path), [
          '/api/v1/info',
          '/vaults/seed/api/v1/info',
        ]);
        expect(h.read(currentVaultProvider), isNull);
      },
    );
  });

  group('vault gone while open (lead ruling, handoff contracts)', () {
    test(
      'the open hosted vault going away clears the last vault so launch does not reopen it',
      () async {
        final h = await hostedContainer(recents: [seedHostedRef]);
        await h.controller.openVault(seedHostedRef);
        h.read(selectedNoteIdProvider.notifier).state = 'n1';
        expect(h.read(settingsProvider).lastVaultRef, seedHostedRef);

        h.first.server.removeVault(seedVaultName);
        await expectLater(
          h.read(vaultAccessProvider)!.notes.listNotes(),
          throwsA(isA<MemexException>()),
        );
        await _wi96Drain();

        expect(h.read(currentVaultProvider), isNull);
        expect(h.read(selectedNoteIdProvider), isNull);
        expect(h.read(settingsProvider).lastVaultRef, isNull);
        expect(h.read(settingsProvider).recentRefs, [seedHostedRef]);
        expect(await h.controller.launchReopen(), isA<NoVaultToReopen>());
        final relaunched = await relaunchSettings(tokenStore: h.tokens);
        expect(relaunched.state.lastVaultRef, isNull);
      },
    );

    test(
      'a vault gone report for a vault that is no longer current changes nothing',
      () async {
        final studio = _wi96Studio();
        final h = await hostedContainer(
          servers: [HostedServerFixture(), studio],
        );
        await h.controller.openVault(seedHostedRef);
        await h.controller.openVault(studio.ref('work'));

        await h.controller.hostedVaultGoneWhileOpen(seedHostedRef);

        expect(h.read(currentVaultProvider), studio.ref('work'));
        expect(h.read(settingsProvider).lastVaultRef, studio.ref('work'));
        expect(h.read(recentRowOutcomeProvider(seedHostedRef)), isNull);
      },
    );

    test(
      'a vault gone report keeps a last vault that is another vault',
      () async {
        final local = createVaultFolder('om96_gone_last_');
        final h = await hostedContainer(
          recents: [LocalVaultRef(local.path), seedHostedRef],
          lastVault: LocalVaultRef(local.path),
          current: seedHostedRef,
        );

        await h.controller.hostedVaultGoneWhileOpen(seedHostedRef);

        expect(h.read(currentVaultProvider), isNull);
        expect(
          h.read(settingsProvider).lastVaultRef,
          LocalVaultRef(local.path),
        );
        expect(
          h.read(recentRowOutcomeProvider(seedHostedRef)),
          isA<RecentRowFailed>().having(
            (r) => r.failure,
            'failure',
            isA<HostedVaultGone>()
                .having((f) => f.message, 'message', 'seed is no longer on nas')
                .having((f) => f.serverName, 'serverName', 'nas')
                .having((f) => f.vault, 'vault', seedHostedRef),
          ),
        );
      },
    );

    test(
      'a vault gone report picks the saved server of that vault for its copy',
      () async {
        final studio = _wi96Studio();
        final h = await hostedContainer(
          servers: [HostedServerFixture(), studio],
          current: studio.ref('work'),
        );

        await h.controller.hostedVaultGoneWhileOpen(studio.ref('work'));

        expect(
          h.read(recentRowOutcomeProvider(studio.ref('work'))),
          isA<RecentRowFailed>().having(
            (r) => r.failure.message,
            'message',
            'work is no longer on studio',
          ),
        );
      },
    );

    test(
      'a vault gone report for an unsaved server names the server by its id',
      () async {
        const orphan = HostedVaultRef('srv-orphan', 'seed');
        final h = await hostedContainer(current: orphan);

        await h.controller.hostedVaultGoneWhileOpen(orphan);

        expect(h.read(currentVaultProvider), isNull);
        expect(
          h.read(recentRowOutcomeProvider(orphan)),
          isA<RecentRowFailed>().having(
            (r) => r.failure.message,
            'message',
            'seed is no longer on srv-orphan',
          ),
        );
      },
    );

    test(
      'a vault gone report that loses the race to another open leaves the new vault open',
      () async {
        final studio = _wi96Studio();
        final h = await hostedContainer(
          servers: [HostedServerFixture(), studio],
        );
        await h.controller.openVault(seedHostedRef);

        // Runs up to its last-vault write, then another vault opens.
        final report = h.controller.hostedVaultGoneWhileOpen(seedHostedRef);
        h.read(currentVaultProvider.notifier).state = studio.ref('work');
        h.read(selectedNoteIdProvider.notifier).state = 'n1';
        await report;

        expect(h.read(currentVaultProvider), studio.ref('work'));
        expect(h.read(selectedNoteIdProvider), 'n1');
      },
    );
  });

  group('concurrent hosted opens (lead ruling)', () {
    test(
      'a later hosted open wins over an earlier open that completes after it',
      () async {
        final studio = _wi96Studio();
        final h = await hostedContainer(
          servers: [HostedServerFixture(), studio],
        );
        studio.server.hold();

        final earlier = h.controller.openVault(studio.ref('work'));
        await _wi96Drain();
        final later = await h.controller.openVault(seedHostedRef);
        expect(later, isA<VaultOpened>());
        expect(h.read(currentVaultProvider), seedHostedRef);

        studio.server.release();
        await earlier;
        await _wi96Drain();

        expect(h.read(currentVaultProvider), seedHostedRef);
        expect(h.read(settingsProvider).lastVaultRef, seedHostedRef);
        expect(h.read(hostedSessionProvider)!.vault, seedHostedRef);
        expect(h.read(recentRowOutcomeProvider(seedHostedRef)), isNull);
      },
    );

    test(
      'an earlier open of the same vault that fails after a later open succeeded keeps the later row outcome',
      () async {
        final h = await hostedContainer();
        h.first.server.failure = FakeServerFailure.timeout;

        VaultOpenOutcome? first;
        unawaited(h.controller.openVault(seedHostedRef).then((o) => first = o));
        await _wi96Drain();
        h.first.server.failure = null;
        final second = await h.controller.openVault(seedHostedRef);
        expect(second, isA<VaultOpened>());
        expect(h.read(recentRowOutcomeProvider(seedHostedRef)), isNull);

        h.clock.advance(const Duration(seconds: 10));
        await _wi96Drain();

        expect(first, isNotNull, reason: 'the earlier open timed out');
        expect(h.read(currentVaultProvider), seedHostedRef);
        expect(h.read(recentRowOutcomeProvider(seedHostedRef)), isNull);
      },
    );

    test(
      'a local open that lands while a hosted open is running wins and the hosted open returns cancelled',
      () async {
        final local = createVaultFolder('om96_local_wins_');
        final localRef = LocalVaultRef(local.path);
        final cli = FakeMemexCli()..on('vault check', (_) => FakeMemexCli.ok());
        final h = await hostedContainer(cli: cli);
        h.first.server.hold();

        final hosted = h.controller.openVault(seedHostedRef);
        await _wi96Drain();
        expect(await h.controller.openVault(localRef), isA<VaultOpened>());
        expect(h.read(currentVaultProvider), localRef);

        h.first.server.release();
        expect(await hosted, isA<VaultOpenCancelled>());
        await _wi96Drain();

        expect(h.read(currentVaultProvider), localRef);
        expect(h.read(settingsProvider).lastVaultRef, localRef);
        expect(h.read(settingsProvider).recentRefs, [localRef]);
        expect(h.read(hostedSessionProvider), isNull);
        expect(
          h.read(recentRowOutcomeProvider(seedHostedRef)),
          isNot(isA<RecentRowFailed>()),
        );
      },
    );

    test(
      'a hosted open superseded during its remember step sets no session or current vault',
      () async {
        final studio = _wi96Studio();
        final h = await hostedContainer(
          servers: [HostedServerFixture(), studio],
        );
        // When the earlier open has remembered studio (its last settings
        // write), a later open of seed starts and is held at its probe.
        Future<VaultOpenOutcome>? later;
        h.container.listen(settingsProvider, (_, next) {
          if (later == null && next.lastVaultRef == studio.ref('work')) {
            h.first.server.hold();
            later = h.controller.openVault(seedHostedRef);
          }
        });

        final earlier = await h.controller.openVault(studio.ref('work'));

        expect(later, isNotNull, reason: 'the later open started');
        expect(earlier, isA<VaultOpenCancelled>());
        expect(h.read(currentVaultProvider), isNull);
        expect(h.read(hostedSessionProvider), isNull);
        expect(
          h.read(recentRowOutcomeProvider(studio.ref('work'))),
          isNot(isA<RecentRowFailed>()),
        );

        h.first.server.release();
        expect(await later, isA<VaultOpened>());
        expect(h.read(currentVaultProvider), seedHostedRef);
        expect(h.read(hostedSessionProvider)!.vault, seedHostedRef);
        expect(h.read(settingsProvider).lastVaultRef, seedHostedRef);
      },
    );

    test(
      'a superseded hosted open that fails afterwards returns cancelled and records no failure on its row',
      () async {
        final studio = _wi96Studio();
        final h = await hostedContainer(
          servers: [HostedServerFixture(), studio],
        );
        studio.server.failure = FakeServerFailure.timeout;

        VaultOpenOutcome? first;
        unawaited(
          h.controller.openVault(studio.ref('work')).then((o) => first = o),
        );
        await _wi96Drain();
        expect(await h.controller.openVault(seedHostedRef), isA<VaultOpened>());

        h.clock.advance(const Duration(seconds: 10));
        await _wi96Drain();

        expect(first, isA<VaultOpenCancelled>());
        expect(
          h.read(recentRowOutcomeProvider(studio.ref('work'))),
          isNot(isA<RecentRowFailed>()),
        );
        expect(h.read(currentVaultProvider), seedHostedRef);
        expect(h.read(hostedSessionProvider)!.vault, seedHostedRef);
        expect(h.read(recentRowOutcomeProvider(seedHostedRef)), isNull);
      },
    );
  });

  group('no schema check for hosted vaults (handoff contracts)', () {
    test(
      'a hosted vault open state does not rerun when the memex binary changes',
      () async {
        final h = await hostedContainer();
        await h.controller.openVault(seedHostedRef);
        final states = <AsyncValue<VaultOpenState>>[];
        h.container.listen(
          vaultOpenProvider,
          (_, next) => states.add(next),
          fireImmediately: true,
        );
        await h.read(vaultOpenProvider.future);
        states.clear();

        await h.read(settingsProvider.notifier).setMemexBinary('other-memex');
        await _wi96Drain();
        h.read(vaultOpenProvider);
        await _wi96Drain();

        expect(states, isEmpty);
        expect(h.read(vaultOpenProvider).value?.schemaOutdated, isFalse);
      },
    );

    test('a hosted vault reads as V5 ready with no database', () async {
      final h = await hostedContainer(current: seedHostedRef);

      expect(h.read(vaultDbProvider), isNull);
      expect(h.read(vaultV5ReadyProvider), isTrue);
    });
  });

  group('hosted UI state location (handoff contracts)', () {
    test(
      'hostedUiStateDir encodes the server id and vault name as one path segment each',
      () {
        expect(
          hostedUiStateDir('/support', 'srv/a b', 'my vault/x'),
          p.join('/support', 'hosted', 'srv%2Fa%20b', 'my%20vault%2Fx'),
        );
        expect(
          hostedUiStateDir('/support', 'srv-nas', 'seed'),
          p.join('/support', 'hosted', 'srv-nas', 'seed'),
        );
      },
    );

    test(
      'the hosted UI state store sits under the encoded app support path',
      () async {
        const odd = HostedVaultRef('srv/x', 'a b');
        final h = await hostedContainer(current: odd);

        expect(
          h.read(uiStateStoreProvider)!.vaultPath,
          p.join(h.appSupport.path, 'hosted', 'srv%2Fx', 'a%20b'),
        );
      },
    );

    test(
      'uiStateStoreProvider gives no store for a hosted vault while the app support dir is unset',
      () {
        final c = ProviderContainer(
          overrides: [currentVaultProvider.overrideWith((_) => seedHostedRef)],
        );
        addTearDown(c.dispose);

        expect(c.read(uiStateStoreProvider), isNull);
        expect(() => c.read(appSupportDirProvider), throwsUnimplementedError);
      },
    );

    test(
      'uiStateStoreProvider still gives a local vault its own store with no app support dir',
      () {
        final local = createVaultFolder('om96_local_store_');
        final c = ProviderContainer(
          overrides: [
            currentVaultProvider.overrideWith((_) => LocalVaultRef(local.path)),
          ],
        );
        addTearDown(c.dispose);

        expect(c.read(uiStateStoreProvider)!.vaultPath, local.path);
      },
    );
  });

  group('window title (handoff contracts)', () {
    test(
      'the window title of a hosted vault on an unsaved server is the vault name',
      () async {
        final h = await hostedContainer(
          current: const HostedVaultRef('srv-orphan', 'seed'),
        );

        expect(h.read(windowTitleTextProvider), 'seed');
      },
    );

    test(
      'the window title names the saved server of the open hosted vault',
      () async {
        final studio = _wi96Studio();
        final h = await hostedContainer(
          servers: [HostedServerFixture(), studio],
          current: studio.ref('work'),
        );

        expect(h.read(windowTitleTextProvider), 'work · studio');
      },
    );
  });

  group('switchToVault takes any VaultRef (handoff contracts)', () {
    testWidgets(
      'switchToVault of a hosted ref runs the hosted open and clears the selected note',
      (tester) async {
        final studio = _wi96Studio();
        final h = await pumpHostedApp(
          tester,
          servers: [HostedServerFixture(), studio],
          overrides: [
            leaveVaultGuardProvider.overrideWithValue((_) async => true),
          ],
        );
        await pumpWhile(tester, () => h.controller.openVault(seedHostedRef));
        h.read(selectedNoteIdProvider.notifier).state = 'n1';
        final context = tester.element(find.byType(Scaffold).first);

        final outcome = await pumpWhile(
          tester,
          () => h.controller.switchToVault(context, studio.ref('work')),
        );

        expect(outcome, isA<VaultOpened>());
        expect(h.read(currentVaultProvider), studio.ref('work'));
        expect(h.read(selectedNoteIdProvider), isNull);
        expect(studio.server.requests.take(2).map((r) => r.url.path), [
          '/api/v1/info',
          '/vaults/work/api/v1/info',
        ]);
      },
    );
  });
}
