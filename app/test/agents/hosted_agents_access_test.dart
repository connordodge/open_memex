// WI #454 (390-A3): HostedAgentsAccess over `GET /vaults/{name}/api/v1/agents`
// (Spec #390 req 16 client side, req 17; D20, D21, D21a, D22).
//
// - 200: the body parses with `AgentActivity.fromJson`, `server_now` ->
//   `serverNow`. P5's `api_v1/agents` rows are replayed (not hand-copied);
//   they carry concrete timestamps and ids, so they are served as committed.
// - 404 `not_found` (an older server; C0's `compat/agents_not_found.json`)
//   -> `available: false`, no agents, no entries, nothing thrown. The match is
//   on the code only (D21).
// - `vault_not_found`, `unauthorized` and every other refusal rethrow the
//   client's own MemexException; an unreachable server rethrows
//   VaultUnreachableException.
// - A 200 body that does not parse throws a null-code MemexException.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/agents_access.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/hosted/agents.dart';
import 'package:path/path.dart' as p;

import '../support/api_fixtures.dart';
import '../support/fake_clock.dart';
import '../support/fake_vault_server.dart';

const _wi454AgentsDir = '$apiV1FixturesDir/agents';
const _wi454CompatDir = '$apiV1FixturesDir/compat';
const _wi454SeedPath = '/vaults/seed/api/v1/agents';

class _Wi454Env {
  _Wi454Env(this.server, this.container, this.clock);

  final FakeVaultServer server;
  final ProviderContainer container;
  final FakeClock clock;

  HostedAgentsAccess access([String vaultName = seedVaultName]) =>
      HostedAgentsAccess(
        client: server.connect(container),
        vaultName: vaultName,
      );
}

_Wi454Env _wi454Env() {
  final clock = FakeClock(DateTime.utc(2026, 11, 11, 9));
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(clock),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  return _Wi454Env(FakeVaultServer(), container, clock);
}

/// The single row of `<dir>/index.json` for [method] [path].
FixtureRow _wi454Row(String dir, String method, String path) {
  final rows = [
    for (final r in loadFixtureRows(dir))
      if (r.method == method && r.path == path) r,
  ];
  expect(rows, hasLength(1), reason: '$dir has one $method $path row');
  return rows.single;
}

/// Serves P5's [row] as committed (its values are concrete); returns the body.
Map<String, Object?> _wi454ServeRow(FakeVaultServer server, FixtureRow row) {
  final body = row.readResponseJson()! as Map<String, Object?>;
  server.route(row.method, row.path, status: row.status, json: body);
  return body;
}

Map<String, Object?> _wi454PresenceJson(AgentPresence a) => {
  'client_name': a.clientName,
  'client_version': a.clientVersion,
  'embeddings': a.embeddings,
  'expires_at': a.expiresAt,
  'last_request_at': a.lastRequestAt,
  'last_seen_at': a.lastSeenAt,
  'last_tool_at': a.lastToolAt,
  'session_id': a.sessionId,
  'started_at': a.startedAt,
  'transport': a.transport,
};

Map<String, Object?> _wi454EntryJson(AgentActivityEntry e) => {
  'client_name': e.clientName,
  'created_at': e.createdAt,
  'id': e.id,
  'note_id': e.noteId,
  'session_id': e.sessionId,
  'summary': e.summary,
  'tool': e.tool,
};

/// A well-formed 200 body: one agent, one entry.
Map<String, Object?> _wi454Body() => {
  'agents': [
    {
      'session_id': 's-1',
      'client_name': 'Claude Desktop',
      'client_version': '0.14.2',
      'transport': 'http',
      'started_at': 1762855100000,
      'last_seen_at': 1762855190000,
      'last_request_at': 1762855180000,
      'last_tool_at': 1762855170000,
      'expires_at': 1762855250000,
      'embeddings': true,
    },
  ],
  'recent': [
    {
      'id': 'a-1',
      'session_id': 's-1',
      'client_name': 'Claude Desktop',
      'tool': 'tag_note',
      'summary': 'tagged Player loop #core',
      'note_id': '01M5DQAYZ3WP7H0NXZZV9M2315',
      'created_at': 1762855170000,
    },
  ],
  'available': true,
  'server_now': 1762855200000,
};

