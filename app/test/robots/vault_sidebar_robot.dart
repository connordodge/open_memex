import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/journey_harness.dart';

/// Robot for the sidebar's VAULTS section (WI #363 journeys). Finds widgets
/// by the stable Keys of #363 and #361 only:
/// - the VAULTS header's MANAGE button `sidebar-vaults-manage`;
/// - hosted vault pills `vault-pill-<serverId>-<vault>`;
/// - the vault menu (#361): `vault-menu-finder`, `vault-menu-remove`,
///   `vault-menu-delete`, `vault-menu-manage`;
/// - the delete vault dialog (#360): `delete-vault-confirm`,
///   `delete-vault-cancel`, `delete-vault-open-line`.
/// The picker and its modal are [PickerRobot]'s.
class VaultSidebarRobot {
  VaultSidebarRobot(this.app);

  final JourneyApp app;

  WidgetTester get tester => app.tester;

  // ---------------------------------------------------------------- finders

  Finder key(String k) => find.byKey(Key(k));

  Finder get manage => key('sidebar-vaults-manage');
  Finder hostedPill(String serverId, String vault) =>
      key('vault-pill-$serverId-$vault');
  Finder get menuFinder => key('vault-menu-finder');
  Finder get menuRemove => key('vault-menu-remove');
  Finder get menuDelete => key('vault-menu-delete');
  Finder get menuManage => key('vault-menu-manage');
  Finder get deleteConfirm => key('delete-vault-confirm');
  Finder get deleteCancel => key('delete-vault-cancel');
  Finder get deleteOpenLine => key('delete-vault-open-line');

  // ------------------------------------------------------------------ state

  VaultRef? get currentVault => app.read(currentVaultProvider);

  /// The vault menu items now shown, top to bottom, by Key value.
  List<String> get menuShown {
    final shown = [
      for (final f in [menuFinder, menuRemove, menuDelete, menuManage])
        if (f.evaluate().isNotEmpty) f,
    ];
    shown.sort(
      (a, b) => tester.getRect(a).top.compareTo(tester.getRect(b).top),
    );
    return [
      for (final f in shown)
        ((f.evaluate().single.widget.key! as ValueKey<String>).value),
    ];
  }

  // ---------------------------------------------------------------- actions

  /// Presses MANAGE: the vault picker modal opens over the open vault.
  Future<void> pressManage() => _tapOne(manage);

  /// A secondary (right) mouse click on [pill]: its vault menu opens.
  Future<void> openMenu(Finder pill) async {
    expect(pill, findsOneWidget);
    await tester.ensureVisible(pill);
    await tester.tapAt(
      tester.getCenter(pill),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await app.settle();
  }

  /// The menu's `manage…`: the vault picker modal opens.
  Future<void> chooseManage() => _tapOne(menuManage);

  /// The menu's `delete vault…`: the delete vault dialog opens.
  Future<void> chooseDelete() => _tapOne(menuDelete);

  /// The delete dialog's `move to trash`, then waits out the close, the
  /// trash and the route change.
  Future<void> confirmDelete() async {
    await _tapOne(deleteConfirm);
    for (var i = 0; i < 4; i++) {
      await app.settle();
    }
  }

  Future<void> _tapOne(Finder f) async {
    expect(f, findsOneWidget);
    await tester.ensureVisible(f);
    await tester.tap(f);
    await app.settle();
  }
}
