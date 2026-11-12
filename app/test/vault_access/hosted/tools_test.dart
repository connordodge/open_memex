// WI #412 (Spec #394 req 16, 35; D20, D21a): ClientHostedToolsApi over
// HostedClient against the T1 wire fixtures (`api_v1/tools/`) and the C0
// compat fixture (`compat/tools_not_found.json`), replayed by
// `fake_vault_server.dart`. Only `404 not_found` is an old server;
// `vault_not_found` and `unauthorized` are errors that carry the server's
// own message (the `hosted/backup.dart` pattern).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/agents_sheet/tools/tool_catalog.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/hosted/tools.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_vault_server.dart';

const _toolsDir = '$apiV1FixturesDir/tools';
const _toolsPath = '/vaults/seed/api/v1/tools';

Object? _json(String path) => jsonDecode(File(path).readAsStringSync());

String _errorMessage(String path) =>
    ((_json(path)! as Map)['error']! as Map)['message']! as String;

class _Env {
  _Env(this.container, this.server, this.api);

  final ProviderContainer container;
  final FakeVaultServer server;
  final ClientHostedToolsApi api;

  Iterable<String> get toolRequests => server.requests
      .where((r) => r.url.path.endsWith('/tools'))
      .map((r) => '${r.method} ${r.url.path}');
}

_Env _env({
  List<String> domains = const ['tools'],
  String vault = seedVaultName,
}) {
  final server = FakeVaultServer();
  for (final d in domains) {
    server.serveDomain(d);
  }
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  return _Env(
    container,
    server,
    ClientHostedToolsApi(client: server.connect(container), vaultName: vault),
  );
}

void main() {
  group('ClientHostedToolsApi.list', () {
    test('GET tools answers the fixture list in the binary order', () async {
      final env = _env();
      final r = await env.api.list();
      expect(r, isA<ToolCatalogOk>());
      final wire = _json('$_toolsDir/tools.json')! as Map<String, Object?>;
      final expected = ToolCatalog.fromJson(wire);
      final got = (r as ToolCatalogOk).catalog;
      expect(got.tools, isNotEmpty);
      expect(got.tools.map((t) => t.name), expected.tools.map((t) => t.name));
      expect(got.tools.map((t) => t.group), expected.tools.map((t) => t.group));
      expect(
        got.tools.map((t) => t.writes),
        expected.tools.map((t) => t.writes),
      );
      expect(
        got.prompts.map((p) => p.name),
        expected.prompts.map((p) => p.name),
      );
      expect(env.toolRequests, ['GET $_toolsPath']);
    });

    test('sends the access token as a bearer header', () async {
      final env = _env();
      await env.api.list();
      expect(env.server.requests, hasLength(1));
      expect(
        env.server.requests.single.headers['authorization'],
        'Bearer $fakeServerToken',
      );
    });

    test('404 not_found (the compat fixture) is a server too old', () async {
      final env = _env(domains: const ['compat']);
      final r = await env.api.list();
      expect(r, isA<ToolCatalogServerTooOld>());
      expect(env.toolRequests, ['GET $_toolsPath']);
    });

    test('404 vault_not_found is an error with the server message', () async {
      final env = _env(vault: 'nope');
      final r = await env.api.list();
      expect(r, isA<ToolCatalogError>());
      expect(
        (r as ToolCatalogError).message,
        _errorMessage('$_toolsDir/vault_not_found.json'),
      );
      expect(r.message, 'no vault named nope');
    });

    test('a wrong access token is an error with the server message', () async {
      final env = _env()..server.token = 'rotated-token';
      final r = await env.api.list();
      expect(r, isA<ToolCatalogError>());
      expect(
        (r as ToolCatalogError).message,
        _errorMessage('$_toolsDir/unauthorized.json'),
      );
    });

    test(
      'a vault the server removed is an error, not a server too old',
      () async {
        final env = _env()..server.removeVault('seed');
        final r = await env.api.list();
        expect(r, isA<ToolCatalogError>());
        expect(r, isNot(isA<ToolCatalogServerTooOld>()));
        expect((r as ToolCatalogError).message, 'no vault named seed');
      },
    );

    test('a 500 with a C1 body is an error with its message', () async {
      final env = _env(domains: const [])
        ..server.route(
          'GET',
          _toolsPath,
          status: 500,
          json: {
            'error': {'code': 'internal', 'message': 'tool x has no row'},
          },
        );
      final r = await env.api.list();
      expect(r, isA<ToolCatalogError>());
      expect((r as ToolCatalogError).message, 'tool x has no row');
    });

    test('a 200 whose body is not the wire shape is an error', () async {
      for (final body in [
        <String, Object?>{'tools': 'x', 'prompts': <Object?>[]},
        <String, Object?>{'prompts': <Object?>[]},
        <String, Object?>{},
      ]) {
        final env = _env(domains: const [])
          ..server.route('GET', _toolsPath, json: body);
        final r = await env.api.list();
        expect(r, isA<ToolCatalogError>(), reason: '$body');
        expect((r as ToolCatalogError).message, isNotEmpty);
      }
    });

    test('an unreachable server throws VaultUnreachableException', () async {
      final env = _env()..server.failure = FakeServerFailure.refused;
      await expectLater(
        env.api.list(),
        throwsA(isA<VaultUnreachableException>()),
      );
    });

    test('each call is one request and none is cached', () async {
      final env = _env();
      await env.api.list();
      await env.api.list();
      expect(env.toolRequests, hasLength(2));
    });
  });

  group('hostedToolsApiProvider', () {
    const hosted = HostedVaultRef(fakeServerId, seedVaultName);

    /// A container whose open vault is [vault] and whose hosted session (if
    /// [sessionFor] is given) was opened for that vault on a fake server.
    ProviderContainer open(VaultRef? vault, {HostedVaultRef? sessionFor}) {
      final server = FakeVaultServer()..serveDomain('tools');
      final container = ProviderContainer(
        overrides: [
          clockProvider.overrideWithValue(FakeClock()),
          utcOffsetProvider.overrideWithValue(() => Duration.zero),
          currentVaultProvider.overrideWith((_) => vault),
        ],
      );
      addTearDown(container.dispose);
      if (sessionFor != null) {
        container.read(hostedSessionProvider.notifier).state = HostedSession(
          sessionFor,
          server.connect(container),
        );
      }
      return container;
    }

    test('is null with a local vault open', () {
      final c = open(const LocalVaultRef('/tmp/Studio'));
      expect(c.read(hostedToolsApiProvider), isNull);
    });

    test('is null for a hosted vault with no session', () {
      final c = open(hosted);
      expect(c.read(hostedToolsApiProvider), isNull);
    });

    test('is null when the session is for another vault', () {
      final c = open(
        hosted,
        sessionFor: const HostedVaultRef(fakeServerId, 'other'),
      );
      expect(c.read(hostedToolsApiProvider), isNull);
    });

    test('reads the open hosted vault through its session', () async {
      final c = open(hosted, sessionFor: hosted);
      final api = c.read(hostedToolsApiProvider);
      expect(api, isNotNull);
      final r = await api!.list();
      expect(r, isA<ToolCatalogOk>());
      expect((r as ToolCatalogOk).catalog.tools, isNotEmpty);
    });
  });
}
