// WI #96 (H2, D19, Req 47, 49, board A10, pack 96): the sidebar vault
// pills. A hosted recent renders "<vault> · <server>" with the server icon
// in the vault colour and a trailing #69 StatusDot fed by
// `hostedConnectionStatusProvider`; a local pill leads with its folder icon
// (#363).
// Tapping a hosted pill (after `leaveVaultGuardProvider`) runs the hosted
// open path; a failed open keeps the current vault and shows the
// `pill-open-failed-snackbar` with the row's copy and action. A refused
// local pill shows #92's refusal dialog with the OPEN LOCAL VAULT eyebrow
// (lead update on #117), and a plain failure the picker's error message.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';
import 'package:path/path.dart' as p;

import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_server.dart';
import '../support/font_fetch_hold.dart';
import '../support/hosted_harness.dart';
import '../support/vault_folders.dart';

const _snack = Key('pill-open-failed-snackbar');
const _refusal = Key('network-drive-refusal');
const _refusalCancel = Key('network-drive-refusal-cancel');
const _tooOld = Key('memex-too-old-refusal');
const _tooOldCancel = Key('memex-too-old-cancel');

const _l9Studio =
    "studio runs memex 0.9.0, which this app can't use. update the app or "
    'memex on the server so both are the same release.';
const _schemaText = 'schema version unsupported: db=7, app=5';

Key _pillKey(String serverId, String vault) =>
    Key('vault-pill-$serverId-$vault');
Key _dotKey(String serverId, String vault) =>
    Key('vault-pill-dot-$serverId-$vault');

/// The vault colours a pill may take (today's `_colorFor` palette).
const _palette = [
  OmColors.accent,
  OmColors.info,
  OmColors.warn,
  OmColors.agent,
  OmColors.fg2,
];

HostedServerFixture _studio() => HostedServerFixture(
  id: 'srv-studio',
  name: 'studio',
  url: 'http://studio.local:9000',
  token: 'studio-token-96',
  vaultName: 'work',
);

/// The StatusDot under [k] (the key may sit on the dot itself).
StatusDot _dot(WidgetTester tester, Key k) => tester.widget<StatusDot>(
  find
      .descendant(
        of: find.byKey(k),
        matching: find.byType(StatusDot),
        matchRoot: true,
      )
      .first,
);

/// Taps [f] and pumps until the fake server, the settings writes and the
/// rebuilds have landed.
Future<void> _tapAndSettle(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await pumpFrames(tester);
}

/// The app with the seed vault on nas open, and "work" on studio (plus any
/// [extra] refs) in the recents. The leave guard allows and counts its
/// calls in [guardCalls].
Future<(HostedHarness, HostedServerFixture, List<int>)> _pumpOpen(
  WidgetTester tester, {
  List<VaultRef> extra = const [],
  bool guardAllows = true,
  List<String>? updateTokenCalls,
}) async {
  final studio = _studio();
  final guardCalls = <int>[];
  final h = await pumpHostedApp(
    tester,
    servers: [HostedServerFixture(), studio],
    recents: [studio.ref('work'), ...extra],
    overrides: [
      leaveVaultGuardProvider.overrideWithValue((_) async {
        guardCalls.add(1);
        return guardAllows;
      }),
      if (updateTokenCalls != null)
        updateTokenSeamProvider.overrideWithValue(updateTokenCalls.add),
    ],
  );
  await pumpWhile(tester, () => h.controller.openVault(seedHostedRef));
  expect(find.byType(Workspace), findsOneWidget);
  // WI #105 (AC1): with the flag gone the picker probes each saved server
  // before the open. Forget that probe so the tests see only what a pill
  // tap sends.
  expect(studio.server.requests.map((r) => '${r.method} ${r.url.path}'), [
    'GET /api/v1/info',
  ], reason: 'the picker probed studio once');
  studio.server.requests.clear();
  return (h, studio, guardCalls);
}

