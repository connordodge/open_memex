// WI #78 (W2) AC3: with `todayNoteProvider` async, opening a vault still
// lands on today's stored daily note (architect risk), and on the virtual
// Today tab when there is none. The daily reads come from a Completer-gated
// daily domain over its own database; `vaultDbProvider` is an empty V5
// database, so a launch that still read SQLite directly would never find
// today's note.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/editor_access_doubles.dart';
import '../support/fake_clock.dart';
import '../support/fake_vault_db.dart';

const _todayId = '01J9TTTTTTTTTTTTTTTTTTTT78';
const _otherId = '01J9BBBBBBBBBBBBBBBBBBBB78';
const _canvasId = '01J9CCCCCCCCCCCCCCCCCCCC78';

class _Launch {
  _Launch(this.dir, this.container, this.doubles);
  final Directory dir;
  final ProviderContainer container;
  final EditorVaultDoubles doubles;

  TabsState get state => container.read(tabsProvider);
}

Future<_Launch> _launch({
  required FakeVaultDb accessDb,
  List<PersistedTab> restored = const [],
  int activeTabIndex = 0,
  bool hold = false,
}) async {
  final dir = await Directory.systemTemp.createTemp('om78_launch');
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
  final emptyDb = FakeVaultDb.v5();
  final doubles = EditorVaultDoubles(notesDb: accessDb, dailyDb: accessDb)
    ..holdFromStart = hold;
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
      vaultDbProvider.overrideWithValue(emptyDb),
      memexCliProvider.overrideWithValue(null),
      clockProvider.overrideWithValue(FakeClock()),
      editorSingleVaultOverride(doubles),
    ],
  );
  addTearDown(() async {
    final store = c.read(tabsProvider.notifier).store;
    c.dispose();
    await store.flush();
    emptyDb.close();
    accessDb.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  c.listen(tabsProvider, (_, _) {});
  await pumpEventQueue();
  return _Launch(dir, c, doubles);
}

void main() {
  group('launch with an async todayNoteProvider (AC3)', () {
    test(
      'opening a vault lands on the stored daily note for today once the daily read completes',
      () async {
        final db = FakeVaultDb.v5()
          ..seedDailyNote('2026-10-03', id: _todayId)
          ..seedNote(id: _otherId, title: 'Other');
        final l = await _launch(
          accessDb: db,
          restored: [
            PersistedTab(kind: PersistedTab.kindCanvas, id: _canvasId),
            PersistedTab(kind: PersistedTab.kindNote, id: _otherId),
          ],
          activeTabIndex: 1,
          hold: true,
        );

        l.doubles.release();
        await pumpEventQueue();

        expect(l.state.tabs, [
          const NoteTab(_todayId),
          const CanvasTab(_canvasId),
          const NoteTab(_otherId),
        ]);
        expect(l.state.activeTab, const NoteTab(_todayId));
        expect(l.state.tabs.whereType<VirtualTodayTab>(), isEmpty);
        expect(l.container.read(selectedNoteIdProvider), _todayId);

        await l.container.read(tabsProvider.notifier).store.flush();
        final json = jsonDecode(
          File('${l.dir.path}/.memex/ui_state.json').readAsStringSync(),
        );
        expect(jsonEncode(json), isNot(contains('virtual')));
      },
    );

    test(
      'opening a vault focuses the restored tab of the stored daily note for today',
      () async {
        final db = FakeVaultDb.v5()
          ..seedDailyNote('2026-10-03', id: _todayId)
          ..seedNote(id: _otherId, title: 'Other');
        final l = await _launch(
          accessDb: db,
          restored: [
            PersistedTab(kind: PersistedTab.kindNote, id: _otherId),
            PersistedTab(kind: PersistedTab.kindNote, id: _todayId),
          ],
        );

        expect(l.state.tabs, [
          const NoteTab(_otherId),
          const NoteTab(_todayId),
        ]);
        expect(l.state.activeTab, const NoteTab(_todayId));
        expect(l.container.read(selectedNoteIdProvider), _todayId);
      },
    );

    test(
      'opening a vault with no stored daily note for today lands on the virtual Today tab',
      () async {
        final db = FakeVaultDb.v5()
          ..seedDailyNote('2026-10-02', id: 'yesterday');
        final l = await _launch(accessDb: db, hold: true);

        l.doubles.release();
        await pumpEventQueue();

        final active = l.state.activeTab;
        expect(active, isA<VirtualTodayTab>());
        expect((active! as VirtualTodayTab).date, '2026-10-03');
        expect(l.state.tabs, hasLength(1));
      },
    );
  });

  group('launch journey with slow daily reads (AC3)', () {
    testWidgets(
      'the workspace opens on the stored daily note for today after slow daily reads complete',
      (tester) async {
        final accessDb = FakeVaultDb.v5()
          ..seedDailyNote('2026-10-03', id: _todayId);
        accessDb.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
          'Stored today text\n',
          _todayId,
        ]);
        addTearDown(accessDb.close);
        final doubles = EditorVaultDoubles(notesDb: accessDb, dailyDb: accessDb)
          ..holdFromStart = true;
        final h = await pumpWorkspace(
          tester,
          clock: FakeClock(DateTime(2026, 10, 3, 9)),
          overrides: [editorSingleVaultOverride(doubles)],
        );

        doubles.release();
        await pumpFrames(tester);

        expect(h.read(tabsProvider).activeTab, const NoteTab(_todayId));
        expect(h.read(tabsProvider).tabs.whereType<VirtualTodayTab>(), isEmpty);
        expect(
          find.descendant(
            of: find.byType(NoteEditor),
            matching: find.textContaining('Stored today text'),
          ),
          findsWidgets,
        );
        expect(find.byKey(const Key('tab-note-$_todayId')), findsOneWidget);
      },
    );
  });
}
