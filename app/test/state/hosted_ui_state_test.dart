// WI #96 (H2, D19, Req 35): a hosted vault's tabs and sidebar mode persist
// under `<app support>/hosted/<serverId>/<vaultName>` (the app-support dir
// from the overridable `appSupportDirProvider`, a temp dir here) and restore
// on reopen. State is keyed by server id and vault name: two vaults with the
// same name on different servers, and two vaults sharing a `vault_id`, keep
// separate state. Nothing is written inside any vault folder; local vaults
// keep `<vault>/.memex/ui_state.json`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/app_support_dir.dart';
import 'package:open_memex_app/src/state/sidebar_mode_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:path/path.dart' as p;

import '../support/fake_memex_cli.dart';
import '../support/hosted_harness.dart';
import '../support/vault_folders.dart';

const _wi96TabA = '01M5DQAYZ3WP7H0NXZZV9M2315';
const _wi96TabB = '01M5DQAYZ4RYSGA8T0YEEF8QRS';
const _wi96SharedVaultId = '01M5DK9Z8CWPQGFA893JX9VRZF';

/// The note ids of the open tabs.
List<String> _tabIds(HostedHarness h) => [
  for (final t in h.read(tabsProvider).tabs)
    if (t is NoteTab) t.id,
];

/// Opens [ref] through the controller and checks it opened.
Future<void> _open(HostedHarness h, VaultRef ref) async {
  await h.controller.openVault(ref);
  expect(h.read(currentVaultProvider), ref);
}

/// Waits for every queued UI-state write of the open vault.
Future<void> _flush(HostedHarness h) async {
  await h.read(uiStateStoreProvider)?.flush();
}

