// WI #361 (Spec #357 Req 23–25, 34, TD4): a local RECENT row's "show in
// Finder" button (`recent-row-finder-<i>`, `LucideIcons.folderSearch`,
// tooltip `show in Finder`) sits before delete and the ×; a hosted row has
// none. Pressing it reveals the folder through `fileRevealerProvider`, or,
// when the folder is no longer a vault, opens nothing and shows the SnackBar
// `<path> is no longer a vault folder.`
// Seams: vault_picker_harness (the full-screen picker; Finder is never
// pressed there), wi361_rows (bare rows with a FakeFileRevealer), real temp
// vault folders. Never a real Finder.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/widgets/picker/server_row.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_vault_server.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/vault_folders.dart';
import '../../support/vault_picker_harness.dart';
import '../../support/wi349_keyboard.dart';
import '../../support/wi361_rows.dart';

Finder _key(String k) => find.byKey(Key(k));

void main() {
  holdFontFetches();

  group('the button', () {
    testWidgets(
      'a local row shows a show in Finder button before delete and the x and a hosted row has none',
      (tester) async {
        final handle = tester.ensureSemantics();
        final vault = createVaultFolder('om361_finder_');
        final name = p.basename(vault.path);
        await pumpVaultPicker(
          tester,
          recents: [
            LocalVaultRef(vault.path),
            const HostedVaultRef(fakeServerId, 'team'),
          ],
        );

        final finder = _key('recent-row-finder-0');
        expect(finder, findsOneWidget);
        expect(wi97Inside('recent-row-0', finder), findsOneWidget);
        final button = tester.widget<PickerRowIconButton>(finder);
        expect(button.icon, LucideIcons.folderSearch);
        expect(button.tooltip, 'show in Finder');
        expect(button.semanticLabel, 'show $name in Finder');
        expect(
          wi97Inside('recent-row-0', find.byTooltip('show in Finder')),
          findsOneWidget,
        );

        // Left to right: show in Finder, delete, x, on one line.
        final f = tester.getRect(finder);
        final d = tester.getRect(_key('recent-row-delete-0'));
        final x = tester.getRect(_key('recent-row-remove-0'));
        expect(f.right, lessThanOrEqualTo(d.left));
        expect(d.right, lessThanOrEqualTo(x.left));
        expect((f.center.dy - d.center.dy).abs(), lessThan(1));
        expect(f.size, const Size(24, 24));

        expect(
          wi349NodeLabelled(tester, finder, 'show $name in Finder'),
          isSemantics(
            label: 'show $name in Finder',
            isButton: true,
            hasTapAction: true,
          ),
        );

        // The hosted row: the x only.
        expect(_key('recent-row-finder-1'), findsNothing);
        expect(
          wi97Inside('recent-row-1', find.byIcon(LucideIcons.folderSearch)),
          findsNothing,
        );
        expect(_key('recent-row-delete-1'), findsNothing);
        expect(_key('recent-row-remove-1'), findsOneWidget);
        handle.dispose();
      },
    );

    testWidgets(
      'the show in Finder key carries the row index after a hosted row',
      (tester) async {
        final vault = createVaultFolder('om361_index_');
        await pumpVaultPicker(
          tester,
          recents: [
            const HostedVaultRef(fakeServerId, 'team'),
            LocalVaultRef(vault.path),
          ],
        );

        expect(_key('recent-row-finder-0'), findsNothing);
        expect(_key('recent-row-finder-1'), findsOneWidget);
        expect(
          wi97Inside('recent-row-1', _key('recent-row-finder-1')),
          findsOneWidget,
        );
      },
    );

    testWidgets('Tab reaches the show in Finder button on a local row', (
      tester,
    ) async {
      final vault = createVaultFolder('om361_tab_');
      await pumpVaultPicker(tester, recents: [LocalVaultRef(vault.path)]);

      await wi349TabTo(tester, _key('recent-row-finder-0'));
      expect(wi349FocusIn(_key('recent-row-finder-0')), isTrue);
    });

    testWidgets(
      'a local row shows the show in Finder button while the memex binary is missing',
      (tester) async {
        final vault = createVaultFolder('om361_nobin_');
        await pumpVaultPicker(
          tester,
          binary: false,
          recents: [LocalVaultRef(vault.path)],
        );

        expect(_key('recent-row-finder-0'), findsOneWidget);
        expect(
          tester.getRect(_key('recent-row-finder-0')).right,
          lessThanOrEqualTo(tester.getRect(_key('recent-row-delete-0')).left),
        );
      },
    );
  });

  group('reveal', () {
    testWidgets(
      'show in Finder on an existing vault calls reveal once with that path',
      (tester) async {
        final a = createVaultFolder('om361_reveal_a_');
        final b = createVaultFolder('om361_reveal_b_');
        final env = await wi361PumpRows(
          tester,
          entries: [LocalVaultRef(a.path), LocalVaultRef(b.path)],
        );

        await tester.tap(_key('recent-row-finder-1'));
        await wi97Settle(tester);

        expect(env.revealer.paths, [b.path]);
        expect(env.opened, isEmpty, reason: 'show in Finder opens no vault');
        expect(find.byType(SnackBar), findsNothing);
        expect(env.settings.recentRefs, [
          LocalVaultRef(a.path),
          LocalVaultRef(b.path),
        ]);
      },
    );

    testWidgets(
      'Enter on a focused show in Finder button reveals the vault once even when held',
      (tester) async {
        final vault = createVaultFolder('om361_enter_');
        final env = await wi361PumpRows(
          tester,
          entries: [LocalVaultRef(vault.path)],
        );

        await wi349TabTo(tester, _key('recent-row-finder-0'));
        await wi349HoldKey(tester, LogicalKeyboardKey.enter);
        await wi97Settle(tester);

        expect(env.revealer.paths, [vault.path]);
        expect(env.opened, isEmpty);
      },
    );

    testWidgets(
      'show in Finder with the memex binary missing still reveals the vault',
      (tester) async {
        final vault = createVaultFolder('om361_nobin_reveal_');
        final env = await wi361PumpRows(
          tester,
          entries: [LocalVaultRef(vault.path)],
          binaryMissing: true,
        );

        await tester.tap(_key('recent-row-finder-0'));
        await wi97Settle(tester);

        expect(env.revealer.paths, [vault.path]);
      },
    );

    testWidgets(
      'show in Finder on a folder that is no longer a vault opens nothing and shows the SnackBar',
      (tester) async {
        final vault = createVaultFolder('om361_unvault_');
        final env = await wi361PumpRows(
          tester,
          entries: [LocalVaultRef(vault.path)],
        );
        expect(_key('recent-row-finder-0'), findsOneWidget);

        // The folder stops being a vault after the row was drawn.
        wi361Unvault(vault.path);
        await tester.tap(_key('recent-row-finder-0'));
        await wi97Settle(tester);

        expect(env.revealer.paths, isEmpty, reason: 'nothing opens');
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text('${vault.path} is no longer a vault folder.'),
          ),
          findsOneWidget,
        );
        expect(env.opened, isEmpty);
        expect(env.settings.recentRefs, [
          LocalVaultRef(vault.path),
        ], reason: 'nothing else changes');
      },
    );
  });
}
