// WI #105 (F1) AC3: connect journeys from the vault picker (boards A4/A5,
// Req 43), end to end on the real app: the picker's "connect to a vault
// server…" opens #98's dialog through the bound picker actions, the probe
// goes to the fake vault server, and a success saves the server (name and
// URL in prefs, token in the fake token store). Spec copy, verbatim.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';

import '../robots/picker_robot.dart';
import '../support/fake_vault_server.dart';
import '../support/hosted_harness.dart';
import '../support/journey_harness.dart';
import '../support/token_store_fakes.dart';
import '../support/font_fetch_hold.dart';

const _url = 'http://nas.local:7878';
const _token = 'fresh-token-105';

/// The L9 api-mismatch copy for [server] running memex [version] (Req 43).
String _l9(String server, String version) =>
    "$server runs memex $version, which this app can't use. update the app "
    'or memex on the server so both are the same release.';

/// The picker with no saved server, its connect dialog open, and a vault
/// server at [_url] that is not saved yet (accepting [_token]).
Future<(PickerRobot, FakeVaultServer)> _connectDialog(
  WidgetTester tester, {
  bool serverListens = true,
}) async {
  final app = await pumpJourneyApp(tester);
  final server = serverListens
      ? app.addUnsavedServer(url: _url, token: _token)
      : FakeVaultServer(token: _token, url: _url);
  final r = PickerRobot(app);
  await r.tap(r.noServersConnect);
  r.expectConnectDialog();
  return (r, server);
}

void _expectNothingSaved(PickerRobot r) {
  expect(r.app.settings.savedServers, isEmpty);
  expect(r.app.tokens.tokens, isEmpty);
}

void main() {
  holdFontFetches();

  group('connect from the picker (AC3)', () {
    testWidgets(
      'a successful connect lists the server with a connected dot and keeps the token only in the token store',
      (tester) async {
        final (r, _) = await _connectDialog(tester);

        await r.connectWith(name: 'nas', url: _url, token: _token);

        expect(r.connectDialog, findsNothing);
        final saved = r.app.settings.savedServers.single;
        expect((saved.name, saved.url), ('nas', _url));
        expect(r.serverRow(saved.id), findsOneWidget);
        expect(r.dotIn('server-row-${saved.id}'), StatusDotState.connected);
        expect(r.app.tokens.tokens, {saved.id: _token});
        expect(await prefsEntriesContaining(_token), isEmpty);
        expect(r.noServersConnect, findsNothing);
      },
    );

    testWidgets(
      'a connect to a server that cannot be reached shows cant reach the url and saves nothing',
      (tester) async {
        final (r, _) = await _connectDialog(tester, serverListens: false);

        await r.connectWith(name: 'nas', url: _url, token: _token);

        r.expectConnectDialog();
        expect(r.shows(r.connectDialog, "can't reach $_url"), isTrue);
        _expectNothingSaved(r);
      },
    );

    testWidgets(
      'a connect with a rejected token shows access token rejected and saves nothing',
      (tester) async {
        final (r, _) = await _connectDialog(tester);

        await r.connectWith(name: 'nas', url: _url, token: 'wrong-token');

        r.expectConnectDialog();
        expect(r.shows(r.connectDialog, 'access token rejected'), isTrue);
        _expectNothingSaved(r);
      },
    );

    testWidgets(
      'a connect to a server on another api version shows the version mismatch message and saves nothing',
      (tester) async {
        final (r, server) = await _connectDialog(tester);
        server.route(
          'GET',
          '/api/v1/info',
          json: {'api_version': 2, 'server_version': '0.9.0'},
        );

        await r.connectWith(name: 'nas', url: _url, token: _token);

        r.expectConnectDialog();
        expect(r.shows(r.connectDialog, _l9('nas', '0.9.0')), isTrue);
        _expectNothingSaved(r);
      },
    );

    testWidgets(
      'an invalid url shows the url error before any request and saves nothing',
      (tester) async {
        final (r, server) = await _connectDialog(tester);

        await r.connectWith(name: 'nas', url: 'nas.local:7878', token: _token);

        r.expectConnectDialog();
        expect(
          r.shows(
            r.connectDialog,
            'enter a url starting with http:// or https://',
          ),
          isTrue,
        );
        expect(server.requests, isEmpty);
        _expectNothingSaved(r);
      },
    );

    testWidgets(
      'a url that is not a memex vault server shows the not a memex server error and saves nothing',
      (tester) async {
        final (r, server) = await _connectDialog(tester);
        server.servesHtml = true;

        await r.connectWith(name: 'nas', url: _url, token: _token);

        r.expectConnectDialog();
        expect(
          r.shows(r.connectDialog, "$_url isn't a memex vault server"),
          isTrue,
        );
        _expectNothingSaved(r);
      },
    );

    testWidgets(
      'cancel while connecting closes the dialog and saves nothing once the server answers',
      (tester) async {
        final (r, server) = await _connectDialog(tester);
        server.hold();

        await r.connectWith(name: 'nas', url: _url, token: _token);
        expect(r.shows(r.connectDialog, 'connecting…'), isTrue);
        await r.tap(r.connectCancel);
        expect(r.connectDialog, findsNothing);

        server.release();
        await r.app.settle();

        _expectNothingSaved(r);
        expect(r.noServersConnect, findsOneWidget);
      },
    );

    testWidgets(
      'a connect to an already saved url updates that server token and adds no server',
      (tester) async {
        final nas = HostedServerFixture(token: 'old-token-105');
        final app = await pumpJourneyApp(tester, servers: [nas]);
        final r = PickerRobot(app);
        expect(app.tokens.tokens, {nas.id: 'old-token-105'});
        nas.server.token = _token;

        await r.tap(r.serversConnect);
        await r.connectWith(url: '$_url/', token: _token);

        expect(r.connectDialog, findsNothing);
        expect(app.settings.savedServers.map((s) => s.id), [nas.id]);
        expect(app.tokens.tokens, {nas.id: _token});
        expect(r.dotIn('server-row-${nas.id}'), StatusDotState.connected);
      },
    );
  });
}
