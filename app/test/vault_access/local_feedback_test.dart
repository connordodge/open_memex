// WI #259 (F7): LocalFeedbackAccess (D13, D21). Reads of Feedback and guide
// revisions come from the VaultDb; filing, guide and every write go through
// the CLI with `--vault`. Writes throw StateError when there is no CLI;
// `VaultAccess.feedback` sits beside `daily` on both composites.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/feedback_access.dart';
import 'package:open_memex_app/src/vault_access/hosted/feedback.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/fake_vault_server.dart';
import '../support/feedback_seeds.dart';
import '../support/vault_access_shapes.dart';

const _vault = '/tmp/om-259-vault';

String _out(Object? json) => '${jsonEncode(json)}\n';

FakeMemexCli _cli() => FakeMemexCli()
  ..on('filing', (_) => FakeMemexCli.ok(_out(filingJson())))
  ..on(
    'excerpt add',
    (_) => FakeMemexCli.ok(
      _out({'vault_id': 'V', 'topic_note_id': 'T1', 'version': 4}),
    ),
  )
  ..on(
    'excerpt remove-block',
    (_) => FakeMemexCli.ok(
      _out({'vault_id': 'V', 'topic_note_id': 'T1', 'version': 5}),
    ),
  )
  ..on(
    'excerpt move',
    (_) => FakeMemexCli.ok(
      _out({
        'vault_id': 'V',
        'from_topic_note_id': 'A1',
        'from_version': 2,
        'to_topic_note_id': 'C1',
        'to_version': 3,
      }),
    ),
  )
  ..on('feedback add', (_) => FakeMemexCli.ok(_out(feedbackJson(id: 'FA'))))
  ..on('feedback edit', (_) => FakeMemexCli.ok(_out(feedbackJson(id: 'FE'))))
  ..on(
    'feedback rm',
    (_) => FakeMemexCli.ok(_out({'vault_id': 'V', 'id': 'FR'})),
  )
  ..on(
    'guide get',
    (_) => FakeMemexCli.ok(
      _out({
        'vault_id': 'V',
        'note_id': 'G',
        'version': 3,
        'content_md': '# G',
      }),
    ),
  )
  ..on(
    'guide restore',
    (_) =>
        FakeMemexCli.ok(_out({'vault_id': 'V', 'note_id': 'G', 'version': 9})),
  );

LocalFeedbackAccess _access({FakeMemexCli? cli, FakeVaultDb? db}) =>
    LocalFeedbackAccess(vaultPath: _vault, db: db, cli: cli);

/// Every write and CLI-served read of the interface, labelled.
Map<String, Future<Object?> Function(FeedbackAccess)> _cliCalls() => {
  'filing': (a) => a.filing('2026-11-05'),
  'fileBlock': (a) => a.fileBlock(
    topicNoteId: 'T1',
    date: '2026-11-05',
    blockId: 'b1',
    note: 'n',
  ),
  'moveBlock': (a) => a.moveBlock(
    fromTopicNoteId: 'A1',
    toTopicNoteId: 'C1',
    date: '2026-11-05',
    blockId: 'b1',
    note: 'n',
  ),
  'removeBlock': (a) => a.removeBlock(
    topicNoteId: 'T1',
    date: '2026-11-05',
    blockId: 'b1',
    note: 'n',
  ),
  'addComment': (a) =>
      a.addComment(noteId: 'N1', date: '2026-11-05', changeId: 'C1', text: 't'),
  'editComment': (a) => a.editComment(id: 'F1', text: 't'),
  'deleteComment': (a) => a.deleteComment(id: 'F1'),
  'guide': (a) => a.guide(),
  'restoreGuide': (a) => a.restoreGuide('R1'),
};

