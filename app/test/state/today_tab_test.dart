// WI #22 (A5): launch order of the Today tab, the virtual Today tab's
// persistence rule (D26), `openToday` and the first-edit helper.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/today_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import '../support/daily_seed.dart';
import '../support/editor_access_doubles.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/today_cli_fakes.dart';

const _todayId = '01J9TTTTTTTTTTTTTTTTTTTTTT';
const _otherId = '01J9BBBBBBBBBBBBBBBBBBBBBB';
const _yesterdayId = '01J9YYYYYYYYYYYYYYYYYYYYYY';
const _existingId = '01J9EEEEEEEEEEEEEEEEEEEEEE';
const _adoptedId = '01J9AAAAAAAAAAAAAAAAAAAAAA';
const _canvasId = '01J9CCCCCCCCCCCCCCCCCCCCCC';

PersistedTab _note(String id) =>
    PersistedTab(kind: PersistedTab.kindNote, id: id);
PersistedTab _canvas(String id) =>
    PersistedTab(kind: PersistedTab.kindCanvas, id: id);

/// A temp vault dir whose `.memex/ui_state.json` holds [tabs], plus a
/// container over it with a [FakeVaultDb] and a [FakeClock] (2026-10-03 09:00
/// by default). The container's tabs store is flushed before the dir is
/// deleted.
class _Launch {
  _Launch(this.dir, this.container);
  final Directory dir;
  final ProviderContainer container;

  TabsNotifier get notifier => container.read(tabsProvider.notifier);
  TabsState get state => container.read(tabsProvider);

  /// Waits for every queued `ui_state.json` write, then reads the file.
  Future<Map<String, dynamic>> persisted() async {
    await notifier.store.flush();
    final f = File('${dir.path}/.memex/ui_state.json');
    return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  }
}

