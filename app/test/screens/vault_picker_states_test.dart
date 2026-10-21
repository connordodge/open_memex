// WI #97 (H3): vault picker states (board A3 states 1 to 3, pack
// design/66-hosted-vault/packs/97.md). Hosted row states from probes and
// from the opening state, launch outcomes from the row outcome per entry
// (#96's `recentRowOutcomeProvider`, injected as `RecentRowFailed` of #96's
// hosted failures, or `RecentRowOpening`), binary not found and no saved
// servers.
//
// Seams: test/support/vault_picker_harness.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:path/path.dart' as p;

import '../support/fake_vault_server.dart';
import '../support/vault_folders.dart';
import '../support/vault_picker_harness.dart';

const _hostedMemex = HostedVaultRef(fakeServerId, 'memex');

/// #96's unreachable failure for nas/memex, with #96's copy.
const _unreachable = HostedServerUnreachable(
  _hostedMemex,
  fakeServerName,
  "can't reach nas",
);

/// Keeps nas's probe in flight, so the row shows only its recorded outcome.
void _holdNas(Map<String, FakeVaultServer> s) => s[fakeServerId]!.hold();

void main() {
  wi97HoldFontFetches();

  group('hosted row states', () {
    testWidgets(
      'an unreachable hosted row has warn styling cant reach and a retry that reruns the open',
      (tester) async {
        final env = await pumpVaultPicker(
          tester,
          recents: const [_hostedMemex],
          beforePump: (s) =>
              s[fakeServerId]!.failure = FakeServerFailure.refused,
          configureOpener: (o) => o.onOpen = (_) async => _unreachable,
        );

        expect(wi97Inside('recent-row-0', find.text('memex')), findsOneWidget);
        expect(
          wi97TextColorIn(tester, 'recent-row-0', "can't reach nas"),
          OmColors.warn,
        );
        final icon = wi97Inside(
          'recent-row-0',
          find.byIcon(LucideIcons.wifiOff),
        );
        expect(icon, findsOneWidget);
        expect(tester.widget<Icon>(icon).color, OmColors.warn);
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.cantReach);
        expect(
          wi97Inside('recent-row-retry-0', find.text('retry')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('recent-row-remove-0')), findsOneWidget);

        await tester.tap(find.byKey(const Key('recent-row-retry-0')));
        await wi97Settle(tester);
        expect(env.opener.opened, [_hostedMemex]);

        await tester.tap(find.byKey(const Key('recent-row-retry-0')));
        await wi97Settle(tester);
        expect(env.opener.opened, [_hostedMemex, _hostedMemex]);
      },
    );

    testWidgets(
      'a token rejected hosted row has the danger dot and update token calls editServer',
      (tester) async {
        final env = await pumpVaultPicker(
          tester,
          recents: const [_hostedMemex],
          beforePump: (s) => s[fakeServerId]!.token = 'rotated-on-server',
        );

        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.tokenRejected);
        expect(
          wi97TextColorIn(
            tester,
            'recent-row-0',
            'nas rejected the access token',
          ),
          OmColors.danger,
        );
        expect(
          wi97Inside('recent-row-0', find.byIcon(LucideIcons.keyRound)),
          findsOneWidget,
        );
        expect(
          wi97Inside('recent-row-update-token-0', find.text('update token')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('recent-row-update-token-0')));
        await wi97Settle(tester);
        expect(env.actions.calls, ['editServer $fakeServerId']);
        expect(env.opener.opened, isEmpty);
      },
    );

    testWidgets(
      'an opening hosted row shows a spinner and connecting to the server with no x',
      (tester) async {
        final pending = Completer<VaultOpenOutcome>();
        final env = await pumpVaultPicker(
          tester,
          recents: const [_hostedMemex],
          configureOpener: (o) => o.onOpen = (_) => pending.future,
        );

        await tester.tap(find.byKey(const Key('recent-row-0')));
        await wi97Settle(tester);

        expect(env.opener.opened, [_hostedMemex]);
        expect(find.text('connecting to nas…'), findsOneWidget);
        expect(find.byIcon(LucideIcons.loader2), findsOneWidget);
        expect(find.byKey(const Key('recent-row-remove-0')), findsNothing);

        pending.complete(const VaultOpenFailure('done'));
        await wi97Settle(tester);
        expect(find.text('connecting to nas…'), findsNothing);
      },
    );

    testWidgets('a hosted open that fails unreachable records it on the row', (
      tester,
    ) async {
      final env = await pumpVaultPicker(
        tester,
        recents: const [_hostedMemex],
        configureOpener: (o) => o.onOpen = (_) async => _unreachable,
      );
      // The probe found the server, so the row starts connected.
      expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.connected);

      await tester.tap(find.byKey(const Key('recent-row-0')));
      await wi97Settle(tester);

      expect(
        wi97Inside('recent-row-0', find.text("can't reach nas")),
        findsOneWidget,
      );
      expect(find.byKey(const Key('recent-row-retry-0')), findsOneWidget);
      expect(
        env.container.read(recentRowOutcomeProvider(_hostedMemex)),
        isA<RecentRowFailed>().having(
          (r) => r.failure,
          'failure',
          isA<HostedServerUnreachable>(),
        ),
      );
    });
  });

  group('launch outcomes', () {
    testWidgets(
      'a hosted last vault shows the opening row while launch runs then its outcome',
      (tester) async {
        final launch = Completer<VaultOpenOutcome>();
        final env = await pumpVaultPicker(
          tester,
          recents: const [_hostedMemex],
          last: _hostedMemex,
          beforePump: _holdNas,
          configureOpener: (o) => o.onLaunch = () => launch.future,
        );

        expect(env.opener.launches, 1);
        expect(find.text('connecting to nas…'), findsOneWidget);
        expect(find.byKey(const Key('recent-row-remove-0')), findsNothing);

        launch.complete(_unreachable);
        await wi97Settle(tester);

        expect(find.text('connecting to nas…'), findsNothing);
        expect(
          wi97Inside('recent-row-0', find.text("can't reach nas")),
          findsOneWidget,
        );
        expect(find.byKey(const Key('recent-row-retry-0')), findsOneWidget);
      },
    );

    testWidgets('a recorded unreachable outcome shows the error and retry', (
      tester,
    ) async {
      final env = await pumpVaultPicker(
        tester,
        recents: const [_hostedMemex],
        beforePump: _holdNas,
        recorded: {_hostedMemex: const RecentRowFailed(_unreachable)},
        configureOpener: (o) =>
            o.onOpen = (_) async => const VaultOpenFailure('still down'),
      );

      expect(
        wi97Inside('recent-row-0', find.text("can't reach nas")),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('recent-row-retry-0')));
      await wi97Settle(tester);
      expect(env.opener.opened, [_hostedMemex]);
    });

    testWidgets(
      'a recorded 401 outcome shows the danger dot and update token',
      (tester) async {
        final env = await pumpVaultPicker(
          tester,
          recents: const [_hostedMemex],
          beforePump: _holdNas,
          recorded: {
            _hostedMemex: const RecentRowFailed(
              HostedTokenRejected(
                _hostedMemex,
                fakeServerName,
                'nas rejected the access token',
              ),
            ),
          },
        );

        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.tokenRejected);
        expect(
          wi97Inside(
            'recent-row-0',
            find.text('nas rejected the access token'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('recent-row-update-token-0')));
        await wi97Settle(tester);
        expect(env.actions.calls, ['editServer $fakeServerId']);
      },
    );

    testWidgets(
      'a recorded api mismatch shows the L9 message with no action and the row does not open',
      (tester) async {
        final version = ['0', '9', '3'].join('.');
        final env = await pumpVaultPicker(
          tester,
          recents: const [_hostedMemex],
          beforePump: _holdNas,
          recorded: {
            _hostedMemex: RecentRowFailed(
              HostedApiMismatch(
                _hostedMemex,
                fakeServerName,
                wi97L9(fakeServerName, version),
                serverVersion: version,
              ),
            ),
          },
        );

        final text = wi97L9('nas', '0.9.3');
        expect(wi97Inside('recent-row-0', find.text(text)), findsOneWidget);
        expect(wi97TextColorIn(tester, 'recent-row-0', text), OmColors.danger);
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.tokenRejected);
        expect(
          wi97Inside('recent-row-0', find.byIcon(LucideIcons.alertTriangle)),
          findsOneWidget,
        );
        _expectNoRowAction(0);

        await tester.tap(find.byKey(const Key('recent-row-0')));
        await wi97Settle(tester);
        expect(env.opener.opened, isEmpty);
      },
    );

    testWidgets(
      'a recorded vault gone shows no longer on the server and remove from recents drops the entry',
      (tester) async {
        final local = createVaultFolder();
        final env = await pumpVaultPicker(
          tester,
          recents: [_hostedMemex, LocalVaultRef(local.path)],
          recorded: {
            _hostedMemex: const RecentRowFailed(
              HostedVaultGone(
                _hostedMemex,
                fakeServerName,
                'memex is no longer on nas',
              ),
            ),
          },
        );

        // The server answers; the vault is what is gone.
        expect(
          wi97DotIn(tester, 'server-row-srv-nas'),
          StatusDotState.connected,
        );
        expect(
          wi97Inside('recent-row-0', find.text('memex is no longer on nas')),
          findsOneWidget,
        );
        expect(
          wi97TextColorIn(tester, 'recent-row-0', 'memex is no longer on nas'),
          OmColors.danger,
        );
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.tokenRejected);
        expect(
          wi97Inside('recent-row-0', find.byIcon(LucideIcons.folderX)),
          findsOneWidget,
        );
        expect(find.byKey(const Key('recent-row-retry-0')), findsNothing);
        expect(
          find.byKey(const Key('recent-row-update-token-0')),
          findsNothing,
        );
        expect(
          wi97Inside(
            'recent-row-remove-from-recents-0',
            find.text('remove from recents'),
          ),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const Key('recent-row-remove-from-recents-0')),
        );
        await wi97Settle(tester);

        expect(env.settings.recentRefs, [LocalVaultRef(local.path)]);
        expect(find.text('memex is no longer on nas'), findsNothing);
        expect(env.settings.savedServers.map((s) => s.id), [fakeServerId]);
        expect(env.opener.opened, isEmpty);
      },
    );

    testWidgets(
      'a recorded schema refused shows the server error text with no action and the row does not open',
      (tester) async {
        const serverText = 'vault schema 7 is newer than this server supports';
        final env = await pumpVaultPicker(
          tester,
          recents: const [_hostedMemex],
          beforePump: _holdNas,
          recorded: {
            _hostedMemex: const RecentRowFailed(
              HostedSchemaRefused(_hostedMemex, fakeServerName, serverText),
            ),
          },
        );

        expect(
          wi97Inside('recent-row-0', find.text(serverText)),
          findsOneWidget,
        );
        expect(
          wi97TextColorIn(tester, 'recent-row-0', serverText),
          OmColors.danger,
        );
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.tokenRejected);
        _expectNoRowAction(0);

        await tester.tap(find.byKey(const Key('recent-row-0')));
        await wi97Settle(tester);
        expect(env.opener.opened, isEmpty);
      },
    );

    testWidgets(
      'a recorded not memex outcome shows the danger dot and the isnt a memex vault server text',
      (tester) async {
        const text = "http://nas.local:7878 isn't a memex vault server";
        final env = await pumpVaultPicker(
          tester,
          recents: const [_hostedMemex],
          beforePump: _holdNas,
          recorded: {
            _hostedMemex: const RecentRowFailed(
              HostedNotMemexServer(_hostedMemex, fakeServerName, text),
            ),
          },
        );

        expect(wi97Inside('recent-row-0', find.text(text)), findsOneWidget);
        expect(wi97TextColorIn(tester, 'recent-row-0', text), OmColors.danger);
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.tokenRejected);
        // The probe is still in flight, so the server row has no verdict.
        expect(
          wi97DotIn(tester, 'server-row-srv-nas'),
          StatusDotState.checking,
        );
        _expectNoRowAction(0);

        await tester.tap(find.byKey(const Key('recent-row-0')));
        await wi97Settle(tester);
        expect(env.opener.opened, isEmpty);
      },
    );

    testWidgets(
      'a recorded opening outcome shows the spinner and connecting to the server with no x',
      (tester) async {
        final env = await pumpVaultPicker(
          tester,
          recents: const [_hostedMemex],
          recorded: {_hostedMemex: const RecentRowOpening()},
        );

        expect(
          wi97Inside('recent-row-0', find.text('connecting to nas…')),
          findsOneWidget,
        );
        expect(
          wi97Inside('recent-row-0', find.byIcon(LucideIcons.loader2)),
          findsOneWidget,
        );
        expect(find.byKey(const Key('recent-row-remove-0')), findsNothing);
        expect(env.opener.opened, isEmpty);

        // The open controller clears it when the open ends.
        env.container
                .read(recentRowOutcomeProvider(_hostedMemex).notifier)
                .state =
            null;
        await wi97Settle(tester);
        expect(find.text('connecting to nas…'), findsNothing);
        expect(
          wi97Inside('recent-row-0', find.text('nas · nas.local:7878')),
          findsOneWidget,
        );
      },
    );

    testWidgets('a recorded outcome shows only on its own entry', (
      tester,
    ) async {
      const other = HostedVaultRef(fakeServerId, 'work');
      await pumpVaultPicker(
        tester,
        recents: const [_hostedMemex, other],
        recorded: {
          _hostedMemex: const RecentRowFailed(
            HostedVaultGone(
              _hostedMemex,
              fakeServerName,
              'memex is no longer on nas',
            ),
          ),
        },
      );

      expect(
        wi97Inside('recent-row-0', find.text('memex is no longer on nas')),
        findsOneWidget,
      );
      expect(
        wi97Inside('recent-row-1', find.text('nas · nas.local:7878')),
        findsOneWidget,
      );
      expect(wi97DotIn(tester, 'recent-row-1'), StatusDotState.connected);
    });
  });

  group('binary not found', () {
    testWidgets(
      'without a binary the local buttons are disabled and open vault on a server is primary',
      (tester) async {
        await pumpVaultPicker(tester, binary: false);

        expect(wi97ButtonIn(tester, 'vault-picker-create').onPressed, isNull);
        expect(wi97ButtonIn(tester, 'vault-picker-open').onPressed, isNull);
        final onServer = wi97ButtonIn(tester, 'vault-picker-open-on-server');
        expect(onServer.kind, OmButtonKind.primary);
        expect(onServer.onPressed, isNotNull);
        final createOnServer = wi97ButtonIn(
          tester,
          'vault-picker-create-on-server',
        );
        expect(createOnServer.kind, OmButtonKind.secondary);
        expect(createOnServer.onPressed, isNotNull);
      },
    );

    testWidgets(
      'without a binary the card says hosted vaults do not need it and offers locate',
      (tester) async {
        await pumpVaultPicker(tester, binary: false);

        expect(find.text('memex binary not found'), findsOneWidget);
        expect(
          find.text("local vaults need it. hosted vaults don't."),
          findsOneWidget,
        );
        expect(find.text('locate memex binary…'), findsOneWidget);
      },
    );

    testWidgets(
      'without a binary local rows need the memex binary do not open and x still removes them',
      (tester) async {
        final local = createVaultFolder();
        final env = await pumpVaultPicker(
          tester,
          binary: false,
          recents: [LocalVaultRef(local.path), _hostedMemex],
        );

        expect(
          wi97Inside('recent-row-0', find.text('needs the memex binary')),
          findsOneWidget,
        );
        expect(
          wi97Inside('recent-row-1', find.text('needs the memex binary')),
          findsNothing,
        );

        await tester.tap(find.byKey(const Key('recent-row-0')));
        await wi97Settle(tester);
        expect(env.opener.opened, isEmpty);

        await tester.tap(find.byKey(const Key('recent-row-remove-0')));
        await wi97Settle(tester);
        expect(env.settings.recentRefs, [_hostedMemex]);
        expect(find.text(p.basename(local.path)), findsNothing);
      },
    );

    testWidgets(
      'without a binary hosted rows and server actions behave as with one',
      (tester) async {
        final env = await pumpVaultPicker(
          tester,
          binary: false,
          recents: const [_hostedMemex],
          configureOpener: (o) =>
              o.onOpen = (_) async => const VaultOpenFailure('not yet'),
        );

        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.connected);
        expect(
          wi97Inside('recent-row-0', find.text('needs the memex binary')),
          findsNothing,
        );
        await tester.tap(find.byKey(const Key('recent-row-0')));
        await wi97Settle(tester);
        expect(env.opener.opened, [_hostedMemex]);

        await tester.tap(find.byKey(const Key('vault-picker-open-on-server')));
        await wi97Settle(tester);
        await tester.tap(
          find.byKey(const Key('vault-picker-create-on-server')),
        );
        await wi97Settle(tester);
        await tester.tap(find.byKey(const Key('server-row-edit-srv-nas')));
        await wi97Settle(tester);
        expect(env.actions.calls, [
          'openOnServer',
          'createOnServer',
          'editServer $fakeServerId',
        ]);
      },
    );
  });

  group('no saved servers', () {
    testWidgets(
      'with no saved server SERVERS 0 shows the empty box with connect and set up',
      (tester) async {
        final env = await pumpVaultPicker(tester, savedServers: const []);

        expect(find.text('SERVERS'), findsOneWidget);
        expect(find.text('· 0'), findsOneWidget);
        expect(
          wi97Inside('picker-servers-connect', find.text('+ CONNECT')),
          findsOneWidget,
        );
        expect(
          find.text(
            'no vault servers yet. connect to one to open its vaults on this mac.',
          ),
          findsOneWidget,
        );
        expect(
          wi97Inside(
            'picker-no-servers-connect',
            find.text('connect to a vault server…'),
          ),
          findsOneWidget,
        );
        expect(
          wi97Inside(
            'picker-no-servers-setup',
            find.text('how do I set one up?'),
          ),
          findsOneWidget,
        );
        expect(
          wi97ButtonIn(tester, 'vault-picker-open-on-server').onPressed,
          isNotNull,
        );
        expect(
          wi97ButtonIn(tester, 'vault-picker-create-on-server').onPressed,
          isNotNull,
        );

        await tester.tap(find.byKey(const Key('picker-no-servers-connect')));
        await wi97Settle(tester);
        expect(env.actions.calls, ['connect']);

        await tester.tap(find.byKey(const Key('picker-no-servers-setup')));
        await wi97Settle(tester);
        expect(env.actions.calls, ['connect', 'setUp']);
      },
    );

    testWidgets('with a saved server the empty servers box is absent', (
      tester,
    ) async {
      await pumpVaultPicker(tester);
      expect(find.text('· 1'), findsOneWidget);
      expect(find.byKey(const Key('server-row-srv-nas')), findsOneWidget);
      expect(find.byKey(const Key('picker-no-servers-connect')), findsNothing);
      expect(find.byKey(const Key('picker-no-servers-setup')), findsNothing);
    });
  });
}

/// The row [n] offers no retry, update token or remove from recents.
void _expectNoRowAction(int n) {
  expect(find.byKey(Key('recent-row-retry-$n')), findsNothing);
  expect(find.byKey(Key('recent-row-update-token-$n')), findsNothing);
  expect(find.byKey(Key('recent-row-remove-from-recents-$n')), findsNothing);
}
