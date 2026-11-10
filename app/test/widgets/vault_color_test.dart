// WI #361 (Spec #357 Req 18, TD6): `vaultColorFor` hashes a vault's label
// exactly as the sidebar's private `_vaultColorFor` does, so a picker row
// and its pill get the same colour. Checked against the sidebar's formula
// for a table of labels and against the colours the real sidebar pills
// draw. Seams: hosted_harness (fake vault server, mock prefs) and a real
// temp vault folder.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';
import 'package:open_memex_app/src/widgets/vault_color.dart';
import 'package:path/path.dart' as p;

import '../support/api_fixtures.dart';
import '../support/fake_vault_server.dart';
import '../support/font_fetch_hold.dart';
import '../support/hosted_harness.dart';
import '../support/vault_folders.dart';
import '../support/wi361_rows.dart';

void main() {
  holdFontFetches();

  test(
    'vaultColorFor matches the sidebar hash for a table of local and hosted labels',
    () {
      // Labels built at run time, local folder names and hosted labels.
      final labels = <String>[
        'memex',
        'work-notes',
        'reading-notes',
        ['jour', 'nal'].join(),
        '',
        'a',
        'notes 東京',
        hostedVaultLabel('team', 'nas'),
        hostedVaultLabel('memex', 'nas'),
        hostedVaultLabel('work', 'studio'),
        hostedVaultLabel('seed', fakeServerName),
        hostedVaultLabel('reading-notes', 'studio-mini'),
      ];
      for (final label in labels) {
        expect(vaultColorFor(label), wi361Bucket(label), reason: label);
      }
    },
  );

  test(
    'vaultColorFor uses every colour of the sidebar palette and no other',
    () {
      final colours = {
        for (var i = 0; i < 200; i++) vaultColorFor('vault$i'),
        for (var i = 0; i < 200; i++)
          vaultColorFor(hostedVaultLabel('v$i', 'nas')),
      };
      expect(colours, wi361Palette.toSet());
    },
  );

  test(
    'vaultColorFor hashes the full hosted label not the bare vault name',
    () {
      final name = wi361NameWhere(
        (n) => wi361Bucket(hostedVaultLabel(n, 'nas')) != wi361Bucket(n),
      );
      expect(
        vaultColorFor(hostedVaultLabel(name, 'nas')),
        wi361Bucket('$name · nas'),
      );
      expect(vaultColorFor(name), wi361Bucket(name));
      expect(
        vaultColorFor(hostedVaultLabel(name, 'nas')),
        isNot(vaultColorFor(name)),
      );
    },
  );

  testWidgets(
    'vaultColorFor gives the colours the sidebar pills draw for a local and a hosted vault',
    (tester) async {
      final local = createVaultFolder('om361_pill_');
      final localName = p.basename(local.path);
      final h = await pumpHostedApp(
        tester,
        servers: [HostedServerFixture()],
        recents: [seedHostedRef, LocalVaultRef(local.path)],
      );
      await pumpWhile(tester, () => h.controller.openVault(seedHostedRef));
      expect(find.byType(Workspace), findsOneWidget);

      final hostedIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(Key('vault-pill-$fakeServerId-$seedVaultName')),
          matching: find.byIcon(LucideIcons.server),
        ),
      );
      expect(
        hostedIcon.color,
        vaultColorFor(hostedVaultLabel(seedVaultName, fakeServerName)),
      );

      // The local pill leads with its vault colour: an OmDot today, the
      // folder icon once #363 lands.
      final localPill = find
          .ancestor(
            of: find.descendant(
              of: find.byType(Sidebar),
              matching: find.text(localName),
            ),
            matching: find.byType(Row),
          )
          .first;
      final dots = find.descendant(of: localPill, matching: find.byType(OmDot));
      final Color? localColour = dots.evaluate().isNotEmpty
          ? tester.widget<OmDot>(dots).color
          : tester
                .widget<Icon>(
                  find.descendant(
                    of: localPill,
                    matching: find.byIcon(LucideIcons.folder),
                  ),
                )
                .color;
      expect(localColour, vaultColorFor(localName));
      expect(localColour, isNot(OmColors.fg3));
    },
  );
}
