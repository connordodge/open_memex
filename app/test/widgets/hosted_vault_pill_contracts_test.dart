// WI #96 (verify mode): sidebar pill contracts the implementer handoff and
// pack 96 name but the red tests left open: the incompatible dot, a hosted
// recent whose server is gone, the local pill active state, the pill colour
// hashed from the full label (pack 96 lead decision), and the VAULTS count
// of board A10 ("VAULTS · 4" over one local and three hosted pills).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';
import 'package:path/path.dart' as p;

import '../support/app_harness.dart';
import '../support/fake_vault_server.dart';
import '../support/hosted_harness.dart';
import '../support/vault_folders.dart';

/// Today's pill palette, in its order (sidebar.dart `_vaultColorFor`).
const _wi96Palette = [
  OmColors.accent,
  OmColors.info,
  OmColors.warn,
  OmColors.agent,
  OmColors.fg2,
];

Color _wi96Bucket(String s) => _wi96Palette[s.hashCode.abs() % 5];

HostedServerFixture _wi96Studio() => HostedServerFixture(
  id: 'srv-studio',
  name: 'studio',
  url: 'http://studio.local:9000',
  token: 'studio-token-96',
  vaultName: 'work',
);

Key _wi96Pill(String serverId, String vault) =>
    Key('vault-pill-$serverId-$vault');

/// The workspace with seed on nas open and [recents] in RECENT.
Future<HostedHarness> _wi96PumpOpen(
  WidgetTester tester, {
  required List<VaultRef> recents,
  List<HostedServerFixture>? servers,
}) async {
  final h = await pumpHostedApp(
    tester,
    servers: servers ?? [HostedServerFixture(), _wi96Studio()],
    recents: recents,
  );
  await pumpWhile(tester, () => h.controller.openVault(seedHostedRef));
  expect(find.byType(Workspace), findsOneWidget);
  return h;
}

void main() {
  group('hosted pill contracts (AC9, pack 96)', () {
    testWidgets(
      'a hosted pill for an incompatible server shows the token rejected dot and copy',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final studio = _wi96Studio();
        final h = await _wi96PumpOpen(
          tester,
          recents: [studio.ref('work')],
          servers: [HostedServerFixture(), studio],
        );

        h.read(hostedConnectionStatusProvider(studio.id).notifier).state =
            HostedConnectionStatus.incompatible;
        await pumpFrames(tester);

        final dot = tester.widget<StatusDot>(
          find.byKey(Key('vault-pill-dot-${studio.id}-work')),
        );
        expect(dot.state, StatusDotState.tokenRejected);
        expect(
          find.descendant(
            of: find.byKey(_wi96Pill(studio.id, 'work')),
            matching: find.bySemanticsLabel('studio rejected the access token'),
          ),
          findsOneWidget,
        );
        semantics.dispose();
      },
    );

    testWidgets('a hosted recent whose server is not saved renders no pill', (
      tester,
    ) async {
      const orphan = HostedVaultRef('srv-orphan', 'lost');
      await _wi96PumpOpen(tester, recents: [seedHostedRef, orphan]);

      expect(find.byKey(_wi96Pill(fakeServerId, 'seed')), findsOneWidget);
      expect(find.byKey(_wi96Pill('srv-orphan', 'lost')), findsNothing);
      expect(
        find.descendant(
          of: find.byType(Sidebar),
          matching: find.textContaining('lost'),
        ),
        findsNothing,
      );
    });

    testWidgets(
      'a local pill is inactive while a hosted vault is open and the hosted pill is active',
      (tester) async {
        final local = createVaultFolder('om96_inactive_');
        final studio = _wi96Studio();
        await _wi96PumpOpen(
          tester,
          recents: [
            LocalVaultRef(local.path),
            seedHostedRef,
            studio.ref('work'),
          ],
          servers: [HostedServerFixture(), studio],
        );

        Color? labelColor(String text) => tester
            .widget<Text>(
              find.descendant(
                of: find.byType(Sidebar),
                matching: find.text(text),
              ),
            )
            .style
            ?.color;
        expect(labelColor(p.basename(local.path)), OmColors.fg2);
        expect(labelColor('seed · nas'), OmColors.fg0);
        expect(labelColor('work · studio'), OmColors.fg2);
      },
    );

    testWidgets(
      'a hosted pill colour is hashed from its full label not its vault name',
      (tester) async {
        // A vault name whose label lands in another palette bucket than the
        // bare name, so the two hash inputs are told apart.
        final name = [
          for (var i = 0; i < 50; i++) 'vault$i',
        ].firstWhere((n) => _wi96Bucket('$n · nas') != _wi96Bucket(n));
        final ref = HostedVaultRef(fakeServerId, name);
        final local = createVaultFolder('om96_colour_');
        await _wi96PumpOpen(
          tester,
          recents: [ref, LocalVaultRef(local.path)],
          servers: [HostedServerFixture()],
        );

        final icon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(_wi96Pill(fakeServerId, name)),
            matching: find.byIcon(LucideIcons.server),
          ),
        );
        expect(icon.color, _wi96Bucket('$name · nas'));

        final localName = p.basename(local.path);
        final localRow = find
            .ancestor(
              of: find.descendant(
                of: find.byType(Sidebar),
                matching: find.text(localName),
              ),
              matching: find.byType(Row),
            )
            .first;
        final omDot = tester.widget<OmDot>(
          find.descendant(of: localRow, matching: find.byType(OmDot)),
        );
        expect(omDot.color, _wi96Bucket(localName));
      },
    );

    testWidgets(
      'the vaults header count includes hosted recents as board A10 shows',
      (tester) async {
        final local = createVaultFolder('om96_count_');
        final studio = _wi96Studio();
        await _wi96PumpOpen(
          tester,
          recents: [
            LocalVaultRef(local.path),
            seedHostedRef,
            studio.ref('work'),
          ],
          servers: [HostedServerFixture(), studio],
        );

        final header = find.ancestor(
          of: find.text('VAULTS'),
          matching: find.byType(PanelHeader),
        );
        expect(header, findsOneWidget);
        expect(tester.widget<PanelHeader>(header).count, 3);
        expect(
          find.descendant(of: header, matching: find.text('· 3')),
          findsOneWidget,
        );
      },
    );
  });
}
