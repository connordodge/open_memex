// WI #413 (Spec #394 req 15, 38, 40, 43; R1 #403 wire shape): the
// embeddings status model and the `memex embeddings status` wrapper. The
// local CLI prints `server_embeddings: null` (crates/memex-mcp/src/cli/
// embeddings.rs); the hosted fixtures in `api_v1/embeddings/` carry a bool.
// The wrapper runs against FakeMemexCli: exit 2 is too old whatever stderr
// says, a missing or unstartable binary is binary not found, and every other
// failure carries the CLI's own message.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/agents_sheet/recall/embeddings_status.dart';
import 'package:open_memex_app/src/cli/embeddings_cli.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_memex_cli.dart';

const _embeddingsDir = '$apiV1FixturesDir/embeddings';

Object? _fixture(String name) =>
    jsonDecode(File('$_embeddingsDir/$name').readAsStringSync());

/// The local CLI's line for a vault with [chunks] chunks, [embedded] of them
/// embedded, as `memex embeddings status` prints it (one JSON line).
String _localLine({
  int chunks = 71,
  int embedded = 64,
  bool cached = true,
  int bytes = 127000000,
}) =>
    '${jsonEncode({'server_embeddings': null, 'chunks': chunks, 'embedded': embedded, 'model_cached': cached, 'model_bytes': bytes})}\n';

FakeMemexCli _cli(FakeCliHandler handler) =>
    FakeMemexCli()..on('embeddings status', handler);

