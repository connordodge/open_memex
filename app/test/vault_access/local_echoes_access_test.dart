// #425 (391-A1): LocalEchoesAccess runs `memex echoes` through the CLI and maps
// the outcome (Spec #391 req 20, 22). Everything goes through FakeMemexCli;
// no real `memex` ever runs. Each mapping is pinned on both arms: the exit
// code, JSON vs non-JSON stderr, and each C1 code.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';

import '../support/api_fixtures.dart';
import '../support/fake_memex_cli.dart';

const _vault = '/vaults/My Vault';
const _noteId = '01M5DQAYZ4RYSGA8T0YEEF8QRS';

/// The V4 wire fixture of a successful `memex echoes` (also the HTTP 200 body).
String _fixtureStdout() =>
    '${jsonEncode(jsonDecode(File('$apiV1FixturesDir/notes/echoes.json').readAsStringSync()))}\n';

/// One CLI answer: `{"echoes":[<rows>],"pending":<n>,"reason":<r>}`.
String _stdout({
  List<Map<String, Object?>> echoes = const [],
  Object? pending = 0,
  String? reason,
}) =>
    '${jsonEncode({'echoes': echoes, 'pending': pending, 'reason': reason})}\n';

Map<String, Object?> _echoRow({String passage = 'A passage.'}) => {
  'day': null,
  'note_id': '01JECHOROW000000000000000A',
  'note_role': null,
  'note_title': 'Row',
  'note_updated_at': 1760000000000,
  'passage': passage,
  'start_byte': 12,
};

/// Access over a fake whose `echoes` handler is [handler].
(LocalEchoesAccess, FakeMemexCli) _access(FakeCliHandler handler) {
  final cli = FakeMemexCli()..on('echoes', handler);
  return (LocalEchoesAccess(vaultPath: _vault, cli: cli), cli);
}

Future<Object?> _outcome(Future<Object?> f) async {
  try {
    return await f;
  } catch (e) {
    return e;
  }
}

