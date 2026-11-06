// WI #251 (A4): the third sidebar segment, `Days | Topics | Tags`, and the
// `tags` value of `sidebar_mode` in `<vault>/.memex/ui_state.json`. #23's
// Days/Topics persistence tests stay in test/state/sidebar_mode_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/sidebar_mode_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:path/path.dart' as p;

import '../support/fake_clock.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/tags_pane_harness.dart';

Directory _vault(String name) {
  final dir = Directory.systemTemp.createTempSync('sidebar_mode_tags_$name');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

ProviderContainer _container(String vaultPath) {
  final db = FakeVaultDb.v5();
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(vaultPath)),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(null),
      clockProvider.overrideWithValue(FakeClock()),
    ],
  );
  addTearDown(db.close);
  addTearDown(c.dispose);
  return c;
}

File _uiStateFile(String vaultPath) =>
    File(p.join(vaultPath, '.memex', 'ui_state.json'));

Map<String, dynamic> _readJson(String vaultPath) =>
    jsonDecode(_uiStateFile(vaultPath).readAsStringSync())
        as Map<String, dynamic>;

/// Waits for the queued `ui_state.json` writes of the vault (real IO).
Future<void> _flush(WidgetTester tester, TagsEnv env) async {
  await tester.runAsync(() => UiStateStore(vaultPath: env.vault.path).flush());
}

bool _selected(WidgetTester tester, String key) =>
    hasFill(tester, find.byKey(Key(key)), OmColors.surface4);

