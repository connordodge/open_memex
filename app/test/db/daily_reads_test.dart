import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';

import '../support/daily_seed.dart';
import '../support/fake_vault_db.dart';

FakeVaultDb _v5() {
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  return db;
}

FakeVaultDb _v4() {
  final db = FakeVaultDb.v4();
  addTearDown(db.close);
  return db;
}

void main() {
  group('dailyNotes (AC1, AC2)', () {
    test(
      'returns one row per role daily note with date, note id, preview and review state',
      () {
        final db = _v5();
        final id = db.seedDailyNote('2026-10-03', id: 'd-oct3');
        db.seedBlock(id, 'b1', ord: 0, text: 'Met Priya about the roadmap');
        db.seedDayReview(id, contentVersion: 2, reviewedContentVersion: 2);

        final rows = db.dailyNotes();

        expect(rows, hasLength(1));
        expect(rows.single.date, '2026-10-03');
        expect(rows.single.noteId, 'd-oct3');
        expect(rows.single.preview, 'Met Priya about the roadmap');
        expect(rows.single.reviewState, ReviewState.reviewed);
      },
    );

    test(
      'orders daily notes newest date first regardless of insertion or update time',
      () {
        final db = _v5();
        // Inserted and touched in an order that contradicts date order.
        db.seedDailyNote('2026-09-05', updatedAt: 1759900000000);
        db.seedDailyNote('2026-10-03', updatedAt: 1759100000000);
        db.seedDailyNote('2025-12-31', updatedAt: 1759800000000);
        db.seedDailyNote('2026-08-30', updatedAt: 1759200000000);

        expect(db.dailyNotes().map((r) => r.date), [
          '2026-10-03',
          '2026-09-05',
          '2026-08-30',
          '2025-12-31',
        ]);
      },
    );

    test(
      'excludes topic notes, role-less notes and role-less notes with ISO date titles',
      () {
        final db = _v5();
        db.seedDailyNote('2026-10-03');
        db.seedTopicNote('t1', 'Roadmap');
        db.seedTopicNote('t2', '2026-10-02'); // topic with an ISO title
        db.seedNote(id: 'n1', title: 'Plain note');
        db.seedNote(id: 'n2', title: '2026-10-01'); // role-less ISO title
        db.seedNote(
          id: 'n3',
          title: 'Empty role',
          frontmatter: '{"role":null}',
        );

        final rows = db.dailyNotes();

        expect(rows.map((r) => r.noteId), ['daily-2026-10-03']);
      },
    );

    test(
      'ignores a note whose frontmatter is not valid JSON instead of throwing',
      () {
        final db = _v5();
        db.seedDailyNote('2026-10-03');
        db.seedNote(id: 'bad', title: '2026-10-02', frontmatter: 'not json{');

        expect(db.dailyNotes().map((r) => r.date), ['2026-10-03']);
      },
    );

    test('returns an empty list when the vault has no daily notes', () {
      final db = _v5();
      db.seedTopicNote('t1', 'Roadmap');

      expect(db.dailyNotes(), isEmpty);
    });

    test(
      'preview is the first line of the lowest ord block text, not the lowest block id or insertion order',
      () {
        final db = _v5();
        final id = db.seedDailyNote('2026-10-03');
        // Inserted out of ord order; block ids sort opposite to ord.
        db.seedBlock(id, 'a-last', ord: 2, text: 'Third');
        db.seedBlock(
          id,
          'z-first',
          ord: 0,
          text: 'Alpha line\nsecond line\nthird',
        );
        db.seedBlock(id, 'm-mid', ord: 1, text: 'Second block');

        expect(db.dailyNotes().single.preview, 'Alpha line');
      },
    );

    test('preview of a single line block is the whole text', () {
      final db = _v5();
      final id = db.seedDailyNote('2026-10-03');
      db.seedBlock(id, 'b1', ord: 0, text: 'Only line');

      expect(db.dailyNotes().single.preview, 'Only line');
    });

    test('preview is an empty string when the daily note has no blocks', () {
      final db = _v5();
      db.seedDailyNote('2026-10-03');

      expect(db.dailyNotes().single.preview, '');
    });

    test('preview comes from each notes own blocks, never another notes', () {
      final db = _v5();
      final a = db.seedDailyNote('2026-10-03');
      final b = db.seedDailyNote('2026-10-02');
      db.seedBlock(a, 'ba', ord: 0, text: 'Today block');
      db.seedBlock(b, 'bb', ord: 0, text: 'Yesterday block');

      final rows = db.dailyNotes();

      expect(rows.map((r) => r.preview), ['Today block', 'Yesterday block']);
    });

    test('each row carries its own review state', () {
      final db = _v5();
      final never = db.seedDailyNote('2026-10-05'); // no day_reviews row
      final nullReviewed = db.seedDailyNote('2026-10-04');
      final reviewed = db.seedDailyNote('2026-10-03');
      final changed = db.seedDailyNote('2026-10-02');
      db.seedDayReview(nullReviewed, contentVersion: 2);
      db.seedDayReview(reviewed, contentVersion: 3, reviewedContentVersion: 3);
      db.seedDayReview(changed, contentVersion: 5, reviewedContentVersion: 3);

      final byId = {for (final r in db.dailyNotes()) r.noteId: r.reviewState};

      expect(byId, {
        never: ReviewState.unreviewed,
        nullReviewed: ReviewState.unreviewed,
        reviewed: ReviewState.reviewed,
        changed: ReviewState.changedSinceReview,
      });
    });
  });

  group('reviewState (AC3)', () {
    test('is Unreviewed with no day_reviews row and no reviewedAt', () {
      final db = _v5();
      final id = db.seedDailyNote('2026-10-03');

      final info = db.reviewState(id)!;

      expect(info.state, ReviewState.unreviewed);
      expect(info.reviewedAt, isNull);
    });

    test('is Unreviewed when reviewed_content_version is NULL', () {
      final db = _v5();
      final id = db.seedDailyNote('2026-10-03');
      db.seedDayReview(id, contentVersion: 4);

      final info = db.reviewState(id)!;

      expect(info.state, ReviewState.unreviewed);
      expect(info.reviewedAt, isNull);
    });

    test(
      'is Reviewed when content version equals reviewed content version, with reviewedAt',
      () {
        final db = _v5();
        final id = db.seedDailyNote('2026-10-03');
        db.seedDayReview(
          id,
          contentVersion: 3,
          reviewedContentVersion: 3,
          reviewedAt: 1759500123000,
        );

        final info = db.reviewState(id)!;

        expect(info.state, ReviewState.reviewed);
        expect(info.reviewedAt, 1759500123000);
      },
    );

    test('is Reviewed at version zero when both versions are zero', () {
      final db = _v5();
      final id = db.seedDailyNote('2026-10-03');
      db.seedDayReview(id, contentVersion: 0, reviewedContentVersion: 0);

      expect(db.reviewState(id)!.state, ReviewState.reviewed);
    });

    test(
      'is Changed since review when content version is newer, keeping reviewedAt',
      () {
        final db = _v5();
        final id = db.seedDailyNote('2026-10-03');
        db.seedDayReview(
          id,
          contentVersion: 4,
          reviewedContentVersion: 3,
          reviewedAt: 1759500123000,
        );

        final info = db.reviewState(id)!;

        expect(info.state, ReviewState.changedSinceReview);
        expect(info.reviewedAt, 1759500123000);
      },
    );

    test('is Changed since review by one version only', () {
      final db = _v5();
      final id = db.seedDailyNote('2026-10-03');
      db.seedDayReview(id, contentVersion: 1, reviewedContentVersion: 0);

      expect(db.reviewState(id)!.state, ReviewState.changedSinceReview);
    });

    test('is Changed since review when versions differ in any direction', () {
      // Mirrors the Rust function: equal means Reviewed, anything else with a
      // reviewed version recorded is Changed since review.
      final db = _v5();
      final id = db.seedDailyNote('2026-10-03');
      db.seedDayReview(id, contentVersion: 2, reviewedContentVersion: 3);

      expect(db.reviewState(id)!.state, ReviewState.changedSinceReview);
    });

    test('reads the row of the asked note only', () {
      final db = _v5();
      final a = db.seedDailyNote('2026-10-03');
      final b = db.seedDailyNote('2026-10-02');
      db.seedDayReview(a, contentVersion: 1, reviewedContentVersion: 1);
      db.seedDayReview(b, contentVersion: 2, reviewedContentVersion: 1);

      expect(db.reviewState(a)!.state, ReviewState.reviewed);
      expect(db.reviewState(b)!.state, ReviewState.changedSinceReview);
    });
  });

  group('dailyNoteForDate (AC5)', () {
    test('returns the role daily note with that title', () {
      final db = _v5();
      final id = db.seedDailyNote('2026-10-03', id: 'd-oct3');
      db.seedDailyNote('2026-10-02');
      db.seedBlock(id, 'b1', ord: 0, text: 'Hello');
      db.seedDayReview(id, contentVersion: 2, reviewedContentVersion: 1);

      final row = db.dailyNoteForDate('2026-10-03')!;

      expect(row.noteId, 'd-oct3');
      expect(row.date, '2026-10-03');
      expect(row.preview, 'Hello');
      expect(row.reviewState, ReviewState.changedSinceReview);
    });

    test('returns null when only a role-less note has that title', () {
      final db = _v5();
      db.seedNote(id: 'plain', title: '2026-10-03');

      expect(db.dailyNoteForDate('2026-10-03'), isNull);
    });

    test('returns null when only a topic note has that title', () {
      final db = _v5();
      db.seedTopicNote('t', '2026-10-03');

      expect(db.dailyNoteForDate('2026-10-03'), isNull);
    });

    test(
      'returns null when only a note with invalid frontmatter has that title',
      () {
        final db = _v5();
        db.seedNote(id: 'bad', title: '2026-10-03', frontmatter: 'not json{');

        expect(db.dailyNoteForDate('2026-10-03'), isNull);
      },
    );

    test('returns null for a date with no note at all', () {
      final db = _v5();
      db.seedDailyNote('2026-10-02');

      expect(db.dailyNoteForDate('2026-10-03'), isNull);
    });
  });

  group('blocksForNote (AC6)', () {
    test('returns every field of each block in ord order', () {
      final db = _v5();
      final id = db.seedDailyNote('2026-10-03');
      db.seedBlock(
        id,
        'b-agent',
        ord: 2,
        text: 'agent text',
        source: 'agent',
        startByte: 40,
        endByte: 50,
        createdVersion: 5,
        createdAt: 1759500300000,
      );
      db.seedBlock(
        id,
        'b-person',
        ord: 0,
        text: 'person text',
        source: 'person',
        startByte: 0,
        endByte: 11,
        createdVersion: 1,
        createdAt: 1759500100000,
      );
      db.seedBlock(
        id,
        'b-quick',
        ord: 1,
        text: 'quick\nentry',
        source: 'quick-entry',
        startByte: 13,
        endByte: 24,
        createdVersion: 3,
        createdAt: 1759500200000,
      );

      final blocks = db.blocksForNote(id);

      expect(blocks.map((b) => b.blockId), ['b-person', 'b-quick', 'b-agent']);
      expect(blocks.map((b) => b.ord), [0, 1, 2]);
      expect(blocks.map((b) => b.text), [
        'person text',
        'quick\nentry',
        'agent text',
      ]);
      expect(blocks.map((b) => b.source), ['person', 'quick-entry', 'agent']);
      expect(blocks.map((b) => b.createdVersion), [1, 3, 5]);
      expect(blocks.map((b) => b.createdAt), [
        1759500100000,
        1759500200000,
        1759500300000,
      ]);
      expect(blocks.map((b) => b.startByte), [0, 13, 40]);
      expect(blocks.map((b) => b.endByte), [11, 24, 50]);
    });

    test('returns only the blocks of the asked note', () {
      final db = _v5();
      final a = db.seedDailyNote('2026-10-03');
      final b = db.seedDailyNote('2026-10-02');
      db.seedBlock(a, 'ba', ord: 0, text: 'A');
      db.seedBlock(b, 'bb', ord: 0, text: 'B');

      expect(db.blocksForNote(a).map((x) => x.blockId), ['ba']);
    });

    test(
      'returns an empty list for a note with no blocks or an unknown note',
      () {
        final db = _v5();
        final id = db.seedDailyNote('2026-10-03');

        expect(db.blocksForNote(id), isEmpty);
        expect(db.blocksForNote('missing'), isEmpty);
      },
    );
  });

  group('footerChips (AC7)', () {
    test(
      'returns topic note id, topic title and origin in insertion order, not created_at or id order',
      () {
        final db = _v5();
        final day = db.seedDailyNote('2026-10-03');
        db.seedTopicNote('t-zeta', 'Zeta topic');
        db.seedTopicNote('t-alpha', 'Alpha topic');
        db.seedTopicNote('t-mid', 'Mid topic');
        // created_at and ids disagree with insertion order on purpose.
        db.seedFooterChip(day, 't-zeta', origin: 'excerpt', createdAt: 3000);
        db.seedFooterChip(day, 't-alpha', origin: 'person', createdAt: 1000);
        db.seedFooterChip(day, 't-mid', origin: 'excerpt', createdAt: 2000);

        final chips = db.footerChips(day);

        expect(chips.map((c) => c.topicNoteId), ['t-zeta', 't-alpha', 't-mid']);
        expect(chips.map((c) => c.topicTitle), [
          'Zeta topic',
          'Alpha topic',
          'Mid topic',
        ]);
        expect(chips.map((c) => c.origin), ['excerpt', 'person', 'excerpt']);
      },
    );

    test('returns only the chips of the asked daily note', () {
      final db = _v5();
      final a = db.seedDailyNote('2026-10-03');
      final b = db.seedDailyNote('2026-10-02');
      db.seedTopicNote('t1', 'One');
      db.seedTopicNote('t2', 'Two');
      db.seedFooterChip(a, 't1');
      db.seedFooterChip(b, 't2');

      expect(db.footerChips(a).map((c) => c.topicNoteId), ['t1']);
      expect(db.footerChips(b).map((c) => c.topicNoteId), ['t2']);
    });

    test('returns an empty list for a daily note with no chips', () {
      final db = _v5();
      final day = db.seedDailyNote('2026-10-03');

      expect(db.footerChips(day), isEmpty);
    });
  });

  group('V4 vault (AC8)', () {
    test('every daily read returns an empty list or null without throwing', () {
      final db = _v4();
      // The notes table exists on V4, so seed rows a naive query would find.
      db.seedDailyNote('2026-10-03', id: 'd1');
      db.seedTopicNote('t1', 'Topic');

      expect(db.dailyNotes(), isEmpty);
      expect(db.dailyNoteForDate('2026-10-03'), isNull);
      expect(db.reviewState('d1'), isNull);
      expect(db.blocksForNote('d1'), isEmpty);
      expect(db.footerChips('d1'), isEmpty);
    });

    test(
      'reads see the V5 tables after the vault is migrated on the same handle',
      () {
        final db = _v4();
        db.seedDailyNote('2026-10-03', id: 'd1');
        expect(db.dailyNotes(), isEmpty);

        db.migrateToV5();
        db.seedBlock('d1', 'b1', ord: 0, text: 'Now visible');

        final rows = db.dailyNotes();
        expect(rows.map((r) => r.noteId), ['d1']);
        expect(rows.single.preview, 'Now visible');
        expect(db.reviewState('d1')!.state, ReviewState.unreviewed);
      },
    );
  });
}
