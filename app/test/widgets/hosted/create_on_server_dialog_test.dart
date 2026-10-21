// WI #99 (H5, Spec #67 req 44 and 45; D17, D18, D20): the "create vault on a
// server" dialog (board A7, states 1-3, with the derived failure states of
// design pack #99).
//
// API under test:
//   app/lib/src/widgets/hosted/create_on_server_dialog.dart
//     Future<void> showCreateOnServerDialog(BuildContext context,
//         {String? serverId, VoidCallback? onConnect,
//          void Function(String serverId)? onUpdateToken})
//   (the server choice and serverDialogHttpClientProvider live in
//   app/lib/src/widgets/hosted/server_select.dart; see the open dialog test)
// Keys: create-on-server-dialog / -name / -submit / -error for the name rule
// copy; server-dialog-error / server-dialog-update-token for connection
// failures; open-on-server-server-menu is the server select in both dialogs.
// The dialog never checks a name: the server owns the rule (D20).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/theme/colors.dart';

import '../../support/fake_vault_server.dart';
import 'wi99_server_dialog_harness.dart';

void _created(Wi99Env env, String name) => env.nas.route(
  'POST',
  '/api/v1/vaults',
  status: 201,
  json: {'name': name, 'vault_id': '01CREATED0000000000000000'},
);

void _answer(Wi99Env env, int status, String fixture, {bool onCabin = false}) =>
    (onCabin ? env.cabin : env.nas).route(
      'POST',
      '/api/v1/vaults',
      status: status,
      json: wi99ErrorFixture(fixture),
    );

Map<String, Object?> _bodyOf(http.Request r) =>
    jsonDecode(r.body) as Map<String, Object?>;

const _invalidCopy = 'use letters, digits, - and _ (1–64 characters)';

