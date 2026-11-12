// WI #413 (Spec #394 req 16, 43; D21a): ClientHostedEmbeddingsApi over
// HostedClient against R1's wire fixtures (`api_v1/embeddings/`) and C0's
// compat fixture (`compat/embeddings_not_found.json`), replayed by
// `fake_vault_server.dart`. Only `404 not_found` is an old server;
// `vault_not_found` and `unauthorized` are errors that carry the server's
// own message (the `hosted/backup.dart` pattern).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/agents_sheet/recall/embeddings_status.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/hosted/embeddings.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_vault_server.dart';

const _embeddingsDir = '$apiV1FixturesDir/embeddings';
const _embeddingsPath = '/vaults/seed/api/v1/embeddings';

Object? _json(String path) => jsonDecode(File(path).readAsStringSync());

String _errorMessage(String path) =>
    ((_json(path)! as Map)['error']! as Map)['message']! as String;

String _file(String path) => File(path).readAsStringSync();

class _Wi413Env {
  _Wi413Env(this.container, this.server, this.api);

  final ProviderContainer container;
  final FakeVaultServer server;
  final ClientHostedEmbeddingsApi api;

  Iterable<String> get embeddingRequests => server.requests
      .where((r) => r.url.path.endsWith('/embeddings'))
      .map((r) => '${r.method} ${r.url.path}');
}

/// A fake server answering `GET …/embeddings` for `seed` with [response]
/// (a fixture path), or serving [domains].
_Wi413Env _env({
  String? response,
  int status = 200,
  List<String> domains = const [],
  String vault = seedVaultName,
}) {
  final server = FakeVaultServer();
  for (final d in domains) {
    server.serveDomain(d);
  }
  if (response != null) {
    server.route('GET', _embeddingsPath, status: status, body: _file(response));
  }
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  return _Wi413Env(
    container,
    server,
    ClientHostedEmbeddingsApi(
      client: server.connect(container),
      vaultName: vault,
    ),
  );
}

