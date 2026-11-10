// WI #361 (Spec #357 Req 19–22, 25, TD5): `VaultMenuRegion`, the one vault
// menu the picker rows (and #363's pills) use, and `showVaultInFinder`, the
// seam its "show in Finder" item and the row button share.
// - Items per variant: local `show in Finder`, `remove from recents` (not
//   when open), `delete vault…`; hosted `remove from recents` (not when
//   open); with `onManage` a divider then `manage…`; with no items no menu.
// - The look from pack 361 (S2): labels, icons, danger delete, 198x32 items.
// Seams: wi361_rows (a bare region over mock prefs, FakeFileRevealer), real
// temp vault folders. Never a real Finder.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/vault_menu.dart';
import 'package:path/path.dart' as p;

import '../support/fake_vault_server.dart';
import '../support/font_fetch_hold.dart';
import '../support/vault_folders.dart';
import '../support/vault_picker_harness.dart';
import '../support/wi349_keyboard.dart';
import '../support/wi361_rows.dart';

Finder _key(String k) => find.byKey(Key(k));

const _wi361Team = HostedVaultRef(fakeServerId, 'team');

/// The colour [text] is drawn in (its merged style, wherever it was set).
Color? _wi361DrawnTextColour(WidgetTester tester, Finder text) =>
    tester.renderObject<RenderParagraph>(text).text.style?.color;

/// The colour the single [icon] inside [of] is drawn in.
Color? _wi361DrawnIconColour(WidgetTester tester, Finder of, IconData icon) {
  final glyph = find.descendant(
    of: find.descendant(of: of, matching: find.byIcon(icon)),
    matching: find.byType(RichText),
  );
  return tester.renderObject<RenderParagraph>(glyph).text.style?.color;
}

/// The menu variants: (test name, local?, isOpen, onManage?, items shown,
/// divider shown).
const _wi361Variants = <(String, bool, bool, bool, List<String>, bool)>[
  (
    'a local vault menu with onManage ends with a divider and manage',
    true,
    false,
    true,
    [
      'vault-menu-finder',
      'vault-menu-remove',
      'vault-menu-delete',
      'vault-menu-manage',
    ],
    true,
  ),
  (
    'a hosted vault menu with onManage is remove from recents then a divider and manage',
    false,
    false,
    true,
    ['vault-menu-remove', 'vault-menu-manage'],
    true,
  ),
  (
    'an open local vault menu with onManage is show in Finder delete vault a divider and manage',
    true,
    true,
    true,
    ['vault-menu-finder', 'vault-menu-delete', 'vault-menu-manage'],
    true,
  ),
  (
    'an open hosted vault menu with onManage has manage as its only item and no divider',
    false,
    true,
    true,
    ['vault-menu-manage'],
    false,
  ),
  (
    'a local vault menu without onManage has no divider and no manage',
    true,
    false,
    false,
    ['vault-menu-finder', 'vault-menu-remove', 'vault-menu-delete'],
    false,
  ),
  (
    'an open local vault menu without onManage is show in Finder then delete vault',
    true,
    true,
    false,
    ['vault-menu-finder', 'vault-menu-delete'],
    false,
  ),
  (
    'a hosted vault menu without onManage is remove from recents only',
    false,
    false,
    false,
    ['vault-menu-remove'],
    false,
  ),
];

