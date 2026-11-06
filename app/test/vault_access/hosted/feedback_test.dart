// WI #259 (F7): HostedFeedbackAccess over HostedClient (D13, D17) against the
// Contract of #256, replayed by `fake_vault_server.dart`.
//
// Pinned routes (under `/vaults/<vault>/api/v1`):
//   GET    /daily-notes/{date}/filing                 -> Filing
//   POST   /notes/{topic}/excerpts {date, block_id, note?}
//                                                      -> {vault_id, topic_note_id, version}
//   DELETE /notes/{topic}/excerpts/blocks/{block}?date=&note=
//                                                      -> {vault_id, topic_note_id, version}
//   POST   /notes/{from}/excerpts/move {date, block_id, to_topic_note_id, note?}
//                                                      -> {vault_id, from_topic_note_id,
//                                                          from_version, to_topic_note_id, to_version}
//   POST   /feedback {note_id, date, change_id, text}  -> Feedback
//   PATCH  /feedback/{id} {text}                       -> Feedback
//   DELETE /feedback/{id}                              -> {vault_id, id}
//   GET    /feedback?note_id=N | GET /feedback         -> {vault_id, feedback: [Feedback]}
//                                                         (no parameter = the no-note list)
//   GET    /guide                                      -> {vault_id, note_id, version, content_md}
//   GET    /guide/revisions                            -> {vault_id, revisions: [{id, agent_change_id, created_at}]}
//   POST   /guide/revisions/{id}/restore               -> {vault_id, note_id, version}
// Path parameters are one encoded segment each. Errors are
// MemexException.fromC1 labelled with the CLI command name (`filing`,
// `excerpt add`, `excerpt remove-block`, `excerpt move`, `feedback add`,
// `feedback edit`, `feedback rm`, `feedback ls`, `guide get`,
// `guide revisions`, `guide restore`); a response that is not the Contract
// shape throws a MemexException with a null code.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/feedback.dart';

import '../../support/fake_clock.dart';
import '../../support/fake_vault_server.dart';
import '../../support/feedback_seeds.dart';
import '../../support/vault_access_shapes.dart';

const _base = '/vaults/seed/api/v1';

class _Env {
  _Env(this.server, this.feedback);

  final FakeVaultServer server;
  final HostedFeedbackAccess feedback;

  http.Request get last => server.requests.last;

  Object? get lastBody => jsonDecode(last.body);
}

_Env _env({String vaultName = 'seed'}) {
  final server = FakeVaultServer();
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  return _Env(
    server,
    HostedFeedbackAccess(
      client: server.connect(container),
      vaultName: vaultName,
    ),
  );
}

Map<String, Object?> _edit(int v) => {
  'vault_id': 'V1',
  'topic_note_id': 'T1',
  'version': v,
};

Map<String, Object?> _list(List<Map<String, Object?>> rows) => {
  'vault_id': 'V1',
  'feedback': rows,
};

/// One hosted call, labelled: its route, the success body, the CLI-style
/// operation label of its errors and the call itself.
class _Call {
  _Call(this.method, this.path, this.ok, this.op, this.call);

  final String method;
  final String path;
  final Object? ok;
  final String op;
  final Future<Object?> Function(HostedFeedbackAccess) call;
}

