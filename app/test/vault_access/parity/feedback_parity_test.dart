// WI #259 (F7) AC6: HostedFeedbackAccess and LocalFeedbackAccess return the
// same shapes (`vault_access_shapes.dart`) for the same vault state.
//
// - Database reads (feedbackForNote, feedbackWithoutNote, guideRevisions):
//   the local side reads a seeded V6 database, the hosted side is served the
//   Contract JSON (#256) of the same rows.
// - CLI-served calls (filing, guide, every write): the local side runs a fake
//   `memex` that prints the Contract object, the hosted side is served the
//   same object.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/feedback.dart';
import 'package:open_memex_app/src/vault_access/hosted/topics.dart';
import 'package:open_memex_app/src/vault_access/local/feedback.dart';
import 'package:open_memex_app/src/vault_access/local/topics.dart';

import '../../support/fake_clock.dart';
import '../../support/fake_memex_cli.dart';
import '../../support/fake_vault_db.dart';
import '../../support/fake_vault_server.dart';
import '../../support/feedback_seeds.dart';
import '../../support/vault_access_shapes.dart';

const _vault = '/tmp/om-259-vault';
const _base = '/vaults/seed/api/v1';

class _Pair {
  _Pair(
    this.local,
    this.hosted,
    this.localTopics,
    this.hostedTopics,
    this.cli,
    this.server,
  );

  final LocalFeedbackAccess local;
  final HostedFeedbackAccess hosted;
  final LocalTopicsAccess localTopics;
  final HostedTopicsAccess hostedTopics;
  final FakeMemexCli cli;
  final FakeVaultServer server;
}

_Pair _pair({FakeVaultDb? db}) {
  final server = FakeVaultServer();
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  final cli = FakeMemexCli();
  final client = server.connect(container);
  return _Pair(
    LocalFeedbackAccess(vaultPath: _vault, db: db, cli: cli),
    HostedFeedbackAccess(client: client, vaultName: 'seed'),
    LocalTopicsAccess(vaultPath: _vault, cli: cli),
    HostedTopicsAccess(client: client, vaultName: 'seed'),
    cli,
    server,
  );
}

/// The local CLI prints [json] for [subcommand]; the hosted [method] [path]
/// answers it.
void _serve(
  _Pair p,
  String subcommand,
  String method,
  String path,
  Object? json,
) {
  p.cli.on(subcommand, (_) => FakeMemexCli.ok('${jsonEncode(json)}\n'));
  p.server.route(method, '$_base$path', json: json);
}

void _expectSame(Object? local, Object? hosted, {String? reason}) {
  expect(vaultAccessShape(hosted), vaultAccessShape(local), reason: reason);
}

