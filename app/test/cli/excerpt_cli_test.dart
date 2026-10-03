// WI #27 (A9) AC14: the `memex excerpt rm` wrapper (C2.4, D19, D21).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/excerpt_cli.dart';
import 'package:open_memex_app/src/memex_cli.dart';

import '../support/excerpt_cli_fakes.dart';
import '../support/fake_memex_cli.dart';

const _vault = '/tmp/om-fake-vault';
const _topicId = '01J9TOPIC0000000000000000A';

void main() {
  group('excerpt rm wrapper (AC14)', () {
    test(
      'removeExcerpt parses the C2.4 sample into a result with version 5',
      () async {
        final cli = FakeMemexCli()
          ..on('excerpt rm', (_) => FakeMemexCli.ok(excerptRmC24Sample));

        final result = await cli.removeExcerpt(
          vaultPath: _vault,
          topicNoteId: _topicId,
          date: '2026-09-05',
          fromBlockId: 'b7k2m9',
          toBlockId: 'c3d4e5',
        );

        expect(result.version, 5);
        expect(result.vaultId, '01HV…');
        expect(result.topicNoteId, '01J9…');
      },
    );

    test(
      'a range removal sends excerpt rm with both endpoint ids comma separated',
      () async {
        final cli = FakeMemexCli()
          ..on('excerpt rm', (_) => FakeMemexCli.ok(excerptRmC24Sample));

        await cli.removeExcerpt(
          vaultPath: _vault,
          topicNoteId: _topicId,
          date: '2026-09-05',
          fromBlockId: 'b7k2m9',
          toBlockId: 'c3d4e5',
        );

        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.subcommand, 'excerpt rm');
        expect(cli.calls.single.args, [
          'excerpt',
          'rm',
          '--vault',
          _vault,
          '--topic-note-id',
          _topicId,
          '--date',
          '2026-09-05',
          '--block-ids',
          'b7k2m9,c3d4e5',
        ]);
      },
    );

    test('a single block removal sends one block id', () async {
      final cli = FakeMemexCli()
        ..on('excerpt rm', (_) => FakeMemexCli.ok(excerptRmC24Sample));

      await cli.removeExcerpt(
        vaultPath: _vault,
        topicNoteId: _topicId,
        date: '2026-09-06',
        fromBlockId: 'b7k2m9',
      );

      final call = cli.calls.single;
      expect(call.flag('block-ids'), 'b7k2m9');
      expect(call.flag('date'), '2026-09-06');
      expect(call.flag('topic-note-id'), _topicId);
      expect(call.flag('vault'), _vault);
    });

    test(
      'removeExcerpt reads ids and version from stdout, not constants',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'excerpt rm',
            (_) => FakeMemexCli.ok(
              '{"version":12,"topic_note_id":"01J9OTHER000000000000000AB","vault_id":"01HV9"}\n',
            ),
          );

        final result = await cli.removeExcerpt(
          vaultPath: _vault,
          topicNoteId: '01J9OTHER000000000000000AB',
          date: '2026-09-05',
          fromBlockId: 'b7k2m9',
        );

        expect(result.version, 12);
        expect(result.topicNoteId, '01J9OTHER000000000000000AB');
        expect(result.vaultId, '01HV9');
      },
    );

    test('a not_found stderr yields MemexException code not_found', () async {
      final cli = FakeMemexCli()
        ..on(
          'excerpt rm',
          (_) => FakeMemexCli.error('not_found', 'no such transclusion'),
        );

      await expectLater(
        cli.removeExcerpt(
          vaultPath: _vault,
          topicNoteId: _topicId,
          date: '2026-09-05',
          fromBlockId: 'b7k2m9',
        ),
        throwsA(
          isA<MemexException>()
              .having((e) => e.code, 'code', 'not_found')
              .having((e) => e.kind, 'kind', MemexErrorKind.other)
              .having(
                (e) => e.message,
                'message',
                contains('no such transclusion'),
              ),
        ),
      );
    });

    test('role_rule and invalid_date stderr keep their C1 codes', () async {
      for (final code in ['role_rule', 'invalid_date']) {
        final cli = FakeMemexCli()
          ..on('excerpt rm', (_) => FakeMemexCli.error(code, 'nope $code'));
        await expectLater(
          cli.removeExcerpt(
            vaultPath: _vault,
            topicNoteId: _topicId,
            date: '2026-09-05',
            fromBlockId: 'b7k2m9',
          ),
          throwsA(
            isA<MemexException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.message, 'message', contains('nope $code')),
          ),
          reason: code,
        );
      }
    });

    test(
      'excerpt rm stdout that is not the C2.4 shape throws with a null code',
      () async {
        for (final out in [
          'not json',
          '[]',
          '{"vault_id":"01HV…","topic_note_id":"01J9…"}',
          '{"vault_id":"01HV…","topic_note_id":"01J9…","version":"5"}',
          '{"vault_id":"01HV…","version":5}',
          '{"topic_note_id":"01J9…","version":5}',
        ]) {
          final cli = FakeMemexCli()
            ..on('excerpt rm', (_) => FakeMemexCli.ok(out));
          await expectLater(
            cli.removeExcerpt(
              vaultPath: _vault,
              topicNoteId: _topicId,
              date: '2026-09-05',
              fromBlockId: 'b7k2m9',
            ),
            throwsA(
              isA<MemexException>().having((e) => e.code, 'code', isNull),
            ),
            reason: out,
          );
        }
      },
    );
  });
}
