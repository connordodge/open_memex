// WI #98 (H4, Spec #67 req 43, L9, L10, L18; D17, D18, D20): the
// "connect to a vault server" dialog (boards A4, A5 states 1-5).
//
// API under test (app/lib/src/widgets/hosted/connect_server_dialog.dart):
//   Future<SavedServer?> showConnectServerDialog(BuildContext context,
//       {SavedServer? edit, VoidCallback? onSetUp})
//   connectServerHttpClientProvider: Provider<http.Client> (the probe's HTTP
//       client; tests override it with FakeVaultServer.client)
// The probe is #77's HostedClient.probeServer (Authorization: Bearer, 10 s
// timeout through clockProvider); saving is #91's SettingsController
// .saveServer (name and URL in prefs, the access token in the TokenStore).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/hosted/connect_server_dialog.dart';

import '../../support/fake_vault_server.dart';
import 'wi98_connect_harness.dart';

const _url = 'http://nas.local:7878';
const _token = 'tok-connect-98-secret';

/// A fake server that knows [_token] and answers `GET /api/v1/info` with the
/// frozen contract fixture (api_version 1).
FakeVaultServer _server() =>
    FakeVaultServer(token: _token)..serveDomain('server');

void _expectNothingSaved(Wi98Env env) {
  expect(env.saved, isEmpty, reason: 'no server is saved');
  expect(env.tokens.tokens, isEmpty, reason: 'no token is stored');
}

