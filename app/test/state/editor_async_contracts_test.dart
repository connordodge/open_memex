// WI #78 (W2) contracts the implementer documented but no AC test pinned
// (verify mode):
// - tabsProvider: the launch's virtual Today tab resolves onto the stored
//   daily note only when the read lands for the launch date and vault;
// - excerptRenderProvider: null with no vault open.
// The virtual Today read-back contract is in editor_daily_read_back_test.dart.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/daily_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/widgets/editor/excerpt_card.dart';

import '../support/daily_seed.dart';
import '../support/editor_access_doubles.dart';
import '../support/fake_clock.dart';
import '../support/fake_vault_db.dart';
import '../support/vault_scoped_reads.dart';

const _today = '2026-10-03';
const _aTodayId = '01J9ATODAY0000000000000078';
const _bTodayId = '01J9BTODAY0000000000000078';
const _oct4Id = '01J9OCT0400000000000000078';

/// A daily domain whose `dailyNotes` read always fails (D21: extends the
/// local class).
class _Wi78FailingDailyNotes extends LocalDailyAccess {
  _Wi78FailingDailyNotes({required super.vaultPath, super.db});

  int calls = 0;

  @override
  Future<List<DailyNoteRow>> dailyNotes() async {
    calls++;
    throw MemexException('read failed: database is locked');
  }
}

class _Launch {
  _Launch(this.c, this.dirs);
  final ProviderContainer c;
  final Map<String, Directory> dirs;

  TabsState get tabs => c.read(tabsProvider);

  void open(String name) => c.read(currentVaultProvider.notifier).state =
      LocalVaultRef(dirs[name]!.path);
}

/// A container opened on the first of [vaults] (name → its access override
/// builder), with an empty V5 `vaultDbProvider` database so only the daily
/// domain can find today's note.
Future<_Launch> _launch(
  Map<String, LocalVaultAccess Function(String path)> vaults, {
  FakeClock? clock,
}) async {
  final dirs = <String, Directory>{};
  for (final name in vaults.keys) {
    dirs[name] = await Directory.systemTemp.createTemp('om78_contract_$name');
  }
  final byPath = {for (final e in vaults.entries) dirs[e.key]!.path: e.value};
  final emptyDb = FakeVaultDb.v5();
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith(
        (_) => LocalVaultRef(dirs[vaults.keys.first]!.path),
      ),
      vaultDbProvider.overrideWithValue(emptyDb),
      memexCliProvider.overrideWithValue(null),
      clockProvider.overrideWithValue(clock ?? FakeClock()),
      vaultAccessProvider.overrideWith((ref) {
        final path = ref.watch(currentVaultProvider).localPath;
        if (path == null) return null;
        return byPath[path]?.call(path);
      }),
    ],
  );
  addTearDown(() async {
    final store = c.read(tabsProvider.notifier).store;
    c.dispose();
    await store.flush();
    emptyDb.close();
    for (final d in dirs.values) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });
  c.listen(tabsProvider, (_, _) {});
  await pumpEventQueue();
  return _Launch(c, dirs);
}

