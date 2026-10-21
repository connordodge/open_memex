// WI #99 (H5): the shared harness of the open and create "on a server"
// dialogs' tests. Not a test file.
//
// Two fake vault servers (nas, cabin) sit behind one routing HTTP client, so
// the dialogs' requests go through `serverDialogHttpClientProvider` (the
// production provider this WI adds in server_select.dart, mirroring #98's
// `connectServerHttpClientProvider`) and `HostedClient`. Saved servers and
// their tokens go through the real `SettingsController` with a
// `FakeTokenStore`. The open controller is replaced by a recorder, so no
// vault is really opened.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/token_store.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/hosted/create_on_server_dialog.dart';
import 'package:open_memex_app/src/widgets/hosted/open_on_server_dialog.dart';
import 'package:open_memex_app/src/widgets/hosted/server_select.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_clock.dart';
import '../../support/fake_vault_server.dart';
import '../../support/token_store_fakes.dart';

const kWi99NasUrl = 'http://nas.local:7878';
const kWi99NasToken = 'tok-nas-99-secret';
const kWi99CabinUrl = 'http://cabin.local:7979';
const kWi99CabinToken = 'tok-cabin-99-secret';

// Keys the pack and the WI name.
const kOpenDialog = Key('open-on-server-dialog');
const kCreateDialog = Key('create-on-server-dialog');
const kServerSelect = Key('open-on-server-server-menu');
const kOpenButton = Key('open-on-server-open');
const kCreateLink = Key('open-on-server-create-link');
const kEmptyCreate = Key('open-on-server-empty-create');
const kNameField = Key('create-on-server-name');
const kSubmit = Key('create-on-server-submit');
const kNameError = Key('create-on-server-error');
const kServerError = Key('server-dialog-error');
const kUpdateToken = Key('server-dialog-update-token');

// Keys this WI's tests expect on top of that list (reported to the lead):
// the server menu rows, `server-select-item-<saved server id>`, and the
// "connect to a vault server…" row, `server-select-connect`.
const kConnectItem = Key('server-select-connect');
Key serverItem(String serverId) => Key('server-select-item-$serverId');
Key vaultRow(String name) => Key('open-on-server-vault-$name');

/// A decoded error body of the frozen contract fixtures.
Object? wi99ErrorFixture(String name) => jsonDecode(
  File('test/fixtures/api_v1/errors/$name.json').readAsStringSync(),
);

/// Records the refs the dialogs open; never opens a vault.
class Wi99OpenRecorder extends VaultOpenController {
  Wi99OpenRecorder(super.ref);

  final List<VaultRef> opened = [];

  @override
  Future<VaultOpenOutcome> openVault(VaultRef vault) async {
    opened.add(vault);
    return VaultOpened(vault);
  }
}

class Wi99Env {
  Wi99Env._(this.tester);

  final WidgetTester tester;
  final nas = FakeVaultServer(token: kWi99NasToken);
  final cabin = FakeVaultServer(token: kWi99CabinToken, url: kWi99CabinUrl);
  final tokens = FakeTokenStore();
  final clock = FakeClock();
  late final SettingsController settings;
  late final ProviderContainer container;
  late SavedServer nasSaved;
  late SavedServer cabinSaved;

  int connectCalls = 0;
  final List<String> updateTokenCalls = [];

  Wi99OpenRecorder get recorder =>
      container.read(vaultOpenControllerProvider) as Wi99OpenRecorder;

  List<VaultRef> get opened => recorder.opened;

  /// Requests the fakes saw whose method is [method], across both servers.
  List<http.Request> sent(String method) => [
    for (final r in [...nas.requests, ...cabin.requests])
      if (r.method == method) r,
  ];

  /// A few frames, then long enough for a dialog route to finish closing.
  /// (The loading spinner never settles, so no `pumpAndSettle`.)
  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  late BuildContext _context;

  /// Opens the open dialog and lets the list request run.
  Future<void> openOpenDialog({
    String? serverId,
    bool wireCallbacks = true,
    bool settleAfter = true,
  }) async {
    unawaited(
      showOpenOnServerDialog(
        _context,
        serverId: serverId,
        onConnect: wireCallbacks ? () => connectCalls++ : null,
        onUpdateToken: wireCallbacks ? updateTokenCalls.add : null,
      ),
    );
    if (settleAfter) await settle();
  }

