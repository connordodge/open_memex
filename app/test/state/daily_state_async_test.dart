// WI #78 (W2) AC1, AC2, AC5: the daily providers read through the `daily`
// domain (D13), read here the way a reader shows them (`readScoped`, D14a).
// The today note read resolves today's daily note for `todayDateProvider`'s
// date. The editor's note read (`editorNoteAsyncProvider`) never shows
// another vault's note.
//
// `vaultDbProvider` is an EMPTY V5 database here (it only makes the vault
// read as V5-ready); the rows live in the doubles' databases, so a read that
// still read `vaultDbProvider` directly would be empty.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/daily_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/today_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';

import '../support/daily_seed.dart';
import '../support/editor_access_doubles.dart';
import '../support/fake_clock.dart';
import '../support/fake_vault_db.dart';
import '../support/vault_scoped_reads.dart';

const _vaultA = '/tmp/om-78-daily-a';
const _vaultB = '/tmp/om-78-daily-b';

/// The same daily-note id in both vaults, so a family facade keyed by it
/// would show the old vault's row if it ignored the loaded vault.
const _dayId = '01J9DAY0000000000000000000';
const _today = '2026-10-03';

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

/// A vault whose today note [_dayId] has one block [blockText], a footer chip
/// to the topic [topic], an Unreviewed review row, and (A only) a 2026-10-02
/// daily note.
FakeVaultDb _seedVault(
  FakeVaultDb db, {
  required String blockText,
  required String topic,
  bool withYesterday = false,
}) {
  db.seedDailyNote(_today, id: _dayId);
  if (withYesterday) db.seedDailyNote('2026-10-02', id: 'a-yesterday');
  db.seedTopicNote('t-$topic', topic);
  db.seedBlock(_dayId, 'blk-$topic', ord: 0, text: blockText);
  db.seedFooterChip(_dayId, 't-$topic', origin: 'person');
  db.seedDayReview(_dayId, contentVersion: 1);
  return db;
}

class _Daily {
  _Daily(this.c, this.a, this.b, this.clock);
  final ProviderContainer c;
  final EditorVaultDoubles a;
  final EditorVaultDoubles b;
  final FakeClock clock;

  void open(String? path) => c.read(currentVaultProvider.notifier).state =
      path == null ? null : LocalVaultRef(path);

  void bump() => c.read(vaultRevisionProvider.notifier).state++;
}

_Daily _container({
  String? open = _vaultA,
  FakeVaultDb? vaultDb,
  FakeVaultDb? dbA,
  FakeVaultDb? dbB,
  FakeClock? clock,
}) {
  final aDb =
      dbA ??
      _seedVault(
        _v5(),
        blockText: 'Alpha block',
        topic: 'Alpha',
        withYesterday: true,
      );
  final a = EditorVaultDoubles(notesDb: aDb, dailyDb: aDb);
  final bDb = dbB ?? _seedVault(_v5(), blockText: 'Beta block', topic: 'Beta');
  final b = EditorVaultDoubles(notesDb: bDb, dailyDb: bDb);
  final fakeClock = clock ?? FakeClock(DateTime(2026, 10, 3, 9));
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith(
        (_) => open == null ? null : LocalVaultRef(open),
      ),
      vaultDbProvider.overrideWithValue(vaultDb ?? _v5()),
      memexCliProvider.overrideWithValue(null),
      clockProvider.overrideWithValue(fakeClock),
      editorAccessOverride({_vaultA: a, _vaultB: b}),
    ],
  );
  addTearDown(c.dispose);
  return _Daily(c, a, b, fakeClock);
}

List<String> _dates(List<DailyNoteRow> rows) => [for (final r in rows) r.date];

