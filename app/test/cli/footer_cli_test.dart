// WI #26 (A14): the `memex footer add` wrapper (C2.3, D21).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/footer_cli.dart';
import 'package:open_memex_app/src/memex_cli.dart';

import '../support/fake_memex_cli.dart';
import '../support/footer_cli_fakes.dart';

const _vault = '/tmp/om-fake-vault';
const _dailyId = '01J9Z8Y7X6W5V4T3S2R1Q0P9N8';
const _topicId = '01J9Z8Y7X6W5V4T3S2R1Q0TOPC';

void main() {
  group('footer add wrapper (AC8)', () {
    test(
      'addFooterChip sends footer add --vault --daily-note-id --topic-note-id and parses the C2.3 sample',
      () async {
        final cli = FakeMemexCli()
          ..on('footer add', (_) => FakeMemexCli.ok('$footerAddSample\n'));

        final result = await cli.addFooterChip(
          vaultPath: _vault,
          dailyNoteId: _dailyId,
          topicNoteId: _topicId,
        );

        expect(result.origin, 'person');
        expect(result.version, 7);
        expect(result.vaultId, '01HV0000000000000000000000');
        expect(result.dailyNoteId, _dailyId);
        expect(result.topicNoteId, _topicId);
        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.args, [
          'footer',
          'add',
          '--vault',
          _vault,
          '--daily-note-id',
          _dailyId,
          '--topic-note-id',
          _topicId,
        ]);
      },
    );

    test('addFooterChip reads every field from stdout, not constants', () async {
      final cli = FakeMemexCli()
        ..on(
          'footer add',
          (_) => FakeMemexCli.ok(
            '{"version":12,"origin":"person","topic_note_id":"01OTHERTOPIC00000000000000",'
            '"daily_note_id":"01OTHERDAILY00000000000000","vault_id":"01HV0000000000000000000009"}',
          ),
        );

      final result = await cli.addFooterChip(
        vaultPath: _vault,
        dailyNoteId: '01OTHERDAILY00000000000000',
        topicNoteId: '01OTHERTOPIC00000000000000',
      );

      expect(result.version, 12);
      expect(result.vaultId, '01HV0000000000000000000009');
      expect(result.dailyNoteId, '01OTHERDAILY00000000000000');
      expect(result.topicNoteId, '01OTHERTOPIC00000000000000');
    });

    test('a role_rule stderr yields MemexException code role_rule', () async {
      final cli = FakeMemexCli()
        ..on(
          'footer add',
          (_) => FakeMemexCli.error(
            'role_rule',
            'footer chips link a daily note to a topic note',
          ),
        );

      await expectLater(
        cli.addFooterChip(
          vaultPath: _vault,
          dailyNoteId: _dailyId,
          topicNoteId: _topicId,
        ),
        throwsA(
          isA<MemexException>()
              .having((e) => e.code, 'code', 'role_rule')
              .having(
                (e) => e.message,
                'message',
                contains('footer chips link a daily note to a topic note'),
              ),
        ),
      );
    });

    test('a not_found stderr yields MemexException code not_found', () async {
      final cli = FakeMemexCli()
        ..on('footer add', (_) => FakeMemexCli.error('not_found', 'no note'));

      await expectLater(
        cli.addFooterChip(
          vaultPath: _vault,
          dailyNoteId: _dailyId,
          topicNoteId: _topicId,
        ),
        throwsA(
          isA<MemexException>()
              .having((e) => e.code, 'code', 'not_found')
              .having((e) => e.message, 'message', contains('no note')),
        ),
      );
    });

    test(
      'non JSON stderr from footer add surfaces a MemexException with a null code',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'footer add',
            (_) => FakeMemexCli.failure('boom\n', exitCode: 2),
          );

        await expectLater(
          cli.addFooterChip(
            vaultPath: _vault,
            dailyNoteId: _dailyId,
            topicNoteId: _topicId,
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
      'footer add stdout that is not the C2.3 shape throws with a null code',
      () async {
        for (final out in [
          'not json',
          '{"daily_note_id":"x"}',
          '[]',
          '{"vault_id":"v","daily_note_id":"d","topic_note_id":"t","origin":"person"}',
        ]) {
          final cli = FakeMemexCli()
            ..on('footer add', (_) => FakeMemexCli.ok(out));
          await expectLater(
            cli.addFooterChip(
              vaultPath: _vault,
              dailyNoteId: _dailyId,
              topicNoteId: _topicId,
            ),
            throwsA(
              isA<MemexException>()
                  .having((e) => e.code, 'code', isNull)
                  .having((e) => e.message, 'message', contains('footer add')),
            ),
            reason: out,
          );
        }
      },
    );
  });
}