Map<String, _Call> _calls() => {
  'filing': _Call(
    'GET',
    '$_base/daily-notes/2026-11-05/filing',
    filingJson(),
    'filing',
    (a) => a.filing('2026-11-05'),
  ),
  'fileBlock': _Call(
    'POST',
    '$_base/notes/T1/excerpts',
    _edit(4),
    'excerpt add',
    (a) => a.fileBlock(topicNoteId: 'T1', date: '2026-11-05', blockId: 'b1'),
  ),
  'removeBlock': _Call(
    'DELETE',
    '$_base/notes/T1/excerpts/blocks/b1?date=2026-11-05',
    _edit(5),
    'excerpt remove-block',
    (a) => a.removeBlock(topicNoteId: 'T1', date: '2026-11-05', blockId: 'b1'),
  ),
  'moveBlock': _Call(
    'POST',
    '$_base/notes/A1/excerpts/move',
    {
      'vault_id': 'V1',
      'from_topic_note_id': 'A1',
      'from_version': 2,
      'to_topic_note_id': 'C1',
      'to_version': 3,
    },
    'excerpt move',
    (a) => a.moveBlock(
      fromTopicNoteId: 'A1',
      toTopicNoteId: 'C1',
      date: '2026-11-05',
      blockId: 'b1',
    ),
  ),
  'addComment': _Call(
    'POST',
    '$_base/feedback',
    feedbackJson(),
    'feedback add',
    (a) => a.addComment(
      noteId: 'N1',
      date: '2026-11-05',
      changeId: 'C1',
      text: 't',
    ),
  ),
  'editComment': _Call(
    'PATCH',
    '$_base/feedback/F1',
    feedbackJson(),
    'feedback edit',
    (a) => a.editComment(id: 'F1', text: 't'),
  ),
  'deleteComment': _Call(
    'DELETE',
    '$_base/feedback/F1',
    {'vault_id': 'V1', 'id': 'F1'},
    'feedback rm',
    (a) => a.deleteComment(id: 'F1'),
  ),
  'feedbackForNote': _Call(
    'GET',
    '$_base/feedback?note_id=N1',
    _list([feedbackJson()]),
    'feedback ls',
    (a) => a.feedbackForNote('N1'),
  ),
  'feedbackWithoutNote': _Call(
    'GET',
    '$_base/feedback',
    _list([feedbackJson()]),
    'feedback ls',
    (a) => a.feedbackWithoutNote(),
  ),
  'guide': _Call(
    'GET',
    '$_base/guide',
    {'vault_id': 'V1', 'note_id': 'G1', 'version': 3, 'content_md': '# G'},
    'guide get',
    (a) => a.guide(),
  ),
  'guideRevisions': _Call(
    'GET',
    '$_base/guide/revisions',
    {
      'vault_id': 'V1',
      'revisions': [
        {'id': 'R1', 'agent_change_id': null, 'created_at': 1},
      ],
    },
    'guide revisions',
    (a) => a.guideRevisions(),
  ),
  'restoreGuide': _Call(
    'POST',
    '$_base/guide/revisions/R1/restore',
    {'vault_id': 'V1', 'note_id': 'G1', 'version': 4},
    'guide restore',
    (a) => a.restoreGuide('R1'),
  ),
};

Future<Object?> _outcome(Future<Object?> f) async {
  try {
    return await f;
  } catch (e) {
    return e;
  }
}

void _serve(_Env env, _Call c, {int status = 200, Object? json}) =>
    env.server.route(c.method, c.path, status: status, json: json ?? c.ok);

