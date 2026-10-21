// WI #99 (H5): the lead rulings and the contracts the red tests left open,
// pinned in the verify pass. Both dialogs, one host (the shared harness).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/widgets/hosted/create_on_server_dialog.dart';
import 'package:open_memex_app/src/widgets/hosted/server_select.dart';

import '../../support/fake_vault_server.dart';
import 'wi99_server_dialog_harness.dart';

void _serve(FakeVaultServer server, Object? body) =>
    server.route('GET', '/api/v1/vaults', json: body);

Map<String, Object?> _vaults(List<String> names) => {
  'vaults': [
    for (final n in names) {'name': n, 'vault_id': '01VAULT00000000000000000'},
  ],
};

void _created(Wi99Env env, String name) => env.nas.route(
  'POST',
  '/api/v1/vaults',
  status: 201,
  json: {'name': name, 'vault_id': '01CREATED0000000000000000'},
);

Map<String, Object?> _c1(String code, String message) => {
  'error': {'code': code, 'message': message},
};

String _typed(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(kNameField),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

void main() {
  group('non-401 C1 errors show the server message inline', () {
    testWidgets(
      'a 500 on the vault list shows the server message without the operation prefix',
      (tester) async {
        final env = await pumpWi99Host(tester);
        env.nas.route(
          'GET',
          '/api/v1/vaults',
          status: 500,
          json: _c1('internal_error', 'disk on fire'),
        );
        await env.openOpenDialog();

        expect(env.textOf(find.byKey(kServerError)), 'disk on fire');
        expect(find.byKey(kUpdateToken), findsNothing);
        expect(find.textContaining('list vaults failed'), findsNothing);
        expect(find.byKey(kCreateLink), findsNothing);
        expect(find.byKey(kEmptyCreate), findsNothing);
        expect(find.textContaining('vaults on nas'), findsNothing);
        expect(env.isDisabled(kOpenButton), isTrue);
        expect(find.byKey(kOpenDialog), findsOneWidget);
      },
    );

    testWidgets(
      'a 500 on the create POST shows the server message without the operation prefix',
      (tester) async {
        final env = await pumpWi99Host(tester);
        env.nas.route(
          'POST',
          '/api/v1/vaults',
          status: 500,
          json: _c1('internal_error', 'quota exceeded'),
        );
        await env.openCreateDialog();
        await env.typeName('work');
        await env.tapKey(kSubmit);

        expect(env.textOf(find.byKey(kServerError)), 'quota exceeded');
        expect(find.textContaining('create vault failed'), findsNothing);
        expect(find.byKey(kNameError), findsNothing);
        expect(find.byKey(kUpdateToken), findsNothing);
        expect(env.opened, isEmpty);
        expect(find.byKey(kCreateDialog), findsOneWidget);
        expect(env.isDisabled(kSubmit), isFalse, reason: 'can try again');
      },
    );

    testWidgets('a 502 without a C1 body shows the HTTP status', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      env.nas.route(
        'GET',
        '/api/v1/vaults',
        status: 502,
        body: '<html>bad gateway</html>',
        contentType: 'text/html',
      );
      await env.openOpenDialog();

      expect(env.textOf(find.byKey(kServerError)), 'HTTP 502');
      expect(find.textContaining('bad gateway'), findsNothing);
    });
  });

  group('the open controller refuses', () {
    testWidgets(
      'an open the controller refuses keeps the dialog open with its message',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _serve(env.nas, _vaults(['alpha']));
        await env.openOpenDialog();
        env.recorder.failWith = 'Could not open alpha: nope';
        await env.tapKey(vaultRow('alpha'));
        await env.tapKey(kOpenButton);

        expect(
          env.textOf(find.byKey(kServerError)),
          'Could not open alpha: nope',
        );
        expect(find.byKey(kOpenDialog), findsOneWidget);
        expect(env.opened, [HostedVaultRef(env.nasSaved.id, 'alpha')]);
        expect(
          env.isDisabled(kOpenButton),
          isFalse,
          reason: 'open can be tried again',
        );

        env.recorder.failWith = null;
        await env.tapKey(kOpenButton);

        expect(env.opened, hasLength(2));
        expect(find.byKey(kOpenDialog), findsNothing);
      },
    );

    testWidgets(
      'a create the open controller refuses keeps the dialog open with its message',
      (tester) async {
        final env = await pumpWi99Host(tester);
        _created(env, 'work');
        await env.openCreateDialog();
        env.recorder.failWith = 'Could not open work: nope';
        await env.typeName('work');
        await env.tapKey(kSubmit);

        expect(
          env.textOf(find.byKey(kServerError)),
          'Could not open work: nope',
        );
        expect(find.byKey(kCreateDialog), findsOneWidget);
        expect(env.sent('POST'), hasLength(1));
        expect(env.opened, [HostedVaultRef(env.nasSaved.id, 'work')]);
        expect(find.byKey(kNameError), findsNothing);
      },
    );
  });

  group('a saved server with no stored token', () {
    testWidgets(
      'the open dialog shows access token rejected and sends no request',
      (tester) async {
        final env = await pumpWi99Host(tester);
        env.tokens.tokens.remove(env.nasSaved.id);
        await env.openOpenDialog();

        expect(
          env.textOf(find.byKey(kServerError)),
          contains('access token rejected'),
        );
        expect(env.hasText(find.byKey(kUpdateToken), 'update token'), isTrue);
        expect(env.nas.requests, isEmpty);
        expect(env.cabin.requests, isEmpty);

        await env.tapKey(kUpdateToken);

        expect(env.updateTokenCalls, [env.nasSaved.id]);
      },
    );

    testWidgets(
      'the create dialog shows access token rejected and sends no request',
      (tester) async {
        final env = await pumpWi99Host(tester);
        env.tokens.tokens.remove(env.nasSaved.id);
        await env.openCreateDialog();
        await env.typeName('work');
        await env.tapKey(kSubmit);

        expect(
          env.textOf(find.byKey(kServerError)),
          contains('access token rejected'),
        );
        expect(env.hasText(find.byKey(kUpdateToken), 'update token'), isTrue);
        expect(env.nas.requests, isEmpty);
        expect(env.opened, isEmpty);
      },
    );
  });

  group('the server label', () {
    testWidgets('a server url without a port shows the host alone', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      final bare = (await tester.runAsync(
        () => env.settings.saveServer(
          name: 'bare',
          url: 'https://bare.example.org',
          token: 'tok-bare',
        ),
      ))!;
      await env.openOpenDialog(serverId: bare.id);

      expect(env.textOf(find.byKey(kServerSelect)), 'bare · bare.example.org');

      await tester.tap(find.byKey(kServerSelect));
      await env.settle();
      expect(
        env.textOf(find.byKey(serverItem(bare.id))),
        'bare · bare.example.org',
      );
      expect(
        env.textOf(find.byKey(serverItem(env.nasSaved.id))),
        'nas · nas.local:7878',
      );
    });

    test('hostPortOf gives host and port, the host alone, or the raw text', () {
      expect(hostPortOf('http://nas.local:7878'), 'nas.local:7878');
      expect(hostPortOf('http://nas.local:7878/prefix'), 'nas.local:7878');
      expect(hostPortOf('http://nas.local'), 'nas.local');
      expect(hostPortOf('https://nas.local/'), 'nas.local');
      expect(hostPortOf('not a url'), 'not a url');
      expect(hostPortOf('nas'), 'nas');
    });
  });

  group('the vault list', () {
    testWidgets('a list body with no vaults list is an empty list', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      _serve(env.nas, <String, Object?>{'vaults': 'nope'});
      await env.openOpenDialog();

      expect(find.text('no vaults on nas yet'), findsOneWidget);
      expect(find.byKey(kServerError), findsNothing);
      expect(env.isDisabled(kOpenButton), isTrue);
    });

    testWidgets('a list body without the vaults key is an empty list', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      _serve(env.nas, <String, Object?>{'other': 1});
      await env.openOpenDialog();

      expect(find.text('no vaults on nas yet'), findsOneWidget);
      expect(find.byKey(kServerError), findsNothing);
    });

    testWidgets('entries without a string name are left out of the list', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      _serve(env.nas, <String, Object?>{
        'vaults': [
          {'name': 'ok', 'vault_id': 'x'},
          {'name': 5},
          'stray',
          <String, Object?>{},
          {'name': 'also-ok'},
        ],
      });
      await env.openOpenDialog();

      expect(find.text('vaults on nas · 2'), findsOneWidget);
      expect(find.byKey(vaultRow('ok')), findsOneWidget);
      expect(find.byKey(vaultRow('also-ok')), findsOneWidget);
      expect(find.byKey(kServerError), findsNothing);
    });

    testWidgets('a long list scrolls inside a 250 high area', (tester) async {
      final env = await pumpWi99Host(tester);
      _serve(env.nas, _vaults([for (var i = 0; i < 12; i++) 'vault-$i']));
      await env.openOpenDialog();

      expect(find.text('vaults on nas · 12'), findsOneWidget);
      final list = find.ancestor(
        of: find.byKey(vaultRow('vault-0')),
        matching: find.byType(SingleChildScrollView),
      );
      expect(tester.getSize(list).height, 250);
    });
  });

  group('the create link', () {
    testWidgets('shows only once a non-empty list has loaded', (tester) async {
      final env = await pumpWi99Host(tester);
      _serve(env.nas, _vaults(['alpha']));
      env.nas.hold();
      await env.openOpenDialog();
      expect(find.text('loading vaults on nas…'), findsOneWidget);
      expect(find.byKey(kCreateLink), findsNothing, reason: 'loading');

      env.nas.release();
      await env.settle();
      expect(find.byKey(kCreateLink), findsOneWidget, reason: 'loaded');
      expect(
        env.hasText(find.byKey(kCreateLink), '+ create vault on nas…'),
        isTrue,
      );
    });

    testWidgets('is hidden when the list failed', (tester) async {
      final env = await pumpWi99Host(tester);
      env.nas.failure = FakeServerFailure.refused;
      await env.openOpenDialog();

      expect(find.byKey(kServerError), findsOneWidget);
      expect(find.byKey(kCreateLink), findsNothing);
    });
  });

  group('the host decides what connect and update token do', () {
    testWidgets('connect to a vault server leaves the open dialog open', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      _serve(env.nas, _vaults(['alpha']));
      await env.openOpenDialog();
      await env.tapKey(kServerSelect);
      await env.tapKey(kConnectItem);

      expect(env.connectCalls, 1);
      expect(find.byKey(kOpenDialog), findsOneWidget);
      expect(find.byKey(kConnectItem), findsNothing, reason: 'menu closed');
    });

    testWidgets('connect to a vault server leaves the create dialog open', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      await env.openCreateDialog();
      await env.typeName('draft');
      await env.tapKey(kServerSelect);
      await env.tapKey(kConnectItem);

      expect(env.connectCalls, 1);
      expect(find.byKey(kCreateDialog), findsOneWidget);
      expect(_typed(tester), 'draft');
    });

    testWidgets('update token leaves the open dialog open', (tester) async {
      final env = await pumpWi99Host(tester);
      env.nas.token = 'rotated-on-the-server';
      await env.openOpenDialog();
      await env.tapKey(kUpdateToken);

      expect(env.updateTokenCalls, [env.nasSaved.id]);
      expect(find.byKey(kOpenDialog), findsOneWidget);
      expect(find.byKey(kUpdateToken), findsOneWidget);
    });

    testWidgets('update token leaves the create dialog open', (tester) async {
      final env = await pumpWi99Host(tester);
      env.nas.token = 'rotated-on-the-server';
      await env.openCreateDialog();
      await env.typeName('work');
      await env.tapKey(kSubmit);
      await env.tapKey(kUpdateToken);

      expect(env.updateTokenCalls, [env.nasSaved.id]);
      expect(find.byKey(kCreateDialog), findsOneWidget);
      expect(_typed(tester), 'work');
    });
  });

  group('the create dialog while busy or switching servers', () {
    testWidgets('the server select does not open while a create is pending', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      _created(env, 'slow');
      await env.openCreateDialog();
      await env.typeName('slow');
      env.nas.hold();
      await env.tapKey(kSubmit);

      await tester.tap(find.byKey(kServerSelect));
      await env.settle();
      expect(find.byKey(serverItem(env.cabinSaved.id)), findsNothing);
      expect(find.byKey(kConnectItem), findsNothing);

      env.nas.release();
      await env.settle();
      expect(env.opened, [HostedVaultRef(env.nasSaved.id, 'slow')]);
      expect(env.cabin.requests, isEmpty);
    });

    testWidgets('the server select opens again after a failed create', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      env.nas.failure = FakeServerFailure.refused;
      await env.openCreateDialog();
      await env.typeName('work');
      await env.tapKey(kSubmit);

      await tester.tap(find.byKey(kServerSelect));
      await env.settle();

      expect(find.byKey(serverItem(env.cabinSaved.id)), findsOneWidget);
    });

    testWidgets('cancel during a pending create ignores a late 201', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      _created(env, 'late');
      await env.openCreateDialog();
      await env.typeName('late');
      env.nas.hold();
      await env.tapKey(kSubmit);
      expect(env.sent('POST'), hasLength(1));

      await env.tapText('cancel');
      expect(find.byKey(kCreateDialog), findsNothing);
      env.nas.release();
      await env.settle();

      expect(env.opened, isEmpty, reason: 'nothing opens after a cancel');
      expect(tester.takeException(), isNull);
      expect(find.byKey(kCreateDialog), findsNothing);
    });

    testWidgets(
      'switching server keeps the typed name and clears the server error',
      (tester) async {
        final env = await pumpWi99Host(tester);
        env.nas.failure = FakeServerFailure.refused;
        await env.openCreateDialog();
        await env.typeName('work');
        await env.tapKey(kSubmit);
        expect(find.byKey(kServerError), findsOneWidget);

        await env.pickServer(find.byKey(kServerSelect), env.cabinSaved.id);

        expect(find.byKey(kServerError), findsNothing);
        expect(_typed(tester), 'work');
        expect(
          env.hasText(
            find.byKey(kCreateDialog),
            'http://cabin.local:7979/vaults/work',
          ),
          isTrue,
        );
      },
    );

    testWidgets('switching server clears a name error and re-enables create', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      env.nas.route(
        'POST',
        '/api/v1/vaults',
        status: 400,
        json: wi99ErrorFixture('invalid_vault_name'),
      );
      await env.openCreateDialog();
      await env.typeName('bad name');
      await env.tapKey(kSubmit);
      expect(find.byKey(kNameError), findsOneWidget);
      expect(env.isDisabled(kSubmit), isTrue);

      await env.pickServer(find.byKey(kServerSelect), env.cabinSaved.id);

      expect(find.byKey(kNameError), findsNothing);
      expect(env.isDisabled(kSubmit), isFalse);
      expect(_typed(tester), 'bad name');
    });
  });

  group('showCreateOnServerDialogForResult', () {
    testWidgets('completes true when the vault was created and opened', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      _created(env, 'fresh');
      bool? result;
      showCreateOnServerDialogForResult(env.context).then((v) => result = v);
      await env.settle();
      expect(result, isNull, reason: 'still open');

      await env.typeName('fresh');
      await env.tapKey(kSubmit);

      expect(result, isTrue);
      expect(env.opened, [HostedVaultRef(env.nasSaved.id, 'fresh')]);
    });

    testWidgets('completes false on cancel', (tester) async {
      final env = await pumpWi99Host(tester);
      bool? result;
      showCreateOnServerDialogForResult(env.context).then((v) => result = v);
      await env.settle();

      await env.tapText('cancel');

      expect(result, isFalse);
    });

    testWidgets('completes false when the barrier closes the dialog', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      bool? result;
      showCreateOnServerDialogForResult(env.context).then((v) => result = v);
      await env.settle();

      await tester.tapAt(const Offset(4, 4));
      await env.settle();

      expect(find.byKey(kCreateDialog), findsNothing);
      expect(result, isFalse);
    });

    testWidgets('completes false when the create failed and was cancelled', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      env.nas.failure = FakeServerFailure.refused;
      bool? result;
      showCreateOnServerDialogForResult(
        env.context,
        serverId: env.nasSaved.id,
      ).then((v) => result = v);
      await env.settle();
      await env.typeName('work');
      await env.tapKey(kSubmit);
      expect(result, isNull);

      await env.tapText('cancel');

      expect(result, isFalse);
    });

    testWidgets('the open dialog stays open when the create is cancelled', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      _serve(env.nas, _vaults(['alpha']));
      await env.openOpenDialog();
      await env.tapKey(kCreateLink);
      expect(find.byKey(kCreateDialog), findsOneWidget);

      await tester.tap(find.text('cancel').last);
      await env.settle();

      expect(find.byKey(kCreateDialog), findsNothing);
      expect(find.byKey(kOpenDialog), findsOneWidget);
    });

    testWidgets('a create from the + link opens the vault and closes both', (
      tester,
    ) async {
      final env = await pumpWi99Host(tester);
      _serve(env.nas, _vaults(['alpha']));
      _created(env, 'fresh');
      await env.openOpenDialog();
      await env.tapKey(kCreateLink);
      await env.typeName('fresh');
      await env.tapKey(kSubmit);

      expect(env.opened, [HostedVaultRef(env.nasSaved.id, 'fresh')]);
      expect(find.byKey(kCreateDialog), findsNothing);
      expect(find.byKey(kOpenDialog), findsNothing);
    });
  });
}