void main() {
  holdFontFetches();

  group('refused local pill taps (AC1, lead update on #117)', () {
    /// The workspace on a local vault, with a second local vault in the
    /// recents whose `memex vault check` answers [check].
    Future<(WorkspaceHarness, String)> pumpLocal(
      WidgetTester tester,
      MemexResult Function() check,
    ) async {
      final other = createVaultFolder('om96_pill_');
      final cli = FakeMemexCli()
        ..on(
          'vault check',
          (call) =>
              call.args.contains(other.path) ? check() : FakeMemexCli.ok(),
        )
        ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout));
      final h = await pumpWorkspace(
        tester,
        cli: cli,
        overrides: [
          leaveVaultGuardProvider.overrideWithValue((_) async => true),
        ],
      );
      final settings = h.read(settingsProvider.notifier);
      await tester.runAsync(() async {
        await settings.rememberVault(other.path);
        await settings.rememberVault(h.vaultPath);
      });
      await pumpFrames(tester);
      return (h, other.path);
    }

    Finder localPill(String path) => find.descendant(
      of: find.byType(Sidebar),
      matching: find.text(p.basename(path)),
    );

    void expectUnchanged(WorkspaceHarness h) {
      expect(find.byType(Workspace), findsOneWidget);
      expect(h.read(currentVaultProvider), LocalVaultRef(h.vaultPath));
      expect(h.read(settingsProvider).lastVault, h.vaultPath);
    }

    testWidgets(
      'a local pill on a network drive shows the network drive refusal with the OPEN LOCAL VAULT eyebrow and cancel leaves the workspace',
      (tester) async {
        final (h, other) = await pumpLocal(
          tester,
          () => FakeMemexCli.error(
            'network_filesystem',
            'the vault folder is on a network filesystem',
          ),
        );

        await _tapAndSettle(tester, localPill(other));

        expect(find.byKey(_refusal), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(_refusal),
            matching: find.text('OPEN LOCAL VAULT'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: find.byKey(_refusal), matching: find.text(other)),
          findsOneWidget,
        );

        await _tapAndSettle(tester, find.byKey(_refusalCancel));

        expect(find.byKey(_refusal), findsNothing);
        expectUnchanged(h);
      },
    );

    testWidgets(
      'a local pill with a memex too old shows the too old refusal with the OPEN LOCAL VAULT eyebrow and cancel leaves the workspace',
      (tester) async {
        final (h, other) = await pumpLocal(
          tester,
          () => FakeMemexCli.failure(
            "error: unrecognized subcommand 'vault'\n",
            exitCode: 2,
          ),
        );

        await _tapAndSettle(tester, localPill(other));

        expect(find.byKey(_tooOld), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(_tooOld),
            matching: find.text('OPEN LOCAL VAULT'),
          ),
          findsOneWidget,
        );

        await _tapAndSettle(tester, find.byKey(_tooOldCancel));

        expect(find.byKey(_tooOld), findsNothing);
        expectUnchanged(h);
      },
    );

    testWidgets(
      'a local pill whose open fails plainly shows the picker error message',
      (tester) async {
        final (h, other) = await pumpLocal(
          tester,
          () => FakeMemexCli.error('internal', 'disk on fire'),
        );

        await _tapAndSettle(tester, localPill(other));

        expect(find.byKey(_refusal), findsNothing);
        expect(find.byKey(_tooOld), findsNothing);
        final snack = find.byType(SnackBar);
        expect(snack, findsOneWidget);
        expect(
          find.descendant(
            of: snack,
            matching: find.textContaining('Could not open $other'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: snack,
            matching: find.textContaining('disk on fire'),
          ),
          findsOneWidget,
        );
        expectUnchanged(h);
      },
    );
  });

  group('hosted pills (AC9, board A10)', () {
    testWidgets(
      'each hosted recent renders vault and server with the server icon and a trailing status dot while a local pill leads with its folder icon',
      (tester) async {
        final local = createVaultFolder('om96_localpill_');
        final (h, studio, _) = await _pumpOpen(
          tester,
          extra: [LocalVaultRef(local.path)],
        );

        for (final (serverId, vault, label, active) in [
          (fakeServerId, 'seed', 'seed · nas', true),
          (studio.id, 'work', 'work · studio', false),
        ]) {
          final pill = find.byKey(_pillKey(serverId, vault));
          expect(pill, findsOneWidget, reason: label);
          expect(tester.getSize(pill).height, 26, reason: label);

          final text = find.descendant(of: pill, matching: find.text(label));
          expect(text, findsOneWidget);
          expect(
            tester.widget<Text>(text).style?.color,
            active ? OmColors.fg0 : OmColors.fg2,
            reason: '$label active=$active',
          );

          final icon = find.descendant(
            of: pill,
            matching: find.byIcon(LucideIcons.server),
          );
          expect(icon, findsOneWidget, reason: label);
          final iconWidget = tester.widget<Icon>(icon);
          expect(iconWidget.size, 11);
          expect(_palette, contains(iconWidget.color));

          final dot = find.descendant(
            of: find.byKey(_dotKey(serverId, vault)),
            matching: find.byType(StatusDot),
            matchRoot: true,
          );
          expect(dot, findsOneWidget, reason: label);
          expect(
            find.descendant(of: pill, matching: find.byType(StatusDot)),
            findsOneWidget,
          );
          // Icon, 7, label, 8, dot: the dot trails the label.
          expect(
            tester.getTopLeft(text).dx - tester.getTopRight(icon).dx,
            7,
            reason: label,
          );
          expect(
            tester.getTopLeft(dot).dx - tester.getTopRight(text).dx,
            8,
            reason: label,
          );
          expect(
            find.descendant(of: pill, matching: find.byType(OmDot)),
            findsNothing,
            reason: 'a hosted pill has no leading vault dot',
          );
        }

        // The local pill (#363): leading folder icon, no dot, no status dot,
        // no server icon.
        final localText = find.descendant(
          of: find.byType(Sidebar),
          matching: find.text(p.basename(local.path)),
        );
        expect(localText, findsOneWidget);
        final localRow = find
            .ancestor(of: localText, matching: find.byType(Row))
            .first;
        final folder = find.descendant(
          of: localRow,
          matching: find.byIcon(LucideIcons.folder),
        );
        expect(folder, findsOneWidget);
        expect(
          tester.getTopRight(folder).dx,
          lessThan(tester.getTopLeft(localText).dx),
        );
        expect(
          find.descendant(of: localRow, matching: find.byType(OmDot)),
          findsNothing,
        );
        expect(
          find.descendant(of: localRow, matching: find.byType(StatusDot)),
          findsNothing,
        );
        expect(
          find.descendant(
            of: localRow,
            matching: find.byIcon(LucideIcons.server),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(Sidebar),
            matching: find.byType(StatusDot),
          ),
          findsNWidgets(2),
        );
        expect(h.read(currentVaultProvider), seedHostedRef);
      },
    );

    testWidgets(
      'the hosted pill dot follows that server status entry and shows checking until one exists',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final (h, studio, _) = await _pumpOpen(tester);
        final studioDot = _dotKey(studio.id, 'work');

        // The open probed nas: connected. The picker probed studio (#105
        // AC1): connected too.
        expect(
          _dot(tester, _dotKey(fakeServerId, 'seed')).state,
          StatusDotState.connected,
        );
        expect(
          h.read(hostedConnectionStatusProvider(studio.id)),
          HostedConnectionStatus.connected,
        );
        expect(_dot(tester, studioDot).state, StatusDotState.connected);

        // With no entry for studio the dot shows checking.
        h.read(hostedConnectionStatusProvider(studio.id).notifier).state = null;
        await pumpFrames(tester);
        expect(_dot(tester, studioDot).state, StatusDotState.checking);
        expect(find.bySemanticsLabel(RegExp('checking')), findsOneWidget);

        for (final (status, state, label) in [
          (
            HostedConnectionStatus.unreachable,
            StatusDotState.cantReach,
            "can't reach studio",
          ),
          (
            HostedConnectionStatus.tokenRejected,
            StatusDotState.tokenRejected,
            'studio rejected the access token',
          ),
          (
            HostedConnectionStatus.connected,
            StatusDotState.connected,
            'connected',
          ),
        ]) {
          h.read(hostedConnectionStatusProvider(studio.id).notifier).state =
              status;
          await pumpFrames(tester);
          expect(_dot(tester, studioDot).state, state, reason: '$status');
          expect(
            find.descendant(
              of: find.byKey(_pillKey(studio.id, 'work')),
              matching: find.bySemanticsLabel(RegExp(RegExp.escape(label))),
            ),
            findsOneWidget,
            reason: '$status',
          );
        }
        // Another server's entry never moves this dot.
        h.read(hostedConnectionStatusProvider(fakeServerId).notifier).state =
            HostedConnectionStatus.unreachable;
        await pumpFrames(tester);
        expect(_dot(tester, studioDot).state, StatusDotState.connected);
        expect(
          _dot(tester, _dotKey(fakeServerId, 'seed')).state,
          StatusDotState.cantReach,
        );
        semantics.dispose();
      },
    );
  });

  group('hosted pill taps (AC10)', () {
    testWidgets(
      'a hosted pill tap the guard allows runs the hosted open path and switches to that vault',
      (tester) async {
        final (h, studio, guardCalls) = await _pumpOpen(tester);

        await _tapAndSettle(tester, find.byKey(_pillKey(studio.id, 'work')));

        expect(guardCalls, hasLength(1));
        expect(h.read(currentVaultProvider), studio.ref('work'));
        expect(
          studio.server.requests
              .take(2)
              .map((r) => '${r.method} ${r.url.path}'),
          ['GET /api/v1/info', 'GET /vaults/work/api/v1/info'],
        );
        expect(h.read(settingsProvider).lastVaultRef, studio.ref('work'));
        expect(find.byKey(_snack), findsNothing);
        expect(find.byType(Workspace), findsOneWidget);
      },
    );

    testWidgets(
      'a hosted pill tap the guard refuses opens nothing and sends no request',
      (tester) async {
        final (h, studio, guardCalls) = await _pumpOpen(
          tester,
          guardAllows: false,
        );

        await _tapAndSettle(tester, find.byKey(_pillKey(studio.id, 'work')));

        expect(guardCalls, hasLength(1));
        expect(studio.server.requests, isEmpty);
        expect(h.read(currentVaultProvider), seedHostedRef);
        expect(find.byKey(_snack), findsNothing);
      },
    );

    final failures = <(String, void Function(HostedServerFixture s), String, String?)>[
      (
        'a hosted pill that cannot reach its server keeps the vault open and offers retry',
        (s) => s.server.failure = FakeServerFailure.refused,
        "can't reach studio",
        'retry',
      ),
      (
        'a hosted pill whose token is rejected keeps the vault open and offers update token',
        (s) => s.server.token = 'rotated-on-the-server',
        'studio rejected the access token',
        'update token',
      ),
      (
        'a hosted pill whose vault is gone keeps the vault open and offers remove from recents',
        (s) => s.server.removeVault('work'),
        'work is no longer on studio',
        'remove from recents',
      ),
      (
        'a hosted pill on a mismatched api shows the L9 message with no action',
        (s) => s.server.route(
          'GET',
          '/api/v1/info',
          json: {'api_version': 2, 'server_version': '0.9.0'},
        ),
        _l9Studio,
        null,
      ),
      (
        'a hosted pill whose schema the server refuses shows the server error text with no action',
        (s) => s.server.route(
          'GET',
          '/vaults/work/api/v1/info',
          status: 500,
          json: {
            'error': {'code': 'internal', 'message': _schemaText},
          },
        ),
        _schemaText,
        null,
      ),
    ];

    for (final (name, setUp, copy, action) in failures) {
      testWidgets(name, (tester) async {
        final (h, studio, guardCalls) = await _pumpOpen(tester);
        setUp(studio);

        await _tapAndSettle(tester, find.byKey(_pillKey(studio.id, 'work')));

        expect(guardCalls, hasLength(1));
        expect(h.read(currentVaultProvider), seedHostedRef);
        expect(find.byType(Workspace), findsOneWidget);
        expect(find.byKey(_snack), findsOneWidget);
        expect(
          find.descendant(of: find.byKey(_snack), matching: find.text(copy)),
          findsOneWidget,
        );
        final actions = find.descendant(
          of: find.byKey(_snack),
          matching: find.byType(SnackBarAction),
        );
        if (action == null) {
          expect(actions, findsNothing);
        } else {
          expect(actions, findsOneWidget);
          final a = tester.widget<SnackBarAction>(actions);
          expect(a.label, action);
          expect(a.textColor, OmColors.info);
        }
        expect(
          h.read(recentRowOutcomeProvider(studio.ref('work'))),
          isA<RecentRowFailed>().having(
            (r) => r.failure.message,
            'message',
            copy,
          ),
        );
      });
    }

    testWidgets('retry on the cant reach snackbar re-runs the open', (
      tester,
    ) async {
      final (h, studio, _) = await _pumpOpen(tester);
      studio.server.failure = FakeServerFailure.refused;
      await _tapAndSettle(tester, find.byKey(_pillKey(studio.id, 'work')));
      expect(h.read(currentVaultProvider), seedHostedRef);

      studio.server.failure = null;
      final before = studio.server.requests.length;
      await _tapAndSettle(
        tester,
        find.descendant(of: find.byKey(_snack), matching: find.text('retry')),
      );

      expect(studio.server.requests.length, greaterThan(before));
      expect(h.read(currentVaultProvider), studio.ref('work'));
    });

    testWidgets(
      'update token on the rejected snackbar calls the update token seam with the server id',
      (tester) async {
        final calls = <String>[];
        final (h, studio, _) = await _pumpOpen(tester, updateTokenCalls: calls);
        studio.server.token = 'rotated-on-the-server';
        await _tapAndSettle(tester, find.byKey(_pillKey(studio.id, 'work')));

        await _tapAndSettle(
          tester,
          find.descendant(
            of: find.byKey(_snack),
            matching: find.text('update token'),
          ),
        );

        expect(calls, [studio.id]);
        expect(h.read(currentVaultProvider), seedHostedRef);
      },
    );

    testWidgets(
      'remove from recents on the vault gone snackbar drops that entry',
      (tester) async {
        final (h, studio, _) = await _pumpOpen(tester);
        studio.server.removeVault('work');
        await _tapAndSettle(tester, find.byKey(_pillKey(studio.id, 'work')));

        await _tapAndSettle(
          tester,
          find.descendant(
            of: find.byKey(_snack),
            matching: find.text('remove from recents'),
          ),
        );

        final recents = h.read(settingsProvider).recentRefs;
        expect(recents, isNot(contains(studio.ref('work'))));
        expect(recents, contains(seedHostedRef));
        expect(find.byKey(_pillKey(studio.id, 'work')), findsNothing);
        expect(h.read(currentVaultProvider), seedHostedRef);
      },
    );

    test('the default hosted http client seam is a real client', () {
      // No override: the seam's own default (D17 traffic goes through it).
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(hostedHttpClientProvider), isA<http.Client>());
      expect(c.read(hostedHttpClientProvider), isNot(isA<MockClient>()));
    });
  });
}
