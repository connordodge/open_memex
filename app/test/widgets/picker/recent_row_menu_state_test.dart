// WI #361 (Spec #357 Req 17, 21, 22): row contracts the first test round
// left open (verify round).
// - After the delete dialog opened from the row menu closes, the row
//   re-checks its folder, like its delete button does.
// - A hosted row whose saved server is gone draws its server icon in the
//   vault colour of `<vault> · <server id>`.
// Seams: vault_picker_harness (the full-screen picker), wi361_rows (bare
// rows), real temp vault folders.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/picker/delete_vault_dialog.dart';

import '../../support/font_fetch_hold.dart';
import '../../support/vault_folders.dart';
import '../../support/vault_picker_harness.dart';
import '../../support/wi361_rows.dart';

Finder _key(String k) => find.byKey(Key(k));

void main() {
  holdFontFetches();

  testWidgets(
    'a row re-checks its folder when the delete dialog opened from its menu closes',
    (tester) async {
      final vault = createVaultFolder('om361_recheck_');
      await pumpVaultPicker(tester, recents: [LocalVaultRef(vault.path)]);
      expect(_key('recent-row-finder-0'), findsOneWidget);

      await wi361SecondaryClick(tester, _key('recent-row-0'));
      await tester.tap(_key('vault-menu-delete'));
      await wi97Settle(tester);
      expect(find.byType(DeleteVaultDialog), findsOneWidget);

      // The folder stops being a vault while the dialog is open.
      wi361Unvault(vault.path);
      await tester.tap(_key('delete-vault-cancel'));
      await wi97Settle(tester);

      expect(find.byType(DeleteVaultDialog), findsNothing);
      expect(
        wi97Inside('recent-row-0', find.byIcon(LucideIcons.folderX)),
        findsOneWidget,
      );
      expect(_key('recent-row-finder-0'), findsNothing);
      expect(_key('recent-row-delete-0'), findsNothing);
    },
  );

  testWidgets(
    'a hosted row whose saved server is gone draws its server icon in the vault colour of the vault and server id',
    (tester) async {
      const serverId = 'ghost-server';
      final name = wi361NameWhere((n) {
        final label = hostedVaultLabel(n, serverId);
        return wi361Bucket(label) != OmColors.fg2 &&
            wi361Bucket(label) != wi361Bucket(n);
      });
      await wi361PumpRows(
        tester,
        entries: [HostedVaultRef(serverId, name)],
        savedServers: const [],
      );

      final icon = tester.widget<Icon>(
        wi97Inside('recent-row-0', find.byIcon(LucideIcons.server)),
      );
      expect(icon.color, wi361Bucket(hostedVaultLabel(name, serverId)));
      expect(icon.color, isNot(OmColors.fg2));
    },
  );
}
