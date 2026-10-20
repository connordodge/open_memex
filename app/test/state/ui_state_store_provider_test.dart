// WI #69 (D12, Req 35): `uiStateStoreProvider` replaces the direct
// `UiStateStore(vaultPath: ...)` constructions in tabs_state.dart and
// sidebar_mode_state.dart. A local vault keeps `<vault>/.memex/ui_state.json`.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/sidebar_mode_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:path/path.dart' as p;

import '../support/fake_clock.dart';
import '../support/fake_vault_db.dart';
import '../support/vault_folders.dart';

ProviderContainer _container(
  VaultRef? vault, {
  List<Override> overrides = const [],
}) {
  final db = FakeVaultDb.v5();
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => vault),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(null),
      clockProvider.overrideWithValue(FakeClock()),
      ...overrides,
    ],
  );
  addTearDown(db.close);
  addTearDown(c.dispose);
  return c;
}

File _uiStateFile(String dir) => File(p.join(dir, '.memex', 'ui_state.json'));

Map<String, dynamic> _readJson(String dir) =>
    jsonDecode(_uiStateFile(dir).readAsStringSync()) as Map<String, dynamic>;

List<Object?> _tabIds(String dir) => [
  for (final t in _readJson(dir)['tabs'] as List) (t as Map)['id'],
];

void main() {
  group('uiStateStoreProvider (AC7)', () {
    test(
      'uiStateStoreProvider gives the vault ui_state.json store for a LocalVaultRef',
      () async {
        final dir = createPlainFolder('om69_ui_');
        final c = _container(LocalVaultRef(dir.path));

        final store = c.read(uiStateStoreProvider);

        expect(store, isNotNull);
        expect(store!.vaultPath, dir.path);
        await store.write(
          UiState(
            tabs: [PersistedTab(kind: PersistedTab.kindNote, id: '01H')],
            activeTabIndex: 0,
            canvasViewports: const {},
          ),
        );
        await store.flush();
        expect(_tabIds(dir.path), ['01H']);
      },
    );

    test('uiStateStoreProvider gives no store for a HostedVaultRef', () {
      final c = _container(HostedVaultRef('srv-1', 'work'));
      expect(c.read(uiStateStoreProvider), isNull);
    });

    test('uiStateStoreProvider gives no store with no vault open', () {
      final c = _container(null);
      expect(c.read(uiStateStoreProvider), isNull);
    });

    test('uiStateStoreProvider follows a vault switch', () {
      final a = createPlainFolder('om69_ui_a_');
      final b = createPlainFolder('om69_ui_b_');
      final c = _container(LocalVaultRef(a.path));
      expect(c.read(uiStateStoreProvider)!.vaultPath, a.path);

      c.read(currentVaultProvider.notifier).state = LocalVaultRef(b.path);

      expect(c.read(uiStateStoreProvider)!.vaultPath, b.path);
    });

    test('tabsProvider persists through uiStateStoreProvider', () async {
      final vault = createPlainFolder('om69_vault_');
      final elsewhere = createPlainFolder('om69_store_');
      final c = _container(
        LocalVaultRef(vault.path),
        overrides: [
          uiStateStoreProvider.overrideWithValue(
            UiStateStore(vaultPath: elsewhere.path),
          ),
        ],
      );

      final tabs = c.read(tabsProvider.notifier);
      tabs.openOrFocus(const NoteTab('01N'));
      await tabs.store.flush();

      expect(_tabIds(elsewhere.path), contains('01N'));
      expect(_uiStateFile(vault.path).existsSync(), isFalse);
    });

    test('sidebarModeProvider persists through uiStateStoreProvider', () async {
      final vault = createPlainFolder('om69_vault_');
      final elsewhere = createPlainFolder('om69_store_');
      _uiStateFile(elsewhere.path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'sidebar_mode': 'topics'}));
      final c = _container(
        LocalVaultRef(vault.path),
        overrides: [
          uiStateStoreProvider.overrideWithValue(
            UiStateStore(vaultPath: elsewhere.path),
          ),
        ],
      );

      // Read from the provided store.
      expect(c.read(sidebarModeProvider), SidebarMode.topics);

      // And written to it.
      await c.read(sidebarModeProvider.notifier).select(SidebarMode.days);
      expect(_readJson(elsewhere.path)['sidebar_mode'], 'days');
      expect(_uiStateFile(vault.path).existsSync(), isFalse);
    });

    test(
      'tabs of two local vaults persist separately across a vault switch',
      () async {
        final a = createPlainFolder('om69_tabs_a_');
        final b = createPlainFolder('om69_tabs_b_');
        final c = _container(LocalVaultRef(a.path));

        final tabsA = c.read(tabsProvider.notifier);
        tabsA.openOrFocus(const NoteTab('01A'));
        await tabsA.store.flush();

        c.read(currentVaultProvider.notifier).state = LocalVaultRef(b.path);
        final tabsB = c.read(tabsProvider.notifier);
        tabsB.openOrFocus(const NoteTab('01B'));
        await tabsB.store.flush();

        expect(_tabIds(a.path), contains('01A'));
        expect(_tabIds(a.path), isNot(contains('01B')));
        expect(_tabIds(b.path), contains('01B'));
        expect(_tabIds(b.path), isNot(contains('01A')));

        // Back on a, its tab is restored.
        c.read(currentVaultProvider.notifier).state = LocalVaultRef(a.path);
        expect(c.read(tabsProvider).tabs, contains(const NoteTab('01A')));
      },
    );
  });
}