void main() {
  holdFontFetches();

  group('items per variant', () {
    for (final (name, local, isOpen, manage, items, divider)
        in _wi361Variants) {
      testWidgets(name, (tester) async {
        final VaultRef vault = local
            ? LocalVaultRef(createVaultFolder('om361_menu_').path)
            : _wi361Team;
        await wi361PumpMenu(
          tester,
          vault: vault,
          isOpen: isOpen,
          onManage: manage ? () {} : null,
        );

        await wi361SecondaryClick(tester, wi361Anchor);

        expect(wi361MenuShown(tester), items);
        final dividers = find.byType(Divider);
        if (divider) {
          expect(dividers, findsOneWidget);
          // Between the last vault item and manage.
          final line = tester.getRect(dividers);
          final before = tester.getRect(_key(items[items.length - 2]));
          final after = tester.getRect(_key('vault-menu-manage'));
          expect(line.top, greaterThanOrEqualTo(before.bottom - 0.5));
          expect(line.bottom, lessThanOrEqualTo(after.top + 0.5));
        } else {
          expect(dividers, findsNothing);
        }
        expect(find.text('manage…'), manage ? findsOneWidget : findsNothing);
      });
    }

    testWidgets(
      'an open hosted vault menu without onManage opens no menu on a secondary click',
      (tester) async {
        await wi361PumpMenu(tester, vault: _wi361Team, isOpen: true);
        await wi361SecondaryClick(tester, wi361Anchor);

        expect(wi361MenuShown(tester), isEmpty);
        expect(find.byType(MenuItemButton), findsNothing);
        expect(find.byType(Divider), findsNothing);

        // The same region with onManage does open, so the empty case is real.
        await wi361PumpMenu(
          tester,
          vault: _wi361Team,
          isOpen: true,
          onManage: () {},
        );
        await wi361SecondaryClick(tester, wi361Anchor);
        expect(wi361MenuShown(tester), ['vault-menu-manage']);
      },
    );
  });

  group('manage', () {
    testWidgets('choosing manage calls onManage once and closes the menu', (
      tester,
    ) async {
      var manages = 0;
      final vault = createVaultFolder('om361_manage_');
      await wi361PumpMenu(
        tester,
        vault: LocalVaultRef(vault.path),
        isOpen: false,
        onManage: () => manages++,
      );

      await wi361SecondaryClick(tester, wi361Anchor);
      await tester.tap(_key('vault-menu-manage'));
      await wi97Settle(tester);

      expect(manages, 1);
      expect(wi361MenuShown(tester), isEmpty, reason: 'the menu closes');
    });

    testWidgets('a held Enter on the manage item calls onManage once', (
      tester,
    ) async {
      var manages = 0;
      await wi361PumpMenu(
        tester,
        vault: _wi361Team,
        isOpen: false,
        onManage: () => manages++,
      );

      await wi361SecondaryClick(tester, wi361Anchor);
      await wi361ArrowTo(tester, _key('vault-menu-manage'));
      await wi349HoldKey(tester, LogicalKeyboardKey.enter);
      await wi97Settle(tester);

      expect(manages, 1);
      expect(wi361MenuShown(tester), isEmpty);
    });
  });

  group('look (pack 361, board S2)', () {
    testWidgets(
      'the vault menu items have the pack labels icons and colours with delete in danger',
      (tester) async {
        final vault = createVaultFolder('om361_look_');
        await wi361PumpMenu(
          tester,
          vault: LocalVaultRef(vault.path),
          isOpen: false,
          onManage: () {},
        );
        await wi361SecondaryClick(tester, wi361Anchor);

        final finder = _key('vault-menu-finder');
        final remove = _key('vault-menu-remove');
        final delete = _key('vault-menu-delete');
        expect(
          find.descendant(of: finder, matching: find.text('show in Finder')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: remove,
            matching: find.text('remove from recents'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: delete, matching: find.text('delete vault…')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: _key('vault-menu-manage'),
            matching: find.text('manage…'),
          ),
          findsOneWidget,
        );

        expect(
          _wi361DrawnIconColour(tester, finder, LucideIcons.folderSearch),
          OmColors.fg2,
        );
        expect(
          _wi361DrawnIconColour(tester, remove, LucideIcons.x),
          OmColors.fg2,
        );
        expect(
          _wi361DrawnIconColour(tester, delete, LucideIcons.trash2),
          OmColors.danger,
        );
        expect(
          _wi361DrawnTextColour(tester, find.text('show in Finder')),
          OmColors.fg0,
        );
        expect(
          _wi361DrawnTextColour(tester, find.text('remove from recents')),
          OmColors.fg0,
        );
        expect(
          _wi361DrawnTextColour(tester, find.text('delete vault…')),
          OmColors.danger,
        );

        for (final item in [finder, remove, delete]) {
          final size = tester.getSize(item);
          expect(size.height, 32, reason: '$item height');
          expect(size.width, moreOrLessEquals(198, epsilon: 1));
        }
      },
    );

    testWidgets('the vault menu opens at the pointer', (tester) async {
      final vault = createVaultFolder('om361_pointer_');
      await wi361PumpMenu(
        tester,
        vault: LocalVaultRef(vault.path),
        isOpen: false,
      );

      final at = tester.getTopLeft(wi361Anchor) + const Offset(210, 30);
      await wi361SecondaryClick(tester, wi361Anchor, at: at);

      final first = tester.getRect(_key('vault-menu-finder'));
      expect(first.left, moreOrLessEquals(at.dx, epsilon: 6));
      expect(first.top, moreOrLessEquals(at.dy, epsilon: 8));
      expect(first.top, greaterThanOrEqualTo(at.dy));
    });

    testWidgets('Escape closes the vault menu and does nothing else', (
      tester,
    ) async {
      var manages = 0;
      final vault = createVaultFolder('om361_escape_');
      final env = await wi361PumpMenu(
        tester,
        vault: LocalVaultRef(vault.path),
        isOpen: false,
        onManage: () => manages++,
      );

      await wi361SecondaryClick(tester, wi361Anchor);
      expect(wi361MenuShown(tester), isNotEmpty);
      await wi361ArrowTo(tester, _key('vault-menu-finder'));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await wi97Settle(tester);

      expect(wi361MenuShown(tester), isEmpty);
      expect(manages, 0);
      expect(env.revealer.paths, isEmpty);
      expect(env.settings.recentRefs, [LocalVaultRef(vault.path)]);
    });
  });

  group('showVaultInFinder', () {
    Widget showButton(String path) => Consumer(
      builder: (context, ref, _) => TextButton(
        key: const Key('wi361-show'),
        onPressed: () => showVaultInFinder(context, ref, path),
        child: const Text('show'),
      ),
    );

    testWidgets('showVaultInFinder on a vault folder reveals it once', (
      tester,
    ) async {
      final vault = createVaultFolder('om361_seam_');
      final env = await wi361PumpBody(tester, showButton(vault.path));

      await tester.tap(_key('wi361-show'));
      await wi97Settle(tester);

      expect(env.revealer.paths, [vault.path]);
      expect(find.byType(SnackBar), findsNothing);
    });

    for (final (name, notAVault) in <(String, String Function())>[
      (
        'showVaultInFinder on a plain folder reveals nothing and shows the SnackBar',
        () => createPlainFolder('om361_plain_').path,
      ),
      (
        'showVaultInFinder on a missing path reveals nothing and shows the SnackBar',
        () => p.join(createPlainFolder('om361_gone_').path, 'gone'),
      ),
    ]) {
      testWidgets(name, (tester) async {
        final path = notAVault();
        final env = await wi361PumpBody(tester, showButton(path));

        await tester.tap(_key('wi361-show'));
        await wi97Settle(tester);

        expect(env.revealer.paths, isEmpty);
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text('$path is no longer a vault folder.'),
          ),
          findsOneWidget,
        );
      });
    }
  });
}
