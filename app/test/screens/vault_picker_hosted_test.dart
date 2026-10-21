// WI #97 (H3): the redesigned vault picker (boards A1 1280, A2 720 narrow,
// A9 state 2, pack design/66-hosted-vault/packs/97.md). Layout and order,
// the hosted flag, RECENT rows by kind, SERVERS rows (edit, remove confirm),
// picker probes on open and refocus, the picker-actions seam (Req 42) and
// the open calls a row tap makes.
//
// Seams: test/support/vault_picker_harness.dart (FakeVaultServer per saved
// server, FakeTokenStore, FakeAppFocus, FakeClock, recording picker actions
// and open controller).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:path/path.dart' as p;

import '../support/fake_vault_server.dart';
import '../support/vault_folders.dart';
import '../support/font_fetch_hold.dart';
import '../support/vault_picker_harness.dart';

const _hostedMemex = HostedVaultRef(fakeServerId, 'memex');

const _subtitle =
    'a vault is a folder of your notes. open one on this mac, or one hosted '
    'by a vault server.';

double _top(Finder f) => f.evaluate().isEmpty
    ? throw TestFailure('not found: $f')
    : (f.evaluate().first.renderObject! as RenderBox)
          .localToGlobal(Offset.zero)
          .dy;

void main() {
  holdFontFetches();

  group('layout', () {
    for (final (name, size) in [
      (
        'with the flag on and one saved server the picker shows its sections in order at 1280 by 800',
        const Size(1280, 800),
      ),
      (
        'with the flag on and one saved server the picker shows its sections in order at 720 by 900',
        const Size(720, 900),
      ),
    ]) {
      testWidgets(name, (tester) async {
        final local = createVaultFolder();
        await pumpVaultPicker(
          tester,
          size: size,
          recents: [_hostedMemex, LocalVaultRef(local.path)],
        );

        expect(tester.takeException(), isNull);
        expect(find.text('CHOOSE A VAULT'), findsOneWidget);
        expect(find.text(_subtitle), findsOneWidget);

        final binary = find.textContaining('memex binary');
        final recent = find.text('RECENT');
        final servers = find.text('SERVERS');
        final thisMac = find.text('THIS MAC');
        final vaultServer = find.text('VAULT SERVER');
        for (final f in [binary, recent, servers, thisMac, vaultServer]) {
          expect(f, findsOneWidget);
        }
        expect(find.text('· 1'), findsOneWidget);
        expect(
          wi97Inside('picker-servers-connect', find.text('+ CONNECT')),
          findsOneWidget,
        );

        expect(_top(binary), lessThan(_top(recent)));
        expect(_top(recent), lessThan(_top(servers)));
        expect(_top(servers), lessThan(_top(thisMac)));
        expect(_top(thisMac), lessThan(_top(vaultServer)));
        // The SERVERS rows sit between the header and the grid.
        final serverRow = find.byKey(const Key('server-row-srv-nas'));
        expect(_top(serverRow), greaterThan(_top(servers)));
        expect(_top(serverRow), lessThan(_top(thisMac)));

        for (final (key, label) in [
          ('vault-picker-create', 'create local vault…'),
          ('vault-picker-open', 'open local vault…'),
          ('vault-picker-open-on-server', 'open vault on a server…'),
          ('vault-picker-create-on-server', 'create vault on a server…'),
        ]) {
          expect(
            wi97Inside(key, find.text(label)),
            findsOneWidget,
            reason: key,
          );
        }
        // THIS MAC buttons share the THIS MAC row; VAULT SERVER buttons the
        // row below.
        final create = find.byKey(const Key('vault-picker-create'));
        final open = find.byKey(const Key('vault-picker-open'));
        final onServer = find.byKey(const Key('vault-picker-open-on-server'));
        final createOnServer = find.byKey(
          const Key('vault-picker-create-on-server'),
        );
        expect(_top(create), _top(open));
        expect(_top(onServer), _top(createOnServer));
        expect(_top(onServer), greaterThan(_top(create)));
        expect(tester.getSize(create).height, 36);
        expect(tester.getSize(onServer).height, 36);
        expect(
          tester.getTopLeft(create).dx,
          lessThan(tester.getTopLeft(open).dx),
        );
        expect(
          tester.getTopLeft(onServer).dx,
          lessThan(tester.getTopLeft(createOnServer).dx),
        );

        // Pack 97: a 560 px content column at both sizes.
        expect(tester.getSize(serverRow).width, 560);
        expect(
          tester.getSize(find.byKey(const Key('recent-row-0'))).width,
          560,
        );

        // Button kinds with a binary: create local is primary, the rest
        // secondary.
        expect(
          wi97ButtonIn(tester, 'vault-picker-create').kind,
          OmButtonKind.primary,
        );
        expect(
          wi97ButtonIn(tester, 'vault-picker-open').kind,
          OmButtonKind.secondary,
        );
        expect(
          wi97ButtonIn(tester, 'vault-picker-open-on-server').kind,
          OmButtonKind.secondary,
        );
        expect(
          wi97ButtonIn(tester, 'vault-picker-create-on-server').kind,
          OmButtonKind.secondary,
        );
      });
    }

    testWidgets(
      'two saved servers at 720 by 900 show SERVERS 2 and both rows without overflow',
      (tester) async {
        await pumpVaultPicker(
          tester,
          size: const Size(720, 900),
          savedServers: const [wi97Nas, wi97Mini],
          recents: const [_hostedMemex, HostedVaultRef('srv-mini', 'studio')],
        );
        expect(tester.takeException(), isNull);
        expect(find.text('· 2'), findsOneWidget);
        expect(find.byKey(const Key('server-row-srv-nas')), findsOneWidget);
        expect(find.byKey(const Key('server-row-srv-mini')), findsOneWidget);
        expect(
          wi97Inside(
            'server-row-srv-mini',
            find.text('http://100.101.12.4:7878'),
          ),
          findsOneWidget,
        );
        expect(
          wi97Inside(
            'recent-row-1',
            find.text('studio-mini · 100.101.12.4:7878'),
          ),
          findsOneWidget,
        );
      },
    );
  });

  group('hosted flag', () {
    testWidgets(
      'with the flag off the SERVERS section and VAULT SERVER row are absent and no probe is sent',
      (tester) async {
        final local = createVaultFolder();
        final env = await pumpVaultPicker(
          tester,
          hosted: false,
          recents: [LocalVaultRef(local.path)],
        );

        expect(find.text('SERVERS'), findsNothing);
        expect(find.byKey(const Key('picker-servers-connect')), findsNothing);
        expect(find.byKey(const Key('server-row-srv-nas')), findsNothing);
        expect(find.text('VAULT SERVER'), findsNothing);
        expect(
          find.byKey(const Key('vault-picker-open-on-server')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('vault-picker-create-on-server')),
          findsNothing,
        );
        expect(
          find.text(
            'no vault servers yet. connect to one to open its vaults on this mac.',
          ),
          findsNothing,
        );

        expect(find.text('THIS MAC'), findsOneWidget);
        expect(find.byKey(const Key('vault-picker-create')), findsOneWidget);
        expect(find.byKey(const Key('vault-picker-open')), findsOneWidget);
        expect(find.text('RECENT'), findsOneWidget);
        expect(find.text(p.basename(local.path)), findsOneWidget);

        // No probe on open, and none on a refocus.
        expect(env.infoRequests(fakeServerId), isEmpty);
        env.focus.set(false);
        await wi97Settle(tester);
        env.focus.set(true);
        await wi97Settle(tester);
        expect(env.servers[fakeServerId]!.requests, isEmpty);
      },
    );
  });

  group('recent rows', () {
    testWidgets(
      'a local recent row shows the folder icon its name and the path in fg2',
      (tester) async {
        final local = createVaultFolder();
        await pumpVaultPicker(tester, recents: [LocalVaultRef(local.path)]);

        expect(
          wi97Inside('recent-row-0', find.byIcon(LucideIcons.folder)),
          findsOneWidget,
        );
        expect(
          wi97Inside('recent-row-0', find.text(p.basename(local.path))),
          findsOneWidget,
        );
        expect(
          wi97TextColorIn(tester, 'recent-row-0', local.path),
          OmColors.fg2,
        );
        expect(
          wi97Inside('recent-row-0', find.byType(StatusDot)),
          findsNothing,
        );
      },
    );

    testWidgets(
      'a local recent row with a missing folder shows the folder x icon in danger',
      (tester) async {
        final missing = p.join(createPlainFolder().path, 'gone');
        await pumpVaultPicker(tester, recents: [LocalVaultRef(missing)]);

        final icon = wi97Inside(
          'recent-row-0',
          find.byIcon(LucideIcons.folderX),
        );
        expect(icon, findsOneWidget);
        expect(tester.widget<Icon>(icon).color, OmColors.danger);
        expect(wi97Inside('recent-row-0', find.text('gone')), findsOneWidget);
      },
    );

    testWidgets(
      'a hosted recent row shows the server icon vault name status dot and server host',
      (tester) async {
        await pumpVaultPicker(tester, recents: const [_hostedMemex]);

        expect(
          wi97Inside('recent-row-0', find.byIcon(LucideIcons.server)),
          findsOneWidget,
        );
        expect(wi97Inside('recent-row-0', find.text('memex')), findsOneWidget);
        expect(
          wi97Inside('recent-row-0', find.byType(StatusDot)),
          findsOneWidget,
        );
        expect(
          wi97Inside('recent-row-0', find.text('nas · nas.local:7878')),
          findsOneWidget,
        );
        expect(
          wi97TextColorIn(tester, 'recent-row-0', 'nas · nas.local:7878'),
          OmColors.fg2,
        );
      },
    );

    testWidgets('the x on a hosted row removes exactly that entry', (
      tester,
    ) async {
      final local = createVaultFolder();
      const other = HostedVaultRef(fakeServerId, 'work');
      final env = await pumpVaultPicker(
        tester,
        recents: [_hostedMemex, LocalVaultRef(local.path), other],
      );

      await tester.tap(find.byKey(const Key('recent-row-remove-0')));
      await wi97Settle(tester);

      expect(env.settings.recentRefs, [LocalVaultRef(local.path), other]);
      expect(find.text('memex'), findsNothing);
      expect(find.text('work'), findsOneWidget);
      expect(find.text(p.basename(local.path)), findsOneWidget);
      // The saved server stays.
      expect(env.settings.savedServers.map((s) => s.id), [fakeServerId]);
    });

    testWidgets('the x on a local row removes exactly that entry', (
      tester,
    ) async {
      final local = createVaultFolder();
      final env = await pumpVaultPicker(
        tester,
        recents: [_hostedMemex, LocalVaultRef(local.path)],
      );

      await tester.tap(find.byKey(const Key('recent-row-remove-1')));
      await wi97Settle(tester);

      expect(env.settings.recentRefs, [_hostedMemex]);
      expect(find.text(p.basename(local.path)), findsNothing);
      expect(find.text('memex'), findsOneWidget);
    });
  });

  group('server rows', () {
    testWidgets('a server row shows a status dot its name and URL', (
      tester,
    ) async {
      await pumpVaultPicker(tester);

      expect(
        wi97Inside('server-row-srv-nas', find.byIcon(LucideIcons.server)),
        findsOneWidget,
      );
      expect(
        wi97Inside('server-row-srv-nas', find.text('nas')),
        findsOneWidget,
      );
      expect(
        wi97Inside('server-row-srv-nas', find.text('http://nas.local:7878')),
        findsOneWidget,
      );
      expect(
        wi97Inside('server-row-srv-nas', find.byType(StatusDot)),
        findsOneWidget,
      );
      expect(find.byKey(const Key('server-row-edit-srv-nas')), findsOneWidget);
      expect(
        find.byKey(const Key('server-row-remove-srv-nas')),
        findsOneWidget,
      );
    });

    testWidgets('the pencil on a server row calls editServer with its id', (
      tester,
    ) async {
      final env = await pumpVaultPicker(
        tester,
        savedServers: const [wi97Nas, wi97Mini],
      );

      await tester.tap(find.byKey(const Key('server-row-edit-srv-mini')));
      await wi97Settle(tester);

      expect(env.actions.calls, ['editServer srv-mini']);
    });

    testWidgets(
      'the trash opens the remove server confirm with the board copy',
      (tester) async {
        final env = await pumpVaultPicker(tester);

        await tester.tap(find.byKey(const Key('server-row-remove-srv-nas')));
        await wi97Settle(tester);

        expect(find.text('REMOVE SERVER'), findsOneWidget);
        expect(find.text('remove nas?'), findsOneWidget);
        expect(
          find.text(
            'its vaults leave your recents. nothing on the server is touched.',
          ),
          findsOneWidget,
        );
        expect(
          wi97Inside('remove-server-cancel', find.text('cancel')),
          findsOneWidget,
        );
        expect(
          wi97Inside('remove-server-confirm', find.text('remove')),
          findsOneWidget,
        );
        expect(
          wi97ButtonIn(tester, 'remove-server-confirm').kind,
          OmButtonKind.danger,
        );
        expect(
          wi97ButtonIn(tester, 'remove-server-cancel').kind,
          OmButtonKind.ghost,
        );
        // Opening the confirm changes nothing yet.
        expect(env.tokens.tokens, contains(fakeServerId));
        expect(env.settings.savedServers, hasLength(1));
      },
    );

    testWidgets(
      'remove in the confirm removes the server its token and its hosted rows',
      (tester) async {
        final local = createVaultFolder();
        final env = await pumpVaultPicker(
          tester,
          savedServers: const [wi97Nas, wi97Mini],
          recents: [
            _hostedMemex,
            LocalVaultRef(local.path),
            const HostedVaultRef('srv-mini', 'studio'),
            const HostedVaultRef(fakeServerId, 'work'),
          ],
        );

        await tester.tap(find.byKey(const Key('server-row-remove-srv-nas')));
        await wi97Settle(tester);
        await tester.tap(find.byKey(const Key('remove-server-confirm')));
        await wi97Settle(tester);

        expect(env.tokens.tokens.containsKey(fakeServerId), isFalse);
        expect(env.tokens.calls, contains('delete $fakeServerId'));
        expect(env.tokens.tokens['srv-mini'], wi97TokenFor('srv-mini'));
        expect(env.settings.savedServers.map((s) => s.id), ['srv-mini']);
        expect(env.settings.recentRefs, [
          LocalVaultRef(local.path),
          const HostedVaultRef('srv-mini', 'studio'),
        ]);

        expect(find.text('REMOVE SERVER'), findsNothing);
        expect(find.byKey(const Key('server-row-srv-nas')), findsNothing);
        expect(find.byKey(const Key('server-row-srv-mini')), findsOneWidget);
        expect(find.text('memex'), findsNothing);
        expect(find.text('work'), findsNothing);
        expect(find.text('studio'), findsOneWidget);
        expect(find.text('· 1'), findsOneWidget);
      },
    );

    testWidgets('cancel in the remove confirm changes nothing', (tester) async {
      final env = await pumpVaultPicker(tester, recents: const [_hostedMemex]);

      await tester.tap(find.byKey(const Key('server-row-remove-srv-nas')));
      await wi97Settle(tester);
      await tester.tap(find.byKey(const Key('remove-server-cancel')));
      await wi97Settle(tester);

      expect(find.text('REMOVE SERVER'), findsNothing);
      expect(env.tokens.tokens[fakeServerId], wi97TokenFor(fakeServerId));
      expect(env.tokens.calls.where((c) => c.startsWith('delete')), isEmpty);
      expect(env.settings.savedServers.map((s) => s.id), [fakeServerId]);
      expect(env.settings.recentRefs, [_hostedMemex]);
      expect(find.byKey(const Key('server-row-srv-nas')), findsOneWidget);
      expect(find.text('memex'), findsOneWidget);
    });
  });

  group('probes', () {
    testWidgets(
      'opening the picker sends exactly one info probe to each saved server',
      (tester) async {
        final env = await pumpVaultPicker(
          tester,
          savedServers: const [wi97Nas, wi97Mini],
          recents: const [_hostedMemex],
        );
        await wi97Settle(tester);

        expect(env.infoRequests(fakeServerId), hasLength(1));
        expect(env.infoRequests('srv-mini'), hasLength(1));
        expect(env.servers[fakeServerId]!.requests, hasLength(1));
        expect(env.servers['srv-mini']!.requests, hasLength(1));
      },
    );

    testWidgets(
      'server and hosted rows show checking until the probe returns then connected',
      (tester) async {
        final env = await pumpVaultPicker(
          tester,
          recents: const [_hostedMemex],
          beforePump: (s) => s[fakeServerId]!.hold(),
        );

        expect(env.infoRequests(fakeServerId), hasLength(1));
        expect(
          wi97DotIn(tester, 'server-row-srv-nas'),
          StatusDotState.checking,
        );
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.checking);

        env.servers[fakeServerId]!.release();
        await wi97Settle(tester);

        expect(
          wi97DotIn(tester, 'server-row-srv-nas'),
          StatusDotState.connected,
        );
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.connected);
        expect(
          wi97Inside('recent-row-0', find.text('nas · nas.local:7878')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a refused probe shows cant reach on the server row and its hosted rows',
      (tester) async {
        final local = createVaultFolder();
        await pumpVaultPicker(
          tester,
          recents: [_hostedMemex, LocalVaultRef(local.path)],
          beforePump: (s) =>
              s[fakeServerId]!.failure = FakeServerFailure.refused,
        );

        expect(
          wi97DotIn(tester, 'server-row-srv-nas'),
          StatusDotState.cantReach,
        );
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.cantReach);
        expect(
          wi97Inside('recent-row-0', find.text("can't reach nas")),
          findsOneWidget,
        );
        // The local row is untouched.
        expect(
          wi97Inside('recent-row-1', find.byType(StatusDot)),
          findsNothing,
        );
        expect(
          wi97Inside('recent-row-1', find.text("can't reach nas")),
          findsNothing,
        );
      },
    );

    testWidgets(
      'a 401 probe shows token rejected on the server row and its hosted rows',
      (tester) async {
        await pumpVaultPicker(
          tester,
          recents: const [_hostedMemex],
          beforePump: (s) => s[fakeServerId]!.token = 'rotated-on-server',
        );

        expect(
          wi97DotIn(tester, 'server-row-srv-nas'),
          StatusDotState.tokenRejected,
        );
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.tokenRejected);
        expect(
          wi97Inside(
            'recent-row-0',
            find.text('nas rejected the access token'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a notMemex probe shows the danger dot and the isnt a memex vault server text on both rows',
      (tester) async {
        await pumpVaultPicker(
          tester,
          recents: const [_hostedMemex],
          beforePump: (s) => s[fakeServerId]!.servesHtml = true,
        );

        const text = "http://nas.local:7878 isn't a memex vault server";
        expect(
          wi97DotIn(tester, 'server-row-srv-nas'),
          StatusDotState.tokenRejected,
        );
        expect(
          wi97Inside('server-row-srv-nas', find.text(text)),
          findsOneWidget,
        );
        expect(
          wi97TextColorIn(tester, 'server-row-srv-nas', text),
          OmColors.danger,
        );
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.tokenRejected);
        expect(wi97Inside('recent-row-0', find.text(text)), findsOneWidget);
      },
    );

    testWidgets(
      'an apiMismatch probe shows the danger dot and the L9 message on both rows',
      (tester) async {
        await pumpVaultPicker(
          tester,
          recents: const [_hostedMemex],
          beforePump: (s) => s[fakeServerId]!.route(
            'GET',
            '/api/v1/info',
            json: {'api_version': 2, 'server_version': '0.9.3'},
          ),
        );

        final text = wi97L9('nas', '0.9.3');
        expect(
          wi97DotIn(tester, 'server-row-srv-nas'),
          StatusDotState.tokenRejected,
        );
        expect(
          wi97Inside('server-row-srv-nas', find.text(text)),
          findsOneWidget,
        );
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.tokenRejected);
        expect(wi97Inside('recent-row-0', find.text(text)), findsOneWidget);
      },
    );

    testWidgets('a window refocus probes each saved server once more', (
      tester,
    ) async {
      final env = await pumpVaultPicker(
        tester,
        savedServers: const [wi97Nas, wi97Mini],
      );
      expect(env.infoRequests(fakeServerId), hasLength(1));

      env.focus.set(false);
      await wi97Settle(tester);
      expect(env.infoRequests(fakeServerId), hasLength(1));
      env.focus.set(true);
      await wi97Settle(tester);

      expect(env.infoRequests(fakeServerId), hasLength(2));
      expect(env.infoRequests('srv-mini'), hasLength(2));
    });

    testWidgets(
      'a refocus probe that finds the server back turns cant reach into connected',
      (tester) async {
        final env = await pumpVaultPicker(
          tester,
          recents: const [_hostedMemex],
          beforePump: (s) =>
              s[fakeServerId]!.failure = FakeServerFailure.refused,
        );
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.cantReach);

        env.servers[fakeServerId]!.failure = null;
        env.focus.set(false);
        await wi97Settle(tester);
        env.focus.set(true);
        await wi97Settle(tester);

        expect(
          wi97DotIn(tester, 'server-row-srv-nas'),
          StatusDotState.connected,
        );
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.connected);
        expect(find.text("can't reach nas"), findsNothing);
      },
    );
  });

  group('picker actions (Req 42)', () {
    testWidgets(
      'with no saved server open vault on a server connects first then opens on the server',
      (tester) async {
        final connected = Completer<SavedServer?>();
        final env = await pumpVaultPicker(tester, savedServers: const []);
        env.actions.onConnect = () => connected.future;

        await tester.tap(find.byKey(const Key('vault-picker-open-on-server')));
        await wi97Settle(tester);
        expect(env.actions.calls, ['connect']);

        connected.complete(wi97Nas);
        await wi97Settle(tester);
        expect(env.actions.calls, ['connect', 'openOnServer']);
      },
    );

    testWidgets(
      'with no saved server create vault on a server connects first then creates on the server',
      (tester) async {
        final connected = Completer<SavedServer?>();
        final env = await pumpVaultPicker(tester, savedServers: const []);
        env.actions.onConnect = () => connected.future;

        await tester.tap(
          find.byKey(const Key('vault-picker-create-on-server')),
        );
        await wi97Settle(tester);
        expect(env.actions.calls, ['connect']);

        connected.complete(wi97Nas);
        await wi97Settle(tester);
        expect(env.actions.calls, ['connect', 'createOnServer']);
      },
    );

    testWidgets(
      'a cancelled connect from open vault on a server opens nothing else',
      (tester) async {
        final env = await pumpVaultPicker(tester, savedServers: const []);
        env.actions.onConnect = () async => null;

        await tester.tap(find.byKey(const Key('vault-picker-open-on-server')));
        await wi97Settle(tester);

        expect(env.actions.calls, ['connect']);
      },
    );

    testWidgets(
      'a cancelled connect from create vault on a server creates nothing',
      (tester) async {
        final env = await pumpVaultPicker(tester, savedServers: const []);
        env.actions.onConnect = () async => null;

        await tester.tap(
          find.byKey(const Key('vault-picker-create-on-server')),
        );
        await wi97Settle(tester);

        expect(env.actions.calls, ['connect']);
      },
    );

    testWidgets(
      'with a saved server open vault on a server goes straight to its flow',
      (tester) async {
        final env = await pumpVaultPicker(tester);

        await tester.tap(find.byKey(const Key('vault-picker-open-on-server')));
        await wi97Settle(tester);

        expect(env.actions.calls, ['openOnServer']);
      },
    );

    testWidgets(
      'with a saved server create vault on a server goes straight to its flow',
      (tester) async {
        final env = await pumpVaultPicker(tester);

        await tester.tap(
          find.byKey(const Key('vault-picker-create-on-server')),
        );
        await wi97Settle(tester);

        expect(env.actions.calls, ['createOnServer']);
      },
    );

    testWidgets('plus connect in the SERVERS header calls connect', (
      tester,
    ) async {
      final env = await pumpVaultPicker(tester);

      await tester.tap(find.byKey(const Key('picker-servers-connect')));
      await wi97Settle(tester);

      expect(env.actions.calls, ['connect']);
    });
  });

  group('row taps', () {
    testWidgets(
      'tapping a hosted row calls the open controller with its HostedVaultRef',
      (tester) async {
        final env = await pumpVaultPicker(
          tester,
          savedServers: const [wi97Nas, wi97Mini],
          recents: const [HostedVaultRef('srv-mini', 'studio'), _hostedMemex],
          configureOpener: (o) =>
              o.onOpen = (_) async => const VaultOpenFailure('not yet'),
        );

        await tester.tap(find.byKey(const Key('recent-row-1')));
        await wi97Settle(tester);

        expect(env.opener.opened, [_hostedMemex]);
      },
    );

    testWidgets(
      'tapping a local row runs the local open path and shows its refusal dialog',
      (tester) async {
        final local = createVaultFolder();
        final env = await pumpVaultPicker(
          tester,
          recents: [_hostedMemex, LocalVaultRef(local.path)],
          configureOpener: (o) =>
              o.onOpen = (v) async =>
                  VaultOnNetworkDrive(local.path, networkDriveRefusalMessage),
        );

        await tester.tap(find.byKey(const Key('recent-row-1')));
        await wi97Settle(tester);

        expect(env.opener.opened, [LocalVaultRef(local.path)]);
        expect(find.text(networkDriveRefusalMessage), findsOneWidget);
        expect(find.text('OPEN LOCAL VAULT'), findsOneWidget);
      },
    );
  });
}