void main() {
  group('filing', () {
    test(
      'filing sends GET daily-notes date filing with no body and decodes the Filing',
      () async {
        final env = _env();
        env.server.route(
          'GET',
          '$_base/daily-notes/2026-11-05/filing',
          json: filingJson(),
        );

        final filing = await env.feedback.filing('2026-11-05');

        expect(env.server.requests, hasLength(1));
        expect(env.last.method, 'GET');
        expect(env.last.url.path, '$_base/daily-notes/2026-11-05/filing');
        expect(env.last.url.query, isEmpty);
        expect(env.last.body, isEmpty);
        expect(env.last.headers['authorization'], 'Bearer $fakeServerToken');
        expect(vaultAccessShape(filing), filingShape);
      },
    );
  });

  group('block filing', () {
    test(
      'fileBlock sends POST notes topic excerpts with date block_id and note and decodes the result',
      () async {
        final env = _env();
        env.server.route('POST', '$_base/notes/T1/excerpts', json: _edit(4));

        final r = await env.feedback.fileBlock(
          topicNoteId: 'T1',
          date: '2026-11-05',
          blockId: 'b7k2m9',
          note: 'belongs here',
        );

        expect(env.last.method, 'POST');
        expect(env.last.url.path, '$_base/notes/T1/excerpts');
        expect(env.last.url.query, isEmpty);
        expect(env.lastBody, {
          'date': '2026-11-05',
          'block_id': 'b7k2m9',
          'note': 'belongs here',
        });
        expect(vaultAccessShape(r), {
          'ExcerptEditResult': ['V1', 'T1', 4],
        });
      },
    );

    test('fileBlock without a note sends no note key', () async {
      final env = _env();
      env.server.route('POST', '$_base/notes/T1/excerpts', json: _edit(4));

      await env.feedback.fileBlock(
        topicNoteId: 'T1',
        date: '2026-11-05',
        blockId: 'b7k2m9',
      );

      expect(env.lastBody, {'date': '2026-11-05', 'block_id': 'b7k2m9'});
    });

    test(
      'moveBlock sends POST on the source note with date block_id to_topic_note_id and note',
      () async {
        final env = _env();
        env.server.route(
          'POST',
          '$_base/notes/A1/excerpts/move',
          json: _calls()['moveBlock']!.ok,
        );

        final r = await env.feedback.moveBlock(
          fromTopicNoteId: 'A1',
          toTopicNoteId: 'C1',
          date: '2026-11-05',
          blockId: 'b7k2m9',
          note: 'wrong topic',
        );

        expect(env.last.method, 'POST');
        expect(env.last.url.path, '$_base/notes/A1/excerpts/move');
        expect(env.lastBody, {
          'date': '2026-11-05',
          'block_id': 'b7k2m9',
          'to_topic_note_id': 'C1',
          'note': 'wrong topic',
        });
        expect(vaultAccessShape(r), {
          'ExcerptMoveResult': ['V1', 'A1', 2, 'C1', 3],
        });
      },
    );

    test('moveBlock without a note sends no note key', () async {
      final env = _env();
      env.server.route(
        'POST',
        '$_base/notes/A1/excerpts/move',
        json: _calls()['moveBlock']!.ok,
      );

      await env.feedback.moveBlock(
        fromTopicNoteId: 'A1',
        toTopicNoteId: 'C1',
        date: '2026-11-05',
        blockId: 'b7k2m9',
      );

      expect(env.lastBody, {
        'date': '2026-11-05',
        'block_id': 'b7k2m9',
        'to_topic_note_id': 'C1',
      });
    });

    test(
      'removeBlock sends DELETE with date and note in the query and no body',
      () async {
        final env = _env();
        env.server.route(
          'DELETE',
          '$_base/notes/T1/excerpts/blocks/b7k2m9?date=2026-11-05&note=wrong',
          json: _edit(5),
        );

        final r = await env.feedback.removeBlock(
          topicNoteId: 'T1',
          date: '2026-11-05',
          blockId: 'b7k2m9',
          note: 'wrong',
        );

        expect(env.last.method, 'DELETE');
        expect(env.last.url.path, '$_base/notes/T1/excerpts/blocks/b7k2m9');
        expect(env.last.url.queryParameters, {
          'date': '2026-11-05',
          'note': 'wrong',
        });
        expect(env.last.body, isEmpty);
        expect(vaultAccessShape(r), {
          'ExcerptEditResult': ['V1', 'T1', 5],
        });
      },
    );

    test(
      'removeBlock without a note sends only the date in the query',
      () async {
        final env = _env();
        env.server.route(
          'DELETE',
          '$_base/notes/T1/excerpts/blocks/b7k2m9?date=2026-11-05',
          json: _edit(5),
        );

        await env.feedback.removeBlock(
          topicNoteId: 'T1',
          date: '2026-11-05',
          blockId: 'b7k2m9',
        );

        expect(env.last.url.queryParameters, {'date': '2026-11-05'});
      },
    );

    test(
      'removeBlock sends a note with spaces and symbols decoded intact',
      () async {
        final env = _env();
        const note = 'not about this & that = 100%';
        final encoded = Uri(
          queryParameters: {'date': '2026-11-05', 'note': note},
        ).query;
        env.server.route(
          'DELETE',
          '$_base/notes/T1/excerpts/blocks/b1?$encoded',
          json: _edit(5),
        );

        await env.feedback.removeBlock(
          topicNoteId: 'T1',
          date: '2026-11-05',
          blockId: 'b1',
          note: note,
        );

        expect(env.last.url.queryParameters['note'], note);
      },
    );
  });

  group('comments', () {
    test(
      'addComment sends POST feedback with note_id date change_id and text and decodes the Feedback',
      () async {
        final env = _env();
        env.server.route(
          'POST',
          '$_base/feedback',
          json: feedbackJson(id: 'FNEW'),
        );

        final row = await env.feedback.addComment(
          noteId: 'N1',
          date: '2026-11-05',
          changeId: 'C1',
          text: 'a comment',
        );

        expect(env.last.method, 'POST');
        expect(env.last.url.path, '$_base/feedback');
        expect(env.lastBody, {
          'note_id': 'N1',
          'date': '2026-11-05',
          'change_id': 'C1',
          'text': 'a comment',
        });
        expect(row.id, 'FNEW');
        expect(row.kind.name, 'comment');
        expect(row.text, 'This bullet is wrong');
      },
    );

    test(
      'editComment sends PATCH feedback id with the text and decodes the Feedback',
      () async {
        final env = _env();
        env.server.route(
          'PATCH',
          '$_base/feedback/F1',
          json: feedbackJson(id: 'F1', overrides: {'text': 'better'}),
        );

        final row = await env.feedback.editComment(id: 'F1', text: 'better');

        expect(env.last.method, 'PATCH');
        expect(env.last.url.path, '$_base/feedback/F1');
        expect(env.lastBody, {'text': 'better'});
        expect(row.id, 'F1');
        expect(row.text, 'better');
      },
    );

    test('editComment sends the id as one encoded path segment', () async {
      final env = _env();
      env.server.route(
        'PATCH',
        '$_base/feedback/a%2Fb%3Fc%20d',
        json: feedbackJson(),
      );

      await env.feedback.editComment(id: 'a/b?c d', text: 't');

      expect(env.last.url.pathSegments.last, 'a/b?c d');
      expect(env.last.url.query, isEmpty);
    });

    test(
      'deleteComment sends DELETE feedback id with no body and decodes the result',
      () async {
        final env = _env();
        env.server.route(
          'DELETE',
          '$_base/feedback/F1',
          json: {'vault_id': 'V1', 'id': 'F1'},
        );

        final r = await env.feedback.deleteComment(id: 'F1');

        expect(env.last.method, 'DELETE');
        expect(env.last.url.path, '$_base/feedback/F1');
        expect(env.last.body, isEmpty);
        expect(vaultAccessShape(r), {
          'FeedbackRemoveResult': ['V1', 'F1'],
        });
      },
    );
  });

  group('feedback reads', () {
    test(
      'feedbackForNote sends GET feedback with note_id and decodes every row in server order',
      () async {
        final env = _env();
        env.server.route(
          'GET',
          '$_base/feedback?note_id=N1',
          json: _list([
            feedbackJson(id: 'F2', overrides: {'created_at': 2000}),
            feedbackJson(
              id: 'F1',
              overrides: {
                'kind': 'correction',
                'source': 'chat',
                'text': null,
                'correction': correctionSamples['excerpt_moved'],
                'status': 'handled',
                'reply': 'Done',
                'created_at': 1000,
                'handled_at': 1500,
              },
            ),
          ]),
        );

        final rows = await env.feedback.feedbackForNote('N1');

        expect(env.last.method, 'GET');
        expect(env.last.url.path, '$_base/feedback');
        expect(env.last.url.queryParameters, {'note_id': 'N1'});
        expect(env.last.body, isEmpty);
        expect(rows.map((r) => r.id).toList(), ['F2', 'F1']);
        expect(vaultAccessShape(rows.last), {
          'FeedbackRow': [
            'F1',
            'correction',
            'chat',
            '01J9NOTE00000000000000000A',
            '2026-11-05',
            '01J9CHG000000000000000000A',
            null,
            correctionShapes['excerpt_moved'],
            'handled',
            'Done',
            1000,
            1762300000500,
            1500,
          ],
        });
      },
    );

    test('feedbackWithoutNote sends GET feedback with no query', () async {
      final env = _env();
      env.server.route(
        'GET',
        '$_base/feedback',
        json: _list([
          feedbackJson(id: 'F9', overrides: {'note_id': null}),
        ]),
      );

      final rows = await env.feedback.feedbackWithoutNote();

      expect(env.last.method, 'GET');
      expect(env.last.url.path, '$_base/feedback');
      expect(env.last.url.query, isEmpty);
      expect(rows.single.id, 'F9');
      expect(rows.single.noteId, isNull);
    });

    test(
      'feedback reads decode a tag Correction id and a deleted-note tag_removed',
      () async {
        final env = _env();
        env.server.route(
          'GET',
          '$_base/feedback',
          json: _list([
            feedbackJson(
              id: 'tag-7',
              overrides: {
                'kind': 'correction',
                'note_id': null,
                'day': null,
                'agent_change_id': null,
                'text': null,
                'correction': {
                  'kind': 'tag_removed',
                  'tag': 'gardening',
                  'note_id': null,
                  'note_title': 'Deleted Note',
                },
              },
            ),
          ]),
        );

        final row = (await env.feedback.feedbackWithoutNote()).single;

        expect(row.id, 'tag-7');
        expect(vaultAccessShape(row.correction), {
          'TagRemovedCorrection': ['gardening', null, 'Deleted Note'],
        });
      },
    );

    test(
      'feedback reads decode every correction kind of the Contract',
      () async {
        final env = _env();
        env.server.route(
          'GET',
          '$_base/feedback?note_id=N1',
          json: _list([
            for (final e in correctionSamples.entries)
              feedbackJson(
                id: 'F-${e.key}',
                overrides: {'kind': 'correction', 'correction': e.value},
              ),
          ]),
        );

        final rows = await env.feedback.feedbackForNote('N1');

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
        }
      },
    );

    test(
      'feedbackForNote sends the note id in the query as one value',
      () async {
        final env = _env();
        final query = Uri(queryParameters: {'note_id': 'a/b?c d&e'}).query;
        env.server.route('GET', '$_base/feedback?$query', json: _list([]));

        expect(await env.feedback.feedbackForNote('a/b?c d&e'), isEmpty);
        expect(env.last.url.queryParameters, {'note_id': 'a/b?c d&e'});
      },
    );
  });

  group('guide', () {
    test('guide sends GET guide and decodes the guide note', () async {
      final env = _env();
      env.server.route(
        'GET',
        '$_base/guide',
        json: {
          'vault_id': 'V1',
          'note_id': 'G1',
          'version': 3,
          'content_md': '# Vault Guide\n',
        },
      );

      final guide = await env.feedback.guide();

      expect(env.last.method, 'GET');
      expect(env.last.url.path, '$_base/guide');
      expect(env.last.url.query, isEmpty);
      expect(vaultAccessShape(guide), {
        'VaultGuide': ['V1', 'G1', 3, '# Vault Guide\n'],
      });
    });

    test(
      'guideRevisions sends GET guide revisions and decodes them in server order',
      () async {
        final env = _env();
        env.server.route(
          'GET',
          '$_base/guide/revisions',
          json: {
            'vault_id': 'V1',
            'revisions': [
              {'id': 'R2', 'agent_change_id': 'AC1', 'created_at': 2000},
              {'id': 'R1', 'agent_change_id': null, 'created_at': 1000},
            ],
          },
        );

        final revisions = await env.feedback.guideRevisions();

        expect(env.last.method, 'GET');
        expect(env.last.url.path, '$_base/guide/revisions');
        expect(vaultAccessShape(revisions), [
          {
            'GuideRevisionRow': ['R2', 'AC1', 2000],
          },
          {
            'GuideRevisionRow': ['R1', null, 1000],
          },
        ]);
      },
    );

    test(
      'restoreGuide sends POST guide revisions id restore and decodes the result',
      () async {
        final env = _env();
        env.server.route(
          'POST',
          '$_base/guide/revisions/R1/restore',
          json: {'vault_id': 'V1', 'note_id': 'G1', 'version': 9},
        );

        final r = await env.feedback.restoreGuide('R1');

        expect(env.last.method, 'POST');
        expect(env.last.url.path, '$_base/guide/revisions/R1/restore');
        expect(vaultAccessShape(r), {
          'GuideRestoreResult': ['V1', 'G1', 9],
        });
      },
    );

    test('restoreGuide sends the revision id as one encoded segment', () async {
      final env = _env();
      env.server.route(
        'POST',
        '$_base/guide/revisions/a%2Fb/restore',
        json: {'vault_id': 'V1', 'note_id': 'G1', 'version': 9},
      );

      await env.feedback.restoreGuide('a/b');

      expect(env.last.url.pathSegments.sublist(4), [
        'guide',
        'revisions',
        'a/b',
        'restore',
      ]);
    });
  });

  group('the named vault', () {
    test('hosted feedback requests go to the named vault', () async {
      final env = _env(vaultName: 'my vault');
      env.server.route(
        'GET',
        '/vaults/my%20vault/api/v1/feedback',
        json: _list([]),
      );

      expect(await env.feedback.feedbackWithoutNote(), isEmpty);
      expect(env.last.url.path, '/vaults/my%20vault/api/v1/feedback');
    });
  });

  group('failures', () {
    test(
      'every hosted failure throws the C1 error with its code, fields and command label',
      () async {
        for (final e in _calls().entries) {
          final env = _env();
          final c = e.value;
          _serve(
            env,
            c,
            status: 409,
            json: {
              'error': {
                'code': 'feedback_handled',
                'message': 'already handled',
                'feedback_id': 'F1',
              },
            },
          );

          final out = await _outcome(c.call(env.feedback));

          expect(
            out,
            isA<MemexException>()
                .having((x) => x.code, 'code', 'feedback_handled')
                .having((x) => x.fields, 'fields', {'feedback_id': 'F1'})
                .having(
                  (x) => x.message,
                  'message',
                  startsWith('${c.op} failed'),
                ),
            reason: e.key,
          );
        }
      },
    );

    test('a block_not_found and a not_found status keep their codes', () async {
      for (final (status, code) in [
        (404, 'block_not_found'),
        (404, 'not_found'),
      ]) {
        final env = _env();
        final c = _calls()['moveBlock']!;
        _serve(
          env,
          c,
          status: status,
          json: {
            'error': {'code': code, 'message': 'nope'},
          },
        );

        final out = await _outcome(c.call(env.feedback));

        expect(out, isA<MemexException>().having((x) => x.code, 'code', code));
      }
    });

    test(
      'a response that is not the Contract shape throws with a null code',
      () async {
        for (final e in _calls().entries) {
          for (final bad in <Object?>[
            <String, Object?>{},
            {'vault_id': 'V1', 'unexpected': true},
          ]) {
            final env = _env();
            _serve(env, e.value, json: bad);

            final out = await _outcome(e.value.call(env.feedback));

            expect(
              out,
              isA<MemexException>().having((x) => x.code, 'code', isNull),
              reason: '${e.key} $bad',
            );
          }
        }
      },
    );

    test(
      'a feedback row with an unknown status or a missing id throws with a null code',
      () async {
        final badRows = [
          feedbackJson(overrides: {'status': 'pending'}),
          feedbackJson(overrides: {'kind': 'note'}),
          {...feedbackJson()}..remove('id'),
          feedbackJson(overrides: {'created_at': 'x'}),
        ];
        for (final bad in badRows) {
          final env = _env();
          env.server.route('GET', '$_base/feedback', json: _list([bad]));
          env.server.route('POST', '$_base/feedback', json: bad);

          for (final f in [
            () => env.feedback.feedbackWithoutNote(),
            () => env.feedback.addComment(
              noteId: 'N',
              date: '2026-11-05',
              changeId: 'C',
              text: 't',
            ),
          ]) {
            expect(
              await _outcome(f()),
              isA<MemexException>().having((x) => x.code, 'code', isNull),
              reason: '$bad',
            );
          }
        }
      },
    );
  });
}