Future<_Launch> _launch({
  required FakeVaultDb db,
  List<PersistedTab> restored = const [],
  int activeTabIndex = 0,
  FakeClock? clock,
}) async {
  final dir = await Directory.systemTemp.createTemp('today_tab_test');
  if (restored.isNotEmpty) {
    final seedStore = UiStateStore(vaultPath: dir.path);
    await seedStore.write(
      UiState(
        tabs: restored,
        activeTabIndex: activeTabIndex,
        canvasViewports: const {},
      ),
    );
    await seedStore.flush();
  }
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(null),
      clockProvider.overrideWithValue(clock ?? FakeClock()),
    ],
  );
  final launch = _Launch(dir, c);
  addTearDown(() async {
    final store = c.read(tabsProvider.notifier).store;
    c.dispose();
    await store.flush();
    db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  // Build the tabs notifier: this is the launch.
  c.read(tabsProvider);
  // The launch syncs selectedNoteIdProvider in a microtask: a provider may
  // not modify another provider while it initializes.
  await Future<void>.delayed(Duration.zero);
  // Today's daily note is read through the async daily domain (#78): let
  // the launch's reads finish.
  await pumpEventQueue();
  return launch;
}

List<Map<String, dynamic>> _tabsOf(Map<String, dynamic> json) =>
    (json['tabs'] as List).cast<Map<String, dynamic>>();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('launch order (AC1, AC10)', () {
    test(
      'launch inserts the real daily note for today as the active tab ahead of the restored tabs',
      () async {
        final db = FakeVaultDb.v5()..seedDailyNote('2026-10-03', id: _todayId);
        final l = await _launch(
          db: db,
          restored: [_canvas(_canvasId), _note(_otherId)],
          activeTabIndex: 1,
        );

        expect(l.state.tabs, [
          const NoteTab(_todayId),
          const CanvasTab(_canvasId),
          const NoteTab(_otherId),
        ]);
        expect(l.state.activeIndex, 0);
        expect(l.state.activeTab, isNot(isA<VirtualTodayTab>()));
        expect(l.container.read(selectedNoteIdProvider), _todayId);
      },
    );

    test(
      'launch focuses the restored tab of the daily note for today instead of opening a second one',
      () async {
        final db = FakeVaultDb.v5()
          ..seedDailyNote('2026-10-03', id: _todayId)
          ..seedNote(id: _otherId, title: 'Other');
        final l = await _launch(
          db: db,
          restored: [_note(_otherId), _note(_todayId), _canvas(_canvasId)],
          activeTabIndex: 0,
        );

        expect(l.state.tabs, [
          const NoteTab(_otherId),
          const NoteTab(_todayId),
          const CanvasTab(_canvasId),
        ]);
        expect(l.state.activeIndex, 1);
        expect(l.state.tabs.whereType<VirtualTodayTab>(), isEmpty);
        expect(l.container.read(selectedNoteIdProvider), _todayId);
      },
    );

    test(
      'launch with no daily note for today inserts a virtual Today tab for 2026-10-03 as the active tab ahead of the restored tabs',
      () async {
        final db = FakeVaultDb.v5()
          ..seedDailyNote('2026-10-02', id: _yesterdayId);
        final l = await _launch(
          db: db,
          restored: [_note(_yesterdayId), _canvas(_canvasId)],
          activeTabIndex: 1,
        );

        expect(l.state.tabs, hasLength(3));
        final first = l.state.tabs.first;
        expect(first, isA<VirtualTodayTab>());
        expect((first as VirtualTodayTab).date, '2026-10-03');
        expect(l.state.tabs.sublist(1), [
          const NoteTab(_yesterdayId),
          const CanvasTab(_canvasId),
        ]);
        expect(l.state.activeIndex, 0);
      },
    );

    test(
      'launch uses the clock date: at 00:30 on 2026-10-04 the note for 2026-10-03 is not today',
      () async {
        final db = FakeVaultDb.v5()..seedDailyNote('2026-10-03', id: _todayId);
        final l = await _launch(
          db: db,
          clock: FakeClock(DateTime(2026, 10, 4, 0, 30)),
        );

        final active = l.state.activeTab;
        expect(active, isA<VirtualTodayTab>());
        expect((active! as VirtualTodayTab).date, '2026-10-04');
        expect(l.state.tabs, hasLength(1));
      },
    );
  });

  // #271 (N8) TEST-CHANGE: openToday is `follow` of today's target. A plain
  // call navigates the active tab and no longer focuses or inserts a tab (the
  // launch still does); the Cmd variants are in `today_follow_test.dart`.
  group('openToday (AC10)', () {
    test(
      'openToday shows the virtual Today note in the active tab and leaves the launch Today tab alone',
      () async {
        final db = FakeVaultDb.v5()..seedNote(id: _otherId, title: 'Other');
        final l = await _launch(db: db, restored: [_note(_otherId)]);
        l.notifier.setActive(1);
        expect(l.state.activeTab, const NoteTab(_otherId));

        l.notifier.openToday(date: '2026-10-03');

        expect(l.state.tabs, [
          const VirtualTodayTab('2026-10-03'),
          const VirtualTodayTab('2026-10-03'),
        ]);
        expect(l.state.activeIndex, 1);
        expect(l.state.canGoBack, isTrue);
      },
    );

    test(
      'openToday with the id of an open daily note shows it in the active tab',
      () async {
        final db = FakeVaultDb.v5()
          ..seedDailyNote('2026-10-03', id: _todayId)
          ..seedNote(id: _otherId, title: 'Other');
        final l = await _launch(db: db, restored: [_note(_otherId)]);
        l.notifier.setActive(1);

        l.notifier.openToday(date: '2026-10-03', noteId: _todayId);

        expect(l.state.tabs, [
          const NoteTab(_todayId),
          const NoteTab(_todayId),
        ]);
        expect(l.state.activeIndex, 1);
        expect(l.state.canGoBack, isTrue);
      },
    );
  });

  group('openToday (AC2)', () {
    test(
      'openToday after the virtual Today tab was closed navigates the active tab to a virtual Today note for the date',
      () async {
        final db = FakeVaultDb.v5()..seedNote(id: _otherId, title: 'Other');
        final l = await _launch(db: db, restored: [_note(_otherId)]);
        l.notifier.close(l.state.tabs.first);
        expect(l.state.tabs, [const NoteTab(_otherId)]);

        l.notifier.openToday(date: '2026-10-03');

        expect(l.state.tabs, [const VirtualTodayTab('2026-10-03')]);
        expect(l.state.canGoBack, isTrue);
        l.notifier.back();
        expect(l.state.activeTab, const NoteTab(_otherId));
      },
    );
  });

  group('ui_state.json (AC11)', () {
    test(
      'ui_state.json written after launch never contains the virtual Today tab',
      () async {
        final db = FakeVaultDb.v5()..seedNote(id: _otherId, title: 'Other');
        final l = await _launch(db: db, restored: [_canvas(_canvasId)]);
        expect(l.state.activeTab, isA<VirtualTodayTab>());

        l.notifier.openOrFocus(const NoteTab(_otherId));
        var json = await l.persisted();
        expect(_tabsOf(json), [
          {'kind': 'canvas', 'id': _canvasId},
          {'kind': 'note', 'id': _otherId},
        ]);
        expect(json['active_tab_index'], 1);

        // Back on the virtual tab: still never written.
        l.notifier.setActive(0);
        json = await l.persisted();
        expect(_tabsOf(json), [
          {'kind': 'canvas', 'id': _canvasId},
          {'kind': 'note', 'id': _otherId},
        ]);
        expect(jsonEncode(json), isNot(contains('virtual')));
        expect(jsonEncode(json), isNot(contains('2026-10-03')));
      },
    );

    test(
      'ui_state.json written after launch contains the real daily-note tab',
      () async {
        final db = FakeVaultDb.v5()
          ..seedDailyNote('2026-10-03', id: _todayId)
          ..seedNote(id: _otherId, title: 'Other');
        final l = await _launch(db: db, restored: [_canvas(_canvasId)]);

        l.notifier.openOrFocus(const NoteTab(_otherId));
        final json = await l.persisted();

        expect(_tabsOf(json), [
          {'kind': 'note', 'id': _todayId},
          {'kind': 'canvas', 'id': _canvasId},
          {'kind': 'note', 'id': _otherId},
        ]);
        expect(json['active_tab_index'], 2);
      },
    );
  });

  group('createDailyNote (AC3, AC4, AC5)', () {
    test(
      'createDailyNote creates the daily note through the notes domain addNote with role daily and the date as title',
      () async {
        final db = FakeVaultDb.v5();
        addTearDown(db.close);
        final cli = FakeMemexCli()..onAddDailyCreates(db);
        final notes = EditorNotesAccess(vaultPath: '/vaults/v', cli: cli);

        final result = await createDailyNote(
          notes,
          date: '2026-10-03',
          contentMd: 'hi',
        );

        expect(notes.writes, ['addNote:2026-10-03:daily']);
        expect(result.noteId, createdDailyId);
        expect(result.existed, isFalse);
      },
    );

    test(
      'createDailyNote through the notes domain returns existing_id with existed true on daily_note_exists',
      () async {
        final cli = FakeMemexCli()
          ..onAddReturns(
            FakeMemexCli.error(
              'daily_note_exists',
              'a daily note for 2026-10-03 already exists: $_existingId',
              {'date': '2026-10-03', 'existing_id': _existingId},
            ),
          );
        final notes = EditorNotesAccess(vaultPath: '/vaults/v', cli: cli);

        final result = await createDailyNote(notes, date: '2026-10-03');

        expect(notes.writes, ['addNote:2026-10-03:daily']);
        expect(result.noteId, _existingId);
        expect(result.existed, isTrue);
      },
    );

    test(
      'createDailyNote runs add with role daily, the date as title and the text on stdin, and returns the created id',
      () async {
        final db = FakeVaultDb.v5();
        addTearDown(db.close);
        final cli = FakeMemexCli()..onAddDailyCreates(db);

        final result = await createDailyNote(
          LocalNotesAccess(vaultPath: '/vaults/v', cli: cli),
          date: '2026-10-03',
          contentMd: 'hi',
        );

        expect(result.noteId, createdDailyId);
        expect(result.existed, isFalse);
        final call = cli.callsFor('add').single;
        expect(call.flag('vault'), '/vaults/v');
        expect(call.flag('role'), 'daily');
        expect(call.flag('title'), '2026-10-03');
        expect(call.stdinBody, 'hi');
      },
    );

    test(
      'createDailyNote returns the adopted note id for an Adopted note answer',
      () async {
        final cli = FakeMemexCli()
          ..onAddReturns(
            FakeMemexCli.ok(
              addDailyStdout(_adoptedId, '2026-10-03', adopted: true),
            ),
          );

        final result = await createDailyNote(
          LocalNotesAccess(vaultPath: '/vaults/v', cli: cli),
          date: '2026-10-03',
          contentMd: 'hi',
        );

        expect(result.noteId, _adoptedId);
        expect(result.existed, isFalse);
        expect(cli.callsFor('add'), hasLength(1));
      },
    );

    test(
      'createDailyNote returns existing_id with existed true on daily_note_exists',
      () async {
        final cli = FakeMemexCli()
          ..onAddReturns(
            FakeMemexCli.error(
              'daily_note_exists',
              'a daily note for 2026-10-03 already exists: $_existingId',
              {'date': '2026-10-03', 'existing_id': _existingId},
            ),
          );

        final result = await createDailyNote(
          LocalNotesAccess(vaultPath: '/vaults/v', cli: cli),
          date: '2026-10-03',
          contentMd: 'hi',
        );

        expect(result.noteId, _existingId);
        expect(result.existed, isTrue);
        expect(cli.callsFor('add'), hasLength(1));
      },
    );

    test(
      'createDailyNote rethrows any other add failure with the CLI message',
      () async {
        final cli = FakeMemexCli()
          ..onAddReturns(FakeMemexCli.error('internal', 'database is locked'));

        await expectLater(
          createDailyNote(
            LocalNotesAccess(vaultPath: '/vaults/v', cli: cli),
            date: '2026-10-03',
            contentMd: 'hi',
          ),
          throwsA(
            isA<MemexException>()
                .having((e) => e.code, 'code', 'internal')
                .having(
                  (e) => e.message,
                  'message',
                  contains('database is locked'),
                ),
          ),
        );
      },
    );

    test(
      'createDailyNote rethrows title_conflict instead of treating it as an existing daily note',
      () async {
        final cli = FakeMemexCli()
          ..onAddReturns(
            FakeMemexCli.error('title_conflict', 'title taken', {
              'existing_id': _existingId,
            }),
          );

        await expectLater(
          createDailyNote(
            LocalNotesAccess(vaultPath: '/vaults/v', cli: cli),
            date: '2026-10-03',
            contentMd: 'hi',
          ),
          throwsA(
            isA<MemexException>().having(
              (e) => e.code,
              'code',
              'title_conflict',
            ),
          ),
        );
      },
    );
  });
}
