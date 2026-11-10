// WI #361 (Spec #357 Req 8, 21, 23; pack 361 "OPEN variant"):
// `RecentRow(open: true)`, which #362's modal passes for the open vault.
// The row shows the `OPEN` tag (`recent-row-open-tag-<i>`, accent on
// successBg), has no × and no `remove from recents` menu item; a local
// open row keeps show in Finder and delete, a hosted open row has no
// buttons and no menu. A tap still calls `onOpen`.
// Seams: wi361_rows (bare rows over mock prefs, FakeFileRevealer), real
// temp vault folders.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/picker/server_row.dart';
import 'package:open_memex_app/src/widgets/vault_color.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_vault_server.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/vault_folders.dart';
import '../../support/vault_picker_harness.dart';
import '../../support/wi361_rows.dart';

Finder _key(String k) => find.byKey(Key(k));

Finder _row(int i) => _key('recent-row-$i');

const _wi361Team = HostedVaultRef(fakeServerId, 'team');

/// The PickerRowShell of row [i] (the key may sit on it or on a wrapper).
PickerRowShell _wi361Shell(WidgetTester tester, int i) =>
    tester.widget<PickerRowShell>(
      find.descendant(
        of: _row(i),
        matching: find.byType(PickerRowShell),
        matchRoot: true,
      ),
    );

