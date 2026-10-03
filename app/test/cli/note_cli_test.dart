// WI #31 (A13): the `memex rm` wrapper (C2.2, D21).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/note_cli.dart';
import 'package:open_memex_app/src/memex_cli.dart';

import '../support/fake_memex_cli.dart';

const _vault = '/tmp/om-fake-vault';
const _noteId = '01J9Z8Y7X6W5V4T3S2R1Q0P9N8';

/// C2.2 sample stdout.
const _c22Sample =
    '{"vault_id":"01HV0000000000000000000000","note_id":"01J9Z8Y7X6W5V4T3S2R1Q0P9N8","deleted":true}\n';

void main() {
  group('rm wrapper (AC8)', () {
    test(
      'deleteNote sends rm --vault --note-id --expected-version and parses the C2.2 sample',
      () async {
        final cli = FakeMemexCli()
          ..on('rm', (_) => FakeMemexCli.ok(_c22Sample));

        final result = await cli.deleteNote(
          vaultPath: _vault,
          noteId: _noteId,
          expectedVersion: 7,
        );

        expect(result.noteId, '01J9Z8Y7X6W5V4T3S2R1Q0P9N8');
        expect(result.deleted, isTrue);
        expect(result.vaultId, '01HV0000000000000000000000');
        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.args, [
          'rm',
          '--vault',
          _vault,
          '--note-id',
          _noteId,
          '--expected-version',
          '7',
        ]);
      },
    );

    test(
      'deleteNote reads noteId and deleted from stdout, not constants',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'rm',
            (_) => FakeMemexCli.ok(
              '{"deleted":false,"note_id":"01OTHER00000000000000000AB","vault_id":"01HV0000000000000000000009"}',
            ),
          );

        final result = await cli.deleteNote(
          vaultPath: _vault,
          noteId: '01OTHER00000000000000000AB',
          expectedVersion: 1,
        );

        expect(result.noteId, '01OTHER00000000000000000AB');
        expect(result.deleted, isFalse);
        expect(result.vaultId, '01HV0000000000000000000009');
      },
    );

    test(
      'a version_conflict stderr yields MemexException code version_conflict',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'rm',
            (_) => FakeMemexCli.error(
              'version_conflict',
              'note changed since last read',
              {'current_version': 9},
            ),
          );

        await expectLater(
          cli.deleteNote(
            vaultPath: _vault,
            noteId: _noteId,
            expectedVersion: 7,
          ),
          throwsA(
            isA<MemexException>()
                .having((e) => e.code, 'code', 'version_conflict')
                .having((e) => e.kind, 'kind', MemexErrorKind.versionConflict)
                .having((e) => e.fields['current_version'], 'fields', 9)
                .having(
                  (e) => e.message,
                  'message',
                  contains('note changed since last read'),
                ),
          ),
        );
      },
    );

    test('a not_found stderr yields MemexException code not_found', () async {
      final cli = FakeMemexCli()
        ..on('rm', (_) => FakeMemexCli.error('not_found', 'no such note'));

      await expectLater(
        cli.deleteNote(vaultPath: _vault, noteId: _noteId, expectedVersion: 7),
        throwsA(
          isA<MemexException>()
              .having((e) => e.code, 'code', 'not_found')
              .having((e) => e.kind, 'kind', MemexErrorKind.other)
              .having((e) => e.message, 'message', contains('no such note')),
        ),
      );
    });

    test(
      'non JSON stderr from rm surfaces a MemexException with a null code',
      () async {
        final cli = FakeMemexCli()
          ..on('rm', (_) => FakeMemexCli.failure('boom\n', exitCode: 2));

        await expectLater(
          cli.deleteNote(
            vaultPath: _vault,
            noteId: _noteId,
            expectedVersion: 7,
          ),
          throwsA(
            isA<MemexException>()
                .having((e) => e.code, 'code', isNull)
                .having((e) => e.message, 'message', contains('boom')),
          ),
        );
      },
    );

    test(
      'rm stdout that is not the C2.2 shape throws with a null code',
      () async {
        for (final out in ['not json', '{"note_id":"x"}', '[]']) {
          final cli = FakeMemexCli()..on('rm', (_) => FakeMemexCli.ok(out));
          await expectLater(
            cli.deleteNote(
              vaultPath: _vault,
              noteId: _noteId,
              expectedVersion: 1,
            ),
            throwsA(
              isA<MemexException>()
                  .having((e) => e.code, 'code', isNull)
                  .having((e) => e.message, 'message', contains('rm')),
            ),
            reason: out,
          );
        }
      },
    );
  });
}