  Future<void> openCreateDialog({
    String? serverId,
    bool wireCallbacks = true,
  }) async {
    unawaited(
      showCreateOnServerDialog(
        _context,
        serverId: serverId,
        onConnect: wireCallbacks ? () => connectCalls++ : null,
        onUpdateToken: wireCallbacks ? updateTokenCalls.add : null,
      ),
    );
    await settle();
  }

  Future<void> tapKey(Key key) async {
    await tester.tap(find.byKey(key));
    await settle();
  }

  Future<void> tapText(String text) async {
    await tester.tap(find.text(text));
    await settle();
  }

  /// Types [text] into the vault name field.
  Future<void> typeName(String text) async {
    await tester.enterText(
      find.descendant(
        of: find.byKey(kNameField),
        matching: find.byType(EditableText),
        matchRoot: true,
      ),
      text,
    );
    await settle();
  }

  /// Picks [serverId] in the open server menu.
  Future<void> pickServer(Finder select, String serverId) async {
    await tester.tap(select);
    await settle();
    await tester.tap(find.byKey(serverItem(serverId)));
    await settle();
  }

  /// The plain text of every Text under [finder] (and [finder] itself),
  /// joined with a space and whitespace-normalised.
  String textOf(Finder finder) {
    final texts = tester.widgetList<Text>(
      find.descendant(of: finder, matching: find.byType(Text), matchRoot: true),
    );
    return texts
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// True when a Text under [scope] spells exactly [text].
  bool hasText(Finder scope, String text) => tester
      .widgetList<Text>(find.descendant(of: scope, matching: find.byType(Text)))
      .any(
        (t) =>
            (t.data ?? t.textSpan?.toPlainText() ?? '').replaceAll(
              RegExp(r'\s+'),
              ' ',
            ) ==
            text,
      );

  /// True when the OmButton keyed [key] has no tap handler (disabled).
  bool isDisabled(Key key) =>
      tester.widget<OmButton>(find.byKey(key)).onPressed == null;
}

/// Routes by host to [servers], preserving each fake's own failure and gate
/// behaviour.
http.Client _router(Map<String, FakeVaultServer> byHost) =>
    MockClient((request) async {
      final server = byHost[request.url.host];
      if (server == null) {
        throw http.ClientException('no fake server for ${request.url}');
      }
      // MockClient hands over a finalized request; send a copy.
      final copy = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..bodyBytes = request.bodyBytes;
      final streamed = await server.client.send(copy);
      return http.Response.fromStream(streamed);
    });

/// Pumps the host app with nas and cabin saved (in that order); [saveCabin]
/// false saves nas only.
Future<Wi99Env> pumpWi99Host(
  WidgetTester tester, {
  bool saveCabin = true,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({'memex.binary_path': 'fake-memex'});
  final env = Wi99Env._(tester);
  env.settings = (await tester.runAsync(
    () => SettingsController.load(tokenStore: env.tokens),
  ))!;
  env.nasSaved = (await tester.runAsync(
    () => env.settings.saveServer(
      name: 'nas',
      url: kWi99NasUrl,
      token: kWi99NasToken,
    ),
  ))!;
  if (saveCabin) {
    env.cabinSaved = (await tester.runAsync(
      () => env.settings.saveServer(
        name: 'cabin',
        url: kWi99CabinUrl,
        token: kWi99CabinToken,
      ),
    ))!;
  }
  final router = _router({'nas.local': env.nas, 'cabin.local': env.cabin});
  env.container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith((_) => env.settings),
      tokenStoreProvider.overrideWithValue(env.tokens),
      clockProvider.overrideWithValue(env.clock),
      serverDialogHttpClientProvider.overrideWithValue(router),
      vaultOpenControllerProvider.overrideWith(Wi99OpenRecorder.new),
    ],
  );
  addTearDown(env.container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: env.container,
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              env._context = context;
              return const Center(
                child: Text('wi99 host', key: Key('wi99-open-host')),
              );
            },
          ),
        ),
      ),
    ),
  );
  return env;
}