void main() {
  group('database reads', () {
    FakeVaultDb seeded() {
      final db = FakeVaultDb.v6();
      addTearDown(db.close);
      db.seedFeedback(
        '01J9FBCOMMENT00000000000A1',
        noteId: 'N1',
        day: '2026-11-05',
        agentChangeId: 'AC1',
        text: 'This bullet is wrong',
        createdAt: 3000,
        updatedAt: 3100,
      );
      db.seedFeedback(
        '01J9FBMOVED0000000000000A2',
        kind: 'correction',
        source: 'chat',
        noteId: 'N1',
        day: '2026-11-05',
        correction: correctionSamples['excerpt_moved'],
        status: 'handled',
        reply: 'Understood',
        createdAt: 2000,
        updatedAt: 2500,
        handledAt: 2500,
      );
      db.seedFeedback(
        '01J9FBFOLDER00000000000A3',
        kind: 'correction',
        correction: correctionSamples['folder_deleted'],
        createdAt: 1500,
      );
      db.seedTagCorrection(noteId: 'N1', noteTitle: 'Pacing', createdAt: 4000);
      db.seedTagCorrection(noteTitle: 'Deleted Note', createdAt: 1800);
      db.seedGuideRevision('R2', agentChangeId: 'AC1', createdAt: 2000);
      db.seedGuideRevision('R1', createdAt: 1000);
      return db;
    }

    test(
      'feedbackForNote returns the same shapes locally and hosted',
      () async {
        final p = _pair(db: seeded());
        p.server.route(
          'GET',
          '$_base/feedback?note_id=N1',
          json: {
            'vault_id': 'V',
            'feedback': [
              feedbackJson(
                id: 'tag-1',
                overrides: {
                  'kind': 'correction',
                  'day': null,
                  'agent_change_id': null,
                  'text': null,
                  'correction': {
                    'kind': 'tag_removed',
                    'tag': 'gardening',
                    'note_id': 'N1',
                    'note_title': 'Pacing',
                  },
                  'note_id': 'N1',
                  'created_at': 4000,
                  'updated_at': 4000,
                },
              ),
              feedbackJson(
                id: '01J9FBCOMMENT00000000000A1',
                overrides: {
                  'note_id': 'N1',
                  'agent_change_id': 'AC1',
                  'created_at': 3000,
                  'updated_at': 3100,
                },
              ),
              feedbackJson(
                id: '01J9FBMOVED0000000000000A2',
                overrides: {
                  'kind': 'correction',
                  'source': 'chat',
                  'note_id': 'N1',
                  'agent_change_id': null,
                  'text': null,
                  'correction': correctionSamples['excerpt_moved'],
                  'status': 'handled',
                  'reply': 'Understood',
                  'created_at': 2000,
                  'updated_at': 2500,
                  'handled_at': 2500,
                },
              ),
            ],
          },
        );

        final local = await p.local.feedbackForNote('N1');
        final hosted = await p.hosted.feedbackForNote('N1');

        expect(local, hasLength(3));
        _expectSame(local, hosted);
      },
    );

    test(
      'feedbackWithoutNote returns the same shapes locally and hosted',
      () async {
        final p = _pair(db: seeded());
        p.server.route(
          'GET',
          '$_base/feedback',
          json: {
            'vault_id': 'V',
            'feedback': [
              feedbackJson(
                id: 'tag-2',
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
                  'created_at': 1800,
                  'updated_at': 1800,
                },
              ),
              feedbackJson(
                id: '01J9FBFOLDER00000000000A3',
                overrides: {
                  'kind': 'correction',
                  'note_id': null,
                  'day': null,
                  'agent_change_id': null,
                  'text': null,
                  'correction': correctionSamples['folder_deleted'],
                  'created_at': 1500,
                  'updated_at': 1500,
                },
              ),
            ],
          },
        );

        final local = await p.local.feedbackWithoutNote();
        final hosted = await p.hosted.feedbackWithoutNote();

        expect(local, hasLength(2));
        _expectSame(local, hosted);
      },
    );

    test('guideRevisions returns the same shapes locally and hosted', () async {
      final p = _pair(db: seeded());
      p.server.route(
        'GET',
        '$_base/guide/revisions',
        json: {
          'vault_id': 'V',
          'revisions': [
            {'id': 'R2', 'agent_change_id': 'AC1', 'created_at': 2000},
            {'id': 'R1', 'agent_change_id': null, 'created_at': 1000},
          ],
        },
      );

      final local = await p.local.guideRevisions();
      final hosted = await p.hosted.guideRevisions();

      expect(local, hasLength(2));
      _expectSame(local, hosted);
    });
  });

  group('CLI-served calls', () {
    test('filing returns the same shape locally and hosted', () async {
      final p = _pair();
      _serve(
        p,
        'filing',
        'GET',
        '/daily-notes/2026-11-05/filing',
        filingJson(),
      );

      _expectSame(
        await p.local.filing('2026-11-05'),
        await p.hosted.filing('2026-11-05'),
      );
      expect(p.cli.calls, hasLength(1));
      expect(p.server.requests, hasLength(1));
    });

    test(
      'guide and restoreGuide return the same shapes locally and hosted',
      () async {
        final p = _pair();
        _serve(p, 'guide get', 'GET', '/guide', {
          'vault_id': 'V',
          'note_id': 'G1',
          'version': 3,
          'content_md': '# Vault Guide\n',
        });
        _serve(p, 'guide restore', 'POST', '/guide/revisions/R1/restore', {
          'vault_id': 'V',
          'note_id': 'G1',
          'version': 4,
        });

        _expectSame(
          await p.local.guide(),
          await p.hosted.guide(),
          reason: 'guide',
        );
        _expectSame(
          await p.local.restoreGuide('R1'),
          await p.hosted.restoreGuide('R1'),
          reason: 'restoreGuide',
        );
        expect(p.cli.calls, hasLength(2));
        expect(p.server.requests, hasLength(2));
      },
    );

    test(
      'the block filing writes return the same shapes locally and hosted',
      () async {
        final p = _pair();
        final edit = {'vault_id': 'V', 'topic_note_id': 'T1', 'version': 4};
        _serve(p, 'excerpt add', 'POST', '/notes/T1/excerpts', edit);
        _serve(
          p,
          'excerpt remove-block',
          'DELETE',
          '/notes/T1/excerpts/blocks/b1?date=2026-11-05',
          {...edit, 'version': 5},
        );
        _serve(p, 'excerpt move', 'POST', '/notes/A1/excerpts/move', {
          'vault_id': 'V',
          'from_topic_note_id': 'A1',
          'from_version': 2,
          'to_topic_note_id': 'C1',
          'to_version': 3,
        });

        _expectSame(
          await p.local.fileBlock(
            topicNoteId: 'T1',
            date: '2026-11-05',
            blockId: 'b1',
          ),
          await p.hosted.fileBlock(
            topicNoteId: 'T1',
            date: '2026-11-05',
            blockId: 'b1',
          ),
          reason: 'fileBlock',
        );
        _expectSame(
          await p.local.removeBlock(
            topicNoteId: 'T1',
            date: '2026-11-05',
            blockId: 'b1',
          ),
          await p.hosted.removeBlock(
            topicNoteId: 'T1',
            date: '2026-11-05',
            blockId: 'b1',
          ),
          reason: 'removeBlock',
        );
        _expectSame(
          await p.local.moveBlock(
            fromTopicNoteId: 'A1',
            toTopicNoteId: 'C1',
            date: '2026-11-05',
            blockId: 'b1',
          ),
          await p.hosted.moveBlock(
            fromTopicNoteId: 'A1',
            toTopicNoteId: 'C1',
            date: '2026-11-05',
            blockId: 'b1',
          ),
          reason: 'moveBlock',
        );
        expect(p.cli.calls, hasLength(3));
        expect(p.server.requests, hasLength(3));
      },
    );

    test(
      'the comment writes return the same shapes locally and hosted',
      () async {
        final p = _pair();
        _serve(p, 'feedback add', 'POST', '/feedback', feedbackJson(id: 'FA'));
        _serve(
          p,
          'feedback edit',
          'PATCH',
          '/feedback/FA',
          feedbackJson(id: 'FA', overrides: {'text': 'better'}),
        );
        _serve(p, 'feedback rm', 'DELETE', '/feedback/FA', {
          'vault_id': 'V',
          'id': 'FA',
        });

        _expectSame(
          await p.local.addComment(
            noteId: 'N1',
            date: '2026-11-05',
            changeId: 'C1',
            text: 't',
          ),
          await p.hosted.addComment(
            noteId: 'N1',
            date: '2026-11-05',
            changeId: 'C1',
            text: 't',
          ),
          reason: 'addComment',
        );
        _expectSame(
          await p.local.editComment(id: 'FA', text: 'better'),
          await p.hosted.editComment(id: 'FA', text: 'better'),
          reason: 'editComment',
        );
        _expectSame(
          await p.local.deleteComment(id: 'FA'),
          await p.hosted.deleteComment(id: 'FA'),
          reason: 'deleteComment',
        );
        expect(p.cli.calls, hasLength(3));
        expect(p.server.requests, hasLength(3));
      },
    );

    test(
      'removeFromFolder returns the same shape locally and hosted',
      () async {
        final p = _pair();
        _serve(p, 'folder remove', 'DELETE', '/smart-folders/F1/members/N1', {
          'vault_id': 'V',
          'smart_folder_id': 'F1',
          'note_id': 'N1',
          'removed': true,
        });

        _expectSame(
          await p.localTopics.removeFromFolder(folderId: 'F1', noteId: 'N1'),
          await p.hostedTopics.removeFromFolder(folderId: 'F1', noteId: 'N1'),
        );
        expect(p.cli.calls, hasLength(1));
        expect(p.server.requests, hasLength(1));
      },
    );
  });
}