void main() {
  group('success', () {
    test(
      'local success JSON maps to EchoesReady with every echo field',
      () async {
        final (access, _) = _access((_) => FakeMemexCli.ok(_fixtureStdout()));

        final result = await access.echoes(_noteId);

        // Built from run-time values so the constructors and == really run.
        final expected = EchoesReady(
          [
            Echo(
              noteId: '01M5DQAYZ5RH88SRZGPY15XXVM'.toString(),
              noteTitle: 'Broken Frontmatter',
              passage:
                  'Its frontmatter is not JSON, so every reader treats it as role-less.',
              startByte: int.parse('0'),
              noteUpdatedAt: int.parse('1760000540000'),
            ),
            Echo(
              noteId: '01M5DQAYZ592W2515HPSDF5Q16'.toString(),
              noteTitle: '2026-10-15',
              noteRole: 'daily',
              day: '2026-10-15',
              passage: 'Read about loot tables.',
              startByte: int.parse('0'),
              noteUpdatedAt: int.parse('1760000480000'),
            ),
          ],
          emptyNote: false,
          pending: 0,
        );
        expect(result, expected);
        result as EchoesReady;
        expect(result.echoes.map((e) => e.noteRole), [null, 'daily']);
        expect(result.echoes.map((e) => e.day), [null, '2026-10-15']);
      },
    );

    test(
      'local reason empty_note maps to emptyNote true and pending is read',
      () async {
        final (access, _) = _access(
          (_) => FakeMemexCli.ok(_stdout(pending: 3, reason: 'empty_note')),
        );

        final result = await access.echoes(_noteId);

        expect(result, isA<EchoesReady>());
        result as EchoesReady;
        expect(result.emptyNote, isTrue);
        expect(result.echoes, isEmpty);
        expect(result.pending, 3);
      },
    );

    test(
      'local null reason and any other reason map to emptyNote false',
      () async {
        for (final reason in <String?>[null, 'something_else']) {
          final (access, _) = _access(
            (_) => FakeMemexCli.ok(
              _stdout(echoes: [_echoRow()], pending: 7, reason: reason),
            ),
          );

          final result = await access.echoes(_noteId);

          expect(result, isA<EchoesReady>(), reason: '$reason');
          result as EchoesReady;
          expect(result.emptyNote, isFalse, reason: '$reason');
          expect(result.echoes, hasLength(1), reason: '$reason');
          expect(result.pending, 7, reason: '$reason');
        }
      },
    );

    test('local echoes keep the order the CLI printed them in', () async {
      final rows = [
        for (final p in ['first', 'second', 'third']) _echoRow(passage: p),
      ];
      final (access, _) = _access(
        (_) => FakeMemexCli.ok(_stdout(echoes: rows)),
      );

      final result = await access.echoes(_noteId) as EchoesReady;

      expect(result.echoes.map((e) => e.passage), ['first', 'second', 'third']);
    });
  });

  group('the command', () {
    test(
      'local runs memex echoes with the vault and note id and a 60 s timeout',
      () async {
        final (access, cli) = _access((_) => FakeMemexCli.ok(_stdout()));

        await access.echoes(_noteId);

        expect(cli.calls, hasLength(1));
        final call = cli.calls.single;
        expect(call.args, ['echoes', '--vault', _vault, '--note-id', _noteId]);
        expect(call.hasFlag('allow-download'), isFalse);
        expect(call.hasFlag('limit'), isFalse, reason: 'the CLI default is 8');
        expect(call.timeout, const Duration(seconds: 60));
        expect(call.stdinBody, isNull);
      },
    );

    test(
      'local allowDownload adds --allow-download and a 10 minute timeout',
      () async {
        final (access, cli) = _access((_) => FakeMemexCli.ok(_stdout()));

        await access.echoes(_noteId, allowDownload: true);

        expect(cli.calls, hasLength(1));
        final call = cli.calls.single;
        expect(call.args, [
          'echoes',
          '--vault',
          _vault,
          '--note-id',
          _noteId,
          '--allow-download',
        ]);
        expect(call.timeout, const Duration(minutes: 10));
      },
    );

    test(
      'local allowDownload false after true goes back to the 60 s timeout',
      () async {
        final (access, cli) = _access((_) => FakeMemexCli.ok(_stdout()));

        await access.echoes(_noteId, allowDownload: true);
        await access.echoes('01JOTHERNOTE000000000000000');

        expect(cli.calls, hasLength(2));
        expect(cli.calls[1].timeout, const Duration(seconds: 60));
        expect(cli.calls[1].hasFlag('allow-download'), isFalse);
        expect(cli.calls[1].flag('note-id'), '01JOTHERNOTE000000000000000');
      },
    );
  });

  group('unavailable', () {
    test('local with no CLI maps to NoCli', () async {
      final access = LocalEchoesAccess(vaultPath: _vault);

      expect(await access.echoes(_noteId), const EchoesUnavailable(NoCli()));
      expect(
        await access.echoes(_noteId, allowDownload: true),
        const EchoesUnavailable(NoCli()),
      );
    });

    test('local model_not_downloaded maps to ModelNotDownloaded', () async {
      final (access, cli) = _access(
        (_) => FakeMemexCli.error(
          'model_not_downloaded',
          'the embedding model is not downloaded',
        ),
      );

      expect(
        await access.echoes(_noteId),
        const EchoesUnavailable(ModelNotDownloaded()),
      );
      expect(cli.calls, hasLength(1));
    });

    test(
      'local embedder_unavailable maps to EmbedderUnavailable with the C1 message',
      () async {
        final (access, _) = _access(
          (_) => FakeMemexCli.error(
            'embedder_unavailable',
            'the embedder could not load: no network',
          ),
        );

        final result = await access.echoes(_noteId, allowDownload: true);

        expect(
          result,
          const EchoesUnavailable(
            EmbedderUnavailable('the embedder could not load: no network'),
          ),
        );
      },
    );

    test('local timeout maps to EmbedderUnavailable timed out', () async {
      for (final allowDownload in [false, true]) {
        final (access, cli) = _access(FakeMemexCli.timedOut);

        final result = await access.echoes(
          _noteId,
          allowDownload: allowDownload,
        );

        expect(
          result,
          const EchoesUnavailable(EmbedderUnavailable('timed out')),
          reason: 'allowDownload: $allowDownload',
        );
        expect(cli.calls, hasLength(1));
      }
    });
  });

  group('outdated binary', () {
    test('local exit 2 with non-JSON stderr maps to Outdated', () async {
      final (access, _) = _access(
        (_) => FakeMemexCli.failure(
          "error: unrecognized subcommand 'echoes'\n\nUsage: memex <COMMAND>\n",
          exitCode: 2,
        ),
      );

      expect(await access.echoes(_noteId), const EchoesUnavailable(Outdated()));
    });

    test(
      'local exit 2 with C1 JSON stderr is a normal C1 failure not Outdated',
      () async {
        final (unavailable, _) = _access(
          (_) => MemexResult(
            exitCode: 2,
            stdout: '',
            stderr:
                '{"error":{"code":"embedder_unavailable","message":"no model"}}\n',
          ),
        );
        expect(
          await unavailable.echoes(_noteId),
          const EchoesUnavailable(EmbedderUnavailable('no model')),
        );

        final (notFound, _) = _access(
          (_) => MemexResult(
            exitCode: 2,
            stdout: '',
            stderr:
                '{"error":{"code":"not_found","message":"not found: note"}}\n',
          ),
        );
        final e = await _outcome(notFound.echoes(_noteId));
        expect(e, isA<MemexException>());
        expect((e! as MemexException).code, 'not_found');
      },
    );

    test(
      'local non-zero exits other than 2 with non-JSON stderr throw MemexException',
      () async {
        for (final exitCode in [1, 3, 101]) {
          final (access, _) = _access(
            (_) =>
                FakeMemexCli.failure('thread panicked\n', exitCode: exitCode),
          );

          final e = await _outcome(access.echoes(_noteId));

          expect(e, isA<MemexException>(), reason: 'exit $exitCode');
          e as MemexException;
          expect(e.code, isNull, reason: 'exit $exitCode');
          expect(e.message, 'echoes failed: thread panicked\n');
        }
      },
    );
  });

  group('errors', () {
    test('local not_found throws MemexException', () async {
      final (access, _) = _access(
        (_) => FakeMemexCli.error('not_found', 'not found: note $_noteId'),
      );

      final e = await _outcome(access.echoes(_noteId));

      expect(e, isA<MemexException>());
      e as MemexException;
      expect(e.code, 'not_found');
      expect(e.message, 'echoes failed: not found: note $_noteId');
    });

    test(
      'local unmapped C1 codes throw MemexException with their code',
      () async {
        for (final code in [
          'embeddings_off',
          'invalid_argument',
          'internal',
          'vault_not_found',
        ]) {
          final (access, _) = _access(
            (_) => FakeMemexCli.error(code, 'm-$code'),
          );

          final e = await _outcome(access.echoes(_noteId));

          expect(e, isA<MemexException>(), reason: code);
          e as MemexException;
          expect(e.code, code);
          expect(e.message, 'echoes failed: m-$code');
        }
      },
    );

    test(
      'local exit 0 stdout that is not a valid echoes answer throws MemexException',
      () async {
        final bad = <String>[
          'not json at all\n',
          '',
          '[]\n',
          '{"pending":0,"reason":null}\n',
          '{"echoes":"nope","pending":0,"reason":null}\n',
          '{"echoes":[{"note_id":"n1"}],"pending":0,"reason":null}\n',
          '{"echoes":[],"pending":"0","reason":null}\n',
          '{"echoes":[],"reason":null}\n',
          '{"echoes":[],"pending":null,"reason":null}\n',
          '{"echoes":[7],"pending":0,"reason":null}\n',
          '{"echoes":[[]],"pending":0,"reason":null}\n',
        ];
        for (final stdout in bad) {
          final (access, _) = _access((_) => FakeMemexCli.ok(stdout));

          final e = await _outcome(access.echoes(_noteId));

          expect(e, isA<MemexException>(), reason: stdout);
          expect((e! as MemexException).code, isNull, reason: stdout);
        }
      },
    );
  });
}
