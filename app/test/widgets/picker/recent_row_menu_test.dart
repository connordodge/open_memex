// WI #361 (Spec #357 Req 16, 21, 22, 34): every RECENT row is wrapped in the
// vault menu (no `manage…`). A secondary click on a local row opens
// `show in Finder`, `remove from recents`, `delete vault…`; on a hosted row
// `remove from recents` only. Each item does what its row button does, and
// the items are reachable and activatable from the keyboard (a held key
// activates once).
// Seams: vault_picker_harness (the full-screen picker, FakeVaultTrash;
// Finder is never pressed there), wi361_rows (bare rows with a
// FakeFileRevealer for the Finder item), real temp vault folders.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/widgets/picker/delete_vault_dialog.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_vault_server.dart';
import '../../support/fake_vault_trash.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/vault_folders.dart';
import '../../support/vault_picker_harness.dart';
import '../../support/wi349_keyboard.dart';
import '../../support/wi361_rows.dart';

Finder _key(String k) => find.byKey(Key(k));

Finder _row(int i) => _key('recent-row-$i');

const _wi361Memex = HostedVaultRef(fakeServerId, 'memex');

/// #96's unreachable failure for nas/memex.
const _wi361Unreachable = HostedServerUnreachable(
  _wi361Memex,
  fakeServerName,
  "can't reach nas",
);

