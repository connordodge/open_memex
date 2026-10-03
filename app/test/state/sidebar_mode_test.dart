// WI #23 (A6): the Days/Topics mode persisted per vault (Req 50, TD8) as
// `sidebar_mode` in `<vault>/.memex/ui_state.json`.
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

/// A temp vault dir, removed after the test (after every container that
/// writes into it was disposed and flushed).
Directory _vault(String name) {
  final dir = Directory.systemTemp.createTempSync('sidebar_mode_$name');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

ProviderContainer _container(String vaultPath) {
  final db = FakeVaultDb.v5();
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => vaultPath),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(null),
      clockProvider.overrideWithValue(FakeClock()),
    ],
  );
  // Registered after the vault's teardown, so it runs before the delete.
  addTearDown(db.close);
  addTearDown(c.dispose);
  return c;
}

File _uiStateFile(String vaultPath) =>
    File(p.join(vaultPath, '.memex', 'ui_state.json'));

Map<String, dynamic> _readJson(String vaultPath) =>
    jsonDecode(_uiStateFile(vaultPath).readAsStringSync())
        as Map<String, dynamic>;

void _writeJson(String vaultPath, Map<String, dynamic> json) {
  final f = _uiStateFile(vaultPath);
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(jsonEncode(json));
}

void main() {
  group('UiState sidebar_mode (AC1, AC2)', () {
    test('a missing sidebar_mode reads as days', () {
      // Control: the key is read at all (topics is not the default).
      expect(
        UiState.fromJson({'sidebar_mode': 'topics'}).sidebarMode,
        SidebarMode.topics,
      );
      expect(UiState.fromJson({}).sidebarMode, SidebarMode.days);
      expect(
        UiState.fromJson({
          'tabs': [
            {'kind': 'note', 'id': '01H'},
          ],
          'active_tab_index': 0,
        }).sidebarMode,
        SidebarMode.days,
      );
      expect(UiState.empty().sidebarMode, SidebarMode.days);
    });

    test('an unknown or malformed sidebar_mode reads as days', () {
      // Control: the key is read at all (topics is not the default).
      expect(
        UiState.fromJson({'sidebar_mode': 'topics'}).sidebarMode,
        SidebarMode.topics,
      );
      expect(
        UiState.fromJson({'sidebar_mode': 'graph'}).sidebarMode,
        SidebarMode.days,
      );
      expect(
        UiState.fromJson({'sidebar_mode': 'Topics'}).sidebarMode,
        SidebarMode.days,
      );
      expect(
        UiState.fromJson({'sidebar_mode': 42}).sidebarMode,
        SidebarMode.days,
      );
      expect(
        UiState.fromJson({'sidebar_mode': null}).sidebarMode,
        SidebarMode.days,
      );
    });

    test('sidebar_mode topics and days read back as their modes', () {
      expect(
        UiState.fromJson({'sidebar_mode': 'topics'}).sidebarMode,
        SidebarMode.topics,
      );
      expect(
        UiState.fromJson({
          'sidebar_mode': 'days',
          'tabs': [
            {'kind': 'note', 'id': '01H'},
          ],
        }).sidebarMode,
        SidebarMode.days,
      );
    });

    test('toJson writes sidebar_mode as topics or days', () {
      final topics = UiState(
        tabs: const [],
        activeTabIndex: 0,
        canvasViewports: const {},
        sidebarMode: SidebarMode.topics,
      );
      final days = UiState(
        tabs: const [],
        activeTabIndex: 0,
        canvasViewports: const {},
      );
      expect(topics.toJson()['sidebar_mode'], 'topics');
      expect(days.toJson()['sidebar_mode'], 'days');
    });

    test(
      'the store round-trips sidebar_mode topics with the tabs through ui_state.json',
      () async {
        final dir = _vault('store');
        final store = UiStateStore(vaultPath: dir.path);
        await store.write(
          UiState(
            tabs: [PersistedTab(kind: PersistedTab.kindNote, id: '01H')],
            activeTabIndex: 0,
            canvasViewports: const {},
            sidebarMode: SidebarMode.topics,
          ),
        );
        await store.flush();

        expect(_readJson(dir.path)['sidebar_mode'], 'topics');
        final back = store.read();
        expect(back.sidebarMode, SidebarMode.topics);
        expect(back.tabs.single.id, '01H');
      },
    );
  });

  group('sidebarModeProvider (AC1, AC2)', () {
    test('a vault with no stored mode opens in Days', () {
      final dir = _vault('fresh');
      final c = _container(dir.path);
      expect(c.read(sidebarModeProvider), SidebarMode.days);
    });

    test(
      'a vault whose ui_state.json holds tabs but no mode opens in Days',
      () {
        final dir = _vault('legacy');
        _writeJson(dir.path, {
          'tabs': [
            {'kind': 'note', 'id': '01H'},
          ],
          'active_tab_index': 0,
          'canvas_viewports': {},
        });
        final c = _container(dir.path);
        expect(c.read(sidebarModeProvider), SidebarMode.days);
      },
    );

    test(
      'choosing Topics writes sidebar_mode topics to the vault ui_state.json',
      () async {
        final dir = _vault('choose');
        final c = _container(dir.path);

        await c.read(sidebarModeProvider.notifier).select(SidebarMode.topics);

        expect(c.read(sidebarModeProvider), SidebarMode.topics);
        expect(_readJson(dir.path)['sidebar_mode'], 'topics');
      },
    );

    test('reopening the vault after choosing Topics restores Topics', () async {
      final dir = _vault('reopen');
      final first = _container(dir.path);
      await first.read(sidebarModeProvider.notifier).select(SidebarMode.topics);
      first.dispose();

      final second = _container(dir.path);
      expect(second.read(sidebarModeProvider), SidebarMode.topics);
    });

    test(
      'a second vault still opens in Days after the first chose Topics',
      () async {
        final a = _vault('a');
        final b = _vault('b');
        final c = _container(a.path);
        await c.read(sidebarModeProvider.notifier).select(SidebarMode.topics);

        // Switch the open vault to b in the same app session.
        c.read(currentVaultProvider.notifier).state = b.path;
        expect(c.read(sidebarModeProvider), SidebarMode.days);
        expect(_uiStateFile(b.path).existsSync(), isFalse);

        // And a fresh launch on b.
        final other = _container(b.path);
        expect(other.read(sidebarModeProvider), SidebarMode.days);

        // Back on a, its Topics choice is still there.
        c.read(currentVaultProvider.notifier).state = a.path;
        expect(c.read(sidebarModeProvider), SidebarMode.topics);
      },
    );

    test('choosing Days after Topics writes sidebar_mode days', () async {
      final dir = _vault('back');
      final c = _container(dir.path);
      final n = c.read(sidebarModeProvider.notifier);
      await n.select(SidebarMode.topics);
      await n.select(SidebarMode.days);

      expect(c.read(sidebarModeProvider), SidebarMode.days);
      expect(_readJson(dir.path)['sidebar_mode'], 'days');

      final again = _container(dir.path);
      expect(again.read(sidebarModeProvider), SidebarMode.days);
    });

    test(
      'choosing Topics keeps the tabs and canvas viewports already in ui_state.json',
      () async {
        final dir = _vault('keep');
        _writeJson(dir.path, {
          'tabs': [
            {'kind': 'note', 'id': '01H'},
            {'kind': 'canvas', 'id': '01C'},
          ],
          'active_tab_index': 1,
          'canvas_viewports': {
            '01C': {'dx': 10.0, 'dy': -20.0, 'zoom': 1.5},
          },
        });
        final c = _container(dir.path);

        await c.read(sidebarModeProvider.notifier).select(SidebarMode.topics);

        final back = UiStateStore(vaultPath: dir.path).read();
        expect(back.sidebarMode, SidebarMode.topics);
        expect([for (final t in back.tabs) t.id], ['01H', '01C']);
        expect(back.activeTabIndex, 1);
        expect(back.canvasViewports['01C']!.zoom, 1.5);
      },
    );

    test(
      'a later tab change keeps sidebar_mode topics in ui_state.json',
      () async {
        final dir = _vault('tabs');
        final c = _container(dir.path);
        await c.read(sidebarModeProvider.notifier).select(SidebarMode.topics);

        final tabs = c.read(tabsProvider.notifier);
        tabs.openOrFocus(const NoteTab('01N'));
        await tabs.store.flush();

        final json = _readJson(dir.path);
        expect(json['sidebar_mode'], 'topics');
        expect([
          for (final t in json['tabs'] as List) (t as Map)['id'],
        ], contains('01N'));

        final reopened = _container(dir.path);
        expect(reopened.read(sidebarModeProvider), SidebarMode.topics);
      },
    );
  });
}
