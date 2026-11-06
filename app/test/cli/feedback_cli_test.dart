// WI #259 (F7) AC1: the `memex filing` and `memex feedback add|edit|rm|ls`
// wrappers pass the Contract's exact arguments (#256), parse the output
// object, throw a null-code MemexException for malformed stdout and keep the
// C1 code of a failure.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/feedback_cli.dart';
import 'package:open_memex_app/src/memex_cli.dart';

import '../support/fake_memex_cli.dart';
import '../support/feedback_seeds.dart';
import '../support/vault_access_shapes.dart';

const _vault = '/tmp/om-259-vault';

String _out(Object? json) => '${jsonEncode(json)}\n';

Matcher get _nullCode =>
    throwsA(isA<MemexException>().having((e) => e.code, 'code', isNull));

Matcher _code(String code) =>
    throwsA(isA<MemexException>().having((e) => e.code, 'code', code));

void main() {
  group('filing wrapper', () {
    test(
      'filing sends filing --vault --date and parses the Filing object',
      () async {
        final cli = FakeMemexCli()
          ..on('filing', (_) => FakeMemexCli.ok(_out(filingJson())));

        final filing = await cli.filing(vaultPath: _vault, date: '2026-11-05');

        expect(cli.calls.single.args, [
          'filing',
          '--vault',
          _vault,
          '--date',
          '2026-11-05',
        ]);
        expect(vaultAccessShape(filing), filingShape);
      },
    );

    test('filing reads its fields from stdout, not constants', () async {
      final cli = FakeMemexCli()
        ..on(
          'filing',
          (_) => FakeMemexCli.ok(
            _out({
              'vault_id': 'V2',
              'date': '2026-01-02',
              'note_id': 'N2',
              'reviewed': false,
              'topics': <Object?>[],
              'not_filed': <Object?>[],
            }),
          ),
        );

      final filing = await cli.filing(vaultPath: _vault, date: '2026-01-02');

      expect(vaultAccessShape(filing), {
        'Filing': ['V2', '2026-01-02', 'N2', false, <Object?>[], <Object?>[]],
      });
    });

    test('filing failures keep the C1 code', () async {
      for (final code in ['not_found', 'invalid_date']) {
        final cli = FakeMemexCli()
          ..on('filing', (_) => FakeMemexCli.error(code, 'no $code'));
        await expectLater(
          cli.filing(vaultPath: _vault, date: '2026-11-05'),
          _code(code),
          reason: code,
        );
      }
    });

    test(
      'filing stdout that is not the Filing shape throws with a null code',
      () async {
        final good = filingJson();
        final cases = <String>[
          'not json',
          '[]',
          _out({...good}..remove('reviewed')),
          _out({...good}..remove('not_filed')),
          _out({...good, 'reviewed': 'yes'}),
          _out({
            ...good,
            'topics': [
              {'topic_note_id': 'T', 'title': 'x'},
            ],
          }),
          _out({
            ...good,
            'not_filed': [
              {'id': 'a'},
            ],
          }),
        ];
        for (final out in cases) {
          final cli = FakeMemexCli()..on('filing', (_) => FakeMemexCli.ok(out));
          await expectLater(
            cli.filing(vaultPath: _vault, date: '2026-11-05'),
            _nullCode,
            reason: out,
          );
        }
      },
    );
  });

  group('feedback wrappers', () {
    test(
      'addFeedback sends feedback add with every flag and parses the Feedback',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'feedback add',
            (_) => FakeMemexCli.ok(_out(feedbackJson(id: '01J9NEW'))),
          );

        final row = await cli.addFeedback(
          vaultPath: _vault,
          noteId: 'N1',
          date: '2026-11-05',
          changeId: 'C1',
          text: 'Wrong "quote" bullet',
        );

        expect(cli.calls.single.args, [
          'feedback',
          'add',
          '--vault',
          _vault,
          '--note-id',
          'N1',
          '--date',
          '2026-11-05',
          '--change-id',
          'C1',
          '--text',
          'Wrong "quote" bullet',
        ]);
        expect(vaultAccessShape(row), {
          'FeedbackRow': [
            '01J9NEW',
            'comment',
            'person',
            '01J9NOTE00000000000000000A',
            '2026-11-05',
            '01J9CHG000000000000000000A',
            'This bullet is wrong',
            null,
            'open',
            null,
            1762300000000,
            1762300000500,
            null,
          ],
        });
      },
    );

    test(
      'editFeedback sends feedback edit --id --text and parses the Feedback',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'feedback edit',
            (_) => FakeMemexCli.ok(
              _out(
                feedbackJson(overrides: {'text': 'edited', 'updated_at': 9}),
              ),
            ),
          );

        final row = await cli.editFeedback(
          vaultPath: _vault,
          id: 'F1',
          text: 'edited',
        );

        expect(cli.calls.single.args, [
          'feedback',
          'edit',
          '--vault',
          _vault,
          '--id',
          'F1',
          '--text',
          'edited',
        ]);
        expect(row.text, 'edited');
        expect(row.updatedAt, 9);
      },
    );

    test(
      'removeFeedback sends feedback rm --id and parses vault_id and id',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'feedback rm',
            (_) => FakeMemexCli.ok(_out({'vault_id': 'V9', 'id': 'F1'})),
          );

        final r = await cli.removeFeedback(vaultPath: _vault, id: 'F1');

        expect(cli.calls.single.args, [
          'feedback',
          'rm',
          '--vault',
          _vault,
          '--id',
          'F1',
        ]);
        expect(vaultAccessShape(r), {
          'FeedbackRemoveResult': ['V9', 'F1'],
        });
      },
    );

    test(
      'listFeedback with a note id sends feedback ls --note-id and no no-note flag',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'feedback ls',
            (_) => FakeMemexCli.ok(
              _out({
                'vault_id': 'V',
                'feedback': [
                  feedbackJson(id: 'F2', overrides: {'created_at': 2000}),
                  feedbackJson(
                    id: 'F1',
                    overrides: {
                      'status': 'handled',
                      'reply': 'ok',
                      'handled_at': 1500,
                      'created_at': 1000,
                    },
                  ),
                ],
              }),
            ),
          );

        final rows = await cli.listFeedback(vaultPath: _vault, noteId: 'N1');

        expect(cli.calls.single.args, [
          'feedback',
          'ls',
          '--vault',
          _vault,
          '--note-id',
          'N1',
        ]);
        expect(cli.calls.single.hasFlag('no-note'), isFalse);
        expect(rows.map((r) => r.id).toList(), [
          'F2',
          'F1',
        ], reason: 'stdout order');
        expect(rows.map((r) => r.status.name).toList(), ['open', 'handled']);
        expect(rows.last.reply, 'ok');
        expect(rows.last.handledAt, 1500);
      },
    );

    test(
      'listFeedback with no note id sends feedback ls --no-note and no note id',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'feedback ls',
            (_) => FakeMemexCli.ok(_out({'vault_id': 'V', 'feedback': []})),
          );

        final rows = await cli.listFeedback(vaultPath: _vault);

        expect(cli.calls.single.args, [
          'feedback',
          'ls',
          '--vault',
          _vault,
          '--no-note',
        ]);
        expect(cli.calls.single.hasFlag('note-id'), isFalse);
        expect(rows, isEmpty);
      },
    );

    test(
      'listFeedback decodes every correction kind of the Contract',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'feedback ls',
            (_) => FakeMemexCli.ok(
              _out({
                'vault_id': 'V',
                'feedback': [
                  for (final e in correctionSamples.entries)
                    feedbackJson(
                      id: 'F-${e.key}',
                      overrides: {
                        'kind': 'correction',
                        'text': null,
                        'correction': e.value,
                      },
                    ),
                ],
              }),
            ),
          );

        final rows = await cli.listFeedback(vaultPath: _vault, noteId: 'N1');

        expect(rows, hasLength(8));
        for (final (i, kind) in correctionSamples.keys.indexed) {
          expect(
            correctionMatchesKind(kind, rows[i].correction),
            isTrue,
            reason: kind,
          );
          expect(
            vaultAccessShape(rows[i].correction),
            correctionShapes[kind],
            reason: kind,
          );
          expect(rows[i].kind.name, 'correction');
        }
      },
    );

    test('feedback failures keep the C1 code of each command', () async {
      final cases = <(String, String, Future<Object?> Function(FakeMemexCli))>[
        (
          'feedback add',
          'feedback_invalid',
          (c) => c.addFeedback(
            vaultPath: _vault,
            noteId: 'N',
            date: '2026-11-05',
            changeId: 'C',
            text: ' ',
          ),
        ),
        (
          'feedback add',
          'not_found',
          (c) => c.addFeedback(
            vaultPath: _vault,
            noteId: 'N',
            date: '2026-11-05',
            changeId: 'C',
            text: 't',
          ),
        ),
        (
          'feedback edit',
          'feedback_handled',
          (c) => c.editFeedback(vaultPath: _vault, id: 'F', text: 't'),
        ),
        (
          'feedback rm',
          'feedback_handled',
          (c) => c.removeFeedback(vaultPath: _vault, id: 'F'),
        ),
        (
          'feedback ls',
          'not_found',
          (c) => c.listFeedback(vaultPath: _vault, noteId: 'N'),
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
      'feedback stdout that is not the Contract shape throws with a null code',
      () async {
        final badRows = <Map<String, Object?>>[
          {...feedbackJson()}..remove('id'),
          {...feedbackJson()}..remove('status'),
          {...feedbackJson()}..remove('created_at'),
          feedbackJson(overrides: {'kind': 'note'}),
          feedbackJson(overrides: {'source': 'robot'}),
          feedbackJson(overrides: {'status': 'pending'}),
          feedbackJson(overrides: {'created_at': '1000'}),
          feedbackJson(overrides: {'text': 5}),
        ];
        for (final bad in badRows) {
          final add = FakeMemexCli()
            ..on('feedback add', (_) => FakeMemexCli.ok(_out(bad)));
          await expectLater(
            add.addFeedback(
              vaultPath: _vault,
              noteId: 'N',
              date: '2026-11-05',
              changeId: 'C',
              text: 't',
            ),
            _nullCode,
            reason: 'add $bad',
          );
          final edit = FakeMemexCli()
            ..on('feedback edit', (_) => FakeMemexCli.ok(_out(bad)));
          await expectLater(
            edit.editFeedback(vaultPath: _vault, id: 'F', text: 't'),
            _nullCode,
            reason: 'edit $bad',
          );
          final ls = FakeMemexCli()
            ..on(
              'feedback ls',
              (_) => FakeMemexCli.ok(
                _out({
                  'vault_id': 'V',
                  'feedback': [bad],
                }),
              ),
            );
          await expectLater(
            ls.listFeedback(vaultPath: _vault, noteId: 'N'),
            _nullCode,
            reason: 'ls $bad',
          );
        }
        for (final out in [
          'not json',
          '[]',
          _out({'feedback': []}),
          _out({'vault_id': 'V'}),
          _out({'vault_id': 'V', 'feedback': 'x'}),
        ]) {
          final ls = FakeMemexCli()
            ..on('feedback ls', (_) => FakeMemexCli.ok(out));
          await expectLater(
            ls.listFeedback(vaultPath: _vault),
            _nullCode,
            reason: 'ls $out',
          );
        }
        for (final out in [
          'not json',
          _out({'vault_id': 'V'}),
          _out({'id': 'F'}),
          _out({'vault_id': 'V', 'id': 5}),
        ]) {
          final rm = FakeMemexCli()
            ..on('feedback rm', (_) => FakeMemexCli.ok(out));
          await expectLater(
            rm.removeFeedback(vaultPath: _vault, id: 'F'),
            _nullCode,
            reason: 'rm $out',
          );
        }
      },
    );
  });
}
