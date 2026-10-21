// WI #98 (H4, Spec #67 req 43, req 52; D18, D20): the edit-server dialog
// (board A5 state 6), `showConnectServerDialog(context, edit: server)`. It
// reuses the connect form; "save" re-probes `GET /api/v1/info` with the
// pasted token, or the stored one when the token field is left empty, and
// updates the server in place (same id). It is also the "update token"
// dialog that #105 binds the token-rejected banner and rows to.
//
// Lead update (#91 verify): `updateServer` doesn't dedupe by URL, so this
// dialog refuses an edit whose URL normalises to another saved server's URL.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';

import '../../support/fake_vault_server.dart';
import 'wi98_connect_harness.dart';

const _url = 'http://nas.local:7878';
const _miniUrl = 'http://mini.local:7878';
const _stored = 'tok-stored-98-secret';
const _fresh = 'tok-fresh-98-secret';

/// A fake server whose access token is [token], answering
/// `GET /api/v1/info` with the frozen contract fixture.
FakeVaultServer _server({String token = _stored}) =>
    FakeVaultServer(token: token)..serveDomain('server');

/// Seeds "nas" (token [_stored]) and opens its edit dialog. [withMini] also
/// seeds "mini" at [_miniUrl].
Future<Wi98Env> _openEdit(
  WidgetTester tester, {
  FakeVaultServer? server,
  bool withMini = false,
}) async {
  final env = await pumpWi98Host(
    tester,
    server: server ?? _server(),
    seed: [
      (name: 'nas', url: _url, token: _stored),
      if (withMini) (name: 'mini', url: _miniUrl, token: 'tok-mini-98'),
    ],
    editIndex: 0,
  );
  await env.open();
  return env;
}

/// The saved servers as (id, name, url) records.
List<(String, String, String)> _servers(Wi98Env env) => [
  for (final s in env.saved) (s.id, s.name, s.url),
];