void main() {
  group('EmbeddingsStatus.fromJson', () {
    test('reads the local CLI shape with server_embeddings null', () {
      final s = EmbeddingsStatus.fromJson(
        jsonDecode(_localLine(chunks: 71, embedded: 64, bytes: 127000000)),
      );
      expect(s.serverEmbeddings, isNull);
      expect(s.chunks, 71);
      expect(s.embedded, 64);
      expect(s.modelCached, isTrue);
      expect(s.modelBytes, 127000000);
      expect(s.waiting, 7);
    });

    test('a missing server_embeddings key reads as null', () {
      final s = EmbeddingsStatus.fromJson({
        'chunks': 3,
        'embedded': 1,
        'model_cached': false,
        'model_bytes': 0,
      });
      expect(s.serverEmbeddings, isNull);
      expect(s.chunks, 3);
      expect(s.embedded, 1);
      expect(s.modelCached, isFalse);
      expect(s.waiting, 2);
    });

    test('reads the hosted on and off fixtures', () {
      final on = EmbeddingsStatus.fromJson(
        _fixture('server_embeddings_on.json'),
      );
      expect(on.serverEmbeddings, isTrue);
      expect(on.chunks, 10);
      expect(on.embedded, 0);
      expect(on.modelCached, isFalse);
      expect(on.modelBytes, 0);
      expect(on.waiting, 10);
      final off = EmbeddingsStatus.fromJson(
        _fixture('server_embeddings_off.json'),
      );
      expect(off.serverEmbeddings, isFalse);
      expect(off.chunks, 10);
      expect(off.waiting, 10);
    });

    test('waiting is chunks minus embedded for run-time values', () {
      // Values built at run time, so the constructor and getter run on
      // non-const instances.
      for (final (chunks, embedded) in [(0, 0), (1, 1), (5, 2), (1000, 1)]) {
        final s = EmbeddingsStatus(
          serverEmbeddings: chunks.isEven,
          chunks: chunks,
          embedded: embedded,
          modelCached: embedded > 1,
          modelBytes: chunks * 1000,
        );
        expect(s.waiting, chunks - embedded, reason: '$chunks/$embedded');
        expect(s.serverEmbeddings, chunks.isEven);
        expect(s.modelCached, embedded > 1);
        expect(s.modelBytes, chunks * 1000);
      }
      final parsed = EmbeddingsStatus.fromJson({
        'server_embeddings': true,
        'chunks': 12,
        'embedded': 12,
        'model_cached': true,
        'model_bytes': 5000000000,
      });
      expect(parsed.waiting, 0);
      expect(parsed.modelBytes, 5000000000);
    });

    test('a wrong shape throws FormatException', () {
      final good = <String, Object?>{
        'server_embeddings': false,
        'chunks': 1,
        'embedded': 0,
        'model_cached': false,
        'model_bytes': 0,
      };
      final bad = <Object?>[
        null,
        'x',
        <Object?>[],
        {...good}..remove('chunks'),
        {...good}..remove('embedded'),
        {...good}..remove('model_cached'),
        {...good}..remove('model_bytes'),
        {...good, 'chunks': '1'},
        {...good, 'embedded': null},
        {...good, 'model_cached': 'yes'},
        {...good, 'model_bytes': 'big'},
        {...good, 'server_embeddings': 'on'},
      ];
      for (final json in bad) {
        expect(
          () => EmbeddingsStatus.fromJson(json),
          throwsFormatException,
          reason: '$json',
        );
      }
      expect(EmbeddingsStatus.fromJson(good).chunks, 1);
    });
  });

  group('EmbeddingsCli.status', () {
    test(
      'runs embeddings status with the vault path and reads the line',
      () async {
        final cli = _cli((_) => FakeMemexCli.ok(_localLine()));
        final r = await EmbeddingsCli(cli).status(vaultPath: '/vaults/Studio');
        expect(r, isA<EmbeddingsStatusOk>());
        final s = (r as EmbeddingsStatusOk).status;
        expect(s.serverEmbeddings, isNull);
        expect(s.chunks, 71);
        expect(s.embedded, 64);
        expect(s.waiting, 7);
        expect(s.modelCached, isTrue);
        expect(s.modelBytes, 127000000);
        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.args, [
          'embeddings',
          'status',
          '--vault',
          '/vaults/Studio',
        ]);
      },
    );

    test('passes a vault path with spaces as one argument', () async {
      final cli = _cli((_) => FakeMemexCli.ok(_localLine()));
      final r = await EmbeddingsCli(
        cli,
      ).status(vaultPath: '/vaults/My Vault ü');
      expect(r, isA<EmbeddingsStatusOk>());
      expect(cli.calls.single.flag('vault'), '/vaults/My Vault ü');
    });

    test('no memex configured is binary not found', () async {
      final r = await const EmbeddingsCli(
        null,
      ).status(vaultPath: '/vaults/Studio');
      expect(r, isA<EmbeddingsBinaryNotFound>());
    });

    test('a binary that cannot start is binary not found', () async {
      final cli = _cli(
        (_) => throw const ProcessException('memex', ['embeddings', 'status']),
      );
      final r = await EmbeddingsCli(cli).status(vaultPath: '/vaults/Studio');
      expect(r, isA<EmbeddingsBinaryNotFound>());
      expect(cli.calls, hasLength(1));
    });

    test('exit 2 is too old whatever stderr says', () async {
      for (final stderr in [
        "error: unrecognized subcommand 'embeddings'\n",
        '{"error":{"code":"internal","message":"boom"}}\n',
        '',
      ]) {
        final cli = _cli((_) => FakeMemexCli.failure(stderr, exitCode: 2));
        final r = await EmbeddingsCli(cli).status(vaultPath: '/vaults/Studio');
        expect(r, isA<EmbeddingsTooOld>(), reason: stderr);
      }
    });

    test('a C1 failure is an error with its message', () async {
      final cli = _cli(
        (_) => FakeMemexCli.error('vault_not_found', 'no vault at /vaults/x'),
      );
      final r = await EmbeddingsCli(cli).status(vaultPath: '/vaults/x');
      expect(r, isA<EmbeddingsStatusError>());
      expect((r as EmbeddingsStatusError).message, 'no vault at /vaults/x');
    });

    test('a failure whose stderr is not C1 carries the stderr text', () async {
      final cli = _cli(
        (_) => FakeMemexCli.failure('thread main panicked at disk full'),
      );
      final r = await EmbeddingsCli(cli).status(vaultPath: '/vaults/Studio');
      expect(r, isA<EmbeddingsStatusError>());
      expect(
        (r as EmbeddingsStatusError).message,
        contains('thread main panicked at disk full'),
      );
    });

    test('stdout that is not the wire shape is an error', () async {
      for (final stdout in ['not json', '[]', '{"chunks":"many"}', '']) {
        final cli = _cli((_) => FakeMemexCli.ok(stdout));
        final r = await EmbeddingsCli(cli).status(vaultPath: '/vaults/Studio');
        expect(r, isA<EmbeddingsStatusError>(), reason: stdout);
        expect((r as EmbeddingsStatusError).message, isNotEmpty);
        expect(cli.calls, hasLength(1));
      }
    });

    test('each call runs the binary once and nothing is cached', () async {
      var embedded = 1;
      final cli = _cli(
        (_) => FakeMemexCli.ok(_localLine(chunks: 9, embedded: embedded++)),
      );
      final wrapper = EmbeddingsCli(cli);
      final a = await wrapper.status(vaultPath: '/vaults/Studio');
      final b = await wrapper.status(vaultPath: '/vaults/Studio');
      expect(cli.callsFor('embeddings status'), hasLength(2));
      expect((a as EmbeddingsStatusOk).status.embedded, 1);
      expect((b as EmbeddingsStatusOk).status.embedded, 2);
    });
  });
}