void main() {
  group('hosted ui state (AC8, Req 35)', () {
    test(
      'tabs and sidebar mode of a hosted vault persist under app support hosted server id and vault name and restore on reopen',
      () async {
        final studio = HostedServerFixture(
          id: 'srv-studio',
          name: 'studio',
          url: 'http://studio.local:9000',
          token: 'studio-token-96',
          vaultName: 'work',
        );
        final h = await hostedContainer(
          servers: [HostedServerFixture(), studio],
        );
        expect(h.read(appSupportDirProvider), h.appSupport.path);
        await _open(h, seedHostedRef);
        expect(h.read(uiStateStoreProvider), isNotNull);

        h.read(tabsProvider.notifier)
          ..openOrFocus(const NoteTab(_wi96TabA))
          ..openOrFocus(const NoteTab(_wi96TabB));
        await h.read(sidebarModeProvider.notifier).select(SidebarMode.topics);
        await _flush(h);

        final files = h.appSupportFiles();
        expect(files, isNotEmpty);
        for (final f in files) {
          expect(p.split(f).take(3).toList(), [
            'hosted',
            'srv-nas',
            'seed',
          ], reason: f);
        }
        final stored = [
          for (final f in files)
            File(p.join(h.appSupport.path, f)).readAsStringSync(),
        ].join('\n');
        expect(stored, contains(_wi96TabA));
        expect(stored, contains(_wi96TabB));
        expect(stored, contains('topics'));

        // Leave for another hosted vault, then come back.
        await _open(h, studio.ref('work'));
        expect(_tabIds(h), isNot(contains(_wi96TabA)));
        expect(h.read(sidebarModeProvider), SidebarMode.days);

        await _open(h, seedHostedRef);
        expect(_tabIds(h), containsAllInOrder([_wi96TabA, _wi96TabB]));
        expect(h.read(sidebarModeProvider), SidebarMode.topics);
      },
    );

    test(
      'two vaults with the same name on different servers keep separate ui state',
      () async {
        final other = HostedServerFixture(
          id: 'srv-other',
          name: 'other',
          url: 'http://other.local:7878',
          token: 'other-token-96',
        );
        final h = await hostedContainer(
          servers: [HostedServerFixture(), other],
        );

        await _open(h, seedHostedRef);
        h.read(tabsProvider.notifier).openOrFocus(const NoteTab(_wi96TabA));
        await _flush(h);

        await _open(h, other.ref('seed'));
        expect(_tabIds(h), isNot(contains(_wi96TabA)));
        h.read(tabsProvider.notifier).openOrFocus(const NoteTab(_wi96TabB));
        await h.read(sidebarModeProvider.notifier).select(SidebarMode.topics);
        await _flush(h);

        await _open(h, seedHostedRef);
        expect(_tabIds(h), contains(_wi96TabA));
        expect(_tabIds(h), isNot(contains(_wi96TabB)));
        expect(h.read(sidebarModeProvider), SidebarMode.days);

        await _open(h, other.ref('seed'));
        expect(_tabIds(h), contains(_wi96TabB));
        expect(_tabIds(h), isNot(contains(_wi96TabA)));
        expect(h.read(sidebarModeProvider), SidebarMode.topics);

        final dirs = {for (final f in h.appSupportFiles()) p.split(f)[1]};
        expect(dirs, {'srv-nas', 'srv-other'});
      },
    );

    test('two vaults sharing a vault id keep separate ui state', () async {
      final server = HostedServerFixture()
        ..serveFixturesAs('copy')
        ..serveVault('copy', vaultId: _wi96SharedVaultId)
        ..serveVault('seed', vaultId: _wi96SharedVaultId);
      final h = await hostedContainer(servers: [server]);

      await _open(h, seedHostedRef);
      h.read(tabsProvider.notifier).openOrFocus(const NoteTab(_wi96TabA));
      await _flush(h);

      await _open(h, server.ref('copy'));
      expect(_tabIds(h), isNot(contains(_wi96TabA)));
      h.read(tabsProvider.notifier).openOrFocus(const NoteTab(_wi96TabB));
      await _flush(h);

      await _open(h, seedHostedRef);
      expect(_tabIds(h), contains(_wi96TabA));
      expect(_tabIds(h), isNot(contains(_wi96TabB)));

      await _open(h, server.ref('copy'));
      expect(_tabIds(h), contains(_wi96TabB));
      expect(_tabIds(h), isNot(contains(_wi96TabA)));

      final vaults = {for (final f in h.appSupportFiles()) p.split(f)[2]};
      expect(vaults, {'seed', 'copy'});
    });

    test(
      'a hosted session writes nothing inside any vault folder and a local vault keeps its own ui state file',
      () async {
        final local = createVaultFolder('om96_ui_local_');
        final cli = FakeMemexCli()..on('vault check', (_) => FakeMemexCli.ok());
        final h = await hostedContainer(
          cli: cli,
          recents: [LocalVaultRef(local.path)],
        );

        await _open(h, LocalVaultRef(local.path));
        expect(h.read(uiStateStoreProvider)!.vaultPath, local.path);
        h.read(tabsProvider.notifier).openOrFocus(const NoteTab(_wi96TabA));
        await _flush(h);
        final localFile = File(p.join(local.path, '.memex', 'ui_state.json'));
        expect(localFile.existsSync(), isTrue);
        final localBefore = localFile.readAsStringSync();
        final localEntries = {
          for (final e in local.listSync(recursive: true)) e.path,
        };
        expect(h.appSupportFiles(), isEmpty, reason: 'local stays local');

        await _open(h, seedHostedRef);
        h.read(tabsProvider.notifier).openOrFocus(const NoteTab(_wi96TabB));
        await h.read(sidebarModeProvider.notifier).select(SidebarMode.topics);
        await _flush(h);

        expect(localFile.readAsStringSync(), localBefore);
        expect({
          for (final e in local.listSync(recursive: true)) e.path,
        }, localEntries);
        final files = h.appSupportFiles();
        expect(files, isNotEmpty);
        for (final f in files) {
          expect(f, startsWith(p.join('hosted', 'srv-nas', 'seed')));
        }

        await _open(h, LocalVaultRef(local.path));
        expect(_tabIds(h), contains(_wi96TabA));
        expect(_tabIds(h), isNot(contains(_wi96TabB)));
      },
    );
  });
}