void main() {
  group('launch resolve of the virtual Today tab (tabsProvider contract)', () {
    test(
      'the launch keeps the virtual Today tab when the date changes before the daily read lands',
      () async {
        // Only the next day has a daily note; the launch date sticks to the
        // tab across midnight, so the read that lands after midnight (for
        // 2026-10-04) must not turn the 2026-10-03 tab into that note.
        final db = FakeVaultDb.v5()..seedDailyNote('2026-10-04', id: _oct4Id);
        addTearDown(db.close);
        final doubles = EditorVaultDoubles(notesDb: db, dailyDb: db)
          ..holdFromStart = true;
        final clock = FakeClock(DateTime(2026, 10, 3, 23, 59));
        final l = await _launch({'a': doubles.build}, clock: clock);
        expect(l.tabs.activeTab, const VirtualTodayTab(_today));
        expect(doubles.daily.gate.waiting, greaterThan(0));

        clock.advance(const Duration(minutes: 2));
        await pumpEventQueue();
        doubles.release();
        await pumpEventQueue();

        expect(
          readScoped(l.c, todayNoteAsyncProvider, null)?.noteId,
          _oct4Id,
          reason: 'the read landed, for the new date',
        );
        expect(l.tabs.tabs, [const VirtualTodayTab(_today)]);
        expect(l.tabs.activeTab, const VirtualTodayTab(_today));
        expect(l.tabs.tabs, isNot(contains(const NoteTab(_oct4Id))));
      },
    );

    test(
      'the launch never resolves the virtual Today tab onto a daily note of the vault it switched away from',
      () async {
        final a = FakeVaultDb.v5()..seedDailyNote(_today, id: _aTodayId);
        final b = FakeVaultDb.v5()..seedDailyNote(_today, id: _bTodayId);
        addTearDown(a.close);
        addTearDown(b.close);
        final da = EditorVaultDoubles(notesDb: a, dailyDb: a)
          ..holdFromStart = true;
        final db = EditorVaultDoubles(notesDb: b, dailyDb: b)
          ..holdFromStart = true;
        final l = await _launch({'a': da.build, 'b': db.build});
        expect(l.tabs.activeTab, const VirtualTodayTab(_today));

        l.open('b');
        await pumpEventQueue();
        da.release();
        await pumpEventQueue();

        expect(l.tabs.tabs, isNot(contains(const NoteTab(_aTodayId))));

        db.release();
        await pumpEventQueue();

        expect(l.tabs.activeTab, const NoteTab(_bTodayId));
        expect(l.tabs.tabs, isNot(contains(const NoteTab(_aTodayId))));
        expect(l.tabs.tabs.whereType<VirtualTodayTab>(), isEmpty);
      },
    );

    test(
      'the launch resolve skips a tabs notifier replaced before the daily read lands',
      () async {
        final db = FakeVaultDb.v5()..seedDailyNote(_today, id: _aTodayId);
        addTearDown(db.close);
        final doubles = EditorVaultDoubles(notesDb: db, dailyDb: db)
          ..holdFromStart = true;
        final l = await _launch({'a': doubles.build});
        final first = l.c.read(tabsProvider.notifier);
        expect(l.tabs.activeTab, const VirtualTodayTab(_today));

        // Same vault, new notifier: the first launch's resolve must not touch
        // the disposed one.
        l.c.invalidate(tabsProvider);
        l.c.read(tabsProvider);
        expect(first.mounted, isFalse);
        doubles.release();
        await pumpEventQueue();

        expect(l.tabs.activeTab, const NoteTab(_aTodayId));
        expect(l.tabs.tabs.whereType<VirtualTodayTab>(), isEmpty);
      },
    );

    test(
      'the launch stays on the virtual Today tab when the daily read fails',
      () async {
        final db = FakeVaultDb.v5()..seedDailyNote(_today, id: _aTodayId);
        addTearDown(db.close);
        late _Wi78FailingDailyNotes daily;
        final l = await _launch({
          'a': (path) => LocalVaultAccess(
            vaultPath: path,
            db: db,
            daily: daily = _Wi78FailingDailyNotes(vaultPath: path, db: db),
          ),
        });
        await pumpEventQueue();

        expect(daily.calls, greaterThan(0));
        expect(l.tabs.tabs, [const VirtualTodayTab(_today)]);
        expect(l.tabs.activeTab, const VirtualTodayTab(_today));
      },
    );
  });

  group('excerptRenderProvider contract', () {
    test('excerptRenderProvider is null with no vault open', () async {
      final c = ProviderContainer(
        overrides: [
          currentVaultProvider.overrideWith((_) => null),
          vaultDbProvider.overrideWithValue(null),
          memexCliProvider.overrideWithValue(null),
        ],
      );
      addTearDown(c.dispose);
      final token = (date: '2026-09-05', from: 'b7k2m9', to: null);
      final sub = c.listen(excerptRenderProvider(token), (_, _) {});
      addTearDown(sub.close);

      final rendered = await c.read(excerptRenderProvider(token).future);

      expect(c.read(vaultAccessProvider), isNull);
      expect(rendered.vault, isNull);
      expect(rendered.value, isNull);
    });
  });
}
