// WI #99 (H5, Spec #67 req 44 and 45; D17, D18, D20): the "open vault on a
// server" dialog (board A6, states 1-3, with the server menu and the derived
// failure states of design pack #99).
//
// API under test:
//   app/lib/src/widgets/hosted/open_on_server_dialog.dart
//     Future<void> showOpenOnServerDialog(BuildContext context,
//         {String? serverId, VoidCallback? onConnect,
//          void Function(String serverId)? onUpdateToken})
//   app/lib/src/widgets/hosted/server_select.dart
//     serverDialogHttpClientProvider: Provider<http.Client>
//   Keys beyond the WI list (the server menu rows):
//     server-select-item-<saved server id>, server-select-connect
// Every request goes through HostedClient on that provider (D17); the dialog
// parses no C1 itself. The open controller is replaced by a recorder.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/hosted/server_select.dart';

import '../../support/fake_vault_server.dart';
import 'wi99_server_dialog_harness.dart';

Map<String, Object?> _vaults(List<String> names) => {
  'vaults': [
    for (var i = 0; i < names.length; i++)
      {'name': names[i], 'vault_id': '01VAULT0000000000000000$i'},
  ],
};

void _serve(FakeVaultServer server, List<String> names) =>
    server.route('GET', '/api/v1/vaults', json: _vaults(names));

Finder _icon(IconData icon, Finder scope) =>
    find.descendant(of: scope, matching: find.byIcon(icon));