void main() {
  group('form (AC6 and AC10)', () {
    testWidgets(
      'the create dialog starts on the first saved server with the board labels',
      (tester) async {
        final env = await pumpWi99Host(tester);
        await env.openCreateDialog();

        expect(find.byKey(kCreateDialog), findsOneWidget);
        expect(find.text('CREATE VAULT ON A SERVER'), findsOneWidget);
        expect(find.text('server'), findsOneWidget);
        expect(find.text('vault name'), findsOneWidget);
        expect(find.byKey(kNameField), findsOneWidget);
        expect(env.textOf(find.byKey(kServerSelect)), 'nas · nas.local:7878');
        expect(env.hasText(find.byKey(kSubmit), 'create'), isTrue);
        expect(find.text('cancel'), findsOneWidget);
        expect(find.byKey(kNameError), findsNothing);
        expect(find.byKey(kServerError), findsNothing);
        expect(env.sent('POST'), isEmpty);
      },
    );

    testWidgets(
      'the create dialog starts on the given server when serverId is passed',
      (tester) async {
        final env = await pumpWi99Host(tester);
        await env.openCreateDialog(serverId: env.cabinSaved.id);

        expect(
          env.textOf(find.byKey(kServerSelect)),
          'cabin · cabin.local:7979',
        );
      },
    );

    testWidgets(
      'will be created at shows the server url and the typed name as it changes',
      (tester) async {
        final env = await pumpWi99Host(tester);
        await env.openCreateDialog();
        expect(find.text('will be created at'), findsNothing);

        await env.typeName('reading-notes');
        expect(find.text('will be created at'), findsOneWidget);
        expect(
          env.hasText(
            find.byKey(kCreateDialog),
            'http://nas.local:7878/vaults/reading-notes',
          ),
          isTrue,
        );

        await env.typeName('work');
        expect(
          env.hasText(
            find.byKey(kCreateDialog),
            'http://nas.local:7878/vaults/work',
          ),
          isTrue,
        );
        expect(
          env.hasText(
            find.byKey(kCreateDialog),
            'http://nas.local:7878/vaults/reading-notes',
          ),
          isFalse,
        );

        await env.typeName('');
        expect(find.text('will be created at'), findsNothing);
      },
    );

    testWidgets('create is disabled while the name field is empty', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      await env.openCreateDialog();
      expect(env.isDisabled(kSubmit), isTrue);

      await env.tapKey(kSubmit);
      expect(env.sent('POST'), isEmpty);

      await env.typeName('a');
      expect(env.isDisabled(kSubmit), isFalse);

      await env.typeName('');
      expect(env.isDisabled(kSubmit), isTrue);
    });
  });

  group('create (AC7)', () {
    testWidgets(
      'create posts the name and a 201 opens the new vault and closes the dialog',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _created(env, 'reading-notes');
        await env.openCreateDialog();
        await env.typeName('reading-notes');

        await env.tapKey(kSubmit);

        final posts = env.sent('POST');
        expect(posts, hasLength(1));
        expect(
          posts.single.url.toString(),
          'http://nas.local:7878/api/v1/vaults',
        );
        expect(_bodyOf(posts.single), {'name': 'reading-notes'});
        expect(
          posts.single.headers['content-type'],
          startsWith('application/json'),
        );
        expect(posts.single.headers['authorization'], 'Bearer $kWi99NasToken');
        expect(env.opened, [HostedVaultRef(env.nasSaved.id, 'reading-notes')]);
        expect(find.byKey(kCreateDialog), findsNothing);
      },
    );

    testWidgets(
      'create on the picked server posts to that server and opens its ref',
      (tester) async {
        final env = await pumpWi99Host(tester);
        env.cabin.route(
          'POST',
          '/api/v1/vaults',
          status: 201,
          json: {'name': 'trips', 'vault_id': '01TRIPS00000000000000000'},
        );
        await env.openCreateDialog();
        await env.pickServer(find.byKey(kServerSelect), env.cabinSaved.id);
        expect(
          env.textOf(find.byKey(kServerSelect)),
          'cabin · cabin.local:7979',
        );
        await env.typeName('trips');
        expect(
          env.hasText(
            find.byKey(kCreateDialog),
            'http://cabin.local:7979/vaults/trips',
          ),
          isTrue,
        );

        await env.tapKey(kSubmit);

        expect(env.nas.requests, isEmpty);
        expect(env.cabin.requests.single.url.path, '/api/v1/vaults');
        expect(
          env.cabin.requests.single.headers['authorization'],
          'Bearer $kWi99CabinToken',
        );
        expect(env.opened, [HostedVaultRef(env.cabinSaved.id, 'trips')]);
      },
    );

    testWidgets(
      'a second tap on create while the first request is pending sends no second request',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _created(env, 'once');
        await env.openCreateDialog();
        await env.typeName('once');
        env.nas.hold();

        await tester.tap(find.byKey(kSubmit));
        await env.settle();
        await tester.tap(find.byKey(kSubmit), warnIfMissed: false);
        await env.settle();
        env.nas.release();
        await env.settle();

        expect(env.sent('POST'), hasLength(1));
        expect(env.opened, [HostedVaultRef(env.nasSaved.id, 'once')]);
      },
    );
  });

  group('names go to the server as typed (AC8)', () {
    for (final (title, name) in <(String, String)>[
      ('a name with a space is sent as typed', 'reading notes'),
      ('a 65 character name is sent as typed', 'a' * 65),
      ('a name with a non ascii letter is sent as typed', 'naïve'),
      ('a lone dash is sent as typed', '-'),
    ]) {
      testWidgets(title, (tester) async {
        final env = await pumpWi99Host(tester);
        _answer(env, 400, 'invalid_vault_name');
        await env.openCreateDialog();
        await env.typeName(name);

        await env.tapKey(kSubmit);

        expect(env.sent('POST'), hasLength(1));
        expect(_bodyOf(env.sent('POST').single), {'name': name});
        expect(env.opened, isEmpty);
      });
    }

    testWidgets('a 65 character name is accepted when the server answers 201', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      final name = 'b' * 65;
      _created(env, name);
      await env.openCreateDialog();
      await env.typeName(name);

      await env.tapKey(kSubmit);

      expect(env.opened, [HostedVaultRef(env.nasSaved.id, name)]);
    });

    testWidgets(
      'a 400 invalid_vault_name shows the rule under the name and keeps create disabled until the name changes',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _answer(env, 400, 'invalid_vault_name');
        await env.openCreateDialog();
        await env.typeName('reading notes');
        await env.tapKey(kSubmit);

        expect(env.textOf(find.byKey(kNameError)), _invalidCopy);
        final icon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(kNameError),
            matching: find.byIcon(LucideIcons.alertTriangle),
          ),
        );
        expect(icon.color, OmColors.danger);
        expect(find.byKey(kServerError), findsNothing);
        expect(find.byKey(kUpdateToken), findsNothing);
        expect(find.text('will be created at'), findsNothing);
        expect(env.isDisabled(kSubmit), isTrue);
        expect(env.opened, isEmpty);
        expect(find.byKey(kCreateDialog), findsOneWidget);

        await env.tapKey(kSubmit);
        expect(
          env.sent('POST'),
          hasLength(1),
          reason: 'disabled create sends nothing',
        );

        _created(env, 'reading-notes');
        await env.typeName('reading-notes');
        expect(find.byKey(kNameError), findsNothing);
        expect(env.isDisabled(kSubmit), isFalse);
        expect(find.text('will be created at'), findsOneWidget);

        await env.tapKey(kSubmit);
        expect(env.sent('POST'), hasLength(2));
        expect(env.opened, [HostedVaultRef(env.nasSaved.id, 'reading-notes')]);
      },
    );

    testWidgets(
      'the server message of an invalid_vault_name is never shown instead of the app copy',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _answer(env, 400, 'invalid_vault_name');
        await env.openCreateDialog();
        await env.typeName('x y');
        await env.tapKey(kSubmit);

        expect(find.textContaining('1-64'), findsNothing);
        expect(find.textContaining('vault names use'), findsNothing);
      },
    );
  });

  group('name taken (AC9)', () {
    testWidgets(
      'a 409 vault_exists shows a vault named work already exists on nas and create stays enabled',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _answer(env, 409, 'vault_exists');
        await env.openCreateDialog();
        await env.typeName('work');

        await env.tapKey(kSubmit);

        expect(
          env.textOf(find.byKey(kNameError)),
          'a vault named work already exists on nas',
        );
        expect(find.textContaining('SEED'), findsNothing);
        expect(find.byKey(kServerError), findsNothing);
        expect(find.text('will be created at'), findsNothing);
        expect(env.isDisabled(kSubmit), isFalse);
        expect(env.opened, isEmpty);
        expect(find.byKey(kCreateDialog), findsOneWidget);
      },
    );

    testWidgets('a vault_exists error names the server the dialog is on', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      _answer(env, 409, 'vault_exists', onCabin: true);
      await env.openCreateDialog(serverId: env.cabinSaved.id);
      await env.typeName('Work Notes_2');

      await env.tapKey(kSubmit);

      expect(
        env.textOf(find.byKey(kNameError)),
        'a vault named Work Notes_2 already exists on cabin',
      );
    });
  });

  group('server menu', () {
    testWidgets(
      'the server menu lists the saved servers and connect calls onConnect',
      (tester) async {
        final env = await pumpWi99Host(tester);
        await env.openCreateDialog();
        await env.tapKey(kServerSelect);

        final nas = find.byKey(serverItem(env.nasSaved.id));
        expect(env.textOf(nas), 'nas · nas.local:7878');
        expect(
          env.textOf(find.byKey(serverItem(env.cabinSaved.id))),
          'cabin · cabin.local:7979',
        );
        expect(
          find.descendant(of: nas, matching: find.byIcon(LucideIcons.check)),
          findsOneWidget,
        );
        expect(
          env.textOf(find.byKey(kConnectItem)),
          'connect to a vault server…',
        );

        await env.tapKey(kConnectItem);

        expect(env.connectCalls, 1);
        expect(env.sent('POST'), isEmpty);
      },
    );

    testWidgets('connect to a vault server with no onConnect does nothing', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      await env.openCreateDialog(wireCallbacks: false);
      await env.tapKey(kServerSelect);

      await env.tapKey(kConnectItem);

      expect(tester.takeException(), isNull);
      expect(find.byKey(kCreateDialog), findsOneWidget);
    });
  });

  group('failures (AC11)', () {
    testWidgets(
      'a refused POST shows cannot reach with the url and opens nothing',
      (tester) async {
        final env = await pumpWi99Host(tester);
        env.nas.failure = FakeServerFailure.refused;
        await env.openCreateDialog();
        await env.typeName('work');

        await env.tapKey(kSubmit);

        expect(
          env.textOf(find.byKey(kServerError)),
          contains("can't reach http://nas.local:7878"),
        );
        expect(find.byKey(kNameError), findsNothing);
        expect(find.byKey(kUpdateToken), findsNothing);
        expect(env.opened, isEmpty);
        expect(find.byKey(kCreateDialog), findsOneWidget);
        expect(env.sent('POST'), hasLength(1));
        final icon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(kServerError),
            matching: find.byIcon(LucideIcons.alertTriangle),
          ),
        );
        expect(icon.color, OmColors.danger);
      },
    );

    testWidgets('a failed host lookup on the POST shows cannot reach', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      env.nas.failure = FakeServerFailure.hostLookup;
      await env.openCreateDialog();
      await env.typeName('work');

      await env.tapKey(kSubmit);

      expect(
        env.textOf(find.byKey(kServerError)),
        contains("can't reach http://nas.local:7878"),
      );
    });

    testWidgets('create can be tried again by hand after a refused POST', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      env.nas.failure = FakeServerFailure.refused;
      await env.openCreateDialog();
      await env.typeName('work');
      await env.tapKey(kSubmit);
      expect(find.byKey(kServerError), findsOneWidget);
      expect(env.isDisabled(kSubmit), isFalse);

      env.nas.failure = null;
      _created(env, 'work');
      await env.tapKey(kSubmit);

      expect(env.sent('POST'), hasLength(2));
      expect(env.opened, [HostedVaultRef(env.nasSaved.id, 'work')]);
      expect(find.byKey(kCreateDialog), findsNothing);
    });

    testWidgets(
      'a POST with no answer for 10 seconds shows couldnt confirm and is not retried',
      (tester) async {
        final env = await pumpWi99Host(tester);
        env.nas.failure = FakeServerFailure.timeout;
        await env.openCreateDialog();
        await env.typeName('work');
        await env.tapKey(kSubmit);

        env.clock.advance(const Duration(seconds: 9, milliseconds: 999));
        await env.settle();
        expect(find.byKey(kServerError), findsNothing);

        env.clock.advance(const Duration(milliseconds: 1));
        await env.settle();
        final text = env.textOf(find.byKey(kServerError));
        expect(
          text,
          contains("couldn't confirm with nas — check before trying again"),
        );
        expect(text, isNot(contains("can't reach")));
        expect(find.byKey(kNameError), findsNothing);
        expect(find.byKey(kUpdateToken), findsNothing);

        env.clock.advance(const Duration(minutes: 5));
        await env.settle();
        expect(env.sent('POST'), hasLength(1), reason: 'never retried');
        expect(env.opened, isEmpty);
        expect(find.byKey(kCreateDialog), findsOneWidget);
      },
    );

    testWidgets('a connection dropped after sending shows couldnt confirm', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      env.nas.failure = FakeServerFailure.drop;
      await env.openCreateDialog();
      await env.typeName('work');

      await env.tapKey(kSubmit);

      expect(
        env.textOf(find.byKey(kServerError)),
        contains("couldn't confirm with nas — check before trying again"),
      );
      expect(env.sent('POST'), hasLength(1));
      expect(env.opened, isEmpty);
    });

    testWidgets(
      'a 401 on the POST shows access token rejected with update token that calls onUpdateToken',
      (tester) async {
        final env = await pumpWi99Host(tester);
        env.nas.token = 'rotated-on-the-server';
        await env.openCreateDialog();
        await env.typeName('work');

        await env.tapKey(kSubmit);

        expect(
          env.textOf(find.byKey(kServerError)),
          contains('access token rejected'),
        );
        expect(env.hasText(find.byKey(kUpdateToken), 'update token'), isTrue);
        expect(find.byKey(kNameError), findsNothing);
        expect(find.textContaining(kWi99NasToken), findsNothing);
        expect(env.opened, isEmpty);
        expect(env.updateTokenCalls, isEmpty);

        await env.tapKey(kUpdateToken);

        expect(env.updateTokenCalls, [env.nasSaved.id]);
      },
    );

    testWidgets('update token with no onUpdateToken does nothing', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      env.nas.token = 'rotated-on-the-server';
      await env.openCreateDialog(wireCallbacks: false);
      await env.typeName('work');
      await env.tapKey(kSubmit);

      await env.tapKey(kUpdateToken);

      expect(tester.takeException(), isNull);
      expect(find.byKey(kCreateDialog), findsOneWidget);
    });
  });

  group('cancel (AC12)', () {
    testWidgets(
      'cancel closes the create dialog without sending a create or opening anything',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _created(env, 'draft');
        await env.openCreateDialog();
        await env.typeName('draft');

        await env.tapText('cancel');

        expect(find.byKey(kCreateDialog), findsNothing);
        expect(env.sent('POST'), isEmpty);
        expect(env.opened, isEmpty);
      },
    );
  });

  group('board layout and tokens', () {
    testWidgets('the dialog is 472 wide and the server select is 36 high', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      await env.openCreateDialog();

      expect(tester.getSize(find.byKey(kCreateDialog)).width, 472);
      final select = tester.getSize(find.byKey(kServerSelect));
      expect(select.height, 36);
      expect(select.width, 422);
    });

    test('the dialog source uses theme tokens only', () {
      const path = 'lib/src/widgets/hosted/create_on_server_dialog.dart';
      final source = File(path).readAsStringSync();
      expect(source, contains('OmColors.'), reason: path);
      expect(source, isNot(contains('Color(0x')), reason: path);
      expect(
        RegExp(r'Colors\.(?!transparent)\w+').hasMatch(source),
        isFalse,
        reason: path,
      );
    });
  });
}
