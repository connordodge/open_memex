// WI #259 (F7): the Feedback and Vault Guide revision reads on VaultDb (V6,
// D4, D6, D7a). Seeds are raw inserts against the real V6 schema fixture.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/feedback_reads.dart';

import '../support/fake_vault_db.dart';
import '../support/feedback_seeds.dart';
import '../support/vault_access_shapes.dart';

FakeVaultDb _v6() {
  final db = FakeVaultDb.v6();
  addTearDown(db.close);
  return db;
}

FakeVaultDb _v5() {
  final db = FakeVaultDb.v5Only();
  addTearDown(db.close);
  return db;
}

FakeVaultDb _v4() {
  final db = FakeVaultDb.v4();
  addTearDown(db.close);
  return db;
}

List<String> _ids(List<FeedbackRow> rows) => [for (final r in rows) r.id];

void main() {
  group('feedbackForNote', () {
    test(
      'feedbackForNote returns the note rows of every status newest created_at first regardless of insert order',
      () {
        final db = _v6();
        db.seedFeedback('fb-mid', noteId: 'n1', createdAt: 2000);
        db.seedFeedback('fb-old', noteId: 'n1', createdAt: 1000);
        db.seedFeedback(
          'fb-new',
          noteId: 'n1',
          createdAt: 3000,
          status: 'handled',
          handledAt: 3500,
        );

        final rows = db.feedbackForNote('n1');

        expect(_ids(rows), ['fb-new', 'fb-mid', 'fb-old']);
        expect(rows.map((r) => r.status).toList(), [
          FeedbackStatus.handled,
          FeedbackStatus.open,
          FeedbackStatus.open,
        ]);
      },
    );

    test(
      'feedbackForNote orders rows with equal created_at by insertion order, latest insert first',
      () {
        final db = _v6();
        db.seedFeedback('fb-a', noteId: 'n1', createdAt: 1000);
        db.seedFeedback('fb-b', noteId: 'n1', createdAt: 1000);
        db.seedFeedback('fb-c', noteId: 'n1', createdAt: 1000);

        expect(_ids(db.feedbackForNote('n1')), ['fb-c', 'fb-b', 'fb-a']);
      },
    );

    test('feedbackForNote returns only the asked note rows', () {
      final db = _v6();
      db.seedFeedback('fb-1', noteId: 'n1', createdAt: 1000);
      db.seedFeedback('fb-2', noteId: 'n2', createdAt: 2000);
      db.seedFeedback('fb-none', createdAt: 3000);

      expect(_ids(db.feedbackForNote('n1')), ['fb-1']);
      expect(_ids(db.feedbackForNote('n2')), ['fb-2']);
      expect(db.feedbackForNote('no-such-note'), isEmpty);
    });

    test('feedbackForNote maps every column of a handled correction row', () {
      final db = _v6();
      db.seedFeedback(
        '01J9FB000000000000000000A1',
        kind: 'correction',
        source: 'chat',
        noteId: 'n1',
        day: '2026-11-05',
        agentChangeId: 'ac-1',
        text: 'moved it back',
        correction: correctionSamples['excerpt_moved'],
        status: 'handled',
        reply: 'Understood, I will keep it there',
        createdAt: 1762300000000,
        updatedAt: 1762300000500,
        handledAt: 1762300009000,
      );

      final row = db.feedbackForNote('n1').single;

      expect(vaultAccessShape(row), {
        'FeedbackRow': [
          '01J9FB000000000000000000A1',
          'correction',
          'chat',
          'n1',
          '2026-11-05',
          'ac-1',
          'moved it back',
          correctionShapes['excerpt_moved'],
          'handled',
          'Understood, I will keep it there',
          1762300000000,
          1762300000500,
          1762300009000,
        ],
      });
    });

    test(
      'feedbackForNote maps a bare open comment with nulls for the rest',
      () {
        final db = _v6();
        db.seedFeedback(
          'fb-1',
          noteId: 'n1',
          text: 'only text',
          createdAt: 5,
          updatedAt: 6,
        );

        final row = db.feedbackForNote('n1').single;

        expect(vaultAccessShape(row), {
          'FeedbackRow': [
            'fb-1',
            'comment',
            'person',
            'n1',
            null,
            null,
            'only text',
            null,
            'open',
            null,
            5,
            6,
            null,
          ],
        });
      },
    );

    test(
      'feedbackForNote decodes every correction kind of correction_json to its typed value',
      () {
        expect(correctionSamples.keys, hasLength(8));
        for (final kind in correctionSamples.keys) {
          final db = _v6();
          db.seedFeedback(
            'fb-1',
            kind: 'correction',
            noteId: 'n1',
            correction: correctionSamples[kind],
          );

          final c = db.feedbackForNote('n1').single.correction;

          expect(
            correctionMatchesKind(kind, c),
            isTrue,
            reason: '$kind: ${c.runtimeType}',
          );
          expect(vaultAccessShape(c), correctionShapes[kind], reason: kind);
        }
      },
    );

    test(
      'feedbackForNote gives a null correction for malformed correction_json and does not throw',
      () {
        final db = _v6();
        db.seedFeedback(
          'fb-bad',
          kind: 'correction',
          noteId: 'n1',
          correctionJson: 'not json {',
          createdAt: 2000,
        );
        db.seedFeedback(
          'fb-array',
          kind: 'correction',
          noteId: 'n1',
          correctionJson: '[1,2]',
          createdAt: 1000,
        );

        late List<FeedbackRow> rows;
        expect(() => rows = db.feedbackForNote('n1'), returnsNormally);

        expect(_ids(rows), ['fb-bad', 'fb-array']);
        expect(rows.every((r) => r.correction == null), isTrue);
      },
    );
  });

  group('feedbackForNote tag Corrections (D4)', () {
    test(
      'feedbackForNote includes an uncleared unhandled tag correction as tag-n with a tag_removed correction',
      () {
        final db = _v6();
        final id = db.seedTagCorrection(
          noteId: 'n1',
          noteTitle: 'Pacing',
          tag: 'gardening',
          createdAt: 4000,
        );

        final row = db.feedbackForNote('n1').single;

        expect(row.id, 'tag-$id');
        expect(row.kind, FeedbackKind.correction);
        expect(row.source, FeedbackSource.person);
        expect(row.status, FeedbackStatus.open);
        expect(row.noteId, 'n1');
        expect(row.text, isNull);
        expect(row.reply, isNull);
        expect(row.handledAt, isNull);
        expect(row.createdAt, 4000);
        expect(row.updatedAt, 4000);
        expect(vaultAccessShape(row.correction), {
          'TagRemovedCorrection': ['gardening', 'n1', 'Pacing'],
        });
      },
    );

    test('feedbackForNote ids follow the tag_corrections autoincrement id', () {
      final db = _v6();
      db.seedTagCorrection(noteId: 'n1', tag: 'a', createdAt: 1000);
      final second = db.seedTagCorrection(
        noteId: 'n1',
        tag: 'b',
        createdAt: 2000,
      );

      expect(second, 2);
      expect(_ids(db.feedbackForNote('n1')), ['tag-2', 'tag-1']);
    });

    test('feedbackForNote omits a cleared tag correction', () {
      final db = _v6();
      db.seedTagCorrection(
        noteId: 'n1',
        tag: 'cleared',
        createdAt: 1000,
        clearedAt: 1500,
      );
      final open = db.seedTagCorrection(
        noteId: 'n1',
        tag: 'open',
        createdAt: 2000,
      );

      expect(_ids(db.feedbackForNote('n1')), ['tag-$open']);
    });

    test(
      'feedbackForNote omits a tag correction that has a handled feedback row and keeps the handled row',
      () {
        final db = _v6();
        final handled = db.seedTagCorrection(
          noteId: 'n1',
          tag: 'handled',
          createdAt: 1000,
        );
        db.seedFeedback(
          '01J9FBHANDLED0000000000001',
          kind: 'correction',
          noteId: 'n1',
          correction: correctionSamples['tag_removed'],
          status: 'handled',
          reply: 'Noted',
          tagCorrectionId: handled,
          createdAt: 1000,
          handledAt: 1200,
        );
        final open = db.seedTagCorrection(
          noteId: 'n1',
          tag: 'open',
          createdAt: 2000,
        );

        expect(_ids(db.feedbackForNote('n1')), [
          'tag-$open',
          '01J9FBHANDLED0000000000001',
        ]);
      },
    );

    test('feedbackForNote leaves out tag corrections of other notes', () {
      final db = _v6();
      db.seedTagCorrection(noteId: 'n2', tag: 'other', createdAt: 1000);
      final mine = db.seedTagCorrection(
        noteId: 'n1',
        tag: 'mine',
        createdAt: 2000,
      );

      expect(_ids(db.feedbackForNote('n1')), ['tag-$mine']);
    });

    test(
      'feedbackForNote merges tag corrections and feedback rows by created_at newest first',
      () {
        final db = _v6();
        db.seedFeedback('fb-old', noteId: 'n1', createdAt: 1000);
        final t1 = db.seedTagCorrection(noteId: 'n1', createdAt: 2000);
        db.seedFeedback('fb-mid', noteId: 'n1', createdAt: 3000);
        final t2 = db.seedTagCorrection(noteId: 'n1', createdAt: 4000);

        expect(_ids(db.feedbackForNote('n1')), [
          'tag-$t2',
          'fb-mid',
          'tag-$t1',
          'fb-old',
        ]);
      },
    );
  });

  group('feedbackWithoutNote', () {
    test(
      'feedbackWithoutNote includes rows with no note of every status newest first and leaves out noted rows',
      () {
        final db = _v6();
        db.seedFeedback('fb-old', createdAt: 1000);
        db.seedFeedback('fb-noted', noteId: 'n1', createdAt: 2000);
        db.seedFeedback(
          'fb-new',
          kind: 'correction',
          correction: correctionSamples['folder_deleted'],
          status: 'handled',
          handledAt: 3500,
          createdAt: 3000,
        );

        final rows = db.feedbackWithoutNote();

        expect(_ids(rows), ['fb-new', 'fb-old']);
        expect(rows.first.status, FeedbackStatus.handled);
        expect(
          vaultAccessShape(rows.first.correction),
          correctionShapes['folder_deleted'],
        );
      },
    );

    test(
      'feedbackWithoutNote includes an open tag correction whose note was deleted with its stored title',
      () {
        final db = _v6();
        final id = db.seedTagCorrection(
          noteTitle: 'Deleted Note Title',
          tag: 'gardening',
          createdAt: 5000,
        );

        final row = db.feedbackWithoutNote().single;

        expect(row.id, 'tag-$id');
        expect(row.noteId, isNull);
        expect(row.kind, FeedbackKind.correction);
        expect(row.status, FeedbackStatus.open);
        expect(row.createdAt, 5000);
        expect(vaultAccessShape(row.correction), {
          'TagRemovedCorrection': ['gardening', null, 'Deleted Note Title'],
        });
      },
    );

    test(
      'feedbackWithoutNote omits a cleared tag correction of a deleted note',
      () {
        final db = _v6();
        db.seedTagCorrection(
          noteTitle: 'Gone',
          createdAt: 1000,
          clearedAt: 1100,
        );
        final open = db.seedTagCorrection(
          noteTitle: 'Gone too',
          createdAt: 900,
        );

        expect(_ids(db.feedbackWithoutNote()), ['tag-$open']);
      },
    );

    test(
      'feedbackWithoutNote omits a deleted note tag correction that has a handled feedback row',
      () {
        final db = _v6();
        final handled = db.seedTagCorrection(
          noteTitle: 'Gone',
          createdAt: 1000,
        );
        db.seedFeedback(
          'fb-handled',
          kind: 'correction',
          correction: correctionSamples['tag_removed'],
          status: 'handled',
          tagCorrectionId: handled,
          createdAt: 1000,
        );

        expect(_ids(db.feedbackWithoutNote()), ['fb-handled']);
      },
    );

    test(
      'feedbackWithoutNote leaves out tag corrections of an existing note',
      () {
        final db = _v6();
        db.seedTagCorrection(noteId: 'n1', createdAt: 1000);
        final deleted = db.seedTagCorrection(noteTitle: 'Gone', createdAt: 900);

        expect(_ids(db.feedbackWithoutNote()), ['tag-$deleted']);
      },
    );

    test(
      'feedbackWithoutNote merges no-note rows and tag corrections newest first',
      () {
        final db = _v6();
        db.seedFeedback('fb-old', createdAt: 1000);
        final tag = db.seedTagCorrection(createdAt: 2000);
        db.seedFeedback('fb-new', createdAt: 3000);

        expect(_ids(db.feedbackWithoutNote()), [
          'fb-new',
          'tag-$tag',
          'fb-old',
        ]);
      },
    );
  });

  group('guideRevisions', () {
    test(
      'guideRevisions returns every revision newest created_at first regardless of insert order',
      () {
        final db = _v6();
        db.seedGuideRevision('rev-mid', createdAt: 2000);
        db.seedGuideRevision('rev-old', createdAt: 1000);
        db.seedGuideRevision('rev-new', createdAt: 3000);

        expect(db.guideRevisions().map((r) => r.id).toList(), [
          'rev-new',
          'rev-mid',
          'rev-old',
        ]);
      },
    );

    test(
      'guideRevisions orders equal created_at by insertion order, latest first',
      () {
        final db = _v6();
        db.seedGuideRevision('rev-a', createdAt: 1000);
        db.seedGuideRevision('rev-b', createdAt: 1000);

        expect(db.guideRevisions().map((r) => r.id).toList(), [
          'rev-b',
          'rev-a',
        ]);
      },
    );

    test('guideRevisions maps id, agent change id and created_at', () {
      final db = _v6();
      db.seedGuideRevision(
        'rev-1',
        agentChangeId: 'ac-9',
        createdAt: 1762300000000,
      );
      db.seedGuideRevision('rev-0', createdAt: 5);

      expect(vaultAccessShape(db.guideRevisions()), [
        {
          'GuideRevisionRow': ['rev-1', 'ac-9', 1762300000000],
        },
        {
          'GuideRevisionRow': ['rev-0', null, 5],
        },
      ]);
    });
  });

  group('below V6', () {
    test(
      'the Feedback and guide reads return empty on a V5 vault and do not throw, then the rows once it migrates to V6',
      () {
        final db = _v5();

        expect(db.feedbackForNote('n1'), isEmpty);
        expect(db.feedbackWithoutNote(), isEmpty);
        expect(db.guideRevisions(), isEmpty);

        db.migrateToV6();
        db.seedFeedback('fb-1', noteId: 'n1');
        db.seedFeedback('fb-2');
        db.seedGuideRevision('rev-1');

        expect(_ids(db.feedbackForNote('n1')), ['fb-1']);
        expect(_ids(db.feedbackWithoutNote()), ['fb-2']);
        expect(db.guideRevisions().map((r) => r.id).toList(), ['rev-1']);
      },
    );

    test(
      'the Feedback and guide reads return empty on a V4 vault and do not throw, then the rows once it migrates to V6',
      () {
        final db = _v4();

        expect(db.feedbackForNote('n1'), isEmpty);
        expect(db.feedbackWithoutNote(), isEmpty);
        expect(db.guideRevisions(), isEmpty);

        db.migrateToV6();
        db.seedFeedback('fb-1', noteId: 'n1');
        db.seedGuideRevision('rev-1');

        expect(_ids(db.feedbackForNote('n1')), ['fb-1']);
        expect(db.guideRevisions().map((r) => r.id).toList(), ['rev-1']);
      },
    );
  });
}
