// WI #361 (Spec #357 Req 19-22): `VaultMenuRegion` contracts the first test
// round left open (verify round).
// - An item is drawn on `surface4` while hovered or focused, else clear.
// - The vault items are fixed when the menu opens, and the first item takes
//   the focus.
// - The divider is the pack's 9-high `line2` rule.
// Seams: wi361_rows (a bare region over mock prefs), real temp vault folders.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/vault_menu.dart';

import '../support/fake_vault_server.dart';
import '../support/font_fetch_hold.dart';
import '../support/vault_folders.dart';
import '../support/vault_picker_harness.dart';
import '../support/wi349_keyboard.dart';
import '../support/wi361_rows.dart';

Finder _key(String k) => find.byKey(Key(k));

/// The background colour the item [key] is painted on (its button's Material).
Color? _wi361Background(WidgetTester tester, String key) {
  final materials = find.descendant(
    of: _key(key),
    matching: find.byType(Material),
  );
  for (final m in tester.widgetList<Material>(materials)) {
    if (m.type == MaterialType.button) return m.color;
  }
  return Colors.transparent;
}

void main() {
  holdFontFetches();

  group('item background', () {
    testWidgets(
      'a vault menu item is on surface4 while hovered or focused and clear otherwise',
      (tester) async {
        final vault = createVaultFolder('om361_bg_');
        await wi361PumpMenu(
          tester,
          vault: LocalVaultRef(vault.path),
          isOpen: false,
        );
        // Park the mouse far from the menu so nothing is hovered at open.
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(1200, 780));
        await tester.pump();

        await wi361SecondaryClick(
          tester,
          wi361Anchor,
          at: tester.getTopLeft(wi361Anchor) + const Offset(20, 10),
        );
        await mouse.moveTo(const Offset(1200, 780));
        await tester.pump();
        // A key press puts the focus ring on (a pointer hides it).
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump(const Duration(milliseconds: 300));

        // The first item took the focus when the menu opened.
        expect(wi349FocusIn(_key('vault-menu-finder')), isTrue);
        expect(
          _wi361Background(tester, 'vault-menu-finder'),
          OmColors.surface4,
          reason: 'focused only',
        );
        expect(
          _wi361Background(tester, 'vault-menu-remove'),
          isNot(OmColors.surface4),
          reason: 'neither hovered nor focused',
        );
        expect(
          _wi361Background(tester, 'vault-menu-delete'),
          isNot(OmColors.surface4),
        );

        // Hover the last item (a hover also moves the focus onto it).
        await mouse.moveTo(tester.getCenter(_key('vault-menu-delete')));
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          _wi361Background(tester, 'vault-menu-delete'),
          OmColors.surface4,
          reason: 'hovered',
        );
        expect(
          _wi361Background(tester, 'vault-menu-finder'),
          isNot(OmColors.surface4),
          reason: 'the focus left it',
        );
        expect(
          _wi361Background(tester, 'vault-menu-remove'),
          isNot(OmColors.surface4),
        );
      },
    );
  });

  group('open-time items', () {
    testWidgets(
      'the vault items stay as they were when the menu opened until it opens again',
      (tester) async {
        final vault = createVaultFolder('om361_snap_');
        await wi361PumpMenu(
          tester,
          vault: LocalVaultRef(vault.path),
          isOpen: false,
        );
        await wi361SecondaryClick(tester, wi361Anchor);
        expect(wi361MenuShown(tester), [
          'vault-menu-finder',
          'vault-menu-remove',
          'vault-menu-delete',
        ]);

        // The folder stops being a vault while the menu is open, and the
        // region rebuilds: the open menu does not reflow.
        wi361Unvault(vault.path);
        tester.element(find.byType(VaultMenuRegion)).markNeedsBuild();
        await tester.pump();
        expect(wi361MenuShown(tester), [
          'vault-menu-finder',
          'vault-menu-remove',
          'vault-menu-delete',
        ]);

        // Opened again, it takes the new state: no delete vault.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await wi97Settle(tester);
        expect(wi361MenuShown(tester), isEmpty);
        await wi361SecondaryClick(tester, wi361Anchor);
        expect(wi361MenuShown(tester), [
          'vault-menu-finder',
          'vault-menu-remove',
        ]);
      },
    );

    testWidgets('the first item takes the focus when a menu opens', (
      tester,
    ) async {
      await wi361PumpMenu(
        tester,
        vault: const HostedVaultRef(fakeServerId, 'team'),
        isOpen: true,
        onManage: () {},
      );
      await wi361SecondaryClick(tester, wi361Anchor);
      expect(
        wi349FocusIn(_key('vault-menu-manage')),
        isTrue,
        reason: 'manage is the first item when it is the only one',
      );

      final vault = createVaultFolder('om361_first_');
      await wi361PumpMenu(
        tester,
        vault: LocalVaultRef(vault.path),
        isOpen: false,
        onManage: () {},
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await wi361SecondaryClick(tester, wi361Anchor);
      expect(wi349FocusIn(_key('vault-menu-finder')), isTrue);
      expect(wi349FocusIn(_key('vault-menu-manage')), isFalse);
    });
  });

  group('divider', () {
    testWidgets('the divider before manage is the pack rule 9 high in line2', (
      tester,
    ) async {
      final vault = createVaultFolder('om361_rule_');
      await wi361PumpMenu(
        tester,
        vault: LocalVaultRef(vault.path),
        isOpen: false,
        onManage: () {},
      );
      await wi361SecondaryClick(tester, wi361Anchor);

      final divider = tester.widget<Divider>(find.byType(Divider));
      expect(divider.height, 9);
      expect(divider.thickness, 1);
      expect(divider.color, OmColors.line2);
    });
  });
}