/// A MemexException with [code] and, when given, exactly [message].
Matcher _wi454Memex(String? code, {String? message}) {
  final matcher = isA<MemexException>().having((e) => e.code, 'code', code);
  return message == null
      ? matcher
      : matcher.having((e) => e.message, 'message', message);
}

void main() {
  group('200', () {
    test(
      'replaying the P5 agents fixture returns its agents, recent entries, available true and serverNow',
      () async {
        final env = _wi454Env();
        final row = _wi454Row(_wi454AgentsDir, 'GET', _wi454SeedPath);
        expect(row.status, 200);
        final body = _wi454ServeRow(env.server, row);
        final fixtureAgents = body['agents']! as List<Object?>;
        final fixtureRecent = body['recent']! as List<Object?>;
        expect(fixtureAgents, isNotEmpty, reason: 'the fixture has agents');
        expect(fixtureRecent, isNotEmpty, reason: 'the fixture has entries');

        final access = env.access();
        expect(access.vaultName, seedVaultName);
        final a = await access.activity();

        expect([
          for (final x in a.agents) _wi454PresenceJson(x),
        ], fixtureAgents);
        expect([for (final x in a.recent) _wi454EntryJson(x)], fixtureRecent);
        expect(a.available, isTrue);
        expect(a.serverNow, body['server_now']);
        expect(a.serverNow, 1762855200000);
      },
    );

    test(
      'replaying the P5 empty agents fixture returns no agents, no entries, available true and serverNow',
      () async {
        final env = _wi454Env();
        final row = _wi454Row(
          _wi454AgentsDir,
          'GET',
          '/vaults/empty/api/v1/agents',
        );
        final body = _wi454ServeRow(env.server, row);

        final a = await env.access('empty').activity();

        expect(a.agents, isEmpty);
        expect(a.recent, isEmpty);
        expect(a.available, isTrue);
        expect(a.serverNow, body['server_now']);
        expect(a.serverNow, isNotNull);
      },
    );

    test('a 200 body is parsed field by field from run time values', () async {
      final env = _wi454Env();
      final now = env.clock.now().millisecondsSinceEpoch;
      final body = _wi454Body()
        ..['server_now'] = now
        ..['agents'] = [
          {
            ...((_wi454Body()['agents']! as List).single as Map),
            'session_id': 's-$now',
            'client_version': null,
            'last_tool_at': null,
            'transport': 'bridge',
            'embeddings': false,
            'last_request_at': now - 7,
          },
        ];
      env.server.route('GET', _wi454SeedPath, json: body);

      final a = await env.access().activity();

      expect(a.serverNow, now);
      final agent = a.agents.single;
      expect(agent.sessionId, 's-$now');
      expect(agent.clientName, 'Claude Desktop');
      expect(agent.clientVersion, isNull);
      expect(agent.transport, 'bridge');
      expect(agent.startedAt, 1762855100000);
      expect(agent.lastSeenAt, 1762855190000);
      expect(agent.lastRequestAt, now - 7);
      expect(agent.lastToolAt, isNull);
      expect(agent.expiresAt, 1762855250000);
      expect(agent.embeddings, isFalse);
      final entry = a.recent.single;
      expect(entry.id, 'a-1');
      expect(entry.sessionId, 's-1');
      expect(entry.clientName, 'Claude Desktop');
      expect(entry.tool, 'tag_note');
      expect(entry.summary, 'tagged Player loop #core');
      expect(entry.noteId, '01M5DQAYZ3WP7H0NXZZV9M2315');
      expect(entry.createdAt, 1762855170000);
      expect(a.available, isTrue);
    });

    test(
      'a 200 body with available false is returned as available false',
      () async {
        final env = _wi454Env();
        env.server.route(
          'GET',
          _wi454SeedPath,
          json: _wi454Body()..['available'] = false,
        );

        final a = await env.access().activity();

        expect(a.available, isFalse);
        expect(a.agents, hasLength(1));
        expect(a.recent, hasLength(1));
        expect(a.serverNow, 1762855200000);
      },
    );

    test('a 200 body keeps the server order of agents and entries', () async {
      final env = _wi454Env();
      final base = _wi454Body();
      final agent = (base['agents']! as List).single as Map;
      final entry = (base['recent']! as List).single as Map;
      env.server.route(
        'GET',
        _wi454SeedPath,
        json: base
          ..['agents'] = [
            for (final s in ['s-c', 's-a', 's-b']) {...agent, 'session_id': s},
          ]
          ..['recent'] = [
            for (final id in ['e-3', 'e-1', 'e-2']) {...entry, 'id': id},
          ],
      );

      final a = await env.access().activity();

      expect([for (final x in a.agents) x.sessionId], ['s-c', 's-a', 's-b']);
      expect([for (final x in a.recent) x.id], ['e-3', 'e-1', 'e-2']);
    });

    test('each activity call reads the route again', () async {
      final env = _wi454Env();
      env.server.route('GET', _wi454SeedPath, json: _wi454Body());
      final access = env.access();

      final first = await access.activity();
      env.server.route(
        'GET',
        _wi454SeedPath,
        json: _wi454Body()
          ..['agents'] = <Object?>[]
          ..['server_now'] = 1762855205000,
      );
      final second = await access.activity();

      expect(first.agents, hasLength(1));
      expect(second.agents, isEmpty);
      expect(second.serverNow, 1762855205000);
      expect(env.server.requests, hasLength(2));
    });
  });

  group('older server', () {
    test(
      'a compat agents not found response returns no agents, no entries and available false without throwing',
      () async {
        final env = _wi454Env();
        final row = _wi454Row(_wi454CompatDir, 'GET', _wi454SeedPath);
        expect(row.status, 404);
        expect(row.response, 'agents_not_found.json');
        env.server.serveRows([row]);

        final a = await env.access().activity();

        expect(a.agents, isEmpty);
        expect(a.recent, isEmpty);
        expect(a.available, isFalse);
        expect(a.serverNow, isNull);
        expect(env.server.requests, hasLength(1), reason: 'no retry');
      },
    );

    test(
      'a 404 not_found with another message is still an older server',
      () async {
        final env = _wi454Env();
        env.server.route(
          'GET',
          _wi454SeedPath,
          status: 404,
          json: {
            'error': {'code': 'not_found', 'message': 'not found: something'},
          },
        );

        final a = await env.access().activity();

        expect(a.available, isFalse);
        expect(a.agents, isEmpty);
        expect(a.recent, isEmpty);
      },
    );

    test('a 404 with a code other than not_found is rethrown', () async {
      final env = _wi454Env();
      env.server.route(
        'GET',
        _wi454SeedPath,
        status: 404,
        json: {
          'error': {'code': 'note_not_found', 'message': 'no such note'},
        },
      );

      await expectLater(
        env.access().activity(),
        throwsA(_wi454Memex('note_not_found')),
      );
    });

    test('a 500 without an error body is rethrown with a null code', () async {
      final env = _wi454Env();
      env.server.route(
        'GET',
        _wi454SeedPath,
        status: 500,
        body: 'oops',
        contentType: 'text/plain',
      );

      await expectLater(env.access().activity(), throwsA(_wi454Memex(null)));
    });
  });

  group('vault errors', () {
    test(
      'a 404 vault_not_found response is rethrown as the same MemexException code',
      () async {
        final env = _wi454Env();
        env.server.removeVault(seedVaultName);

        await expectLater(
          env.access().activity(),
          throwsA(
            _wi454Memex(
              'vault_not_found',
              message: 'agents failed: no vault named seed',
            ),
          ),
        );
        expect(env.server.requests, hasLength(1));
        expect(env.server.requests.single.url.path, _wi454SeedPath);
      },
    );

    test(
      'an unauthorized response is rethrown as the same MemexException code',
      () async {
        final env = _wi454Env();
        env.server.route('GET', _wi454SeedPath, json: _wi454Body());
        // The client keeps the token it was connected with; the server's
        // token changes after (a revoked token).
        final access = env.access();
        env.server.token = 'a-different-token';

        await expectLater(
          access.activity(),
          throwsA(_wi454Memex('unauthorized')),
        );
        expect(env.server.requests, hasLength(1));
      },
    );

    for (final (name, failure) in const [
      (
        'an unreachable server rethrows VaultUnreachableException',
        FakeServerFailure.refused,
      ),
      (
        'a failed host lookup rethrows VaultUnreachableException',
        FakeServerFailure.hostLookup,
      ),
      (
        'an unreachable network rethrows VaultUnreachableException',
        FakeServerFailure.networkUnreachable,
      ),
      (
        'a dropped connection rethrows VaultUnreachableException',
        FakeServerFailure.drop,
      ),
    ]) {
      test(name, () async {
        final env = _wi454Env()..server.failure = failure;

        await expectLater(
          env.access().activity(),
          throwsA(
            isA<VaultUnreachableException>().having(
              (e) => e.serverName,
              'serverName',
              fakeServerName,
            ),
          ),
        );
        expect(env.server.requests, hasLength(1), reason: 'no retry');
      });
    }

    test(
      'a server that never answers rethrows VaultUnreachableException after the client timeout',
      () async {
        final env = _wi454Env()..server.failure = FakeServerFailure.timeout;
        Object? outcome;
        var returned = false;
        unawaited(
          env.access().activity().then<void>(
            (_) => returned = true,
            onError: (Object e) => outcome = e,
          ),
        );
        await pumpEventQueue();
        expect(returned, isFalse, reason: 'no value before the timeout');
        expect(outcome, isNull, reason: 'no error before the timeout');

        env.clock.advance(const Duration(seconds: 10));
        await pumpEventQueue();

        expect(returned, isFalse);
        expect(outcome, isA<VaultUnreachableException>());
      },
    );
  });

  group('malformed 200', () {
    test('a 200 body missing agents throws a MemexException', () async {
      final env = _wi454Env();
      env.server.route(
        'GET',
        _wi454SeedPath,
        json: _wi454Body()..remove('agents'),
      );

      await expectLater(
        env.access().activity(),
        throwsA(
          _wi454Memex(
            null,
            message: 'agents failed: missing required key "agents"',
          ),
        ),
      );
    });

    test('a 200 body without server_now returns a null serverNow', () async {
      final env = _wi454Env();
      env.server.route(
        'GET',
        _wi454SeedPath,
        json: _wi454Body()..remove('server_now'),
      );

      final activity = await env.access().activity();

      expect(activity.serverNow, isNull);
      expect(activity.available, isTrue);
      expect(activity.agents, hasLength(1));
    });

    final cases = <(String, void Function(Map<String, Object?>))>[
      ('missing recent', (j) => j.remove('recent')),
      ('missing available', (j) => j.remove('available')),
      ('agents not a list', (j) => j['agents'] = {'a': 1}),
      ('recent not a list', (j) => j['recent'] = 'none'),
      ('available a string', (j) => j['available'] = 'yes'),
      ('server_now a string', (j) => j['server_now'] = '1762855200000'),
      ('an agent not an object', (j) => j['agents'] = [1]),
      (
        'an agent missing session_id',
        (j) => ((j['agents']! as List).single as Map).remove('session_id'),
      ),
      (
        'an agent with a string expires_at',
        (j) => ((j['agents']! as List).single as Map)['expires_at'] =
            '<timestamp>',
      ),
      (
        'an entry missing summary',
        (j) => ((j['recent']! as List).single as Map).remove('summary'),
      ),
    ];
    for (final (name, mutate) in cases) {
      test('a 200 body with $name throws a null code MemexException', () async {
        final env = _wi454Env();
        final body =
            jsonDecode(jsonEncode(_wi454Body())) as Map<String, Object?>;
        mutate(body);
        env.server.route('GET', _wi454SeedPath, json: body);

        final result = env.access().activity();

        await expectLater(result, throwsA(_wi454Memex(null)));
        await expectLater(result, throwsA(isNot(isA<FormatException>())));
      });
    }

    test(
      'a 200 body shaped like the P5 fixture with placeholder strings in its timestamp and id fields throws a null code MemexException',
      () async {
        final env = _wi454Env();
        final row = _wi454Row(_wi454AgentsDir, 'GET', _wi454SeedPath);
        // Built inline from the fixture's shape: every timestamp becomes
        // "<timestamp>" and every id "<id:N>" (the text the server's
        // normalize_volatile() prints into fixtures before P5 committed
        // concrete values).
        var n = 0;
        Object? placeholders(Object? v) => switch (v) {
          Map() => {
            for (final e in v.entries)
              e.key as String: switch (e.key) {
                final String k when k.endsWith('_at') || k == 'server_now' =>
                  '<timestamp>',
                'id' || 'session_id' => '<id:${n++}>',
                _ => placeholders(e.value),
              },
          },
          List() => [for (final e in v) placeholders(e)],
          _ => v,
        };
        final body =
            placeholders(row.readResponseJson())! as Map<String, Object?>;
        expect(jsonEncode(body), contains('"expires_at":"<timestamp>"'));
        expect(jsonEncode(body), contains('"id":"<id:'));
        env.server.route('GET', _wi454SeedPath, json: body);

        final result = env.access().activity();

        await expectLater(result, throwsA(_wi454Memex(null)));
        await expectLater(result, throwsA(isNot(isA<FormatException>())));
      },
    );
  });

  group('route', () {
    test('every request goes to GET vaults name api v1 agents', () async {
      final env = _wi454Env();
      env.server.route('GET', _wi454SeedPath, json: _wi454Body());
      env.server.route(
        'GET',
        '/vaults/${Uri.encodeComponent('my vault')}/api/v1/agents',
        json: _wi454Body(),
      );
      env.server.route(
        'GET',
        '/vaults/other/api/v1/agents',
        status: 404,
        body: File(
          p.join(_wi454CompatDir, 'agents_not_found.json'),
        ).readAsStringSync(),
      );

      await env.access().activity();
      await env.access().activity();
      await env.access('my vault').activity();
      await env.access('other').activity();
      env.server.removeVault('gone');
      await expectLater(
        env.access('gone').activity(),
        throwsA(_wi454Memex('vault_not_found')),
      );

      final sent = env.server.requests;
      expect(sent, hasLength(5));
      for (final r in sent) {
        expect(r.method, 'GET', reason: '${r.url}');
        expect(r.url.query, isEmpty, reason: '${r.url}');
        expect(r.body, isEmpty, reason: '${r.url}');
        expect(
          r.headers['authorization'],
          'Bearer $fakeServerToken',
          reason: '${r.url}',
        );
      }
      expect(
        [for (final r in sent) r.url.toString()],
        [
          '$fakeServerUrl$_wi454SeedPath',
          '$fakeServerUrl$_wi454SeedPath',
          '$fakeServerUrl/vaults/my%20vault/api/v1/agents',
          '$fakeServerUrl/vaults/other/api/v1/agents',
          '$fakeServerUrl/vaults/gone/api/v1/agents',
        ],
      );
    });
  });
}