void main() {
  group('form (AC1)', () {
    testWidgets(
      'the form shows the name url and token fields with the board labels and the token hint',
      (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        await env.open();

        expect(find.text('CONNECT TO A VAULT SERVER'), findsOneWidget);
        expect(find.byKey(kWi98Name), findsOneWidget);
        expect(find.byKey(kWi98Url), findsOneWidget);
        expect(find.byKey(kWi98Token), findsOneWidget);
        expect(find.text('name (optional)'), findsOneWidget);
        expect(find.text('server url'), findsOneWidget);
        expect(find.text('access token'), findsOneWidget);
        expect(find.text(kWi98ConnectHint), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(kWi98SetupLink),
            matching: find.text('how do I set one up?'),
          ),
          findsOneWidget,
        );
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
            matching: find.text('connect'),
          ),
          findsOneWidget,
        );
        // Field order on the board: name, server url, access token.
        final name = tester.getRect(find.byKey(kWi98Name));
        final url = tester.getRect(find.byKey(kWi98Url));
        final token = tester.getRect(find.byKey(kWi98Token));
        expect(name.bottom, lessThanOrEqualTo(url.top));
        expect(url.bottom, lessThanOrEqualTo(token.top));
        // The token hint sits under the token field.
        expectWi98Between(
          tester,
          find.text(kWi98ConnectHint),
          below: find.byKey(kWi98Token),
          above: find.byKey(kWi98Submit),
        );
      },
    );

    testWidgets('the connect dialog is 472 wide', (tester) async {
      final env = await pumpWi98Host(tester, server: _server());
      await env.open();

      expect(tester.getSize(find.byKey(kWi98Dialog)).width, 472);
    });

    testWidgets(
      'the token is obscured by default and the eye toggle shows and hides it',
      (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        await env.open();
        await env.fill(token: _token);

        expect(wi98EditableOf(tester, kWi98Token).obscureText, isTrue);
        expect(
          find.descendant(
            of: find.byKey(kWi98Toggle),
            matching: find.byIcon(LucideIcons.eye),
          ),
          findsOneWidget,
          reason: 'hidden: the eye icon',
        );

        await tester.tap(find.byKey(kWi98Toggle));
        await tester.pumpAndSettle();
        expect(wi98EditableOf(tester, kWi98Token).obscureText, isFalse);
        expect(
          find.descendant(
            of: find.byKey(kWi98Toggle),
            matching: find.byIcon(LucideIcons.eyeOff),
          ),
          findsOneWidget,
          reason: 'shown: the eyeOff icon',
        );

        await tester.tap(find.byKey(kWi98Toggle));
        await tester.pumpAndSettle();
        expect(wi98EditableOf(tester, kWi98Token).obscureText, isTrue);
        expect(
          wi98EditableOf(tester, kWi98Token).controller.text,
          _token,
          reason: 'toggling never changes the token',
        );
      },
    );

    testWidgets('the name placeholder is the host of the entered url', (
      tester,
    ) async {
      final env = await pumpWi98Host(tester, server: _server());
      await env.open();
      await env.fill(url: _url);

      expect(
        find.descendant(
          of: find.byKey(kWi98Name),
          matching: find.text('nas.local'),
        ),
        findsOneWidget,
      );
      expect(wi98EditableOf(tester, kWi98Name).controller.text, isEmpty);
    });

    testWidgets('how do I set one up calls onSetUp', (tester) async {
      final env = await pumpWi98Host(tester, server: _server());
      await env.open();

      await tester.tap(find.byKey(kWi98SetupLink));
      await tester.pumpAndSettle();

      expect(env.setUpCalls, 1);
      expect(env.server.requests, isEmpty);
      _expectNothingSaved(env);
    });

    testWidgets('an empty name saves as the host of the url', (tester) async {
      final env = await pumpWi98Host(tester, server: _server());
      await env.open();
      await env.fill(url: _url, token: _token);

      await env.submit();
      await tester.pumpAndSettle();

      expect(env.returned, isTrue);
      expect(env.result?.name, 'nas.local');
      expect(env.saved.single.name, 'nas.local');
    });

    testWidgets('a whitespace only name saves as the host of the url', (
      tester,
    ) async {
      final env = await pumpWi98Host(tester, server: _server());
      await env.open();
      await env.fill(name: '   ', url: _url, token: _token);

      await env.submit();
      await tester.pumpAndSettle();

      expect(env.saved.single.name, 'nas.local');
    });
  });

  group('url check before any request (AC2)', () {
    for (final (name, url) in [
      (
        'a url without a scheme shows the scheme error under the url field and sends no request',
        'nas.local:7878',
      ),
      (
        'an ftp url shows the scheme error under the url field and sends no request',
        'ftp://nas.local:7878',
      ),
      (
        'an empty url shows the scheme error under the url field and sends no request',
        '',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        await env.open();
        await env.fill(url: url, token: _token);

        await env.submit();
        await tester.pumpAndSettle();

        expect(env.server.requests, isEmpty, reason: 'no request is sent');
        expectWi98A5Error(tester, kWi98SchemeError);
        expectWi98Between(
          tester,
          find.text(kWi98SchemeError),
          below: find.byKey(kWi98Url),
          above: find.text('access token'),
        );
        expect(
          wi98BorderColorsOf(tester, kWi98Url),
          contains(kWi98InvalidBorder),
          reason: 'the server url input turns red',
        );
        expect(find.byKey(kWi98Dialog), findsOneWidget);
        _expectNothingSaved(env);
      });
    }
  });

  group('connecting (AC3)', () {
    testWidgets(
      'connect sends one info request with the bearer token and shows connecting while it waits',
      (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        await env.open();
        await env.fill(name: 'nas', url: _url, token: _token);
        env.server.hold();

        await env.submit();

        expect(env.server.requests, hasLength(1));
        final request = env.server.requests.single;
        expect(request.method, 'GET');
        expect(request.url, Uri.parse('$_url/api/v1/info'));
        expect(request.headers['Authorization'], 'Bearer $_token');

        // The primary reads "connecting…" with the loader2 spinner.
        expect(
          find.descendant(
            of: find.byKey(kWi98Submit),
            matching: find.text('connecting…'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(kWi98Submit),
            matching: find.byIcon(LucideIcons.loader2),
          ),
          findsOneWidget,
        );
        // Fields are read-only while connecting.
        for (final key in [kWi98Name, kWi98Url, kWi98Token]) {
          expect(
            wi98EditableOf(tester, key).readOnly,
            isTrue,
            reason: '$key is read-only while connecting',
          );
        }
        // Lead decision: drawn undimmed as A5 state 2 (no 40% opacity).
        for (final e
            in find
                .descendant(
                  of: find.byKey(kWi98Dialog),
                  matching: find.byType(Opacity),
                )
                .evaluate()) {
          expect(
            (e.widget as Opacity).opacity,
            1.0,
            reason: 'nothing in the dialog is dimmed while connecting',
          );
        }
        // The primary is disabled: a second tap sends nothing.
        await env.submit();
        expect(env.server.requests, hasLength(1));

        env.server.release();
        await env.pumpFrames();
        await tester.pumpAndSettle();

        expect(env.returned, isTrue);
        expect(env.result, isNotNull);
        expect(env.server.requests, hasLength(1));
      },
    );

    testWidgets(
      'cancel while connecting closes the dialog and a late response saves nothing',
      (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        await env.open();
        await env.fill(name: 'nas', url: _url, token: _token);
        env.server.hold();
        await env.submit();
        expect(
          find.descendant(
            of: find.byKey(kWi98Submit),
            matching: find.text('connecting…'),
          ),
          findsOneWidget,
        );

        await tester.tap(find.byKey(kWi98Cancel));
        await tester.pumpAndSettle();

        expect(find.byKey(kWi98Dialog), findsNothing);
        expect(env.returned, isTrue);
        expect(env.result, isNull);

        env.server.release();
        await env.pumpFrames();
        await tester.pumpAndSettle();

        _expectNothingSaved(env);
        expect(await env.prefsWith(_token), isEmpty);
      },
    );

    testWidgets(
      'cancel before connecting changes nothing and sends no request',
      (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        await env.open();
        await env.fill(name: 'nas', url: _url, token: _token);

        await tester.tap(find.byKey(kWi98Cancel));
        await tester.pumpAndSettle();

        expect(find.byKey(kWi98Dialog), findsNothing);
        expect(env.returned, isTrue);
        expect(env.result, isNull);
        expect(env.server.requests, isEmpty);
        _expectNothingSaved(env);
      },
    );
  });

  group('cant reach (AC5)', () {
    for (final (name, failure) in [
      (
        'a refused connection shows cant reach under the url field and saves nothing',
        FakeServerFailure.refused,
      ),
      (
        'a failed host lookup shows cant reach under the url field and saves nothing',
        FakeServerFailure.hostLookup,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        await env.open();
        await env.fill(name: 'nas', url: _url, token: _token);
        env.server.failure = failure;

        await env.submit();
        await tester.pumpAndSettle();

        expectWi98A5Error(tester, wi98CantReach(_url));
        expectWi98Between(
          tester,
          find.text(wi98CantReach(_url)),
          below: find.byKey(kWi98Url),
          above: find.text('access token'),
        );
        expect(
          wi98BorderColorsOf(tester, kWi98Url),
          contains(kWi98InvalidBorder),
        );
        // The token hint stays: only a token error replaces it.
        expect(find.text(kWi98ConnectHint), findsOneWidget);
        _expectNothingSaved(env);

        // Connect is enabled again: a retry sends a second request.
        expect(
          find.descendant(
            of: find.byKey(kWi98Submit),
            matching: find.text('connect'),
          ),
          findsOneWidget,
        );
        env.server.failure = null;
        await env.submit();
        await tester.pumpAndSettle();
        expect(env.server.requests, hasLength(2));
        expect(env.returned, isTrue);
        expect(env.saved, hasLength(1));
      });
    }

    testWidgets(
      'no answer within 10 s shows cant reach under the url field and saves nothing',
      (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        await env.open();
        await env.fill(name: 'nas', url: _url, token: _token);
        env.server.failure = FakeServerFailure.timeout;

        await env.submit();
        env.clock.advance(const Duration(seconds: 9));
        await env.pumpFrames();
        expect(
          find.descendant(
            of: find.byKey(kWi98Submit),
            matching: find.text('connecting…'),
          ),
          findsOneWidget,
          reason: 'still connecting after 9 s',
        );
        expect(find.text(wi98CantReach(_url)), findsNothing);

        env.clock.advance(const Duration(seconds: 1));
        await env.pumpFrames();
        await tester.pumpAndSettle();

        expectWi98A5Error(tester, wi98CantReach(_url));
        expectWi98Between(
          tester,
          find.text(wi98CantReach(_url)),
          below: find.byKey(kWi98Url),
          above: find.text('access token'),
        );
        _expectNothingSaved(env);
        expect(
          find.descendant(
            of: find.byKey(kWi98Submit),
            matching: find.text('connect'),
          ),
          findsOneWidget,
        );
        for (final key in [kWi98Name, kWi98Url, kWi98Token]) {
          expect(wi98EditableOf(tester, key).readOnly, isFalse);
        }

        env.server.failure = null;
        await env.submit();
        await tester.pumpAndSettle();
        expect(env.server.requests, hasLength(2));
        expect(env.saved, hasLength(1));
      },
    );
  });

  group('token rejected (AC6)', () {
    testWidgets(
      'a 401 shows access token rejected under the token field and saves nothing',
      (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        await env.open();
        await env.fill(name: 'nas', url: _url, token: 'tok-wrong-98');

        await env.submit();
        await tester.pumpAndSettle();

        expectWi98A5Error(tester, kWi98TokenRejected);
        expectWi98Between(
          tester,
          find.text(kWi98TokenRejected),
          below: find.byKey(kWi98Token),
          above: find.byKey(kWi98Submit),
        );
        expect(
          wi98BorderColorsOf(tester, kWi98Token),
          contains(kWi98InvalidBorder),
          reason: 'the access token input turns red',
        );
        expect(
          find.text(kWi98ConnectHint),
          findsNothing,
          reason: 'the token error replaces the hint',
        );
        _expectNothingSaved(env);
        expect(find.byKey(kWi98Dialog), findsOneWidget);
      },
    );
  });

  group('not a memex vault server (AC7)', () {
    testWidgets(
      'an html answer shows isnt a memex vault server under the url field and saves nothing',
      (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        env.server.servesHtml = true;
        await env.open();
        await env.fill(name: 'nas', url: _url, token: _token);

        await env.submit();
        await tester.pumpAndSettle();

        expectWi98A5Error(tester, wi98NotMemex(_url));
        expectWi98Between(
          tester,
          find.text(wi98NotMemex(_url)),
          below: find.byKey(kWi98Url),
          above: find.text('access token'),
        );
        expect(
          wi98BorderColorsOf(tester, kWi98Url),
          contains(kWi98InvalidBorder),
        );
        _expectNothingSaved(env);
      },
    );

    testWidgets(
      'an info body without api_version shows isnt a memex vault server and saves nothing',
      (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        env.server.route(
          'GET',
          '/api/v1/info',
          json: {'server_version': '0.1.0'},
        );
        await env.open();
        await env.fill(name: 'nas', url: _url, token: _token);

        await env.submit();
        await tester.pumpAndSettle();

        expectWi98A5Error(tester, wi98NotMemex(_url));
        _expectNothingSaved(env);
      },
    );
  });

  group('api version mismatch (AC8)', () {
    for (final (name, typedName, server) in [
      (
        'an api mismatch shows the L9 message naming the entered name and the server version',
        'nas',
        'nas',
      ),
      (
        'an api mismatch with no name names the url host in the L9 message',
        '',
        'nas.local',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        env.server.route(
          'GET',
          '/api/v1/info',
          json: {'server_version': '2.0.0', 'api_version': 2},
        );
        await env.open();
        await env.fill(name: typedName, url: _url, token: _token);

        await env.submit();
        await tester.pumpAndSettle();

        final message = wi98ApiMismatch(server, '2.0.0');
        expect(
          find.descendant(
            of: find.byKey(kWi98Error),
            matching: find.text(message),
          ),
          findsOneWidget,
        );
        // A danger box above the buttons (A5 state 5).
        expectWi98Between(
          tester,
          find.byKey(kWi98Error),
          below: find.byKey(kWi98Token),
          above: find.byKey(kWi98Submit),
        );
        final boxes = [
          for (final e
              in find
                  .descendant(
                    of: find.byKey(kWi98Error),
                    matching: find.byType(DecoratedBox),
                  )
                  .evaluate())
            (e.widget as DecoratedBox).decoration,
          if (tester.widget(find.byKey(kWi98Error)) case final DecoratedBox d)
            d.decoration,
        ].whereType<BoxDecoration>();
        expect(
          boxes.any(
            (d) =>
                d.color == OmColors.dangerBg &&
                d.border is Border &&
                (d.border! as Border).top.color ==
                    OmColors.danger.withAlpha(69),
          ),
          isTrue,
          reason: 'the L9 box is dangerBg with a danger 69 border',
        );
        _expectNothingSaved(env);
      });
    }
  });

  group('success (AC9, AC10)', () {
    testWidgets(
      'success closes the dialog and returns the saved server with the token only in the token store',
      (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        await env.open();
        await env.fill(name: 'nas', url: _url, token: _token);

        await env.submit();
        await tester.pumpAndSettle();

        expect(find.byKey(kWi98Dialog), findsNothing);
        expect(env.returned, isTrue);
        final result = env.result!;
        expect((result.name, result.url), ('nas', _url));
        final saved = env.saved.single;
        expect((saved.id, saved.name, saved.url), (result.id, 'nas', _url));
        expect(env.tokens.tokens, {result.id: _token});
        expect(
          await env.prefsWith(_token),
          isEmpty,
          reason: 'no SharedPreferences value holds the token',
        );
      },
    );

    testWidgets(
      'connecting to a url that is already saved updates its name and token and keeps its id',
      (tester) async {
        final env = await pumpWi98Host(
          tester,
          server: _server(),
          seed: [(name: 'old nas', url: _url, token: 'tok-old-98')],
        );
        final id = env.saved.single.id;
        await env.open();
        await env.fill(
          name: 'nas home',
          url: 'http://NAS.local:7878/',
          token: _token,
        );

        await env.submit();
        await tester.pumpAndSettle();

        expect(env.returned, isTrue);
        expect(env.result?.id, id);
        expect(env.saved, hasLength(1), reason: 'no second server');
        expect(env.saved.single.id, id);
        expect(env.saved.single.name, 'nas home');
        expect(env.tokens.tokens, {id: _token});
        expect(await env.prefsWith(_token), isEmpty);
      },
    );
  });

  group('token secrecy (D18)', () {
    testWidgets('the access token never appears in logs or in rendered text', (
      tester,
    ) async {
      final logs = <String>[];
      final oldDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        logs.add(message ?? '');
      };
      try {
        await runZoned(
          () async {
            final env = await pumpWi98Host(tester, server: _server());
            await env.open();
            await env.fill(name: 'nas', url: _url, token: 'tok-wrong-98');
            expect(
              wi98RenderedStrings(
                tester,
              ).where((s) => s.contains('tok-wrong-98')),
              isEmpty,
            );

            await env.submit();
            await tester.pumpAndSettle();
            expect(find.text(kWi98TokenRejected), findsOneWidget);
            expect(
              wi98RenderedStrings(
                tester,
              ).where((s) => s.contains('tok-wrong-98')),
              isEmpty,
              reason: 'the rejected state never shows the token',
            );

            await env.fill(token: _token);
            await env.submit();
            await tester.pumpAndSettle();
            expect(env.saved, hasLength(1));
            expect(
              wi98RenderedStrings(tester).where((s) => s.contains(_token)),
              isEmpty,
            );
          },
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => logs.add(line),
          ),
        );
      } finally {
        debugPrint = oldDebugPrint;
      }
      expect(
        logs.where((l) => l.contains(_token) || l.contains('tok-wrong-98')),
        isEmpty,
        reason: 'no log line carries an access token',
      );
    });
  });

  group('normalised url and scheme check (verify)', () {
    testWidgets('cant reach names the normalised url', (tester) async {
      final env = await pumpWi98Host(tester, server: _server());
      await env.open();
      await env.fill(name: 'nas', url: 'http://NAS.local:7878/', token: _token);
      env.server.failure = FakeServerFailure.refused;

      await env.submit();
      await tester.pumpAndSettle();

      expectWi98A5Error(tester, wi98CantReach(_url));
      expect(find.text(wi98CantReach('http://NAS.local:7878/')), findsNothing);
      _expectNothingSaved(env);
    });

    testWidgets('isnt a memex vault server names the normalised url', (
      tester,
    ) async {
      final env = await pumpWi98Host(tester, server: _server());
      env.server.servesHtml = true;
      await env.open();
      await env.fill(name: 'nas', url: 'HTTP://Nas.Local:7878/', token: _token);

      await env.submit();
      await tester.pumpAndSettle();

      expectWi98A5Error(tester, wi98NotMemex(_url));
      _expectNothingSaved(env);
    });

    for (final (name, typed) in [
      (
        'an uppercase HTTP scheme passes the url check and saves the normalised url',
        'HTTP://nas.local:7878',
      ),
      (
        'a mixed case scheme and host pass the url check and save the normalised url',
        'Http://NAS.Local:7878/',
      ),
      (
        'a url padded with spaces passes the url check and saves the trimmed url',
        '  http://nas.local:7878  ',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        await env.open();
        await env.fill(name: 'nas', url: typed, token: _token);

        await env.submit();
        await tester.pumpAndSettle();

        expect(find.text(kWi98SchemeError), findsNothing);
        expect(env.server.requests.single.url, Uri.parse('$_url/api/v1/info'));
        expect(env.returned, isTrue);
        expect(env.result?.url, _url);
        expect(env.saved.single.url, _url);
        expect(env.saved.single.name, 'nas');
      });
    }
  });

  group('token handling (verify)', () {
    testWidgets('the pasted token is trimmed before the probe and the save', (
      tester,
    ) async {
      final env = await pumpWi98Host(tester, server: _server());
      await env.open();
      await env.fill(name: 'nas', url: _url, token: '  $_token  ');

      await env.submit();
      await tester.pumpAndSettle();

      expect(
        env.server.requests.single.headers['Authorization'],
        'Bearer $_token',
      );
      expect(env.returned, isTrue);
      expect(env.tokens.tokens, {env.result!.id: _token});
    });

    testWidgets('an empty token still probes and shows access token rejected', (
      tester,
    ) async {
      final env = await pumpWi98Host(tester, server: _server());
      await env.open();
      await env.fill(name: 'nas', url: _url);

      await env.submit();
      await tester.pumpAndSettle();

      expect(env.server.requests, hasLength(1));
      expectWi98A5Error(tester, kWi98TokenRejected);
      _expectNothingSaved(env);
    });
  });

  group('errors clear (verify)', () {
    testWidgets(
      'editing the url clears the url error and editing the token does not',
      (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        await env.open();
        await env.fill(name: 'nas', url: _url, token: _token);
        env.server.failure = FakeServerFailure.refused;
        await env.submit();
        await tester.pumpAndSettle();
        expect(find.text(wi98CantReach(_url)), findsOneWidget);

        await env.fill(token: 'tok-other-98');
        expect(
          find.text(wi98CantReach(_url)),
          findsOneWidget,
          reason: 'a token edit leaves the url error',
        );

        await env.fill(url: 'http://nas.local:7879');
        expect(find.text(wi98CantReach(_url)), findsNothing);
        expect(
          wi98BorderColorsOf(tester, kWi98Url),
          isNot(contains(kWi98InvalidBorder)),
          reason: 'the url input is no longer red',
        );
      },
    );

    testWidgets(
      'editing the token clears the token error and editing the url does not',
      (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        await env.open();
        await env.fill(name: 'nas', url: _url, token: 'tok-wrong-98');
        await env.submit();
        await tester.pumpAndSettle();
        expect(find.text(kWi98TokenRejected), findsOneWidget);

        await env.fill(url: 'http://nas.local:7879');
        expect(
          find.text(kWi98TokenRejected),
          findsOneWidget,
          reason: 'a url edit leaves the token error',
        );

        await env.fill(token: _token);
        expect(find.text(kWi98TokenRejected), findsNothing);
        expect(
          find.text(kWi98ConnectHint),
          findsOneWidget,
          reason: 'the hint is back',
        );
        expect(
          wi98BorderColorsOf(tester, kWi98Token),
          isNot(contains(kWi98InvalidBorder)),
        );
      },
    );

    testWidgets('a new connect clears the previous error while it waits', (
      tester,
    ) async {
      final env = await pumpWi98Host(tester, server: _server());
      env.server.route(
        'GET',
        '/api/v1/info',
        json: {'server_version': '2.0.0', 'api_version': 2},
      );
      await env.open();
      await env.fill(name: 'nas', url: _url, token: _token);
      await env.submit();
      await tester.pumpAndSettle();
      expect(find.byKey(kWi98Error), findsOneWidget);

      env.server.hold();
      await env.submit();
      expect(wi98Connecting(), findsOneWidget);
      expect(find.byKey(kWi98Error), findsNothing);

      env.server.release();
      await env.pumpFrames();
      await tester.pumpAndSettle();
      expect(find.byKey(kWi98Error), findsOneWidget);
    });
  });

  group('focus (verify)', () {
    testWidgets('the connect dialog autofocuses the server url field', (
      tester,
    ) async {
      final env = await pumpWi98Host(tester, server: _server());
      await env.open();

      expect(wi98Focused(tester, kWi98Url), isTrue);
      expect(wi98Focused(tester, kWi98Name), isFalse);
      expect(wi98Focused(tester, kWi98Token), isFalse);
    });

    testWidgets(
      'a focused input draws the accent border and ring and an invalid one only the danger border',
      (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        await env.open();

        final focused = wi98BoxOf(tester, kWi98Url);
        expect(
          (focused.border! as Border).top.color,
          OmColors.accent.withAlpha(140),
        );
        expect(focused.boxShadow, hasLength(1));
        expect(focused.boxShadow!.single.color, OmColors.accent.withAlpha(31));
        expect(focused.boxShadow!.single.spreadRadius, 3);
        expect(focused.boxShadow!.single.blurRadius, 0);

        final idle = wi98BoxOf(tester, kWi98Name);
        expect((idle.border! as Border).top.color, OmColors.line2);
        expect(idle.boxShadow, anyOf(isNull, isEmpty));

        // Empty url: the scheme error. The url field keeps focus.
        await env.submit();
        await tester.pumpAndSettle();
        expect(wi98Focused(tester, kWi98Url), isTrue);
        final invalid = wi98BoxOf(tester, kWi98Url);
        expect((invalid.border! as Border).top.color, kWi98InvalidBorder);
        expect(
          invalid.boxShadow,
          anyOf(isNull, isEmpty),
          reason: 'invalid wins over focus: no ring',
        );
      },
    );
  });

  group('saved server status (verify)', () {
    testWidgets(
      'probing an unsaved url leaves every saved server status untouched',
      (tester) async {
        final env = await pumpWi98Host(
          tester,
          server: _server(),
          seed: [
            (name: 'mini', url: 'http://mini.local:7878', token: 'tok-mini-98'),
          ],
        );
        final miniId = env.saved.single.id;
        await env.open();
        await env.fill(name: 'nas', url: _url, token: 'tok-wrong-98');

        await env.submit();
        await tester.pumpAndSettle();
        expect(find.text(kWi98TokenRejected), findsOneWidget);
        expect(
          env.container.read(hostedConnectionStatusProvider(miniId)),
          isNull,
          reason: 'another saved server is not marked token rejected',
        );

        await env.fill(token: _token);
        await env.submit();
        await tester.pumpAndSettle();

        expect(env.saved, hasLength(2));
        final added = env.result!;
        expect(added.id, isNot('connect-server-dialog'));
        expect(added.id, isNot(miniId));
        expect(
          env.container.read(hostedConnectionStatusProvider(miniId)),
          isNull,
        );
        expect(
          env.container.read(hostedConnectionStatusProvider(added.id)),
          isNot(HostedConnectionStatus.tokenRejected),
          reason: 'the earlier rejected probe is not reported for it',
        );
      },
    );

    testWidgets(
      'a server just connected to a new url reads connected and the temporary key holds no status',
      (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        await env.open();
        await env.fill(name: 'nas', url: _url, token: _token);

        await env.submit();
        await tester.pumpAndSettle();

        final added = env.result!;
        expect(
          env.container.read(hostedConnectionStatusProvider(added.id)),
          HostedConnectionStatus.connected,
          reason: 'just proved reachable: the picker does not show checking',
        );
        expect(
          env.container.read(
            hostedConnectionStatusProvider('connect-server-dialog'),
          ),
          isNull,
          reason: 'the temporary probe key keeps no stale status',
        );
      },
    );

    testWidgets(
      'a rejected probe of a new url leaves no status under the temporary key',
      (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        await env.open();
        await env.fill(name: 'nas', url: _url, token: 'tok-wrong-98');

        await env.submit();
        await tester.pumpAndSettle();

        expect(find.text(kWi98TokenRejected), findsOneWidget);
        expect(
          env.container.read(
            hostedConnectionStatusProvider('connect-server-dialog'),
          ),
          isNull,
        );
      },
    );

    testWidgets(
      'connecting to a saved url reports the probe under that server id',
      (tester) async {
        final env = await pumpWi98Host(
          tester,
          server: _server(),
          seed: [(name: 'nas', url: _url, token: 'tok-old-98')],
        );
        final id = env.saved.single.id;
        await env.open();
        await env.fill(url: _url, token: 'tok-wrong-98');

        await env.submit();
        await tester.pumpAndSettle();

        expect(find.text(kWi98TokenRejected), findsOneWidget);
        expect(
          env.container.read(hostedConnectionStatusProvider(id)),
          HostedConnectionStatus.tokenRejected,
        );
        expect(env.tokens.tokens, {id: 'tok-old-98'}, reason: 'nothing saved');
      },
    );
  });

  group('cancel during the save (verify)', () {
    testWidgets(
      'cancel after the probe answers but before the save finishes saves nothing',
      (tester) async {
        final tokens = Wi98GatedTokenStore();
        final env = await pumpWi98Host(
          tester,
          server: _server(),
          tokenStore: tokens,
        );
        await env.open();
        await env.fill(name: 'nas', url: _url, token: _token);
        tokens.hold();

        await env.submit();
        expect(env.server.requests, hasLength(1), reason: 'probe answered');
        expect(
          wi98Connecting(),
          findsOneWidget,
          reason: 'the save is in flight: the dialog still reads connecting',
        );

        await tester.tap(find.byKey(kWi98Cancel));
        await tester.pumpAndSettle();
        expect(find.byKey(kWi98Dialog), findsNothing);
        expect(env.returned, isTrue);
        expect(env.result, isNull, reason: 'cancel returns null');

        tokens.release();
        await env.pumpFrames();
        await tester.pumpAndSettle();

        _expectNothingSaved(env);
        expect(await env.prefsWith('nas.local'), isEmpty);
      },
    );

    testWidgets(
      'cancel during the save of a connect to a saved url restores its name and token',
      (tester) async {
        final tokens = Wi98GatedTokenStore();
        final env = await pumpWi98Host(
          tester,
          server: _server(),
          seed: [(name: 'old nas', url: _url, token: 'tok-old-98')],
          tokenStore: tokens,
        );
        final id = env.saved.single.id;
        await env.open();
        await env.fill(
          name: 'nas home',
          url: 'http://NAS.local:7878/',
          token: _token,
        );
        tokens.hold();

        await env.submit();
        expect(env.server.requests, hasLength(1), reason: 'probe answered');
        expect(wi98Connecting(), findsOneWidget, reason: 'save in flight');
        await tester.tap(find.byKey(kWi98Cancel));
        await tester.pumpAndSettle();
        expect(env.result, isNull);

        tokens.release();
        await env.pumpFrames();
        await tester.pumpAndSettle();

        expect(
          [for (final s in env.saved) (s.id, s.name, s.url)],
          [(id, 'old nas', _url)],
          reason: 'name and url restored',
        );
        expect(env.tokens.tokens, {id: 'tok-old-98'}, reason: 'token restored');
        expect(await env.prefsWith('nas home'), isEmpty);
      },
    );

    testWidgets(
      'cancel during the save of a connect to a saved url with no stored token leaves it with none',
      (tester) async {
        final tokens = Wi98GatedTokenStore();
        final env = await pumpWi98Host(
          tester,
          server: _server(),
          seed: [(name: 'old nas', url: _url, token: 'tok-old-98')],
          tokenStore: tokens,
        );
        final id = env.saved.single.id;
        tokens.tokens.remove(id);
        await env.open();
        await env.fill(name: 'nas home', url: _url, token: _token);
        tokens.hold();

        await env.submit();
        expect(wi98Connecting(), findsOneWidget, reason: 'save in flight');
        await tester.tap(find.byKey(kWi98Cancel));
        await tester.pumpAndSettle();

        tokens.release();
        await env.pumpFrames();
        await tester.pumpAndSettle();

        expect(
          [for (final s in env.saved) (s.id, s.name, s.url)],
          [(id, 'old nas', _url)],
        );
        expect(
          env.tokens.tokens,
          isEmpty,
          reason: 'the server had no stored token, so it ends with none',
        );
      },
    );

    for (final (name, dismiss) in [
      (
        'a barrier tap during the save acts as cancel',
        (WidgetTester t) => t.tapAt(const Offset(5, 5)),
      ),
      (
        'Escape during the save acts as cancel',
        (WidgetTester t) => t.sendKeyEvent(LogicalKeyboardKey.escape),
      ),
    ]) {
      testWidgets(name, (tester) async {
        final tokens = Wi98GatedTokenStore();
        final env = await pumpWi98Host(
          tester,
          server: _server(),
          tokenStore: tokens,
        );
        await env.open();
        await env.fill(name: 'nas', url: _url, token: _token);
        tokens.hold();

        await env.submit();
        expect(wi98Connecting(), findsOneWidget, reason: 'save in flight');
        await dismiss(tester);
        await tester.pumpAndSettle();
        expect(find.byKey(kWi98Dialog), findsNothing);
        expect(env.returned, isTrue);
        expect(env.result, isNull);

        tokens.release();
        await env.pumpFrames();
        await tester.pumpAndSettle();

        _expectNothingSaved(env);
        expect(await env.prefsWith('nas.local'), isEmpty);
      });
    }

    testWidgets(
      'a late probe answer during the pop transition saves nothing and never pops twice',
      (tester) async {
        final env = await pumpWi98Host(tester, server: _server());
        await env.open();
        await env.fill(name: 'nas', url: _url, token: _token);
        env.server.hold();
        await env.submit();

        await tester.tap(find.byKey(kWi98Cancel));
        await tester.pump();
        env.server.release();
        for (var i = 0; i < 6; i++) {
          await tester.pump(Duration.zero);
        }
        expect(
          find.byKey(kWi98Dialog),
          findsOneWidget,
          reason: 'the answer landed while the dialog was still animating out',
        );
        await tester.pumpAndSettle();

        expect(find.byKey(kWi98Dialog), findsNothing);
        expect(env.returned, isTrue);
        expect(env.result, isNull);
        expect(
          find.text('open'),
          findsOneWidget,
          reason: 'the host page under the dialog is never popped',
        );
        expect(env.tokens.calls, isEmpty, reason: 'nothing written');
        _expectNothingSaved(env);
      },
    );

    testWidgets('a cancel before the write starts skips the write', (
      tester,
    ) async {
      final env = await pumpWi98Host(tester, server: _server());
      await env.open();
      await env.fill(name: 'nas', url: _url, token: _token);
      env.server.hold();
      await env.submit();

      await tester.tap(find.byKey(kWi98Cancel));
      await tester.pumpAndSettle();
      env.server.release();
      await env.pumpFrames();
      await tester.pumpAndSettle();

      expect(
        env.tokens.calls,
        isEmpty,
        reason: 'no write to undo: the token store is never touched',
      );
      _expectNothingSaved(env);
    });

    testWidgets(
      'a cancel during the stored token read sends no probe and writes nothing',
      (tester) async {
        final tokens = Wi98GatedTokenStore();
        final env = await pumpWi98Host(
          tester,
          server: _server(),
          seed: [(name: 'old nas', url: _url, token: 'tok-old-98')],
          tokenStore: tokens,
        );
        final id = env.saved.single.id;
        await env.open();
        final callsBefore = tokens.calls.length;
        await env.fill(name: 'nas home', url: _url, token: _token);
        tokens.holdReads();

        await env.submit();
        expect(wi98Connecting(), findsOneWidget, reason: 'reading the token');
        await tester.tap(find.byKey(kWi98Cancel));
        await tester.pumpAndSettle();
        expect(env.result, isNull);

        tokens.releaseReads();
        await env.pumpFrames();
        await tester.pumpAndSettle();

        expect(env.server.requests, isEmpty, reason: 'no probe');
        expect(tokens.calls.skip(callsBefore), ['read $id']);
        expect(env.saved.single.name, 'old nas');
        expect(env.tokens.tokens, {id: 'tok-old-98'});
      },
    );
  });

  group('undo failures (lead ruling)', () {
    for (final (name, seeded) in [
      ('an undo whose token write fails raises no uncaught error', true),
      ('an undo whose token delete fails raises no uncaught error', false),
    ]) {
      testWidgets(name, (tester) async {
        final tokens = Wi98GatedTokenStore();
        final env = await pumpWi98Host(
          tester,
          server: _server(),
          seed: [if (seeded) (name: 'old nas', url: _url, token: 'tok-old-98')],
          tokenStore: tokens,
        );
        await env.open();
        await env.fill(name: 'nas home', url: _url, token: _token);
        tokens.hold();

        await env.submit();
        expect(wi98Connecting(), findsOneWidget, reason: 'save in flight');
        await tester.tap(find.byKey(kWi98Cancel));
        await tester.pumpAndSettle();

        // The save lands; the undo after it hits a Keychain error.
        final callsBefore = tokens.calls.length;
        tokens
          ..failWrites = true
          ..failDeletes = true;
        tokens.release();
        await env.pumpFrames();
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(kWi98Dialog), findsNothing);
        expect(env.returned, isTrue);
        expect(env.result, isNull);
        expect(
          tokens.calls
              .skip(callsBefore)
              .where((c) => c.startsWith(seeded ? 'write' : 'delete')),
          isNotEmpty,
          reason: 'the undo ran and its token call failed',
        );
      });
    }
  });

  group('undo steps (verify)', () {
    testWidgets(
      'a failed token restore still restores the saved server name and url',
      (tester) async {
        final tokens = Wi98GatedTokenStore();
        final env = await pumpWi98Host(
          tester,
          server: _server(),
          seed: [(name: 'old nas', url: _url, token: 'tok-old-98')],
          tokenStore: tokens,
        );
        final id = env.saved.single.id;
        await env.open();
        await env.fill(name: 'nas home', url: _url, token: _token);
        tokens.hold();

        await env.submit();
        expect(wi98Connecting(), findsOneWidget, reason: 'save in flight');
        await tester.tap(find.byKey(kWi98Cancel));
        await tester.pumpAndSettle();

        // The save lands; the undo's token restore hits a Keychain error.
        final callsBefore = tokens.calls.length;
        tokens.failWrites = true;
        tokens.release();
        await env.pumpFrames();
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(
          tokens.calls.skip(callsBefore),
          contains('write $id'),
          reason: 'the token restore ran and failed',
        );
        expect(
          [for (final s in env.saved) (s.id, s.name, s.url)],
          [(id, 'old nas', _url)],
          reason: 'the name and url are restored although the token was not',
        );
        expect(await env.prefsWith('nas home'), isEmpty);
      },
    );

    testWidgets(
      'a failed token restore in edit still restores the name and url',
      (tester) async {
        final tokens = Wi98GatedTokenStore();
        final env = await pumpWi98Host(
          tester,
          server: _server(),
          seed: [(name: 'old nas', url: _url, token: 'tok-old-98')],
          editIndex: 0,
          tokenStore: tokens,
        );
        final id = env.edit!.id;
        await env.open();
        await env.fill(
          name: 'nas home',
          url: 'http://nas2.local:7878',
          token: _token,
        );
        tokens.hold();

        await env.submit();
        expect(wi98Connecting(), findsOneWidget, reason: 'update in flight');
        await tester.tap(find.byKey(kWi98Cancel));
        await tester.pumpAndSettle();
        expect(env.result, isNull);

        final callsBefore = tokens.calls.length;
        tokens.failWrites = true;
        tokens.release();
        await env.pumpFrames();
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(
          tokens.calls.skip(callsBefore),
          contains('write $id'),
          reason: 'the token restore ran and failed',
        );
        expect(
          [for (final s in env.saved) (s.id, s.name, s.url)],
          [(id, 'old nas', _url)],
          reason: 'the name and url are restored although the token was not',
        );
        expect(await env.prefsWith('nas2.local'), isEmpty);
      },
    );

    testWidgets(
      'the undo of a cancelled new server save removes it through removeServer',
      (tester) async {
        final tokens = Wi98GatedTokenStore();
        final env = await pumpWi98Host(
          tester,
          server: _server(),
          tokenStore: tokens,
        );
        await env.open();
        await env.fill(name: 'nas', url: _url, token: _token);
        final callsBefore = tokens.calls.length;
        tokens.hold();

        await env.submit();
        expect(wi98Connecting(), findsOneWidget, reason: 'save in flight');
        await tester.tap(find.byKey(kWi98Cancel));
        await tester.pumpAndSettle();
        tokens.release();
        await env.pumpFrames();
        await tester.pumpAndSettle();

        final calls = tokens.calls.skip(callsBefore).toList();
        expect(calls, hasLength(2), reason: 'the save write, then the undo');
        expect(calls.first, startsWith('write '));
        final id = calls.first.substring('write '.length);
        expect(
          calls.last,
          'delete $id',
          reason: 'removeServer deletes the new server token',
        );
        _expectNothingSaved(env);
      },
    );

    testWidgets(
      'cancel during the save of a connect to a saved url with an empty token restores its token',
      (tester) async {
        final tokens = Wi98GatedTokenStore();
        final env = await pumpWi98Host(
          tester,
          server: FakeVaultServer(token: '')..serveDomain('server'),
          seed: [(name: 'old nas', url: _url, token: 'tok-old-98')],
          tokenStore: tokens,
        );
        final id = env.saved.single.id;
        await env.open();
        await env.fill(name: 'nas home', url: _url);
        tokens.hold();

        await env.submit();
        expect(env.server.requests, hasLength(1), reason: 'probe answered');
        expect(wi98Connecting(), findsOneWidget, reason: 'save in flight');
        await tester.tap(find.byKey(kWi98Cancel));
        await tester.pumpAndSettle();
        expect(env.result, isNull);

        tokens.release();
        await env.pumpFrames();
        await tester.pumpAndSettle();

        expect(
          [for (final s in env.saved) (s.id, s.name, s.url)],
          [(id, 'old nas', _url)],
        );
        expect(
          env.tokens.tokens,
          {id: 'tok-old-98'},
          reason:
              'connect wrote the empty token, so the undo writes the old one back',
        );
      },
    );
  });

  group('seams', () {
    test(
      'the connect dialog http client seam defaults to a real http client',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final client = container.read(connectServerHttpClientProvider);
        expect(client, isA<http.Client>());
        expect(
          container.read(connectServerHttpClientProvider),
          same(client),
          reason: 'one client per container',
        );
      },
    );

    test(
      'the default connect dialog http client is closed with its container',
      () async {
        final container = ProviderContainer();
        final client = container.read(connectServerHttpClientProvider);
        container.dispose();

        await expectLater(
          client.get(Uri.parse('http://127.0.0.1:9/api/v1/info')),
          throwsA(
            isA<http.ClientException>().having(
              (e) => e.message,
              'message',
              contains('closed'),
            ),
          ),
        );
      },
    );
  });
}