void main() {
  group('writes go through the CLI', () {
    test(
      'fileBlock runs excerpt add with the vault, the ids and the note',
      () async {
        final cli = _cli();

        final r = await _access(cli: cli).fileBlock(
          topicNoteId: 'T1',
          date: '2026-11-05',
          blockId: 'b7k2m9',
          note: 'belongs here',
        );

        expect(cli.calls.single.args, [
          'excerpt',
          'add',
          '--vault',
          _vault,
          '--topic-note-id',
          'T1',
          '--date',
          '2026-11-05',
          '--block-id',
          'b7k2m9',
          '--note',
          'belongs here',
        ]);
        expect(vaultAccessShape(r), {
          'ExcerptEditResult': ['V', 'T1', 4],
        });
      },
    );

    test('fileBlock without a note sends no note flag', () async {
      final cli = _cli();

      await _access(
        cli: cli,
      ).fileBlock(topicNoteId: 'T1', date: '2026-11-05', blockId: 'b7k2m9');

      expect(cli.calls.single.hasFlag('note'), isFalse);
    });

    test(
      'removeBlock runs excerpt remove-block with the vault, the ids and the note',
      () async {
        final cli = _cli();

        final r = await _access(cli: cli).removeBlock(
          topicNoteId: 'T1',
          date: '2026-11-05',
          blockId: 'b7k2m9',
          note: 'wrong',
        );

        expect(cli.calls.single.args, [
          'excerpt',
          'remove-block',
          '--vault',
          _vault,
          '--topic-note-id',
          'T1',
          '--date',
          '2026-11-05',
          '--block-id',
          'b7k2m9',
          '--note',
          'wrong',
        ]);
        expect(vaultAccessShape(r), {
          'ExcerptEditResult': ['V', 'T1', 5],
        });
      },
    );

    test(
      'moveBlock runs excerpt move with the vault, both topics and the note',
      () async {
        final cli = _cli();

        final r = await _access(cli: cli).moveBlock(
          fromTopicNoteId: 'A1',
          toTopicNoteId: 'C1',
          date: '2026-11-05',
          blockId: 'b7k2m9',
          note: 'moved',
        );

        expect(cli.calls.single.args, [
          'excerpt',
          'move',
          '--vault',
          _vault,
          '--date',
          '2026-11-05',
          '--block-id',
          'b7k2m9',
          '--from-topic-note-id',
          'A1',
          '--to-topic-note-id',
          'C1',
          '--note',
          'moved',
        ]);
        expect(vaultAccessShape(r), {
          'ExcerptMoveResult': ['V', 'A1', 2, 'C1', 3],
        });
      },
    );

    test(
      'addComment runs feedback add with the vault and returns the Feedback',
      () async {
        final cli = _cli();

        final r = await _access(cli: cli).addComment(
          noteId: 'N1',
          date: '2026-11-05',
          changeId: 'C1',
          text: 'a comment',
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
          'a comment',
        ]);
        expect(r.id, 'FA');
      },
    );

    test(
      'editComment runs feedback edit with the vault and returns the Feedback',
      () async {
        final cli = _cli();

        final r = await _access(cli: cli).editComment(id: 'F1', text: 'better');

        expect(cli.calls.single.args, [
          'feedback',
          'edit',
          '--vault',
          _vault,
          '--id',
          'F1',
          '--text',
          'better',
        ]);
        expect(r.id, 'FE');
      },
    );

    test(
      'deleteComment runs feedback rm with the vault and returns its result',
      () async {
        final cli = _cli();

        final r = await _access(cli: cli).deleteComment(id: 'F1');

        expect(cli.calls.single.args, [
          'feedback',
          'rm',
          '--vault',
          _vault,
          '--id',
          'F1',
        ]);
        expect(vaultAccessShape(r), {
          'FeedbackRemoveResult': ['V', 'FR'],
        });
      },
    );

    test(
      'restoreGuide runs guide restore with the vault and the revision id',
      () async {
        final cli = _cli();

        final r = await _access(cli: cli).restoreGuide('R1');

        expect(cli.calls.single.args, [
          'guide',
          'restore',
          '--vault',
          _vault,
          '--revision-id',
          'R1',
        ]);
        expect(vaultAccessShape(r), {
          'GuideRestoreResult': ['V', 'G', 9],
        });
      },
    );

    test(
      'a failing write throws the MemexException with its C1 code',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'feedback edit',
            (_) => FakeMemexCli.error('feedback_handled', 'already handled'),
          );

        await expectLater(
          _access(cli: cli).editComment(id: 'F1', text: 't'),
          throwsA(
            isA<MemexException>().having(
              (e) => e.code,
              'code',
              'feedback_handled',
            ),
          ),
        );
      },
    );
  });

  group('CLI-served reads', () {
    test('filing runs the filing command and returns the Filing', () async {
      final cli = _cli();

      final filing = await _access(cli: cli).filing('2026-11-05');

      expect(cli.calls.single.args, [
        'filing',
        '--vault',
        _vault,
        '--date',
        '2026-11-05',
      ]);
      expect(vaultAccessShape(filing), filingShape);
    });

    test('guide runs guide get and returns the guide note', () async {
      final cli = _cli();

      final guide = await _access(cli: cli).guide();

      expect(cli.calls.single.args, ['guide', 'get', '--vault', _vault]);
      expect(vaultAccessShape(guide), {
        'VaultGuide': ['V', 'G', 3, '# G'],
      });
    });
  });

  group('without a CLI', () {
    test(
      'every write and CLI-served read throws StateError and runs nothing',
      () async {
        final access = _access();
        for (final e in _cliCalls().entries) {
          await expectLater(
            () => e.value(access),
            throwsA(isA<StateError>()),
            reason: e.key,
          );
        }
      },
    );
  });

  group('database reads', () {
    test(
      'feedbackForNote reads the rows and the open tag corrections from the database',
      () async {
        final db = FakeVaultDb.v6();
        addTearDown(db.close);
        db.seedFeedback('fb-1', noteId: 'N1', createdAt: 1000);
        final tag = db.seedTagCorrection(noteId: 'N1', createdAt: 2000);
        db.seedFeedback('fb-other', noteId: 'N2', createdAt: 3000);
        final cli = _cli();

        final rows = await _access(cli: cli, db: db).feedbackForNote('N1');

        expect([for (final r in rows) r.id], ['tag-$tag', 'fb-1']);
        expect(cli.calls, isEmpty, reason: 'reads never run the CLI');
      },
    );

    test(
      'feedbackWithoutNote reads the no-note rows and the deleted note tag corrections',
      () async {
        final db = FakeVaultDb.v6();
        addTearDown(db.close);
        db.seedFeedback('fb-none', createdAt: 1000);
        db.seedFeedback('fb-noted', noteId: 'N1', createdAt: 2000);
        final tag = db.seedTagCorrection(noteTitle: 'Gone', createdAt: 3000);
        final cli = _cli();

        final rows = await _access(cli: cli, db: db).feedbackWithoutNote();

        expect([for (final r in rows) r.id], ['tag-$tag', 'fb-none']);
        expect(cli.calls, isEmpty);
      },
    );

    test(
      'guideRevisions reads the revisions from the database newest first',
      () async {
        final db = FakeVaultDb.v6();
        addTearDown(db.close);
        db.seedGuideRevision('rev-old', createdAt: 1000);
        db.seedGuideRevision('rev-new', createdAt: 2000, agentChangeId: 'ac-1');
        final cli = _cli();

        final revisions = await _access(cli: cli, db: db).guideRevisions();

        expect(vaultAccessShape(revisions), [
          {
            'GuideRevisionRow': ['rev-new', 'ac-1', 2000],
          },
          {
            'GuideRevisionRow': ['rev-old', null, 1000],
          },
        ]);
        expect(cli.calls, isEmpty);
      },
    );

    test('the database reads work without a CLI', () async {
      final db = FakeVaultDb.v6();
      addTearDown(db.close);
      db.seedFeedback('fb-1', noteId: 'N1');
      db.seedGuideRevision('rev-1');
      final access = _access(db: db);

      expect((await access.feedbackForNote('N1')).single.id, 'fb-1');
      expect((await access.guideRevisions()).single.id, 'rev-1');
    });

    test('the database reads are empty without a database handle', () async {
      final db = FakeVaultDb.v6();
      addTearDown(db.close);
      db.seedFeedback('fb-1', noteId: 'N1');
      db.seedGuideRevision('rev-1');
      final access = _access(cli: _cli());

      expect(await access.feedbackForNote('N1'), isEmpty);
      expect(await access.feedbackWithoutNote(), isEmpty);
      expect(await access.guideRevisions(), isEmpty);
      expect(
        await _access(cli: _cli(), db: db).feedbackForNote('N1'),
        isNotEmpty,
        reason: 'the same rows read once a handle is given',
      );
    });

    test(
      'the database reads are empty on a V5 vault and do not throw',
      () async {
        final db = FakeVaultDb.v5Only();
        addTearDown(db.close);
        final access = _access(cli: _cli(), db: db);

        expect(await access.feedbackForNote('N1'), isEmpty);
        expect(await access.feedbackWithoutNote(), isEmpty);
        expect(await access.guideRevisions(), isEmpty);

        db.migrateToV6();
        db.seedFeedback('fb-1', noteId: 'N1');
        expect((await access.feedbackForNote('N1')).single.id, 'fb-1');
      },
    );
  });

  group('the composites', () {
    test(
      'LocalVaultAccess builds a LocalFeedbackAccess over its path, database and CLI by default',
      () async {
        final db = FakeVaultDb.v6();
        addTearDown(db.close);
        db.seedFeedback('fb-1', noteId: 'N1');
        final cli = _cli();
        final access = LocalVaultAccess(vaultPath: _vault, db: db, cli: cli);

        expect(access.feedback, isA<LocalFeedbackAccess>());
        expect(access.feedback.vaultPath, _vault);
        expect((await access.feedback.feedbackForNote('N1')).single.id, 'fb-1');
        await access.feedback.deleteComment(id: 'F1');
        expect(cli.calls.single.flag('vault'), _vault);

        final stub = LocalFeedbackAccess(vaultPath: _vault);
        expect(
          identical(
            LocalVaultAccess(vaultPath: _vault, feedback: stub).feedback,
            stub,
          ),
          isTrue,
          reason: 'D21: a double passed to the composite replaces the default',
        );
      },
    );

    test(
      'HostedVaultAccess builds a HostedFeedbackAccess over its client',
      () async {
        final server = FakeVaultServer()
          ..route(
            'GET',
            '/vaults/seed/api/v1/feedback',
            json: {'vault_id': 'V', 'feedback': <Object?>[]},
          );
        final container = ProviderContainer(
          overrides: [
            clockProvider.overrideWithValue(FakeClock()),
            utcOffsetProvider.overrideWithValue(() => Duration.zero),
          ],
        );
        addTearDown(container.dispose);
        final access = HostedVaultAccess(
          client: server.connect(container),
          vaultName: 'seed',
        );

        expect(access.feedback, isA<HostedFeedbackAccess>());
        expect(await access.feedback.feedbackWithoutNote(), isEmpty);
        expect(server.requests.single.url.path, '/vaults/seed/api/v1/feedback');
      },
    );
  });
}