void main() {
  group('edit opens prefilled (AC11)', () {
    testWidgets(
      'edit opens with the eyebrow the server name and url an empty token and the keychain hint',
      (tester) async {
        final env = await _openEdit(tester);

        expect(find.text('EDIT NAS'), findsOneWidget);
        expect(find.text('CONNECT TO A VAULT SERVER'), findsNothing);
        expect(wi98EditableOf(tester, kWi98Name).controller.text, 'nas');
        expect(wi98EditableOf(tester, kWi98Url).controller.text, _url);
        expect(wi98EditableOf(tester, kWi98Token).controller.text, isEmpty);
        expect(wi98EditableOf(tester, kWi98Token).obscureText, isTrue);
        expect(find.text(kWi98EditHint), findsOneWidget);
        expect(find.text(kWi98ConnectHint), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(kWi98Cancel),
            matching: find.text('cancel'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(kWi98Submit),
            matching: find.text('save'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(kWi98SetupLink),
          findsNothing,
          reason: 'no setup link in edit mode',
        );
        expect(env.server.requests, isEmpty, reason: 'opening sends nothing');
      },
    );

    testWidgets('the edit dialog is 472 wide', (tester) async {
      await _openEdit(tester);

      expect(tester.getSize(find.byKey(kWi98Dialog)).width, 472);
    });
  });

  group('save re-probes (AC11)', () {
    testWidgets(
      'save with an empty token re-probes with the stored token and updates the server in place',
      (tester) async {
        final env = await _openEdit(tester);
        final id = env.edit!.id;
        await env.fill(name: 'nas home', url: 'http://nas2.local:7878');

        await env.submit();
        await tester.pumpAndSettle();

        final request = env.server.requests.single;
        expect(request.method, 'GET');
        expect(request.url, Uri.parse('http://nas2.local:7878/api/v1/info'));
        expect(request.headers['Authorization'], 'Bearer $_stored');
        expect(find.byKey(kWi98Dialog), findsNothing);
        expect(env.returned, isTrue);
        expect(env.result?.id, id);
        expect(_servers(env), [(id, 'nas home', 'http://nas2.local:7878')]);
        expect(env.tokens.tokens, {id: _stored}, reason: 'token kept');
      },
    );

    testWidgets(
      'save with a pasted token re-probes with it and replaces the stored token',
      (tester) async {
        final env = await _openEdit(tester, server: _server(token: _fresh));
        final id = env.edit!.id;
        await env.fill(token: _fresh);

        await env.submit();
        await tester.pumpAndSettle();

        expect(
          env.server.requests.single.headers['Authorization'],
          'Bearer $_fresh',
        );
        expect(env.returned, isTrue);
        expect(env.result?.id, id);
        expect(_servers(env), [(id, 'nas', _url)]);
        expect(env.tokens.tokens, {id: _fresh});
        expect(await env.prefsWith(_fresh), isEmpty);
      },
    );

    testWidgets(
      'update token from a token rejected state replaces the token and marks the server connected',
      (tester) async {
        // The stored token went stale: the server now wants _fresh.
        final env = await _openEdit(tester, server: _server(token: _fresh));
        final id = env.edit!.id;

        await env.submit();
        await tester.pumpAndSettle();
        expectWi98A5Error(tester, kWi98TokenRejected);
        expect(
          env.container.read(hostedConnectionStatusProvider(id)),
          HostedConnectionStatus.tokenRejected,
          reason: 'the probe reports under the saved server id',
        );
        expect(env.tokens.tokens, {id: _stored}, reason: 'nothing saved yet');

        await env.fill(token: _fresh);
        await env.submit();
        await tester.pumpAndSettle();

        expect(env.server.requests, hasLength(2));
        expect(
          env.server.requests.last.headers['Authorization'],
          'Bearer $_fresh',
        );
        expect(find.byKey(kWi98Dialog), findsNothing);
        expect(env.result?.id, id);
        expect(_servers(env), [(id, 'nas', _url)]);
        expect(env.tokens.tokens, {id: _fresh});
        expect(
          env.container.read(hostedConnectionStatusProvider(id)),
          HostedConnectionStatus.connected,
          reason: 'banners and polling see the server connected again',
        );
      },
    );
  });

  group('save shows the connect errors (AC11)', () {
    for (final (name, arrange, message, underToken) in [
      (
        'edit save on a refused connection shows cant reach and changes nothing',
        (FakeVaultServer s) => s.failure = FakeServerFailure.refused,
        wi98CantReach(_url),
        false,
      ),
      (
        'edit save on a 401 shows access token rejected and changes nothing',
        (FakeVaultServer s) => s.token = 'tok-other-98',
        kWi98TokenRejected,
        true,
      ),
      (
        'edit save on an html answer shows isnt a memex vault server and changes nothing',
        (FakeVaultServer s) => s.servesHtml = true,
        wi98NotMemex(_url),
        false,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = await _openEdit(tester);
        final id = env.edit!.id;
        arrange(env.server);
        await env.fill(name: 'nas edited');

        await env.submit();
        await tester.pumpAndSettle();

        expectWi98A5Error(tester, message);
        expectWi98Between(
          tester,
          find.text(message),
          below: find.byKey(underToken ? kWi98Token : kWi98Url),
          above: underToken
              ? find.byKey(kWi98Submit)
              : find.text('access token'),
        );
        expect(find.byKey(kWi98Dialog), findsOneWidget);
        expect(_servers(env), [(id, 'nas', _url)], reason: 'unchanged');
        expect(env.tokens.tokens, {id: _stored});
      });
    }

    testWidgets(
      'edit save on an api mismatch shows the L9 message and changes nothing',
      (tester) async {
        final env = await _openEdit(tester);
        final id = env.edit!.id;
        env.server.route(
          'GET',
          '/api/v1/info',
          json: {'server_version': '2.0.0', 'api_version': 2},
        );

        await env.submit();
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: find.byKey(kWi98Error),
            matching: find.text(wi98ApiMismatch('nas', '2.0.0')),
          ),
          findsOneWidget,
        );
        expect(_servers(env), [(id, 'nas', _url)]);
        expect(env.tokens.tokens, {id: _stored});
      },
    );

    testWidgets(
      'edit save with a url without a scheme shows the scheme error and sends no request',
      (tester) async {
        final env = await _openEdit(tester);
        final id = env.edit!.id;
        await env.fill(url: 'nas.local:7878');

        await env.submit();
        await tester.pumpAndSettle();

        expect(env.server.requests, isEmpty);
        expectWi98A5Error(tester, kWi98SchemeError);
        expect(_servers(env), [(id, 'nas', _url)]);
      },
    );
  });

  group('url dedupe on edit (lead update from #91)', () {
    testWidgets(
      'edit refuses a url that normalises to another saved server url',
      (tester) async {
        final env = await _openEdit(tester, withMini: true);
        final before = _servers(env);
        final tokensBefore = {...env.tokens.tokens};
        await env.fill(url: 'http://Mini.LOCAL:7878/');

        await env.submit();
        await tester.pumpAndSettle();

        final error = find.textContaining('is already saved');
        expect(error, findsOneWidget, reason: 'an inline url error');
        expectWi98Between(
          tester,
          error,
          below: find.byKey(kWi98Url),
          above: find.text('access token'),
        );
        expect(
          wi98BorderColorsOf(tester, kWi98Url),
          contains(kWi98InvalidBorder),
        );
        expect(env.server.requests, isEmpty, reason: 'refused before a probe');
        expect(find.byKey(kWi98Dialog), findsOneWidget);
        expect(_servers(env), before, reason: 'both servers unchanged');
        expect(env.tokens.tokens, tokensBefore);
      },
    );

    testWidgets('edit allows its own url written another way', (tester) async {
      final env = await _openEdit(tester, withMini: true);
      final id = env.edit!.id;
      await env.fill(url: 'http://NAS.local:7878/');

      await env.submit();
      await tester.pumpAndSettle();

      expect(find.textContaining('is already saved'), findsNothing);
      expect(env.returned, isTrue);
      expect(env.result?.id, id);
      expect(env.saved, hasLength(2));
      expect(env.saved.first.id, id);
    });
  });

  group('cancel (AC11)', () {
    testWidgets('cancel in edit changes nothing', (tester) async {
      final env = await _openEdit(tester);
      final before = _servers(env);
      await env.fill(name: 'renamed', url: _miniUrl, token: _fresh);

      await tester.tap(find.byKey(kWi98Cancel));
      await tester.pumpAndSettle();

      expect(find.byKey(kWi98Dialog), findsNothing);
      expect(env.returned, isTrue);
      expect(env.result, isNull);
      expect(env.server.requests, isEmpty);
      expect(_servers(env), before);
      expect(env.tokens.tokens, {env.edit!.id: _stored});
    });

    testWidgets(
      'cancel while saving closes the edit dialog and a late response changes nothing',
      (tester) async {
        final env = await _openEdit(tester, server: _server(token: _fresh));
        final before = _servers(env);
        await env.fill(name: 'renamed', token: _fresh);
        env.server.hold();
        await env.submit();
        expect(env.server.requests, hasLength(1), reason: 'probe pending');

        await tester.tap(find.byKey(kWi98Cancel));
        await tester.pumpAndSettle();
        expect(find.byKey(kWi98Dialog), findsNothing);
        expect(env.result, isNull);

        env.server.release();
        await env.pumpFrames();
        await tester.pumpAndSettle();

        expect(_servers(env), before);
        expect(env.tokens.tokens, {env.edit!.id: _stored});
      },
    );

    testWidgets(
      'cancel after the edit probe answers but before the update finishes changes nothing',
      (tester) async {
        final tokens = Wi98GatedTokenStore();
        final env = await pumpWi98Host(
          tester,
          server: _server(token: _fresh),
          seed: [(name: 'nas', url: _url, token: _stored)],
          editIndex: 0,
          tokenStore: tokens,
        );
        await env.open();
        final before = _servers(env);
        await env.fill(name: 'renamed', token: _fresh);
        tokens.hold();

        await env.submit();
        expect(env.server.requests, hasLength(1), reason: 'probe answered');
        expect(
          wi98Connecting(),
          findsOneWidget,
          reason: 'the update is in flight: the dialog still reads connecting',
        );

        await tester.tap(find.byKey(kWi98Cancel));
        await tester.pumpAndSettle();
        expect(find.byKey(kWi98Dialog), findsNothing);
        expect(env.result, isNull);

        tokens.release();
        await env.pumpFrames();
        await tester.pumpAndSettle();

        expect(_servers(env), before, reason: 'name and url unchanged');
        expect(env.tokens.tokens, {
          env.edit!.id: _stored,
        }, reason: 'token kept');
      },
    );

    testWidgets(
      'edit undo of a cancelled save without a pasted token restores name and url and writes no token',
      (tester) async {
        final env = await _openEdit(tester);
        final id = env.edit!.id;
        final before = _servers(env);
        final callsBefore = env.tokens.calls.length;
        await env.fill(name: 'renamed', url: 'http://nas2.local:7878');
        // No token is pasted, so the update writes no token and nothing
        // holds it: cancel (a pop) lands the moment the update stores the
        // edited server, before updateServer returns.
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        var popped = false;
        final removeListener = env.settings.addListener((s) {
          if (!popped && s.savedServers.any((x) => x.name == 'renamed')) {
            popped = true;
            navigator.pop();
          }
        }, fireImmediately: false);
        addTearDown(removeListener);

        await env.submit();
        await tester.pumpAndSettle();

        expect(popped, isTrue, reason: 'the update ran and cancel landed');
        expect(find.byKey(kWi98Dialog), findsNothing);
        expect(env.returned, isTrue);
        expect(env.result, isNull);
        expect(_servers(env), before, reason: 'name and url restored');
        expect(env.tokens.tokens, {id: _stored});
        expect(
          env.tokens.calls
              .skip(callsBefore)
              .where((c) => !c.startsWith('read')),
          isEmpty,
          reason: 'no pasted token replaced it, so the undo writes none back',
        );
      },
    );

    testWidgets(
      'edit undo of a pasted token on a server with no stored token leaves it with none',
      (tester) async {
        final tokens = Wi98GatedTokenStore();
        final env = await pumpWi98Host(
          tester,
          server: _server(token: _fresh),
          seed: [(name: 'nas', url: _url, token: _stored)],
          editIndex: 0,
          tokenStore: tokens,
        );
        final id = env.edit!.id;
        tokens.tokens.remove(id);
        await env.open();
        final before = _servers(env);
        await env.fill(name: 'renamed', token: _fresh);
        tokens.hold();

        await env.submit();
        expect(wi98Connecting(), findsOneWidget, reason: 'update in flight');
        await tester.tap(find.byKey(kWi98Cancel));
        await tester.pumpAndSettle();
        expect(env.result, isNull);

        tokens.release();
        await env.pumpFrames();
        await tester.pumpAndSettle();

        expect(_servers(env), before);
        expect(
          env.tokens.tokens,
          isEmpty,
          reason: 'the pasted token is removed again: none was stored',
        );
      },
    );
  });

  group('edit contracts (verify)', () {
    testWidgets('edit shows connecting while save re-probes', (tester) async {
      final env = await _openEdit(tester);
      env.server.hold();

      await env.submit();

      expect(wi98Connecting(), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(kWi98Submit),
          matching: find.text('save'),
        ),
        findsNothing,
      );
      for (final key in [kWi98Name, kWi98Url, kWi98Token]) {
        expect(wi98EditableOf(tester, key).readOnly, isTrue);
      }

      env.server.release();
      await env.pumpFrames();
      await tester.pumpAndSettle();
      expect(env.returned, isTrue);
    });

    for (final (name, typed) in [
      ('edit save with an empty token writes no token', ''),
      (
        'edit save with a whitespace only token uses the stored token and writes no token',
        '   ',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = await _openEdit(tester);
        final id = env.edit!.id;
        final callsBefore = env.tokens.calls.length;
        await env.fill(name: 'nas home', token: typed);

        await env.submit();
        await tester.pumpAndSettle();

        expect(
          env.server.requests.single.headers['Authorization'],
          'Bearer $_stored',
        );
        expect(env.result?.id, id);
        expect(_servers(env), [(id, 'nas home', _url)]);
        expect(
          env.tokens.calls
              .skip(callsBefore)
              .where((c) => c.startsWith('write')),
          isEmpty,
          reason: 'updateServer gets a token only when one was pasted',
        );
        expect(env.tokens.tokens, {id: _stored});
      });
    }

    testWidgets('edit save trims a pasted token', (tester) async {
      final env = await _openEdit(tester, server: _server(token: _fresh));
      final id = env.edit!.id;
      await env.fill(token: '  $_fresh  ');

      await env.submit();
      await tester.pumpAndSettle();

      expect(
        env.server.requests.single.headers['Authorization'],
        'Bearer $_fresh',
      );
      expect(env.tokens.tokens, {id: _fresh});
      expect(env.tokens.calls.last, 'write $id');
    });

    testWidgets('the edit token field shows a 26 bullet placeholder in fg2', (
      tester,
    ) async {
      await _openEdit(tester);

      final placeholder = find.descendant(
        of: find.byKey(kWi98Token),
        matching: find.text('•' * 26),
      );
      expect(placeholder, findsOneWidget);
      final style = tester.widget<Text>(placeholder).style;
      expect(style?.color, OmColors.fg2);
      expect(style?.letterSpacing, 2);
    });

    testWidgets('the connect token field has no placeholder', (tester) async {
      final env = await pumpWi98Host(tester, server: _server());
      await env.open();

      expect(
        find.descendant(
          of: find.byKey(kWi98Token),
          matching: find.textContaining('•'),
        ),
        findsNothing,
      );
    });

    testWidgets('the edit dialog autofocuses the access token field', (
      tester,
    ) async {
      await _openEdit(tester);

      expect(wi98Focused(tester, kWi98Token), isTrue);
      expect(wi98Focused(tester, kWi98Url), isFalse);
      expect(wi98Focused(tester, kWi98Name), isFalse);
    });

    testWidgets(
      'the edit refusal names the normalised url and the other server',
      (tester) async {
        final env = await _openEdit(tester, withMini: true);
        await env.fill(url: 'http://Mini.LOCAL:7878/');

        await env.submit();
        await tester.pumpAndSettle();

        expectWi98A5Error(tester, '$_miniUrl is already saved as mini');
      },
    );
  });
}
