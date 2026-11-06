// WI #259 (F7) AC1: the `memex guide get|revisions|restore` wrappers pass the
// Contract's exact arguments (#256), parse the output object, throw a
// null-code MemexException for malformed stdout and keep the C1 code of a
// failure (`guide_rule`, `not_found`).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/guide_cli.dart';
import 'package:open_memex_app/src/memex_cli.dart';

import '../support/fake_memex_cli.dart';
import '../support/vault_access_shapes.dart';

const _vault = '/tmp/om-259-vault';

String _out(Object? json) => '${jsonEncode(json)}\n';

Matcher get _nullCode =>
    throwsA(isA<MemexException>().having((e) => e.code, 'code', isNull));

void main() {
  test('getGuide sends guide get --vault and parses the guide note', () async {
    final cli = FakeMemexCli()
      ..on(
        'guide get',
        (_) => FakeMemexCli.ok(
          _out({
            'vault_id': 'V1',
            'note_id': 'G1',
            'version': 4,
            'content_md': '# Vault Guide\n\nLine "two" é\n',
          }),
        ),
      );

    final guide = await cli.getGuide(vaultPath: _vault);

    expect(cli.calls.single.args, ['guide', 'get', '--vault', _vault]);
    expect(vaultAccessShape(guide), {
      'VaultGuide': ['V1', 'G1', 4, '# Vault Guide\n\nLine "two" é\n'],
    });
  });

  test(
    'guideRevisions sends guide revisions --vault and parses every revision in stdout order',
    () async {
      final cli = FakeMemexCli()
        ..on(
          'guide revisions',
          (_) => FakeMemexCli.ok(
            _out({
              'vault_id': 'V1',
              'revisions': [
                {'id': 'R2', 'agent_change_id': 'AC9', 'created_at': 2000},
                {'id': 'R1', 'agent_change_id': null, 'created_at': 1000},
              ],
            }),
          ),
        );

      final revisions = await cli.guideRevisions(vaultPath: _vault);

      expect(cli.calls.single.args, ['guide', 'revisions', '--vault', _vault]);
      expect(vaultAccessShape(revisions), [
        {
          'GuideRevisionRow': ['R2', 'AC9', 2000],
        },
        {
          'GuideRevisionRow': ['R1', null, 1000],
        },
      ]);
    },
  );

  test('guideRevisions parses an empty revision list', () async {
    final cli = FakeMemexCli()
      ..on(
        'guide revisions',
        (_) => FakeMemexCli.ok(_out({'vault_id': 'V1', 'revisions': []})),
      );

    expect(await cli.guideRevisions(vaultPath: _vault), isEmpty);
    expect(cli.calls.single.args, ['guide', 'revisions', '--vault', _vault]);
  });

  test(
    'restoreGuide sends guide restore --revision-id and parses the new version',
    () async {
      final cli = FakeMemexCli()
        ..on(
          'guide restore',
          (_) => FakeMemexCli.ok(
            _out({'vault_id': 'V1', 'note_id': 'G1', 'version': 7}),
          ),
        );

      final r = await cli.restoreGuide(vaultPath: _vault, revisionId: 'R1');

      expect(cli.calls.single.args, [
        'guide',
        'restore',
        '--vault',
        _vault,
        '--revision-id',
        'R1',
      ]);
      expect(vaultAccessShape(r), {
        'GuideRestoreResult': ['V1', 'G1', 7],
      });
    },
  );

  test('guide failures keep the C1 code of each command', () async {
    final cases = <(String, String, Future<Object?> Function(FakeMemexCli))>[
      ('guide get', 'guide_rule', (c) => c.getGuide(vaultPath: _vault)),
      (
        'guide revisions',
        'guide_rule',
        (c) => c.guideRevisions(vaultPath: _vault),
      ),
      (
        'guide restore',
        'not_found',
        (c) => c.restoreGuide(vaultPath: _vault, revisionId: 'R'),
      ),
      (
        'guide restore',
        'guide_rule',
        (c) => c.restoreGuide(vaultPath: _vault, revisionId: 'R'),
      ),
    ];
    for (final (sub, code, call) in cases) {
      final cli = FakeMemexCli()
        ..on(sub, (_) => FakeMemexCli.error(code, 'nope $code'));
      await expectLater(
        call(cli),
        throwsA(
          isA<MemexException>()
              .having((e) => e.code, 'code', code)
              .having((e) => e.message, 'message', contains('nope $code')),
        ),
        reason: '$sub $code',
      );
    }
  });

  test(
    'guide stdout that is not the Contract shape throws with a null code',
    () async {
      final getCases = [
        'not json',
        '[]',
        _out({'vault_id': 'V', 'note_id': 'G', 'version': 1}),
        _out({'vault_id': 'V', 'note_id': 'G', 'content_md': 'x'}),
        _out({'note_id': 'G', 'version': 1, 'content_md': 'x'}),
        _out({
          'vault_id': 'V',
          'note_id': 'G',
          'version': '1',
          'content_md': 'x',
        }),
      ];
      for (final out in getCases) {
        final cli = FakeMemexCli()
          ..on('guide get', (_) => FakeMemexCli.ok(out));
        await expectLater(
          cli.getGuide(vaultPath: _vault),
          _nullCode,
          reason: out,
        );
      }
      final revisionCases = [
        'not json',
        _out({'vault_id': 'V'}),
        _out({'vault_id': 'V', 'revisions': 'x'}),
        _out({
          'vault_id': 'V',
          'revisions': [
            {'agent_change_id': null, 'created_at': 1},
          ],
        }),
        _out({
          'vault_id': 'V',
          'revisions': [
            {'id': 'R', 'agent_change_id': null, 'created_at': '1'},
          ],
        }),
        // agent_change_id is a string or null: any other type is not the
        // Contract shape.
        _out({
          'vault_id': 'V',
          'revisions': [
            {'id': 'R', 'agent_change_id': 42, 'created_at': 1},
          ],
        }),
      ];
      for (final out in revisionCases) {
        final cli = FakeMemexCli()
          ..on('guide revisions', (_) => FakeMemexCli.ok(out));
        await expectLater(
          cli.guideRevisions(vaultPath: _vault),
          _nullCode,
          reason: out,
        );
      }
      final restoreCases = [
        'not json',
        _out({'vault_id': 'V', 'note_id': 'G'}),
        _out({'vault_id': 'V', 'version': 2}),
        _out({'note_id': 'G', 'version': 2}),
        _out({'vault_id': 'V', 'note_id': 'G', 'version': 'x'}),
      ];
      for (final out in restoreCases) {
        final cli = FakeMemexCli()
          ..on('guide restore', (_) => FakeMemexCli.ok(out));
        await expectLater(
          cli.restoreGuide(vaultPath: _vault, revisionId: 'R'),
          _nullCode,
          reason: out,
        );
      }
    },
  );
}