void main() {
  group('start and loading (AC1)', () {
    testWidgets(
      'the open dialog starts on the first saved server with the board labels',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.nas, ['alpha']);
        _serve(env.cabin, ['other']);
        await env.openOpenDialog();

        expect(find.byKey(kOpenDialog), findsOneWidget);
        expect(find.text('OPEN VAULT ON A SERVER'), findsOneWidget);
        expect(find.text('server'), findsOneWidget);
        expect(env.textOf(find.byKey(kServerSelect)), 'nas · nas.local:7878');
        expect(env.nas.requests.map((r) => '${r.method} ${r.url.path}'), [
          'GET /api/v1/vaults',
        ]);
        expect(
          env.nas.requests.single.headers['authorization'],
          'Bearer $kWi99NasToken',
          reason: 'the token comes from the token store through HostedClient',
        );
        expect(env.cabin.requests, isEmpty, reason: 'cabin is never asked');
      },
    );

    testWidgets(
      'the open dialog starts on the given server when serverId is passed',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.nas, ['alpha']);
        _serve(env.cabin, ['other']);
        await env.openOpenDialog(serverId: env.cabinSaved.id);

        expect(
          env.textOf(find.byKey(kServerSelect)),
          'cabin · cabin.local:7979',
        );
        expect(find.byKey(vaultRow('other')), findsOneWidget);
        expect(find.byKey(vaultRow('alpha')), findsNothing);
        expect(env.nas.requests, isEmpty, reason: 'nas is never asked');
        expect(env.cabin.requests, hasLength(1));
      },
    );

    testWidgets(
      'loading vaults on nas shows until the list answers and open is disabled',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.nas, ['alpha', 'beta']);
        env.nas.hold();
        await env.openOpenDialog();

        expect(find.text('loading vaults on nas…'), findsOneWidget);
        expect(find.byKey(vaultRow('alpha')), findsNothing);
        expect(find.text('no vaults on nas yet'), findsNothing);
        expect(env.isDisabled(kOpenButton), isTrue);

        env.nas.release();
        await env.settle();

        expect(find.text('loading vaults on nas…'), findsNothing);
        expect(find.byKey(vaultRow('alpha')), findsOneWidget);
        expect(env.isDisabled(kOpenButton), isTrue, reason: 'nothing selected');
      },
    );
  });

  group('list and open (AC2)', () {
    testWidgets(
      'the list shows the vaults in server order under the vaults on nas header',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.nas, ['gamma', 'alpha', 'beta']);
        await env.openOpenDialog();

        expect(find.text('vaults on nas · 3'), findsOneWidget);
        final ys = [
          for (final n in ['gamma', 'alpha', 'beta'])
            tester.getTopLeft(find.byKey(vaultRow(n))).dy,
        ];
        expect(
          ys[0] < ys[1] && ys[1] < ys[2],
          isTrue,
          reason: 'the dialog keeps the server order and does not sort',
        );
        for (final n in ['gamma', 'alpha', 'beta']) {
          expect(env.hasText(find.byKey(vaultRow(n)), n), isTrue);
        }
        expect(find.byKey(kEmptyCreate), findsNothing);
      },
    );

    testWidgets(
      'selecting a vault checks it and enables open and another selection moves the check',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.nas, ['alpha', 'beta']);
        await env.openOpenDialog();

        expect(
          _icon(LucideIcons.check, find.byKey(vaultRow('alpha'))),
          findsNothing,
        );
        expect(env.isDisabled(kOpenButton), isTrue);

        await env.tapKey(vaultRow('alpha'));
        expect(
          _icon(LucideIcons.check, find.byKey(vaultRow('alpha'))),
          findsOneWidget,
        );
        expect(
          _icon(LucideIcons.check, find.byKey(vaultRow('beta'))),
          findsNothing,
        );
        expect(env.isDisabled(kOpenButton), isFalse);

        await env.tapKey(vaultRow('beta'));
        expect(
          _icon(LucideIcons.check, find.byKey(vaultRow('alpha'))),
          findsNothing,
        );
        expect(
          _icon(LucideIcons.check, find.byKey(vaultRow('beta'))),
          findsOneWidget,
        );
        final check = tester.widget<Icon>(
          _icon(LucideIcons.check, find.byKey(vaultRow('beta'))),
        );
        expect(check.color, OmColors.accent);
        expect(check.size, 14);
      },
    );

    testWidgets(
      'open calls the open controller with the hosted ref and closes the dialog',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.nas, ['alpha', 'beta']);
        await env.openOpenDialog();
        await env.tapKey(vaultRow('beta'));

        await env.tapKey(kOpenButton);

        expect(env.opened, [HostedVaultRef(env.nasSaved.id, 'beta')]);
        expect(find.byKey(kOpenDialog), findsNothing);
      },
    );

    testWidgets(
      'open on the second server opens a ref carrying that servers id',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.nas, ['alpha']);
        _serve(env.cabin, ['alpha']);
        await env.openOpenDialog(serverId: env.cabinSaved.id);
        await env.tapKey(vaultRow('alpha'));
        await env.tapKey(kOpenButton);

        expect(env.opened, [HostedVaultRef(env.cabinSaved.id, 'alpha')]);
      },
    );

    testWidgets('tapping a disabled open opens nothing and keeps the dialog', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      _serve(env.nas, ['alpha']);
      await env.openOpenDialog();
      await env.tapKey(kOpenButton);

      expect(env.opened, isEmpty);
      expect(find.byKey(kOpenDialog), findsOneWidget);
    });
  });

  group('empty list (AC3)', () {
    testWidgets(
      'an empty list shows no vaults on nas yet with a create button and open disabled',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.nas, const []);
        await env.openOpenDialog();

        expect(find.text('no vaults on nas yet'), findsOneWidget);
        expect(
          env.hasText(find.byKey(kEmptyCreate), 'create vault on nas…'),
          isTrue,
        );
        expect(find.text('loading vaults on nas…'), findsNothing);
        expect(env.isDisabled(kOpenButton), isTrue);
        expect(
          find.byKey(kCreateLink),
          findsNothing,
          reason: 'the empty state replaces the + create link',
        );
      },
    );

    testWidgets(
      'the empty state create button opens the create dialog on that server',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.cabin, const []);
        await env.openOpenDialog(serverId: env.cabinSaved.id);

        await env.tapKey(kEmptyCreate);

        expect(find.byKey(kCreateDialog), findsOneWidget);
        expect(
          env.textOf(
            find.descendant(
              of: find.byKey(kCreateDialog),
              matching: find.byKey(kServerSelect),
            ),
          ),
          'cabin · cabin.local:7979',
        );
        expect(env.opened, isEmpty);
      },
    );

    testWidgets(
      'a vault created from the empty state opens and closes both dialogs',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.nas, const []);
        env.nas.route(
          'POST',
          '/api/v1/vaults',
          status: 201,
          json: {'name': 'fresh', 'vault_id': '01FRESH00000000000000000'},
        );
        await env.openOpenDialog();
        await env.tapKey(kEmptyCreate);
        await env.typeName('fresh');
        await env.tapKey(kSubmit);

        expect(env.opened, [HostedVaultRef(env.nasSaved.id, 'fresh')]);
        expect(find.byKey(kCreateDialog), findsNothing);
        expect(find.byKey(kOpenDialog), findsNothing);
      },
    );
  });

  group('server menu (AC4 and AC5)', () {
    testWidgets(
      'the server menu lists every saved server with a check on the current one and then connect',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.nas, ['alpha']);
        await env.openOpenDialog();

        await env.tapKey(kServerSelect);

        final nas = find.byKey(serverItem(env.nasSaved.id));
        final cabin = find.byKey(serverItem(env.cabinSaved.id));
        expect(env.textOf(nas), 'nas · nas.local:7878');
        expect(env.textOf(cabin), 'cabin · cabin.local:7979');
        expect(_icon(LucideIcons.check, nas), findsOneWidget);
        expect(_icon(LucideIcons.check, cabin), findsNothing);
        expect(
          env.textOf(find.byKey(kConnectItem)),
          'connect to a vault server…',
        );
        expect(
          tester.getTopLeft(find.byKey(kConnectItem)).dy >
              tester.getTopLeft(cabin).dy,
          isTrue,
          reason: 'connect comes after the saved servers',
        );
        final check = tester.widget<Icon>(_icon(LucideIcons.check, nas));
        expect(check.color, OmColors.accent);
      },
    );

    testWidgets('connect to a vault server calls onConnect', (tester) async {
      final env = await pumpWi99Host(tester);
      _serve(env.nas, ['alpha']);
      await env.openOpenDialog();
      await env.tapKey(kServerSelect);

      await env.tapKey(kConnectItem);

      expect(env.connectCalls, 1);
      expect(env.opened, isEmpty);
      expect(
        env.nas.requests,
        hasLength(1),
        reason: 'no new list request for connect',
      );
    });

    testWidgets('connect to a vault server with no onConnect does nothing', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      _serve(env.nas, ['alpha']);
      await env.openOpenDialog(wireCallbacks: false);
      await env.tapKey(kServerSelect);

      await env.tapKey(kConnectItem);

      expect(tester.takeException(), isNull);
      expect(find.byKey(kOpenDialog), findsOneWidget);
    });

    testWidgets(
      'picking another server loads that servers list and clears the selection',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.nas, ['alpha']);
        _serve(env.cabin, ['one', 'two']);
        await env.openOpenDialog();
        await env.tapKey(vaultRow('alpha'));
        expect(env.isDisabled(kOpenButton), isFalse);

        await env.pickServer(find.byKey(kServerSelect), env.cabinSaved.id);

        expect(
          env.textOf(find.byKey(kServerSelect)),
          'cabin · cabin.local:7979',
        );
        expect(find.text('vaults on cabin · 2'), findsOneWidget);
        expect(find.byKey(vaultRow('one')), findsOneWidget);
        expect(find.byKey(vaultRow('two')), findsOneWidget);
        expect(find.byKey(vaultRow('alpha')), findsNothing);
        expect(
          env.isDisabled(kOpenButton),
          isTrue,
          reason: 'a selection never carries over to another server',
        );
        expect(env.cabin.requests.map((r) => r.url.path), ['/api/v1/vaults']);
        expect(
          env.cabin.requests.single.headers['authorization'],
          'Bearer $kWi99CabinToken',
        );
      },
    );

    testWidgets(
      'picking another server shows loading vaults on that server until it answers',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.nas, ['alpha']);
        _serve(env.cabin, ['one']);
        await env.openOpenDialog();
        env.cabin.hold();

        await env.pickServer(find.byKey(kServerSelect), env.cabinSaved.id);

        expect(find.text('loading vaults on cabin…'), findsOneWidget);
        expect(find.byKey(vaultRow('alpha')), findsNothing);
        expect(env.isDisabled(kOpenButton), isTrue);
        env.cabin.release();
        await env.settle();
        expect(find.byKey(vaultRow('one')), findsOneWidget);
      },
    );

    testWidgets(
      'a late list from the server that was left never replaces the new servers list',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.nas, ['stale']);
        _serve(env.cabin, ['fresh']);
        env.nas.hold();
        await env.openOpenDialog();

        await env.pickServer(find.byKey(kServerSelect), env.cabinSaved.id);
        expect(find.byKey(vaultRow('fresh')), findsOneWidget);
        env.nas.release();
        await env.settle();

        expect(find.byKey(vaultRow('fresh')), findsOneWidget);
        expect(find.byKey(vaultRow('stale')), findsNothing);
        expect(find.text('vaults on cabin · 1'), findsOneWidget);
        expect(
          env.textOf(find.byKey(kServerSelect)),
          'cabin · cabin.local:7979',
        );
      },
    );

    testWidgets(
      'picking the current server again keeps the list and sends no new request',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.nas, ['alpha']);
        await env.openOpenDialog();
        await env.tapKey(vaultRow('alpha'));

        await env.pickServer(find.byKey(kServerSelect), env.nasSaved.id);

        expect(find.byKey(vaultRow('alpha')), findsOneWidget);
        expect(env.nas.requests, hasLength(1));
        expect(env.isDisabled(kOpenButton), isFalse);
      },
    );

    testWidgets(
      'the create link opens the create dialog on the selected server',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.nas, ['alpha']);
        _serve(env.cabin, ['one']);
        await env.openOpenDialog();
        await env.pickServer(find.byKey(kServerSelect), env.cabinSaved.id);
        expect(
          env.hasText(find.byKey(kCreateLink), '+ create vault on cabin…'),
          isTrue,
        );

        await env.tapKey(kCreateLink);

        expect(find.byKey(kCreateDialog), findsOneWidget);
        expect(
          env.textOf(
            find.descendant(
              of: find.byKey(kCreateDialog),
              matching: find.byKey(kServerSelect),
            ),
          ),
          'cabin · cabin.local:7979',
        );
        expect(env.opened, isEmpty);
        expect(env.sent('POST'), isEmpty);
      },
    );
  });

  group('failures (AC11)', () {
    testWidgets(
      'a refused connection shows cannot reach with the url and nothing to open',
      (tester) async {
        final env = await pumpWi99Host(tester);
        env.nas.failure = FakeServerFailure.refused;
        await env.openOpenDialog();

        expect(
          env.textOf(find.byKey(kServerError)),
          contains("can't reach http://nas.local:7878"),
        );
        expect(find.byKey(kUpdateToken), findsNothing);
        expect(find.text('loading vaults on nas…'), findsNothing);
        expect(find.text('no vaults on nas yet'), findsNothing);
        expect(find.byKey(kEmptyCreate), findsNothing);
        expect(env.isDisabled(kOpenButton), isTrue);
        expect(env.opened, isEmpty);
        final icon = tester.widget<Icon>(
          _icon(LucideIcons.alertTriangle, find.byKey(kServerError)),
        );
        expect(icon.color, OmColors.danger);
      },
    );

    testWidgets('a failed host lookup shows cannot reach with the url', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      env.nas.failure = FakeServerFailure.hostLookup;
      await env.openOpenDialog();

      expect(
        env.textOf(find.byKey(kServerError)),
        contains("can't reach http://nas.local:7878"),
      );
    });

    testWidgets(
      'no answer to the list request within 10 seconds shows cannot reach',
      (tester) async {
        final env = await pumpWi99Host(tester);
        env.nas.failure = FakeServerFailure.timeout;
        await env.openOpenDialog();

        env.clock.advance(const Duration(seconds: 9, milliseconds: 999));
        await env.settle();
        expect(find.text('loading vaults on nas…'), findsOneWidget);
        expect(find.byKey(kServerError), findsNothing);

        env.clock.advance(const Duration(milliseconds: 1));
        await env.settle();
        expect(find.text('loading vaults on nas…'), findsNothing);
        expect(
          env.textOf(find.byKey(kServerError)),
          contains("can't reach http://nas.local:7878"),
        );
        expect(env.isDisabled(kOpenButton), isTrue);
        expect(env.opened, isEmpty);
      },
    );

    testWidgets(
      'a 401 shows access token rejected with update token that calls onUpdateToken',
      (tester) async {
        final env = await pumpWi99Host(tester);
        env.nas.token = 'rotated-on-the-server';
        await env.openOpenDialog();

        expect(
          env.textOf(find.byKey(kServerError)),
          contains('access token rejected'),
        );
        expect(find.byKey(kUpdateToken), findsOneWidget);
        expect(env.hasText(find.byKey(kUpdateToken), 'update token'), isTrue);
        expect(find.textContaining(kWi99NasToken), findsNothing);
        expect(find.byKey(vaultRow('alpha')), findsNothing);
        expect(env.isDisabled(kOpenButton), isTrue);
        expect(env.updateTokenCalls, isEmpty);

        await env.tapKey(kUpdateToken);

        expect(env.updateTokenCalls, [env.nasSaved.id]);
        expect(env.opened, isEmpty);
      },
    );

    testWidgets('update token with no onUpdateToken does nothing', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      env.nas.token = 'rotated-on-the-server';
      await env.openOpenDialog(wireCallbacks: false);

      await env.tapKey(kUpdateToken);

      expect(tester.takeException(), isNull);
      expect(find.byKey(kOpenDialog), findsOneWidget);
    });

    testWidgets(
      'the update token callback gets the id of the server the dialog is on',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.nas, ['alpha']);
        env.cabin.token = 'rotated-on-the-server';
        await env.openOpenDialog();

        await env.pickServer(find.byKey(kServerSelect), env.cabinSaved.id);
        expect(
          env.textOf(find.byKey(kServerError)),
          contains('access token rejected'),
        );
        await env.tapKey(kUpdateToken);

        expect(env.updateTokenCalls, [env.cabinSaved.id]);
      },
    );

    testWidgets(
      'switching from a failed server to a working one clears the error and loads the list',
      (tester) async {
        final env = await pumpWi99Host(tester);
        env.nas.failure = FakeServerFailure.refused;
        _serve(env.cabin, ['one']);
        await env.openOpenDialog();
        expect(find.byKey(kServerError), findsOneWidget);

        await env.pickServer(find.byKey(kServerSelect), env.cabinSaved.id);

        expect(find.byKey(kServerError), findsNothing);
        expect(find.byKey(vaultRow('one')), findsOneWidget);
      },
    );
  });

  group('cancel (AC12)', () {
    testWidgets('cancel closes the open dialog without opening anything', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      _serve(env.nas, ['alpha']);
      await env.openOpenDialog();
      await env.tapKey(vaultRow('alpha'));

      await env.tapText('cancel');

      expect(find.byKey(kOpenDialog), findsNothing);
      expect(env.opened, isEmpty);
      expect(env.sent('POST'), isEmpty);
    });

    testWidgets('cancel while the list is loading closes the dialog quietly', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      _serve(env.nas, ['alpha']);
      env.nas.hold();
      await env.openOpenDialog();

      await env.tapText('cancel');
      env.nas.release();
      await env.settle();

      expect(find.byKey(kOpenDialog), findsNothing);
      expect(env.opened, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('board layout and tokens', () {
    testWidgets('the dialog is 472 wide and the server select is 36 high', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      _serve(env.nas, ['alpha']);
      await env.openOpenDialog();

      expect(tester.getSize(find.byKey(kOpenDialog)).width, 472);
      final select = tester.getSize(find.byKey(kServerSelect));
      expect(select.height, 36);
      expect(
        select.width,
        422,
        reason: '472 less 2 x 24 padding less 2 x 1 border',
      );
    });

    test('the dialog sources use theme tokens only', () {
      for (final path in [
        'lib/src/widgets/hosted/open_on_server_dialog.dart',
        'lib/src/widgets/hosted/server_select.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(source, contains('OmColors.'), reason: path);
        expect(source, isNot(contains('Color(0x')), reason: path);
        expect(
          RegExp(r'Colors\.(?!transparent)\w+').hasMatch(source),
          isFalse,
          reason: path,
        );
      }
    });
  });

  group('http client seam', () {
    test('serverDialogHttpClientProvider defaults to a real http client', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final client = container.read(serverDialogHttpClientProvider);

      expect(client, isA<http.Client>());
      expect(client, isNot(isA<MockClient>()));
    });

    test('the default client is closed when the container is disposed', () {
      final container = ProviderContainer();
      final client = container.read(serverDialogHttpClientProvider);
      container.dispose();

      expect(
        () => client.get(Uri.parse('http://127.0.0.1:1/')),
        throwsA(isA<http.ClientException>()),
      );
    });
  });

  group('request shape (D17)', () {
    testWidgets(
      'the list is one GET api v1 vaults with the utc offset header',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.nas, ['alpha']);
        await env.openOpenDialog();

        final r = env.nas.requests.single;
        expect(r.method, 'GET');
        expect(r.url.toString(), 'http://nas.local:7878/api/v1/vaults');
        expect(r.headers.containsKey('x-memex-utc-offset'), isTrue);
      },
    );
  });
}
