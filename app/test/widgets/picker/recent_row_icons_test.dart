// WI #361 (Spec #357 Req 17, 18, 34): the full-screen picker's RECENT rows
// lead with their type icon in the vault colour: `LucideIcons.folder` in
// `vaultColorFor(<folder name>)` for a local vault, `LucideIcons.server` in
// `vaultColorFor("<vault> · <server>")` for a hosted vault. The existing
// states win: a missing folder keeps `folderX` in danger, the binary
// missing keeps the local icon `fg3`, and hosted states keep their icons.
// Seams: test/support/vault_picker_harness.dart, real temp vault folders
// named so the label is known.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/vault_color.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_vault_server.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/vault_folders.dart';
import '../../support/vault_picker_harness.dart';
import '../../support/wi361_rows.dart';

/// The single [icon] inside the row keyed `recent-row-<index>`.
Icon _wi361IconIn(WidgetTester tester, int index, IconData icon) =>
    tester.widget<Icon>(wi97Inside('recent-row-$index', find.byIcon(icon)));

void main() {
  holdFontFetches();

  testWidgets(
    'a local picker row draws its folder icon in the vault colour of its folder name',
    (tester) async {
      // A name whose colour is not today's fg2, so the change is visible.
      final name = wi361NameWhere((n) => wi361Bucket(n) != OmColors.fg2);
      final path = wi361VaultNamed(name);
      await pumpVaultPicker(tester, recents: [LocalVaultRef(path)]);

      final icon = _wi361IconIn(tester, 0, LucideIcons.folder);
      expect(icon.size, 14);
      expect(icon.color, vaultColorFor(name));
      expect(icon.color, wi361Bucket(name));
      expect(icon.color, isNot(OmColors.fg2));
    },
  );

  testWidgets(
    'a hosted picker row draws its server icon in the vault colour of the vault and server label',
    (tester) async {
      // A vault whose full label lands in another bucket than its bare
      // name, and not in today's fg2.
      final name = wi361NameWhere((n) {
        final label = hostedVaultLabel(n, fakeServerName);
        return wi361Bucket(label) != wi361Bucket(n) &&
            wi361Bucket(label) != OmColors.fg2;
      });
      await pumpVaultPicker(
        tester,
        recents: [HostedVaultRef(fakeServerId, name)],
      );

      final icon = _wi361IconIn(tester, 0, LucideIcons.server);
      final label = hostedVaultLabel(name, fakeServerName);
      expect(label, '$name · nas');
      expect(icon.size, 14);
      expect(icon.color, vaultColorFor(label));
      expect(icon.color, wi361Bucket(label));
      expect(icon.color, isNot(vaultColorFor(name)));
    },
  );

  testWidgets(
    'local and hosted rows in one list each take the colour of their own label',
    (tester) async {
      final localName = wi361NameWhere((n) => wi361Bucket(n) != OmColors.fg2);
      final hostedName = wi361NameWhere((n) {
        final c = wi361Bucket(hostedVaultLabel(n, fakeServerName));
        return c != OmColors.fg2 && c != wi361Bucket(localName);
      });
      final path = wi361VaultNamed(localName);
      await pumpVaultPicker(
        tester,
        recents: [
          HostedVaultRef(fakeServerId, hostedName),
          LocalVaultRef(path),
        ],
      );

      expect(
        _wi361IconIn(tester, 0, LucideIcons.server).color,
        vaultColorFor(hostedVaultLabel(hostedName, fakeServerName)),
      );
      expect(
        _wi361IconIn(tester, 1, LucideIcons.folder).color,
        vaultColorFor(localName),
      );
    },
  );

  testWidgets(
    'a missing local vault row keeps the folder x icon in danger whatever its name hashes to',
    (tester) async {
      final name = wi361NameWhere((n) => wi361Bucket(n) != OmColors.fg2);
      final missing = p.join(createPlainFolder('om361_gone_').path, name);
      await pumpVaultPicker(tester, recents: [LocalVaultRef(missing)]);

      final icon = _wi361IconIn(tester, 0, LucideIcons.folderX);
      expect(icon.color, OmColors.danger);
      expect(
        wi97Inside('recent-row-0', find.byIcon(LucideIcons.folder)),
        findsNothing,
      );
    },
  );

  testWidgets(
    'with the memex binary missing a local row keeps its folder icon in fg3',
    (tester) async {
      final name = wi361NameWhere((n) => wi361Bucket(n) != OmColors.fg2);
      final path = wi361VaultNamed(name);
      await pumpVaultPicker(
        tester,
        binary: false,
        recents: [LocalVaultRef(path)],
      );

      expect(
        wi97Inside('recent-row-0', find.text('needs the memex binary')),
        findsOneWidget,
      );
      expect(_wi361IconIn(tester, 0, LucideIcons.folder).color, OmColors.fg3);
    },
  );

  testWidgets(
    'a hosted row that cannot reach its server keeps the warn wifi off icon',
    (tester) async {
      final name = wi361NameWhere(
        (n) =>
            wi361Bucket(hostedVaultLabel(n, fakeServerName)) != OmColors.warn,
      );
      await pumpVaultPicker(
        tester,
        recents: [HostedVaultRef(fakeServerId, name)],
        beforePump: (s) => s[fakeServerId]!.failure = FakeServerFailure.refused,
      );

      expect(_wi361IconIn(tester, 0, LucideIcons.wifiOff).color, OmColors.warn);
      expect(
        wi97Inside('recent-row-0', find.byIcon(LucideIcons.server)),
        findsNothing,
      );
    },
  );
}
