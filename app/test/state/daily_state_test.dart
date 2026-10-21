import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/daily_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/review_state_colors.dart';

import '../support/daily_seed.dart';
import '../support/fake_clock.dart';
import '../support/fake_vault_db.dart';
import '../support/vault_scoped_reads.dart';

ProviderContainer _container({
  VaultDb? db,
  FakeClock? clock,
  bool noDb = false,
}) {
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith(
        (_) => LocalVaultRef('/tmp/om-fake-vault'),
      ),
      vaultDbProvider.overrideWithValue(noDb ? null : db),
      memexCliProvider.overrideWithValue(null),
      clockProvider.overrideWithValue(clock ?? FakeClock()),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

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

void _bump(ProviderContainer c) =>
    c.read(vaultRevisionProvider.notifier).state++;

void main() {
  group('ReviewState labels and colours (AC4)', () {
    test(
      'labels are exactly Unreviewed, Reviewed and Changed since review',
      () {
        expect(ReviewState.unreviewed.label, 'Unreviewed');
        expect(ReviewState.reviewed.label, 'Reviewed');
        expect(ReviewState.changedSinceReview.label, 'Changed since review');
      },
    );

    test('the theme helper maps the states to fg3, accentSoft and warn', () {
      expect(reviewStateColor(ReviewState.unreviewed), OmColors.fg3);
      expect(reviewStateColor(ReviewState.reviewed), OmColors.accentSoft);
      expect(reviewStateColor(ReviewState.changedSinceReview), OmColors.warn);
    });
  });

  group('todayDateProvider (AC9)', () {
    test(
      'reads the local ISO date and moves to the next date two minutes past 23:59',
      () {
        final clock = FakeClock(DateTime(2026, 10, 3, 23, 59));
        final c = _container(db: _v5(), clock: clock);

        expect(c.read(todayDateProvider), '2026-10-03');

        clock.advance(const Duration(minutes: 2));

        expect(c.read(todayDateProvider), '2026-10-04');
      },
    );

    test(
      'notifies listeners exactly at local midnight, not a moment before',
      () {
        final clock = FakeClock(DateTime(2026, 10, 3, 23, 59));
        final c = _container(db: _v5(), clock: clock);
        final seen = <String>[];
        c.listen<String>(todayDateProvider, (_, next) => seen.add(next));

        clock.advance(const Duration(seconds: 59, milliseconds: 999));
        expect(seen, isEmpty);
        expect(c.read(todayDateProvider), '2026-10-03');

        clock.advance(const Duration(milliseconds: 1));
        expect(seen, ['2026-10-04']);
        expect(c.read(todayDateProvider), '2026-10-04');
      },
    );

    test('keeps moving: a second midnight rolls the date again', () {
      final clock = FakeClock(DateTime(2026, 10, 3, 23, 59));
      final c = _container(db: _v5(), clock: clock);
      final seen = <String>[];
      c.listen<String>(todayDateProvider, (_, next) => seen.add(next));

      clock.advance(const Duration(minutes: 1));
      clock.advance(const Duration(hours: 24));

      expect(seen, ['2026-10-04', '2026-10-05']);
    });

    test('rolls over a month and year boundary', () {
      final clock = FakeClock(DateTime(2026, 12, 31, 23, 59, 30));
      final c = _container(db: _v5(), clock: clock);

      expect(c.read(todayDateProvider), '2026-12-31');
      clock.advance(const Duration(minutes: 1));

      expect(c.read(todayDateProvider), '2027-01-01');
    });

    test('does not change within the day and zero-pads the date', () {
      final clock = FakeClock(DateTime(2026, 3, 5, 0, 0, 1));
      final c = _container(db: _v5(), clock: clock);
      final seen = <String>[];
      c.listen<String>(todayDateProvider, (_, next) => seen.add(next));

      expect(c.read(todayDateProvider), '2026-03-05');
      clock.advance(const Duration(hours: 23, minutes: 59));

      expect(seen, isEmpty);
      expect(c.read(todayDateProvider), '2026-03-05');
    });

    test('leaves no timer behind once the container is disposed', () {
      final clock = FakeClock(DateTime(2026, 10, 3, 23, 59));
      final c = ProviderContainer(
        overrides: [
          currentVaultProvider.overrideWith(
            (_) => LocalVaultRef('/tmp/om-fake-vault'),
          ),
          vaultDbProvider.overrideWithValue(null),
          memexCliProvider.overrideWithValue(null),
          clockProvider.overrideWithValue(clock),
        ],
      );
      c.listen<String>(todayDateProvider, (_, _) {});
      expect(c.read(todayDateProvider), '2026-10-03');

      c.dispose();

      expect(clock.pendingTimers, 0);
    });
  });

  group('the today note read (AC10)', () {
    test(
      'is null with no daily note for today and the note once seeded and the revision is bumped',
      () async {
        final db = _v5();
        final clock = FakeClock(DateTime(2026, 10, 3, 9));
        final c = _container(db: db, clock: clock);
        db.seedDailyNote('2026-10-02', id: 'yesterday');

        expect(await settledScoped(c, todayNoteAsyncProvider, null), isNull);

        db.seedDailyNote('2026-10-03', id: 'today');
        _bump(c);

        final note = (await settledScoped(c, todayNoteAsyncProvider, null))!;
        expect(note.noteId, 'today');
        expect(note.date, '2026-10-03');
      },
    );

    test('follows the date past local midnight', () async {
      final db = _v5();
      final clock = FakeClock(DateTime(2026, 10, 3, 23, 59));
      final c = _container(db: db, clock: clock);
      db.seedDailyNote('2026-10-03', id: 'oct3');
      db.seedDailyNote('2026-10-04', id: 'oct4');
      listenScoped(c, todayNoteAsyncProvider, null, (_, _) {});

      expect(
        (await settledScoped(c, todayNoteAsyncProvider, null))!.noteId,
        'oct3',
      );

      clock.advance(const Duration(minutes: 2));

      expect(
        (await settledScoped(c, todayNoteAsyncProvider, null))!.noteId,
        'oct4',
      );
    });

    test('is null after midnight when the new day has no note yet', () async {
      final db = _v5();
      final clock = FakeClock(DateTime(2026, 10, 3, 23, 59));
      final c = _container(db: db, clock: clock);
      db.seedDailyNote('2026-10-03', id: 'oct3');
      listenScoped(c, todayNoteAsyncProvider, null, (_, _) {});
      expect(
        (await settledScoped(c, todayNoteAsyncProvider, null))!.noteId,
        'oct3',
      );

      clock.advance(const Duration(minutes: 2));

      expect(await settledScoped(c, todayNoteAsyncProvider, null), isNull);
    });

    test('ignores a role-less note titled with today', () async {
      final db = _v5();
      final c = _container(db: db, clock: FakeClock(DateTime(2026, 10, 3, 9)));
      db.seedNote(id: 'plain', title: '2026-10-03');

      expect(await settledScoped(c, todayNoteAsyncProvider, null), isNull);
    });

    test('is null when no vault database is open', () async {
      final c = _container(noDb: true);

      expect(await settledScoped(c, todayNoteAsyncProvider, null), isNull);
    });
  });

  group('the daily notes read and the review state read (AC11)', () {
    test(
      'the daily notes read re-reads after a vaultRevisionProvider bump',
      () async {
        final db = _v5();
        final c = _container(db: db);
        db.seedDailyNote('2026-10-02');
        expect(
          (await settledScoped(
            c,
            dailyNotesAsyncProvider,
            const <DailyNoteRow>[],
          )).map((r) => r.date),
          ['2026-10-02'],
        );

        db.seedDailyNote('2026-10-03');
        _bump(c);

        expect(
          (await settledScoped(
            c,
            dailyNotesAsyncProvider,
            const <DailyNoteRow>[],
          )).map((r) => r.date),
          ['2026-10-03', '2026-10-02'],
        );
      },
    );

    test(
      'the review state read flips from Unreviewed to Reviewed after a seeded review and a bump',
      () async {
        final db = _v5();
        final c = _container(db: db);
        final id = db.seedDailyNote('2026-10-03');

        expect(
          (await settledScoped(c, reviewStateAsyncProvider(id), null))!.state,
          ReviewState.unreviewed,
        );

        db.seedDayReview(
          id,
          contentVersion: 2,
          reviewedContentVersion: 2,
          reviewedAt: 1759500123000,
        );
        _bump(c);

        final info = (await settledScoped(
          c,
          reviewStateAsyncProvider(id),
          null,
        ))!;
        expect(info.state, ReviewState.reviewed);
        expect(info.reviewedAt, 1759500123000);
      },
    );

    test('the review state read is keyed by note id', () async {
      final db = _v5();
      final c = _container(db: db);
      final a = db.seedDailyNote('2026-10-03');
      final b = db.seedDailyNote('2026-10-02');
      db.seedDayReview(a, contentVersion: 1, reviewedContentVersion: 1);
      db.seedDayReview(b, contentVersion: 2, reviewedContentVersion: 1);

      expect(
        (await settledScoped(c, reviewStateAsyncProvider(a), null))!.state,
        ReviewState.reviewed,
      );
      expect(
        (await settledScoped(c, reviewStateAsyncProvider(b), null))!.state,
        ReviewState.changedSinceReview,
      );
    });

    test(
      'the blocks read and the footer chips read re-read after a bump',
      () async {
        final db = _v5();
        final c = _container(db: db);
        final day = db.seedDailyNote('2026-10-03');
        db.seedTopicNote('t1', 'Roadmap');
        expect(
          await settledScoped(
            c,
            blocksForNoteAsyncProvider(day),
            const <BlockRow>[],
          ),
          isEmpty,
        );
        expect(
          await settledScoped(
            c,
            footerChipsAsyncProvider(day),
            const <FooterChipRow>[],
          ),
          isEmpty,
        );

        db.seedBlock(day, 'b1', ord: 0, text: 'First');
        db.seedFooterChip(day, 't1', origin: 'person');
        _bump(c);

        expect(
          (await settledScoped(
            c,
            blocksForNoteAsyncProvider(day),
            const <BlockRow>[],
          )).map((b) => b.blockId),
          ['b1'],
        );
        final chips = (await settledScoped(
          c,
          footerChipsAsyncProvider(day),
          const <FooterChipRow>[],
        ));
        expect(chips.map((x) => x.topicTitle), ['Roadmap']);
        expect(chips.single.origin, 'person');
      },
    );
  });

  group('V4 vault and no vault (AC8)', () {
    test(
      'every provider is empty on a V4 vault and fills after migration and a bump',
      () async {
        final db = _v4();
        final c = _container(
          db: db,
          clock: FakeClock(DateTime(2026, 10, 3, 9)),
        );
        db.seedDailyNote('2026-10-03', id: 'd1');

        expect(
          await settledScoped(
            c,
            dailyNotesAsyncProvider,
            const <DailyNoteRow>[],
          ),
          isEmpty,
        );
        expect(await settledScoped(c, todayNoteAsyncProvider, null), isNull);
        expect(
          await settledScoped(c, reviewStateAsyncProvider('d1'), null),
          isNull,
        );
        expect(
          await settledScoped(
            c,
            blocksForNoteAsyncProvider('d1'),
            const <BlockRow>[],
          ),
          isEmpty,
        );
        expect(
          await settledScoped(
            c,
            footerChipsAsyncProvider('d1'),
            const <FooterChipRow>[],
          ),
          isEmpty,
        );

        db.migrateToV5();
        _bump(c);

        expect(
          (await settledScoped(
            c,
            dailyNotesAsyncProvider,
            const <DailyNoteRow>[],
          )).map((r) => r.noteId),
          ['d1'],
        );
        expect(
          (await settledScoped(c, todayNoteAsyncProvider, null))!.noteId,
          'd1',
        );
        expect(
          (await settledScoped(c, reviewStateAsyncProvider('d1'), null))!.state,
          ReviewState.unreviewed,
        );
      },
    );

    test('providers are empty when no vault database is open', () async {
      final c = _container(noDb: true);

      expect(
        await settledScoped(c, dailyNotesAsyncProvider, const <DailyNoteRow>[]),
        isEmpty,
      );
      expect(await settledScoped(c, todayNoteAsyncProvider, null), isNull);
      expect(
        await settledScoped(c, reviewStateAsyncProvider('d1'), null),
        isNull,
      );
      expect(
        await settledScoped(
          c,
          blocksForNoteAsyncProvider('d1'),
          const <BlockRow>[],
        ),
        isEmpty,
      );
      expect(
        await settledScoped(
          c,
          footerChipsAsyncProvider('d1'),
          const <FooterChipRow>[],
        ),
        isEmpty,
      );
    });
  });
}
