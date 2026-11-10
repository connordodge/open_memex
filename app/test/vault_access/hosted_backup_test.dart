// WI #322 (A1, D21): `ClientHostedBackupApi` over `HostedClient.vaultRequest`
// against the fake vault server and the frozen `api_v1/backup`,
// `api_v1/backup_off` and `api_v1/compat` rows (R0 owns them). GET and POST
// `/vaults/<name>/api/v1/backup`; 200 and 202 are success; 409
// `backup_in_progress` and `backups_not_configured` and 404 `not_found` are
// results; 404 `vault_not_found` and every other refusal rethrow the client's
// own exception; an unreachable server throws `VaultUnreachableException`.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/hosted/backup.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_client.dart';
import 'package:path/path.dart' as p;

import '../support/api_fixtures.dart';
import '../support/fake_clock.dart';
import '../support/fake_vault_server.dart';

const _statusPath = '/vaults/seed/api/v1/backup';

DateTime _ms(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

class _Env {
  _Env(this.server, this.container, this.clock);

  final FakeVaultServer server;
  final ProviderContainer container;
  final FakeClock clock;

  HostedClient client() => server.connect(container);

  ClientHostedBackupApi api([String vaultName = seedVaultName]) =>
      ClientHostedBackupApi(client: client(), vaultName: vaultName);
}

_Env _env() {
  final clock = FakeClock();
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(clock),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  return _Env(FakeVaultServer(), container, clock);
}

/// The rows of `api_v1/<domain>` whose response file is [response].
List<FixtureRow> _row(String domain, String response) => [
  for (final row in loadFixtureRows(p.join(apiV1FixturesDir, domain)))
    if (row.response == response) row,
];

/// A server that answers GET with the row of `backup/<response>`.
_Env _serving(String domain, String response) {
  final env = _env();
  final rows = _row(domain, response);
  expect(rows, hasLength(1), reason: '$domain/$response is one fixture row');
  env.server.serveRows(rows);
  return env;
}

void main() {
  group('status', () {
    test('GET status of a vault that never backed up has no history', () async {
      final env = _serving('backup', 'status_never.json');

      final result = await env.api().status();

      expect(
        result,
        const HostedBackupOk(BackupStatus(enabled: true, keep: 30)),
      );
      expect(env.server.requests, hasLength(1));
      expect(env.server.requests.single.method, 'GET');
      expect(env.server.requests.single.url.path, _statusPath);
    });

    test('GET status of a created backup carries every field', () async {
      final env = _serving('backup', 'status_created.json');

      final result = await env.api().status();

      expect(
        result,
        HostedBackupOk(
          BackupStatus(
            enabled: true,
            keep: 30,
            lastAttemptAt: _ms(1794214800000),
            lastSuccessAt: _ms(1794214800000),
            lastResult: 'created',
            lastFile:
                'seed-20261109T090000Z-01M5DK9Z8CWPQGFA893JX9VRZF.memex.zip',
            lastFileCreatedAt: _ms(1794214800000),
            lastBytes: 52480,
          ),
        ),
      );
      final status = (result as HostedBackupOk).status;
      expect(status.lastAttemptAt!.isUtc, isTrue);
      expect(status.inProgress, isFalse);
      expect(status.lastAttemptFailed, isFalse);
    });

    test(
      'GET status of a failed attempt keeps the error and last good',
      () async {
        final env = _serving('backup', 'status_failed.json');

        final result = await env.api().status();

        expect(
          result,
          HostedBackupOk(
            BackupStatus(
              enabled: true,
              keep: 30,
              lastAttemptAt: _ms(1794218400000),
              lastSuccessAt: _ms(1794128400000),
              lastResult: 'backup_destination_unavailable',
              lastError:
                  'backup destination unavailable: /srv/memex/.backups/seed is '
                  'not writable',
              lastFile:
                  'seed-20261108T090000Z-01M5DK9Z8CWPQGFA893JX9VRZF.memex.zip',
              lastFileCreatedAt: _ms(1794128400000),
              lastBytes: 52210,
            ),
          ),
        );
        expect((result as HostedBackupOk).status.lastAttemptFailed, isTrue);
      },
    );

    test('GET status while a backup runs says in progress', () async {
      final env = _serving('backup', 'status_in_progress.json');

      final result = await env.api().status();

      expect(result, isA<HostedBackupOk>());
      final status = (result as HostedBackupOk).status;
      expect(status.inProgress, isTrue);
      expect(status.lastResult, 'created');
      expect(status.lastBytes, 52210);
    });

    test(
      'GET status of a server without backup dir is ok and not enabled',
      () async {
        final env = _env()..server.serveDomain('backup_off');

        final result = await env.api().status();

        expect(result, const HostedBackupOk(BackupStatus(enabled: false)));
        expect((result as HostedBackupOk).status.keep, isNull);
      },
    );

    test('status sends the saved server token and no body', () async {
      final env = _serving('backup', 'status_never.json');

      await env.api().status();

      final request = env.server.requests.single;
      expect(request.headers['authorization'], 'Bearer $fakeServerToken');
      expect(request.body, isEmpty);
    });

    test('status asks for the vault name given to the api', () async {
      final env = _env();
      env.server.route(
        'GET',
        '/vaults/My%20Vault%20%C3%A9/api/v1/backup',
        json: {'enabled': true, 'keep': 7, 'in_progress': false},
      );

      final result = await env.api('My Vault é').status();

      expect(
        result,
        const HostedBackupOk(BackupStatus(enabled: true, keep: 7)),
      );
    });
  });

  group('start', () {
    test(
      'POST start is accepted with 202 and reads the in progress state',
      () async {
        final env = _serving('backup', 'start_accepted.json');

        final result = await env.api().start();

        expect(
          result,
          const HostedBackupOk(
            BackupStatus(enabled: true, keep: 30, inProgress: true),
          ),
        );
        expect(env.server.requests, hasLength(1));
        expect(env.server.requests.single.method, 'POST');
        expect(env.server.requests.single.url.path, _statusPath);
      },
    );

    test('POST start sends no body and the saved server token', () async {
      final env = _serving('backup', 'start_accepted.json');

      await env.api().start();

      final request = env.server.requests.single;
      expect(request.headers['authorization'], 'Bearer $fakeServerToken');
      expect(request.body, isEmpty);
    });

    test('POST start while a backup runs says already running', () async {
      final env = _serving('backup', 'start_in_progress.json');

      expect(await env.api().start(), const HostedBackupAlreadyRunning());
    });

    test(
      'POST start on a server without backup dir says not configured',
      () async {
        final env = _env()..server.serveDomain('backup_off');

        expect(await env.api().start(), const HostedBackupNotConfigured());
      },
    );

    test('start sends one POST and never polls', () async {
      final env = _serving('backup', 'start_accepted.json');

      await env.api().start();

      expect(env.server.requests.map((r) => r.method), ['POST']);
    });
  });

  group('errors', () {
    test('404 not_found on status says the server is too old', () async {
      final env = _env()
        ..server.serveRows(_row('compat', 'backup_not_found.json'));

      expect(await env.api().status(), const HostedBackupServerTooOld());
    });

    test('404 not_found on start says the server is too old', () async {
      final env = _env();
      env.server.route(
        'POST',
        _statusPath,
        status: 404,
        json: {
          'error': {
            'code': 'not_found',
            'message': 'not found: no route for this path',
          },
        },
      );

      expect(await env.api().start(), const HostedBackupServerTooOld());
    });

    test(
      '404 vault_not_found on status rethrows the vault gone error',
      () async {
        final env = _serving('backup', 'status_never.json');
        env.server.removeVault('seed');

        await expectLater(
          env.api().status(),
          throwsA(
            isA<MemexException>().having(
              (e) => e.code,
              'code',
              'vault_not_found',
            ),
          ),
        );
      },
    );

    test(
      '404 vault_not_found on start rethrows the vault gone error',
      () async {
        final env = _serving('backup', 'start_accepted.json');
        env.server.removeVault('seed');

        await expectLater(
          env.api().start(),
          throwsA(
            isA<MemexException>().having(
              (e) => e.code,
              'code',
              'vault_not_found',
            ),
          ),
        );
      },
    );

    test('a 404 with another code is not a too old server', () async {
      final env = _env();
      env.server.route(
        'GET',
        _statusPath,
        status: 404,
        json: {
          'error': {'code': 'something_else', 'message': 'nope'},
        },
      );

      await expectLater(
        env.api().status(),
        throwsA(
          isA<MemexException>().having((e) => e.code, 'code', 'something_else'),
        ),
      );
    });

    test('a 409 with another code is not already running', () async {
      final env = _env();
      env.server.route(
        'POST',
        _statusPath,
        status: 409,
        json: {
          'error': {'code': 'version_conflict', 'message': 'nope'},
        },
      );

      await expectLater(
        env.api().start(),
        throwsA(
          isA<MemexException>().having(
            (e) => e.code,
            'code',
            'version_conflict',
          ),
        ),
      );
    });

    test('backup_in_progress on status is not a result', () async {
      final env = _env();
      env.server.route(
        'GET',
        _statusPath,
        status: 409,
        json: {
          'error': {'code': 'backup_in_progress', 'message': 'running'},
        },
      );

      await expectLater(env.api().status(), throwsA(isA<MemexException>()));
    });

    test('a wrong token rethrows unauthorized', () async {
      final env = _serving('backup', 'status_never.json');
      final wrong = ClientHostedBackupApi(
        client: env.server.connect(env.container, accessToken: 'not-the-token'),
        vaultName: seedVaultName,
      );

      await expectLater(
        wrong.status(),
        throwsA(
          isA<MemexException>().having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
    });

    test('a server error rethrows the C1 error of the server', () async {
      final env = _env();
      env.server.route(
        'POST',
        _statusPath,
        status: 500,
        json: {
          'error': {'code': 'internal', 'message': 'disk on fire'},
        },
      );

      await expectLater(
        env.api().start(),
        throwsA(
          isA<MemexException>()
              .having((e) => e.code, 'code', 'internal')
              .having((e) => e.message, 'message', contains('disk on fire')),
        ),
      );
    });

    test('a body that is not an object rethrows a memex exception', () async {
      final env = _env();
      env.server.route('GET', _statusPath, body: '[]');

      await expectLater(env.api().status(), throwsA(isA<MemexException>()));
    });

    for (final c in [
      (
        'a refused connection throws unreachable on status and start',
        FakeServerFailure.refused,
      ),
      (
        'a failed host lookup throws unreachable on status and start',
        FakeServerFailure.hostLookup,
      ),
      (
        'an unreachable network throws unreachable on status and start',
        FakeServerFailure.networkUnreachable,
      ),
    ]) {
      test(c.$1, () async {
        final env = _env()..server.failure = c.$2;

        await expectLater(
          env.api().status(),
          throwsA(
            isA<VaultUnreachableException>()
                .having((e) => e.serverName, 'serverName', fakeServerName)
                .having((e) => e.mayHaveCommitted, 'mayHaveCommitted', false),
          ),
        );
        await expectLater(
          env.api().start(),
          throwsA(isA<VaultUnreachableException>()),
        );
      });
    }

    test(
      'a start that never answers is unreachable after 10 seconds',
      () async {
        final env = _env()..server.failure = FakeServerFailure.timeout;
        Object? outcome;
        unawaited(
          env.api().start().then<void>(
            (_) {},
            onError: (Object e) => outcome = e,
          ),
        );
        await pumpEventQueue();
        expect(outcome, isNull, reason: 'nothing before the timeout');

        env.clock.advance(const Duration(seconds: 10));
        await pumpEventQueue();

        expect(outcome, isA<VaultUnreachableException>());
        expect(
          (outcome! as VaultUnreachableException).mayHaveCommitted,
          isTrue,
        );
      },
    );
  });

  group('hostedBackupApiProvider', () {
    const hosted = HostedVaultRef(fakeServerId, seedVaultName);

    ProviderContainer container(
      _Env env, {
      VaultRef? current = hosted,
      HostedSession? session,
    }) {
      final c = ProviderContainer(
        overrides: [
          clockProvider.overrideWithValue(env.clock),
          utcOffsetProvider.overrideWithValue(() => Duration.zero),
          currentVaultProvider.overrideWith((_) => current),
          hostedSessionProvider.overrideWith(
            (_) => session ?? HostedSession(hosted, env.client()),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('hostedBackupApiProvider is null when no hosted vault is open', () {
      final env = _env();

      expect(
        container(env, current: null).read(hostedBackupApiProvider),
        isNull,
      );
      expect(
        container(
          env,
          current: const LocalVaultRef('/Users/a b/My Vault'),
        ).read(hostedBackupApiProvider),
        isNull,
      );
    });

    test('hostedBackupApiProvider builds the api of the open hosted vault', () {
      final env = _env();
      final session = HostedSession(hosted, env.client());

      final api = container(
        env,
        session: session,
      ).read(hostedBackupApiProvider);

      expect(api, isA<ClientHostedBackupApi>());
      final client = api! as ClientHostedBackupApi;
      expect(client.vaultName, seedVaultName);
      expect(identical(client.client, session.client), isTrue);
    });

    test(
      'hostedBackupApiProvider reaches the server of the open vault',
      () async {
        final env = _serving('backup', 'status_created.json');

        final api = container(env).read(hostedBackupApiProvider);

        final result = await api!.status();
        expect(result, isA<HostedBackupOk>());
        expect((result as HostedBackupOk).status.lastResult, 'created');
        expect(env.server.requests.single.url.path, _statusPath);
      },
    );

    test(
      'hostedBackupApiProvider is null when the session is of another vault',
      () {
        final env = _env();
        const other = HostedVaultRef(fakeServerId, 'other');

        final c = container(env, session: HostedSession(other, env.client()));

        expect(c.read(hostedBackupApiProvider), isNull);
      },
    );

    test('hostedBackupApiProvider is null when no open made a session', () {
      final env = _env();
      final c = ProviderContainer(
        overrides: [
          clockProvider.overrideWithValue(env.clock),
          currentVaultProvider.overrideWith((_) => hosted),
        ],
      );
      addTearDown(c.dispose);

      expect(c.read(hostedBackupApiProvider), isNull);
    });

    test('hostedBackupApiProvider follows the open vault', () async {
      final env = _env();
      final c = container(env);
      final seen = <bool>[];
      c.listen<HostedBackupApi?>(
        hostedBackupApiProvider,
        (_, next) => seen.add(next != null),
        fireImmediately: true,
      );

      c.read(currentVaultProvider.notifier).state = const LocalVaultRef('/v');
      await pumpEventQueue();
      c.read(currentVaultProvider.notifier).state = hosted;
      await pumpEventQueue();

      expect(seen, [true, false, true]);
    });
  });

  group('a 200 body that is not a status', () {
    test(
      'a wrong typed field rethrows a memex exception naming the operation',
      () async {
        final env = _env();
        env.server.route('GET', _statusPath, json: {'enabled': 'yes'});
        env.server.route('POST', _statusPath, status: 202, json: {'keep': 'x'});

        await expectLater(
          env.api().status(),
          throwsA(
            isA<MemexException>().having(
              (e) => e.message,
              'message',
              startsWith('backup status failed: '),
            ),
          ),
        );
        await expectLater(
          env.api().start(),
          throwsA(
            isA<MemexException>().having(
              (e) => e.message,
              'message',
              startsWith('backup start failed: '),
            ),
          ),
        );
      },
    );
  });
}