void main() {
  holdFontFetches();

  group('items', () {
    testWidgets(
      'a secondary click on a local row opens show in Finder remove from recents and delete vault in that order',
      (tester) async {
        final vault = createVaultFolder('om361_rowmenu_');
        await pumpVaultPicker(tester, recents: [LocalVaultRef(vault.path)]);

        await wi361SecondaryClick(tester, _row(0));

        expect(wi361MenuShown(tester), [
          'vault-menu-finder',
          'vault-menu-remove',
          'vault-menu-delete',
        ]);
        expect(find.text('show in Finder'), findsWidgets);
        expect(
          find.descendant(
            of: _key('vault-menu-delete'),
            matching: find.text('delete vault…'),
          ),
          findsOneWidget,
        );
        expect(find.text('manage…'), findsNothing);
        expect(find.byType(Divider), findsNothing);
      },
    );

    testWidgets(
      'a secondary click on a hosted row opens remove from recents only',
      (tester) async {
        await pumpVaultPicker(tester, recents: const [_wi361Memex]);

        await wi361SecondaryClick(tester, _row(0));

        expect(wi361MenuShown(tester), ['vault-menu-remove']);
        expect(find.text('manage…'), findsNothing);
        expect(find.text('show in Finder'), findsNothing);
        expect(find.byType(Divider), findsNothing);
      },
    );

    // Lead ruling Q1: the folderX row keeps only its x, and its menu is
    // show in Finder then remove from recents, with no delete vault.
    testWidgets(
      'a missing folder row keeps only the x and its menu is show in Finder then remove from recents',
      (tester) async {
        final gone = p.join(createPlainFolder('om361_q1_').path, 'gone');
        final env = await wi361PumpRows(tester, entries: [LocalVaultRef(gone)]);

        expect(_key('recent-row-remove-0'), findsOneWidget);
        expect(_key('recent-row-finder-0'), findsNothing);
        expect(_key('recent-row-delete-0'), findsNothing);

        await wi361SecondaryClick(tester, _row(0));
        expect(wi361MenuShown(tester), [
          'vault-menu-finder',
          'vault-menu-remove',
        ]);
        expect(find.text('delete vault…'), findsNothing);

        await tester.tap(_key('vault-menu-finder'));
        await wi97Settle(tester);
        expect(env.revealer.paths, isEmpty);
        expect(find.text('$gone is no longer a vault folder.'), findsOneWidget);
      },
    );

    testWidgets('each row opens the menu of its own vault in a mixed list', (
      tester,
    ) async {
      final vault = createVaultFolder('om361_mixed_');
      await pumpVaultPicker(
        tester,
        recents: [_wi361Memex, LocalVaultRef(vault.path)],
      );

      await wi361SecondaryClick(tester, _row(1));
      expect(wi361MenuShown(tester), [
        'vault-menu-finder',
        'vault-menu-remove',
        'vault-menu-delete',
      ]);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await wi97Settle(tester);

      await wi361SecondaryClick(tester, _row(0));
      expect(wi361MenuShown(tester), ['vault-menu-remove']);
    });
  });

  group('actions', () {
    testWidgets('the show in Finder menu item reveals the vault of that row', (
      tester,
    ) async {
      final a = createVaultFolder('om361_item_a_');
      final b = createVaultFolder('om361_item_b_');
      final env = await wi361PumpRows(
        tester,
        entries: [LocalVaultRef(a.path), LocalVaultRef(b.path)],
      );

      await wi361SecondaryClick(tester, _row(1));
      await tester.tap(_key('vault-menu-finder'));
      await wi97Settle(tester);

      expect(env.revealer.paths, [b.path]);
      expect(env.opened, isEmpty, reason: 'the item opens no vault');
      expect(wi361MenuShown(tester), isEmpty, reason: 'the menu closes');
    });

    testWidgets(
      'the show in Finder menu item on a folder that is no longer a vault shows the SnackBar',
      (tester) async {
        final vault = createVaultFolder('om361_item_gone_');
        final env = await wi361PumpRows(
          tester,
          entries: [LocalVaultRef(vault.path)],
        );

        wi361Unvault(vault.path);
        await wi361SecondaryClick(tester, _row(0));
        await tester.tap(_key('vault-menu-finder'));
        await wi97Settle(tester);

        expect(env.revealer.paths, isEmpty);
        expect(
          find.text('${vault.path} is no longer a vault folder.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'the remove from recents menu item forgets that local vault only',
      (tester) async {
        final keep = createVaultFolder('om361_keep_');
        final forget = createVaultFolder('om361_forget_');
        final env = await pumpVaultPicker(
          tester,
          recents: [LocalVaultRef(keep.path), LocalVaultRef(forget.path)],
        );

        await wi361SecondaryClick(tester, _row(1));
        await tester.tap(_key('vault-menu-remove'));
        await wi97Settle(tester);

        expect(env.settings.recentRefs, [LocalVaultRef(keep.path)]);
        expect(find.text(p.basename(forget.path)), findsNothing);
        expect(find.text(p.basename(keep.path)), findsOneWidget);
        expect(env.opener.opened, isEmpty);
      },
    );

    testWidgets(
      'the remove from recents menu item forgets a hosted vault and clears its recorded outcome',
      (tester) async {
        final env = await pumpVaultPicker(
          tester,
          recents: const [_wi361Memex],
          recorded: {_wi361Memex: const RecentRowFailed(_wi361Unreachable)},
          beforePump: (s) => s[fakeServerId]!.hold(),
        );
        expect(
          env.container.read(recentRowOutcomeProvider(_wi361Memex)),
          isA<RecentRowFailed>(),
        );

        await wi361SecondaryClick(tester, _row(0));
        await tester.tap(_key('vault-menu-remove'));
        await wi97Settle(tester);

        expect(env.settings.recentRefs, isEmpty);
        expect(
          env.container.read(recentRowOutcomeProvider(_wi361Memex)),
          isNull,
        );
        expect(env.opener.opened, isEmpty);
      },
    );

    testWidgets(
      'the delete vault menu item opens the delete dialog for that vault',
      (tester) async {
        final a = createVaultFolder('om361_del_a_');
        final b = createVaultFolder('om361_del_b_');
        final trash = FakeVaultTrash();
        final env = await pumpVaultPicker(
          tester,
          recents: [LocalVaultRef(a.path), LocalVaultRef(b.path)],
          trash: trash,
        );

        await wi361SecondaryClick(tester, _row(1));
        await tester.tap(_key('vault-menu-delete'));
        await wi97Settle(tester);

        final dialog = find.byType(DeleteVaultDialog);
        expect(dialog, findsOneWidget);
        expect(tester.widget<DeleteVaultDialog>(dialog).path, b.path);
        expect(
          find.descendant(
            of: dialog,
            matching: find.text('move ${p.basename(b.path)} to the trash?'),
          ),
          findsOneWidget,
        );
        expect(
          trash.calls,
          isEmpty,
          reason: 'opening the dialog moves nothing',
        );
        expect(wi361MenuShown(tester), isEmpty, reason: 'the menu closes');

        await tester.tap(_key('delete-vault-cancel'));
        await wi97Settle(tester);
        expect(find.byType(DeleteVaultDialog), findsNothing);
        expect(env.settings.recentRefs, [
          LocalVaultRef(a.path),
          LocalVaultRef(b.path),
        ]);
      },
    );
  });

  group('keyboard', () {
    testWidgets(
      'the down arrow reaches each row menu item and Enter on remove from recents forgets that vault',
      (tester) async {
        final keep = createVaultFolder('om361_kb_keep_');
        final forget = createVaultFolder('om361_kb_forget_');
        final env = await pumpVaultPicker(
          tester,
          recents: [LocalVaultRef(forget.path), LocalVaultRef(keep.path)],
        );

        await wi361SecondaryClick(tester, _row(0));
        await wi361ArrowTo(tester, _key('vault-menu-finder'));
        await wi361ArrowTo(tester, _key('vault-menu-remove'));
        await wi361ArrowTo(tester, _key('vault-menu-delete'));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(wi349FocusIn(_key('vault-menu-remove')), isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await wi97Settle(tester);

        expect(env.settings.recentRefs, [LocalVaultRef(keep.path)]);
        expect(env.opener.opened, isEmpty);
      },
    );

    testWidgets(
      'a held Enter on the remove from recents menu item forgets exactly one vault',
      (tester) async {
        final a = createVaultFolder('om361_held_a_');
        final b = createVaultFolder('om361_held_b_');
        final c = createVaultFolder('om361_held_c_');
        final env = await pumpVaultPicker(
          tester,
          recents: [
            LocalVaultRef(a.path),
            LocalVaultRef(b.path),
            LocalVaultRef(c.path),
          ],
        );

        await wi361SecondaryClick(tester, _row(0));
        await wi361ArrowTo(tester, _key('vault-menu-remove'));
        await wi349HoldKey(tester, LogicalKeyboardKey.enter);
        await wi97Settle(tester);

        expect(env.settings.recentRefs, [
          LocalVaultRef(b.path),
          LocalVaultRef(c.path),
        ], reason: 'one vault forgotten, not one per key repeat');
        expect(env.opener.opened, isEmpty);
      },
    );

    testWidgets(
      'a held Enter on the delete vault menu item opens one delete dialog',
      (tester) async {
        final vault = createVaultFolder('om361_held_del_');
        final trash = FakeVaultTrash();
        await pumpVaultPicker(
          tester,
          recents: [LocalVaultRef(vault.path)],
          trash: trash,
        );

        await wi361SecondaryClick(tester, _row(0));
        await wi361ArrowTo(tester, _key('vault-menu-delete'));
        await wi349HoldKey(tester, LogicalKeyboardKey.enter);
        await wi97Settle(tester);

        expect(find.byType(DeleteVaultDialog), findsOneWidget);
        expect(trash.calls, isEmpty, reason: 'a repeat never confirms it');
      },
    );

    testWidgets(
      'a held Enter on the show in Finder menu item reveals the vault once',
      (tester) async {
        final vault = createVaultFolder('om361_held_finder_');
        final env = await wi361PumpRows(
          tester,
          entries: [LocalVaultRef(vault.path)],
        );

        await wi361SecondaryClick(tester, _row(0));
        await wi361ArrowTo(tester, _key('vault-menu-finder'));
        await wi349HoldKey(tester, LogicalKeyboardKey.enter);
        await wi97Settle(tester);

        expect(env.revealer.paths, [vault.path]);
        expect(env.opened, isEmpty);
      },
    );
  });
}