void main() {
  group('ClientHostedEmbeddingsApi.status', () {
    test('GET embeddings reads the server on fixture', () async {
      final env = _env(response: '$_embeddingsDir/server_embeddings_on.json');
      final r = await env.api.status();
      expect(r, isA<EmbeddingsStatusOk>());
      final s = (r as EmbeddingsStatusOk).status;
      expect(s.serverEmbeddings, isTrue);
      expect(s.chunks, 10);
      expect(s.embedded, 0);
      expect(s.waiting, 10);
      expect(s.modelCached, isFalse);
      expect(s.modelBytes, 0);
      expect(env.embeddingRequests, ['GET $_embeddingsPath']);
    });

    test('GET embeddings reads the server off fixture', () async {
      final env = _env(response: '$_embeddingsDir/server_embeddings_off.json');
      final r = await env.api.status();
      expect(r, isA<EmbeddingsStatusOk>());
      expect((r as EmbeddingsStatusOk).status.serverEmbeddings, isFalse);
    });

    test('the fixture domain rows answer through the client', () async {
      final env = _env(domains: const ['embeddings']);
      final r = await env.api.status();
      expect(r, isA<EmbeddingsStatusOk>());
      expect((r as EmbeddingsStatusOk).status.chunks, 10);
    });

    test('reads a cached model and its size', () async {
      final env = _env()
        ..server.route(
          'GET',
          _embeddingsPath,
          json: {
            'server_embeddings': true,
            'chunks': 71,
            'embedded': 64,
            'model_cached': true,
            'model_bytes': 127000000,
          },
        );
      final r = await env.api.status();
      expect(r, isA<EmbeddingsStatusOk>());
      final s = (r as EmbeddingsStatusOk).status;
      expect(s.embedded, 64);
      expect(s.waiting, 7);
      expect(s.modelCached, isTrue);
      expect(s.modelBytes, 127000000);
    });

    test('sends the access token as a bearer header', () async {
      final env = _env(response: '$_embeddingsDir/server_embeddings_on.json');
      await env.api.status();
      expect(env.server.requests, hasLength(1));
      expect(
        env.server.requests.single.headers['authorization'],
        'Bearer $fakeServerToken',
      );
    });

    test('the compat 404 not_found fixture is a server too old', () async {
      final env = _env(domains: const ['compat']);
      final r = await env.api.status();
      expect(r, isA<EmbeddingsServerTooOld>());
      expect(env.embeddingRequests, ['GET $_embeddingsPath']);
    });

    test('404 vault_not_found is an error with the server message', () async {
      final env = _env(domains: const ['embeddings'], vault: 'nope');
      final r = await env.api.status();
      expect(r, isA<EmbeddingsStatusError>());
      expect(
        (r as EmbeddingsStatusError).message,
        _errorMessage('$_embeddingsDir/vault_not_found.json'),
      );
      expect(r.message, 'no vault named nope');
    });

    test('a wrong access token is an error with the server message', () async {
      final env = _env(response: '$_embeddingsDir/server_embeddings_on.json')
        ..server.token = 'rotated-token';
      final r = await env.api.status();
      expect(r, isA<EmbeddingsStatusError>());
      expect(
        (r as EmbeddingsStatusError).message,
        _errorMessage('$_embeddingsDir/unauthorized.json'),
      );
    });

    test(
      'a vault the server removed is an error, not a server too old',
      () async {
        final env = _env(domains: const ['embeddings'])
          ..server.removeVault('seed');
        final r = await env.api.status();
        expect(r, isA<EmbeddingsStatusError>());
        expect(r, isNot(isA<EmbeddingsServerTooOld>()));
        expect((r as EmbeddingsStatusError).message, 'no vault named seed');
      },
    );

    test('a 500 with a C1 body is an error with its message', () async {
      final env = _env()
        ..server.route(
          'GET',
          _embeddingsPath,
          status: 500,
          json: {
            'error': {'code': 'internal', 'message': 'chunk_vec is locked'},
          },
        );
      final r = await env.api.status();
      expect(r, isA<EmbeddingsStatusError>());
      expect((r as EmbeddingsStatusError).message, 'chunk_vec is locked');
    });

    test('a 200 whose body is not the wire shape is an error', () async {
      for (final body in [
        <String, Object?>{'chunks': 'x'},
        <String, Object?>{
          'server_embeddings': 'on',
          'chunks': 1,
          'embedded': 0,
          'model_cached': false,
          'model_bytes': 0,
        },
        <String, Object?>{},
      ]) {
        final env = _env()..server.route('GET', _embeddingsPath, json: body);
        final r = await env.api.status();
        expect(r, isA<EmbeddingsStatusError>(), reason: '$body');
        expect((r as EmbeddingsStatusError).message, isNotEmpty);
      }
    });

    test('an unreachable server throws VaultUnreachableException', () async {
      final env = _env(response: '$_embeddingsDir/server_embeddings_on.json')
        ..server.failure = FakeServerFailure.refused;
      await expectLater(
        env.api.status(),
        throwsA(isA<VaultUnreachableException>()),
      );
    });

    test('each call is one request and none is cached', () async {
      final env = _env(response: '$_embeddingsDir/server_embeddings_on.json');
      await env.api.status();
      await env.api.status();
      expect(env.embeddingRequests, hasLength(2));
    });
  });

  group('hostedEmbeddingsApiProvider', () {
    const hosted = HostedVaultRef(fakeServerId, seedVaultName);

    /// A container whose open vault is [vault] and whose hosted session (if
    /// [sessionFor] is given) was opened for that vault on a fake server.
    ProviderContainer open(VaultRef? vault, {HostedVaultRef? sessionFor}) {
      final server = FakeVaultServer()
        ..route(
          'GET',
          _embeddingsPath,
          body: _file('$_embeddingsDir/server_embeddings_off.json'),
        );
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

    test(
      'reads the open hosted vault through its session and is null otherwise',
      () async {
        expect(
          open(
            const LocalVaultRef('/vaults/Studio'),
          ).read(hostedEmbeddingsApiProvider),
          isNull,
          reason: 'a local vault',
        );
        expect(
          open(hosted).read(hostedEmbeddingsApiProvider),
          isNull,
          reason: 'no session',
        );
        expect(
          open(
            hosted,
            sessionFor: const HostedVaultRef(fakeServerId, 'other'),
          ).read(hostedEmbeddingsApiProvider),
          isNull,
          reason: 'a session for another vault',
        );
        final api = open(
          hosted,
          sessionFor: hosted,
        ).read(hostedEmbeddingsApiProvider);
        expect(api, isNotNull);
        final r = await api!.status();
        expect(r, isA<EmbeddingsStatusOk>());
        expect((r as EmbeddingsStatusOk).status.serverEmbeddings, isFalse);
      },
    );
  });
}