void main() {
  holdFontFetches();

  testWidgets(
    'an open local row shows the OPEN tag keeps show in Finder and delete and has no x',
    (tester) async {
      final open = createVaultFolder('om361_open_');
      final other = createVaultFolder('om361_other_');
      final env = await wi361PumpRows(
        tester,
        entries: [LocalVaultRef(open.path), LocalVaultRef(other.path)],
        openIndex: 0,
      );

      final tag = _key('recent-row-open-tag-0');
      expect(tag, findsOneWidget);
      expect(wi97Inside('recent-row-0', tag), findsOneWidget);
      expect(find.descendant(of: tag, matching: find.text('OPEN')), findsOne);

      expect(_key('recent-row-finder-0'), findsOneWidget);
      expect(_key('recent-row-delete-0'), findsOneWidget);
      expect(_key('recent-row-remove-0'), findsNothing);
      expect(
        tester.getRect(_key('recent-row-finder-0')).right,
        lessThanOrEqualTo(tester.getRect(_key('recent-row-delete-0')).left),
      );

      // The row that is not open is unchanged: no tag, all three buttons.
      expect(_key('recent-row-open-tag-1'), findsNothing);
      expect(_key('recent-row-finder-1'), findsOneWidget);
      expect(_key('recent-row-delete-1'), findsOneWidget);
      expect(_key('recent-row-remove-1'), findsOneWidget);

      // The caller still supplies onOpen and a tap still calls it.
      await tester.tap(
        wi97Inside('recent-row-0', find.text(p.basename(open.path))),
      );
      await wi97Settle(tester);
      expect(env.opened, [LocalVaultRef(open.path)]);
    },
  );

  testWidgets(
    'an open local row menu is show in Finder then delete vault without remove from recents',
    (tester) async {
      final open = createVaultFolder('om361_openmenu_');
      final env = await wi361PumpRows(
        tester,
        entries: [LocalVaultRef(open.path)],
        openIndex: 0,
      );
      expect(_key('recent-row-open-tag-0'), findsOneWidget);

      await wi361SecondaryClick(tester, _row(0));

      expect(wi361MenuShown(tester), [
        'vault-menu-finder',
        'vault-menu-delete',
      ]);
      expect(find.text('remove from recents'), findsNothing);
      expect(find.text('manage…'), findsNothing);

      await tester.tap(_key('vault-menu-finder'));
      await wi97Settle(tester);
      expect(env.revealer.paths, [open.path]);
    },
  );

  testWidgets(
    'an open hosted row shows the OPEN tag and has no buttons and no menu',
    (tester) async {
      final env = await wi361PumpRows(
        tester,
        entries: const [_wi361Team],
        openIndex: 0,
      );

      expect(_key('recent-row-open-tag-0'), findsOneWidget);
      expect(
        find.descendant(
          of: _key('recent-row-open-tag-0'),
          matching: find.text('OPEN'),
        ),
        findsOneWidget,
      );
      expect(wi97Inside('recent-row-0', find.text('team')), findsOneWidget);
      expect(
        wi97Inside('recent-row-0', find.byType(PickerRowIconButton)),
        findsNothing,
      );
      expect(wi97Inside('recent-row-0', find.byType(OmButton)), findsNothing);
      expect(_key('recent-row-remove-0'), findsNothing);
      expect(_key('recent-row-finder-0'), findsNothing);

      await wi361SecondaryClick(tester, _row(0));
      expect(wi361MenuShown(tester), isEmpty);
      expect(find.byType(MenuItemButton), findsNothing);

      // A tap still calls onOpen (#362 closes the modal with it).
      await tester.tap(_row(0));
      await wi97Settle(tester);
      expect(env.opened, [_wi361Team]);
    },
  );

  testWidgets(
    'a hosted row that is not open keeps its x and its remove from recents menu',
    (tester) async {
      await wi361PumpRows(tester, entries: const [_wi361Team]);

      expect(_key('recent-row-open-tag-0'), findsNothing);
      expect(_key('recent-row-remove-0'), findsOneWidget);

      await wi361SecondaryClick(tester, _row(0));
      expect(wi361MenuShown(tester), ['vault-menu-remove']);
    },
  );

  testWidgets(
    'the OPEN tag and the open row border use the pack colours and sizes',
    (tester) async {
      final name = wi361NameWhere((n) => wi361Bucket(n) != OmColors.fg2);
      final path = wi361VaultNamed(name);
      await wi361PumpRows(
        tester,
        entries: [LocalVaultRef(path), const HostedVaultRef(fakeServerId, 'x')],
        openIndex: 0,
      );

      // Row: 1px accent at 0x4D; the other row keeps the default border.
      expect(_wi361Shell(tester, 0).border, OmColors.accentLine30);
      expect(OmColors.accentLine30, OmColors.accent.withAlpha(77));
      expect(_wi361Shell(tester, 1).border, isNull);

      // The icon is still in the vault colour.
      expect(
        tester
            .widget<Icon>(wi97Inside('recent-row-0', find.byType(Icon)).first)
            .color,
        vaultColorFor(name),
      );

      // Tag: 18 high, successBg fill, 1px accent at 0x45, radius 4, 8 after
      // the name.
      final tag = _key('recent-row-open-tag-0');
      expect(tester.getSize(tag).height, 18);
      final boxes = find.descendant(
        of: tag,
        matching: find.byWidgetPredicate(
          (w) =>
              (w is DecoratedBox && w.decoration is BoxDecoration) ||
              (w is Container && w.decoration is BoxDecoration),
        ),
        matchRoot: true,
      );
      final decoration = switch (tester.widget(boxes.first)) {
        final DecoratedBox d => d.decoration as BoxDecoration,
        final Container c => c.decoration! as BoxDecoration,
        _ => throw StateError('no tag decoration'),
      };
      expect(decoration.color, OmColors.successBg);
      expect(decoration.border, Border.all(color: OmColors.accentLine));
      expect(OmColors.accentLine, OmColors.accent.withAlpha(69));
      expect(decoration.borderRadius, BorderRadius.circular(4));

      final nameRect = tester.getRect(
        wi97Inside('recent-row-0', find.text(name)),
      );
      final tagRect = tester.getRect(tag);
      expect(tagRect.left, moreOrLessEquals(nameRect.right + 8, epsilon: 1));
      expect((tagRect.center.dy - nameRect.center.dy).abs(), lessThan(2));

      // Text: OPEN, mono 10 w500, letter spacing 0.8, accent.
      final text = tester.widget<Text>(
        find.descendant(of: tag, matching: find.text('OPEN')),
      );
      expect(text.style?.color, OmColors.accent);
      expect(text.style?.fontSize, 10);
      expect(text.style?.fontWeight, FontWeight.w500);
      expect(text.style?.letterSpacing, 0.8);
    },
  );
}