void main() {
  group('daily providers read through the daily domain (AC1)', () {
    test(
      'the daily facades read through the daily domain and return the seeded rows',
      () async {
        final d = _container();

        expect(
          _dates(
            await settledScoped(
              d.c,
              dailyNotesAsyncProvider,
              const <DailyNoteRow>[],
            ),
          ),
          [_today, '2026-10-02'],
        );
        final review = await settledScoped(
          d.c,
          reviewStateAsyncProvider(_dayId),
          null,
        );
        expect(review!.state, ReviewState.unreviewed);
        final blocks = await settledScoped(
          d.c,
          blocksForNoteAsyncProvider(_dayId),
          const <BlockRow>[],
        );
        expect([for (final b in blocks) b.text], ['Alpha block']);
        final chips = await settledScoped(
          d.c,
          footerChipsAsyncProvider(_dayId),
          const <FooterChipRow>[],
        );
        expect([for (final x in chips) x.topicTitle], ['Alpha']);

        expect(
          d.a.daily.reads,
          containsAll([
            'dailyNotes',
            'reviewState:$_dayId',
            'blocksForNote:$_dayId',
            'footerChips:$_dayId',
          ]),
        );
      },
    );

    test(
      'the async daily providers yield the rows stamped with the vault they were loaded for',
      () async {
        final d = _container();

        final notes = await d.c.read(dailyNotesAsyncProvider.future);
        final review = await d.c.read(reviewStateAsyncProvider(_dayId).future);
        final blocks = await d.c.read(
          blocksForNoteAsyncProvider(_dayId).future,
        );
        final chips = await d.c.read(footerChipsAsyncProvider(_dayId).future);
        final today = await d.c.read(todayNoteAsyncProvider.future);

        const a = LocalVaultRef(_vaultA);
        expect(notes.vault, a);
        expect(_dates(notes.value), contains(_today));
        expect(review.vault, a);
        expect(review.value!.state, ReviewState.unreviewed);
        expect(blocks.vault, a);
        expect(blocks.value.single.text, 'Alpha block');
        expect(chips.vault, a);
        expect(chips.value.single.topicTitle, 'Alpha');
        expect(today.vault, a);
        expect(today.value!.noteId, _dayId);
      },
    );

    test(
      'the daily facades are empty before the first daily read completes',
      () async {
        final d = _container();
        d.a.holdFromStart = true;
        final notes = listenScoped(
          d.c,
          dailyNotesAsyncProvider,
          const <DailyNoteRow>[],
          (_, _) {},
        );
        final today = listenScoped(
          d.c,
          todayNoteAsyncProvider,
          null,
          (_, _) {},
        );
        final review = listenScoped(
          d.c,
          reviewStateAsyncProvider(_dayId),
          null,
          (_, _) {},
        );
        final blocks = listenScoped(
          d.c,
          blocksForNoteAsyncProvider(_dayId),
          const <BlockRow>[],
          (_, _) {},
        );
        final chips = listenScoped(
          d.c,
          footerChipsAsyncProvider(_dayId),
          const <FooterChipRow>[],
          (_, _) {},
        );
        await pumpEventQueue();

        expect(d.a.daily.gate.waiting, greaterThan(0));
        expect(notes.read(), isEmpty);
        expect(today.read(), isNull);
        expect(review.read(), isNull);
        expect(blocks.read(), isEmpty);
        expect(chips.read(), isEmpty);

        d.a.release();
        await pumpEventQueue();

        expect(notes.read(), isNotEmpty);
        expect(today.read()!.noteId, _dayId);
        expect(review.read(), isNotNull);
        expect(blocks.read(), hasLength(1));
        expect(chips.read(), hasLength(1));
      },
    );

    test('the daily facades are empty on a vault below V5', () async {
      final v4 = _v4()..seedDailyNote(_today, id: _dayId);
      final d = _container(vaultDb: v4, dbA: v4);

      expect(
        await settledScoped(
          d.c,
          dailyNotesAsyncProvider,
          const <DailyNoteRow>[],
        ),
        isEmpty,
      );
      expect(await settledScoped(d.c, todayNoteAsyncProvider, null), isNull);
      expect(
        await settledScoped(d.c, reviewStateAsyncProvider(_dayId), null),
        isNull,
      );
      expect(
        await settledScoped(
          d.c,
          blocksForNoteAsyncProvider(_dayId),
          const <BlockRow>[],
        ),
        isEmpty,
      );
      expect(
        await settledScoped(
          d.c,
          footerChipsAsyncProvider(_dayId),
          const <FooterChipRow>[],
        ),
        isEmpty,
      );
    });

    test('the daily facades are empty with no vault open', () async {
      final d = _container(open: null);

      expect(
        await settledScoped(
          d.c,
          dailyNotesAsyncProvider,
          const <DailyNoteRow>[],
        ),
        isEmpty,
      );
      expect(await settledScoped(d.c, todayNoteAsyncProvider, null), isNull);
      expect(
        await settledScoped(d.c, reviewStateAsyncProvider(_dayId), null),
        isNull,
      );
      expect(
        await settledScoped(
          d.c,
          blocksForNoteAsyncProvider(_dayId),
          const <BlockRow>[],
        ),
        isEmpty,
      );
      expect(
        await settledScoped(
          d.c,
          footerChipsAsyncProvider(_dayId),
          const <FooterChipRow>[],
        ),
        isEmpty,
      );
    });

    test(
      'on a revision bump the daily facades keep their previous values until the new read completes',
      () async {
        final d = _container();
        final notes = listenScoped(
          d.c,
          dailyNotesAsyncProvider,
          const <DailyNoteRow>[],
          (_, _) {},
        );
        final blocks = listenScoped(
          d.c,
          blocksForNoteAsyncProvider(_dayId),
          const <BlockRow>[],
          (_, _) {},
        );
        final chips = listenScoped(
          d.c,
          footerChipsAsyncProvider(_dayId),
          const <FooterChipRow>[],
          (_, _) {},
        );
        await pumpEventQueue();
        expect(_dates(notes.read()), [_today, '2026-10-02']);

        final db = d.a.notesDb! as FakeVaultDb;
        db.seedDailyNote('2026-10-01', id: 'a-older');
        db.seedBlock(_dayId, 'blk-new', ord: 1, text: 'New block');
        db.seedTopicNote('t-Gamma', 'Gamma');
        db.seedFooterChip(_dayId, 't-Gamma');
        d.a.hold();
        d.bump();
        await pumpEventQueue();

        expect(d.a.daily.gate.waiting, greaterThan(0));
        expect(_dates(notes.read()), [_today, '2026-10-02']);
        expect(blocks.read(), hasLength(1));
        expect(chips.read(), hasLength(1));

        d.a.release();
        await pumpEventQueue();

        expect(_dates(notes.read()), [_today, '2026-10-02', '2026-10-01']);
        expect(blocks.read(), hasLength(2));
        expect(chips.read(), hasLength(2));
      },
    );
  });

  group('the today note read (AC2)', () {
    test(
      'the today note read resolves to the daily note for the todayDateProvider date',
      () async {
        final d = _container();

        final note = await settledScoped(d.c, todayNoteAsyncProvider, null);

        expect(note!.noteId, _dayId);
        expect(note.date, d.c.read(todayDateProvider));
      },
    );

    test('the today note read is null when today has no daily note', () async {
      final db = _v5()..seedDailyNote('2026-10-02', id: 'yesterday');
      final d = _container(dbA: db);

      expect(await settledScoped(d.c, todayNoteAsyncProvider, null), isNull);
    });

    test(
      'the today note read follows todayDateProvider past local midnight',
      () async {
        final db = _v5()
          ..seedDailyNote('2026-10-03', id: 'oct3')
          ..seedDailyNote('2026-10-04', id: 'oct4');
        final d = _container(
          dbA: db,
          clock: FakeClock(DateTime(2026, 10, 3, 23, 59)),
        );
        expect(
          (await settledScoped(d.c, todayNoteAsyncProvider, null))!.noteId,
          'oct3',
        );

        d.clock.advance(const Duration(minutes: 2));

        expect(
          (await settledScoped(d.c, todayNoteAsyncProvider, null))!.noteId,
          'oct4',
        );
      },
    );

    test(
      'the today note read ignores a role-less note titled with today',
      () async {
        final db = _v5()..seedNote(id: 'plain', title: _today);
        final d = _container(dbA: db);

        expect(await settledScoped(d.c, todayNoteAsyncProvider, null), isNull);
      },
    );
  });

  group('switching vaults (AC5, D14a)', () {
    /// Loads [read] on vault A, switches to a held vault B and returns a
    /// subscription to what a reader of [read] shows (B still pending).
    Future<ProviderSubscription<T>> switchToHeldB<T>(
      _Daily d,
      ProviderListenable<AsyncValue<VaultScoped<T>>> read,
      T empty,
    ) async {
      final sub = listenScoped<T>(d.c, read, empty, (_, _) {});
      await pumpEventQueue();
      d.b.holdFromStart = true;
      d.open(_vaultB);
      await pumpEventQueue();
      return sub;
    }

    test(
      'switching vaults never shows the previous vault rows in the daily notes read',
      () async {
        final d = _container();
        expect(
          await settledScoped(
            d.c,
            dailyNotesAsyncProvider,
            const <DailyNoteRow>[],
          ),
          hasLength(2),
        );

        final sub = await switchToHeldB(
          d,
          dailyNotesAsyncProvider,
          const <DailyNoteRow>[],
        );

        expect(sub.read(), isEmpty, reason: 'B is still loading');
        d.b.release();
        await pumpEventQueue();
        expect(_dates(sub.read()), [_today]);
      },
    );

    test(
      'switching vaults never shows the previous vault rows in the today note read',
      () async {
        final d = _container();
        expect(
          await settledScoped(d.c, todayNoteAsyncProvider, null),
          isNotNull,
        );

        final sub = await switchToHeldB(d, todayNoteAsyncProvider, null);

        expect(sub.read(), isNull, reason: 'B is still loading');
        d.b.release();
        await pumpEventQueue();
        expect(sub.read()!.noteId, _dayId);
      },
    );

    test(
      'switching vaults never shows the previous vault rows in the review state read',
      () async {
        final d = _container();
        expect(
          await settledScoped(d.c, reviewStateAsyncProvider(_dayId), null),
          isNotNull,
        );

        final sub = await switchToHeldB(
          d,
          reviewStateAsyncProvider(_dayId),
          null,
        );

        expect(sub.read(), isNull, reason: 'B is still loading');
        d.b.release();
        await pumpEventQueue();
        expect(sub.read()!.state, ReviewState.unreviewed);
      },
    );

    test(
      'switching vaults never shows the previous vault rows in the blocks read',
      () async {
        final d = _container();
        expect(
          await settledScoped(
            d.c,
            blocksForNoteAsyncProvider(_dayId),
            const <BlockRow>[],
          ),
          hasLength(1),
        );

        final sub = await switchToHeldB(
          d,
          blocksForNoteAsyncProvider(_dayId),
          const <BlockRow>[],
        );

        expect(sub.read(), isEmpty, reason: 'B is still loading');
        d.b.release();
        await pumpEventQueue();
        expect(sub.read().single.text, 'Beta block');
      },
    );

    test(
      'switching vaults never shows the previous vault rows in the footer chips read',
      () async {
        final d = _container();
        expect(
          await settledScoped(
            d.c,
            footerChipsAsyncProvider(_dayId),
            const <FooterChipRow>[],
          ),
          hasLength(1),
        );

        final sub = await switchToHeldB(
          d,
          footerChipsAsyncProvider(_dayId),
          const <FooterChipRow>[],
        );

        expect(sub.read(), isEmpty, reason: 'B is still loading');
        d.b.release();
        await pumpEventQueue();
        expect(sub.read().single.topicTitle, 'Beta');
      },
    );

    test(
      'switching vaults never shows the previous vault rows in the editor note read',
      () async {
        final d = _container();
        d.c.read(selectedNoteIdProvider.notifier).state = _dayId;
        final note = await settledScoped(d.c, editorNoteAsyncProvider, null);
        expect(note!.id, _dayId);
        expect(d.a.notes.reads, contains('getNote:$_dayId'));

        final sub = await switchToHeldB(d, editorNoteAsyncProvider, null);

        expect(sub.read(), isNull, reason: 'B is still loading');
        d.b.release();
        await pumpEventQueue();
        expect(sub.read()!.id, _dayId);
        expect(d.b.notes.reads, contains('getNote:$_dayId'));
      },
    );

    test(
      'the editor note read is the virtual Today note for a virtual Today tab without a vault read',
      () async {
        final d = _container();
        d.c.read(selectedNoteIdProvider.notifier).state = const VirtualTodayTab(
          _today,
        ).id;

        final note = await settledScoped(d.c, editorNoteAsyncProvider, null);

        expect(note!.id, const VirtualTodayTab(_today).id);
        expect(note.title, _today);
        expect(note.role, 'daily');
        expect(d.a.noteReads.where((r) => r.startsWith('getNote')), isEmpty);
      },
    );
  });
}
