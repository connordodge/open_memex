// WI #22 (A5), beyond the ACs: how the virtual Today tab turns into the real
// daily-note tab (`resolveVirtualToday`), the persisted active index once the
// virtual tab is dropped (D26), the tab cap at launch, and the tab id scheme.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/fake_clock.dart';
import '../support/fake_vault_db.dart';

const _noteId = '01J9NNNNNNNNNNNNNNNNNNNNNN';
const _otherId = '01J9BBBBBBBBBBBBBBBBBBBBBB';
const _canvasId = '01J9CCCCCCCCCCCCCCCCCCCCCC';

PersistedTab _note(String id) =>
    PersistedTab(kind: PersistedTab.kindNote, id: id);
PersistedTab _canvas(String id) =>
    PersistedTab(kind: PersistedTab.kindCanvas, id: id);

/// Launches the tabs over a temp vault whose `ui_state.json` holds
/// [restored], at FakeClock 2026-10-03 09:00 with no daily notes (so the
/// launch inserts the virtual Today tab for 2026-10-03).
Future<ProviderContainer> _launch({
  List<PersistedTab> restored = const [],
}) async {
  final dir = await Directory.systemTemp.createTemp('virtual_today_tabs');
  final db = FakeVaultDb.v5();
  if (restored.isNotEmpty) {
    final seed = UiStateStore(vaultPath: dir.path);
    await seed.write(
      UiState(tabs: restored, activeTabIndex: 0, canvasViewports: const {}),
    );
    await seed.flush();
  }
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(null),
      clockProvider.overrideWithValue(FakeClock()),
    ],
  );
  addTearDown(() async {
    final store = c.read(tabsProvider.notifier).store;
    c.dispose();
    await store.flush();
    db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  c.read(tabsProvider);
  await Future<void>.delayed(Duration.zero);
  return c;
}

Future<Map<String, dynamic>> _persisted(ProviderContainer c) async {
  final store = c.read(tabsProvider.notifier).store;
  await store.flush();
  final f = File('${store.vaultPath}/.memex/ui_state.json');
  return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  group('resolveVirtualToday', () {
    test(
      'resolveVirtualToday puts the note tab in place of the active virtual tab and selects the note',
      () async {
        final c = await _launch(restored: [_canvas(_canvasId)]);
        final tabs = c.read(tabsProvider.notifier);

        tabs.resolveVirtualToday(date: '2026-10-03', noteId: _noteId);

        final state = c.read(tabsProvider);
        expect(state.tabs, [
          const NoteTab(_noteId),
          const CanvasTab(_canvasId),
        ]);
        expect(state.tabs.first, isNot(isA<VirtualTodayTab>()));
        expect(state.activeIndex, 0);
        expect(c.read(selectedNoteIdProvider), _noteId);
      },
    );

    test(
      'resolveVirtualToday keeps another active tab active and persists the note tab',
      () async {
        final c = await _launch(restored: [_canvas(_canvasId)]);
        final tabs = c.read(tabsProvider.notifier)..setActive(1);

        tabs.resolveVirtualToday(date: '2026-10-03', noteId: _noteId);

        final state = c.read(tabsProvider);
        expect(state.tabs, [
          const NoteTab(_noteId),
          const CanvasTab(_canvasId),
        ]);
        expect(state.activeIndex, 1);
        final json = await _persisted(c);
        expect(json['tabs'], [
          {'kind': 'note', 'id': _noteId},
          {'kind': 'canvas', 'id': _canvasId},
        ]);
        expect(json['active_tab_index'], 1);
      },
    );

    test(
      'resolveVirtualToday with the note already open closes the virtual tab and focuses the open note tab',
      () async {
        final c = await _launch(restored: [_canvas(_canvasId), _note(_noteId)]);

        c
            .read(tabsProvider.notifier)
            .resolveVirtualToday(date: '2026-10-03', noteId: _noteId);

        final state = c.read(tabsProvider);
        expect(state.tabs, [
          const CanvasTab(_canvasId),
          const NoteTab(_noteId),
        ]);
        expect(state.activeIndex, 1);
        expect(c.read(selectedNoteIdProvider), _noteId);
      },
    );

    test(
      'resolveVirtualToday after the virtual tab was closed leaves the tabs alone',
      () async {
        final c = await _launch(restored: [_canvas(_canvasId)]);
        final tabs = c.read(tabsProvider.notifier);
        tabs.close(c.read(tabsProvider).tabs.first);

        tabs.resolveVirtualToday(date: '2026-10-03', noteId: _noteId);

        expect(c.read(tabsProvider).tabs, [const CanvasTab(_canvasId)]);
      },
    );
  });

  group('persisted active index without the virtual tab (D26)', () {
    test(
      'a middle tab that is active keeps its index among the remaining tabs',
      () async {
        final c = await _launch(
          restored: [_canvas(_canvasId), _note(_otherId)],
        );

        c.read(tabsProvider.notifier).setActive(1);

        final json = await _persisted(c);
        expect(json['tabs'], [
          {'kind': 'canvas', 'id': _canvasId},
          {'kind': 'note', 'id': _otherId},
        ]);
        expect(json['active_tab_index'], 0);
      },
    );

    test(
      'an active virtual tab after the last real tab persists the last real tab as active',
      () async {
        final c = await _launch();
        // #271 (N8) TEST-CHANGE: openToday navigates now, so the real tab
        // is opened and the virtual one appended through openOrFocus.
        final tabs = c.read(tabsProvider.notifier)
          ..openOrFocus(const NoteTab(_noteId))
          ..closeAt(0)
          ..openOrFocus(const VirtualTodayTab('2026-10-03'));
        expect(c.read(tabsProvider).tabs, [
          const NoteTab(_noteId),
          const VirtualTodayTab('2026-10-03'),
        ]);

        tabs.setActive(1);

        final json = await _persisted(c);
        expect(json['tabs'], [
          {'kind': 'note', 'id': _noteId},
        ]);
        expect(json['active_tab_index'], 0);
      },
    );

    test('only the virtual tab open persists no tabs and index 0', () async {
      final c = await _launch(restored: [_canvas(_canvasId)]);
      final tabs = c.read(tabsProvider.notifier);
      tabs.close(const CanvasTab(_canvasId));

      final json = await _persisted(c);
      expect(json['tabs'], isEmpty);
      expect(json['active_tab_index'], 0);
    });
  });

  test(
    'launch with a full set of restored tabs evicts one to insert the Today tab first',
    () async {
      final restored = [
        for (var i = 0; i < kMaxOpenTabs; i++) _note('note-$i'),
      ];
      final c = await _launch(restored: restored);

      final state = c.read(tabsProvider);
      expect(state.tabs, hasLength(kMaxOpenTabs));
      expect(state.tabs.first, const VirtualTodayTab('2026-10-03'));
      expect(state.activeIndex, 0);
      expect(state.tabs.contains(const NoteTab('note-1')), isTrue);
    },
  );

  test(
    'without a launch date an out of range persisted active index lands on the last restored tab',
    () async {
      final dir = await Directory.systemTemp.createTemp('virtual_today_tabs');
      final store = UiStateStore(vaultPath: dir.path);
      addTearDown(() async {
        await store.flush();
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      await store.write(
        UiState(
          tabs: [_note(_noteId), _canvas(_canvasId)],
          activeTabIndex: 5,
          canvasViewports: const {},
        ),
      );
      await store.flush();

      final selection = <String?>[];
      final notifier = TabsNotifier(
        store: store,
        onPersistedSelection: selection.add,
      );
      addTearDown(notifier.dispose);

      expect(notifier.state.tabs, [
        const NoteTab(_noteId),
        const CanvasTab(_canvasId),
      ]);
      expect(notifier.state.activeIndex, 1);
      await Future<void>.delayed(Duration.zero);
      expect(selection, [null]);
    },
  );

  test('VirtualTodayTab.dateOf reads the date back from a virtual tab id', () {
    expect(
      VirtualTodayTab.dateOf(const VirtualTodayTab('2026-10-03').id),
      '2026-10-03',
    );
    expect(VirtualTodayTab.dateOf(_noteId), isNull);
    expect(VirtualTodayTab.dateOf(null), isNull);
  });
}