void main() {
  holdFontFetches();

  group('sidebar_mode tags in ui_state.json', () {
    test(
      'a stored sidebar_mode tags reads as the tags mode and is written back as tags',
      () async {
        expect(
          UiState.fromJson({'sidebar_mode': 'tags'}).sidebarMode,
          SidebarMode.tags,
        );
        // The other two values still read as themselves.
        expect(
          UiState.fromJson({'sidebar_mode': 'topics'}).sidebarMode,
          SidebarMode.topics,
        );
        expect(
          UiState.fromJson({'sidebar_mode': 'days'}).sidebarMode,
          SidebarMode.days,
        );

        final dir = _vault('store');
        final store = UiStateStore(vaultPath: dir.path);
        await store.write(
          UiState(
            tabs: [PersistedTab(kind: PersistedTab.kindNote, id: '01H')],
            activeTabIndex: 0,
            canvasViewports: const {},
            sidebarMode: SidebarMode.tags,
          ),
        );
        await store.flush();

        expect(_readJson(dir.path)['sidebar_mode'], 'tags');
        final back = store.read();
        expect(back.sidebarMode, SidebarMode.tags);
        expect(back.tabs.single.id, '01H');
      },
    );

    test('an unknown stored sidebar_mode still reads as days', () {
      // Control: tags is read at all, so days below is the fallback.
      expect(
        UiState.fromJson({'sidebar_mode': 'tags'}).sidebarMode,
        SidebarMode.tags,
      );
      for (final unknown in <Object?>['Tags', 'tag', 'graph', '', 42, null]) {
        expect(
          UiState.fromJson({'sidebar_mode': unknown}).sidebarMode,
          SidebarMode.days,
          reason: 'sidebar_mode: $unknown',
        );
      }
      expect(UiState.fromJson({}).sidebarMode, SidebarMode.days);
    });

    test('an unknown stored sidebar_mode opens the vault in days', () {
      // Control: the stored value is read at all.
      final known = _vault('known');
      _uiStateFile(known.path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'sidebar_mode': 'tags'}));
      expect(
        _container(known.path).read(sidebarModeProvider),
        SidebarMode.tags,
      );

      final dir = _vault('unknown');
      _uiStateFile(dir.path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'sidebar_mode': 'bookmarks'}));
      final c = _container(dir.path);
      expect(c.read(sidebarModeProvider), SidebarMode.days);
    });

    test(
      'choosing Tags writes sidebar_mode tags and reopening the vault restores Tags',
      () async {
        final dir = _vault('reopen');
        final first = _container(dir.path);
        await first.read(sidebarModeProvider.notifier).select(SidebarMode.tags);

        expect(first.read(sidebarModeProvider), SidebarMode.tags);
        expect(_readJson(dir.path)['sidebar_mode'], 'tags');
        first.dispose();

        final second = _container(dir.path);
        expect(second.read(sidebarModeProvider), SidebarMode.tags);
      },
    );

    test(
      'a second vault still opens in days after the first chose Tags',
      () async {
        final a = _vault('a');
        final b = _vault('b');
        final c = _container(a.path);
        await c.read(sidebarModeProvider.notifier).select(SidebarMode.tags);

        c.read(currentVaultProvider.notifier).state = LocalVaultRef(b.path);
        expect(c.read(sidebarModeProvider), SidebarMode.days);

        c.read(currentVaultProvider.notifier).state = LocalVaultRef(a.path);
        expect(c.read(sidebarModeProvider), SidebarMode.tags);
      },
    );

    test(
      'choosing Tags keeps the tabs and canvas viewports already stored',
      () async {
        final dir = _vault('keep');
        _uiStateFile(dir.path)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
            jsonEncode({
              'tabs': [
                {'kind': 'note', 'id': '01H'},
                {'kind': 'canvas', 'id': '01C'},
              ],
              'active_tab_index': 1,
              'canvas_viewports': {
                '01C': {'dx': 10.0, 'dy': -20.0, 'zoom': 1.5},
              },
            }),
          );
        final c = _container(dir.path);

        await c.read(sidebarModeProvider.notifier).select(SidebarMode.tags);

        final back = UiStateStore(vaultPath: dir.path).read();
        expect(back.sidebarMode, SidebarMode.tags);
        expect([for (final t in back.tabs) t.id], ['01H', '01C']);
        expect(back.activeTabIndex, 1);
        expect(back.canvasViewports['01C']!.zoom, 1.5);
      },
    );

    test('choosing Days after Tags writes sidebar_mode days', () async {
      final dir = _vault('back');
      final c = _container(dir.path);
      final n = c.read(sidebarModeProvider.notifier);
      await n.select(SidebarMode.tags);
      expect(_container(dir.path).read(sidebarModeProvider), SidebarMode.tags);
      await n.select(SidebarMode.days);

      expect(c.read(sidebarModeProvider), SidebarMode.days);
      expect(_readJson(dir.path)['sidebar_mode'], 'days');
      expect(_container(dir.path).read(sidebarModeProvider), SidebarMode.days);
    });
  });

  group('the mode switch', () {
    testWidgets(
      'the switch shows Days Topics and Tags in three equal segments',
      (tester) async {
        await pumpTagsSidebar(tester, tags: TagsDouble());

        expect(find.byKey(const Key('sidebar-mode-days')), findsOneWidget);
        expect(find.byKey(const Key('sidebar-mode-topics')), findsOneWidget);
        expect(find.byKey(const Key('sidebar-mode-tags')), findsOneWidget);
        for (final (key, label) in [
          ('sidebar-mode-days', 'Days'),
          ('sidebar-mode-topics', 'Topics'),
          ('sidebar-mode-tags', 'Tags'),
        ]) {
          expect(
            find.descendant(
              of: find.byKey(Key(key)),
              matching: find.text(label),
            ),
            findsOneWidget,
            reason: key,
          );
        }
        final days = tester.getRect(find.byKey(const Key('sidebar-mode-days')));
        final topics = tester.getRect(
          find.byKey(const Key('sidebar-mode-topics')),
        );
        final tags = tester.getRect(find.byKey(const Key('sidebar-mode-tags')));
        expect(days.width, closeTo(topics.width, 0.5));
        expect(tags.width, closeTo(topics.width, 0.5));
        expect(tags.width, greaterThan(70));
        // Left to right, side by side.
        expect(topics.left, closeTo(days.right, 0.5));
        expect(tags.left, closeTo(topics.right, 0.5));
        expect(tags.top, days.top);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'tapping the Tags segment shows the Tags pane and marks only Tags selected',
      (tester) async {
        final env = await pumpTagsSidebar(tester, tags: TagsDouble());
        expect(find.byKey(const Key('days-pane')), findsOneWidget);
        expect(find.byKey(const Key('tags-pane')), findsNothing);
        expect(_selected(tester, 'sidebar-mode-days'), isTrue);
        expect(_selected(tester, 'sidebar-mode-tags'), isFalse);

        expect(find.byKey(const Key('sidebar-mode-tags')), findsOneWidget);
        await tester.tap(find.byKey(const Key('sidebar-mode-tags')));
        await env.settle(tester);

        expect(find.byKey(const Key('tags-pane')), findsOneWidget);
        expect(find.byKey(const Key('days-pane')), findsNothing);
        expect(find.byKey(const Key('topics-pane')), findsNothing);
        expect(_selected(tester, 'sidebar-mode-tags'), isTrue);
        expect(_selected(tester, 'sidebar-mode-days'), isFalse);
        expect(_selected(tester, 'sidebar-mode-topics'), isFalse);
        expect(env.container.read(sidebarModeProvider), SidebarMode.tags);
        await _flush(tester, env);
      },
    );

    testWidgets('leaving Tags for Topics or Days swaps the pane back', (
      tester,
    ) async {
      final env = await pumpTagsSidebar(
        tester,
        tags: TagsDouble(),
        storedMode: 'tags',
      );
      expect(find.byKey(const Key('tags-pane')), findsOneWidget);

      await tester.tap(find.byKey(const Key('sidebar-mode-topics')));
      await env.settle(tester);
      expect(find.byKey(const Key('topics-pane')), findsOneWidget);
      expect(find.byKey(const Key('tags-pane')), findsNothing);
      expect(_selected(tester, 'sidebar-mode-tags'), isFalse);

      expect(find.byKey(const Key('sidebar-mode-tags')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sidebar-mode-tags')));
      await env.settle(tester);
      expect(find.byKey(const Key('tags-pane')), findsOneWidget);

      await tester.tap(find.byKey(const Key('sidebar-mode-days')));
      await env.settle(tester);
      expect(find.byKey(const Key('days-pane')), findsOneWidget);
      expect(find.byKey(const Key('tags-pane')), findsNothing);
      await _flush(tester, env);
    });

    testWidgets('a vault reopened after choosing Tags opens in the Tags pane', (
      tester,
    ) async {
      final first = await pumpTagsSidebar(tester, tags: TagsDouble());
      expect(find.byKey(const Key('sidebar-mode-tags')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sidebar-mode-tags')));
      await first.settle(tester);
      await _flush(tester, first);
      expect(first.uiStateFile.existsSync(), isTrue);
      expect(
        (jsonDecode(first.uiStateFile.readAsStringSync())
            as Map<String, dynamic>)['sidebar_mode'],
        'tags',
      );

      // Reopen: a new app over the same vault directory.
      await tester.pumpWidget(const SizedBox());
      final second = await pumpTagsSidebar(
        tester,
        tags: TagsDouble(),
        vault: first.vault,
      );

      expect(find.byKey(const Key('tags-pane')), findsOneWidget);
      expect(find.byKey(const Key('days-pane')), findsNothing);
      expect(_selected(tester, 'sidebar-mode-tags'), isTrue);
      expect(second.container.read(sidebarModeProvider), SidebarMode.tags);
    });

    testWidgets('an unknown stored sidebar_mode opens the sidebar in Days', (
      tester,
    ) async {
      // Control: a stored tags opens the Tags pane, so Days below is the
      // fallback.
      final vault = tagsTempVault();
      await pumpTagsSidebar(
        tester,
        tags: TagsDouble(),
        storedMode: 'tags',
        vault: vault,
      );
      expect(find.byKey(const Key('tags-pane')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await pumpTagsSidebar(
        tester,
        tags: TagsDouble(),
        storedMode: 'bookmarks',
        vault: vault,
      );

      expect(find.byKey(const Key('days-pane')), findsOneWidget);
      expect(find.byKey(const Key('tags-pane')), findsNothing);
      expect(_selected(tester, 'sidebar-mode-days'), isTrue);
      expect(_selected(tester, 'sidebar-mode-tags'), isFalse);
    });
  });
}
