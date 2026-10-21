// WI #97 (H3): the vault picker with hosted seams. Saved servers and typed
// recents in mock prefs, one FakeVaultServer per saved server behind one
// routing MockClient (#96's `hostedHttpClientProvider`), FakeTokenStore,
// FakeClock, FakeAppFocus, a recording picker-actions seam and a recording
// open controller. Row outcomes go through #96's `recentRowOutcomeProvider`.
// No real network, Keychain or `memex` binary.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_memex_app/main.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/state/app_focus.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/picker_actions.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/token_store.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_harness.dart';
import 'fake_clock.dart';
import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';
import 'fake_vault_server.dart';
import 'poll_fakes.dart';
import 'token_store_fakes.dart';

/// The saved server of boards A1/A3 ("nas", http://nas.local:7878).
const wi97Nas = SavedServer(
  id: fakeServerId,
  name: fakeServerName,
  url: fakeServerUrl,
);

/// A2's second saved server.
const wi97Mini = SavedServer(
  id: 'srv-mini',
  name: 'studio-mini',
  url: 'http://100.101.12.4:7878',
);

/// The access token each saved server's FakeVaultServer accepts.
String wi97TokenFor(String serverId) => 'token-$serverId';

/// Every picker-actions call, as `connect`, `editServer <id>`,
/// `openOnServer`, `createOnServer` or `setUp`.
class Wi97PickerActions extends PickerActions {
  Wi97PickerActions();

  final List<String> calls = [];

  /// What `connect` completes with (default: null, a cancelled connect).
  Future<SavedServer?> Function()? onConnect;

  @override
  Future<SavedServer?> connect(BuildContext context) async {
    calls.add('connect');
    return onConnect?.call();
  }

  @override
  Future<void> editServer(BuildContext context, String serverId) async {
    calls.add('editServer $serverId');
  }

  @override
  Future<void> openOnServer(BuildContext context) async {
    calls.add('openOnServer');
  }

  @override
  Future<void> createOnServer(BuildContext context) async {
    calls.add('createOnServer');
  }

  @override
  Future<void> setUp(BuildContext context) async {
    calls.add('setUp');
  }
}

/// The open controller with every `openVault` / `launchReopen` call
/// recorded. [onOpen] / [onLaunch] replace the real path when set; the
/// replacement still writes `recentRowOutcomeProvider` for a hosted vault
/// as #96's open controller does (opening while it runs, then failed or
/// null).
class Wi97OpenController extends VaultOpenController {
  Wi97OpenController(super.ref) : _wi97Ref = ref;

  final Ref _wi97Ref;
  final List<VaultRef> opened = [];
  int launches = 0;

  Future<VaultOpenOutcome> Function(VaultRef vault)? onOpen;
  Future<VaultOpenOutcome> Function()? onLaunch;

  @override
  Future<VaultOpenOutcome> openVault(VaultRef vault) {
    opened.add(vault);
    final f = onOpen;
    return f == null
        ? super.openVault(vault)
        : _wi97Record(vault, () => f(vault));
  }

  @override
  Future<VaultOpenOutcome> launchReopen() {
    launches++;
    final f = onLaunch;
    if (f == null) return super.launchReopen();
    final last = _wi97Ref.read(settingsProvider).lastVaultRef;
    return last == null ? f() : _wi97Record(last, f);
  }

  /// #96's row-outcome contract for a hosted [vault]: [RecentRowOpening]
  /// while [run] runs, then [RecentRowFailed] for a hosted failure, else
  /// null. A local vault records nothing.
  Future<VaultOpenOutcome> _wi97Record(
    VaultRef vault,
    Future<VaultOpenOutcome> Function() run,
  ) async {
    if (vault is! HostedVaultRef) return run();
    final row = _wi97Ref.read(recentRowOutcomeProvider(vault).notifier);
    row.state = const RecentRowOpening();
    final outcome = await run();
    row.state = outcome is HostedVaultOpenFailure
        ? RecentRowFailed(outcome)
        : null;
    return outcome;
  }
}

/// Everything a picker test needs after [pumpVaultPicker].
class Wi97Picker {
  Wi97Picker({
    required this.container,
    required this.tokens,
    required this.servers,
    required this.actions,
    required this.clock,
  });

  final ProviderContainer container;
  final FakeTokenStore tokens;

  /// One fake per saved server, by saved-server id.
  final Map<String, FakeVaultServer> servers;
  final Wi97PickerActions actions;
  final FakeClock clock;

  AppSettings get settings => container.read(settingsProvider);

  Wi97OpenController get opener =>
      container.read(vaultOpenControllerProvider) as Wi97OpenController;

  FakeAppFocus get focus =>
      container.read(appFocusProvider.notifier) as FakeAppFocus;

  HostedConnectionStatus? status(String serverId) =>
      container.read(hostedConnectionStatusProvider(serverId));

  /// The `GET /api/v1/info` requests [serverId]'s fake received.
  List<http.Request> infoRequests(String serverId) => [
    for (final r in servers[serverId]!.requests)
      if (r.method == 'GET' && r.url.path == '/api/v1/info') r,
  ];
}

/// Let async work (prefs, token reads, fake server responses) finish, then
/// draw.
Future<void> wi97Settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await pumpFrames(tester, frames: 2);
  }
}

String _encodeRef(VaultRef ref) => jsonEncode(switch (ref) {
  LocalVaultRef(:final path) => {'kind': 'local', 'path': path},
  HostedVaultRef(:final serverId, :final vaultName) => {
    'kind': 'hosted',
    'server': serverId,
    'vault': vaultName,
  },
});

/// The picker app (no vault open) with:
/// - [savedServers] and typed [recents] (most recent first) in mock prefs,
///   [last] as the last vault (launch reopens it);
/// - [binary]: a FakeMemexCli as `memexCliProvider`, or null (binary not
///   found);
/// - a FakeVaultServer per saved server serving the `server` fixtures, with
///   access token [wi97TokenFor] saved in the FakeTokenStore;
/// - [recorded] row outcomes written to #96's `recentRowOutcomeProvider`
///   before the first frame;
/// - [beforePump] runs on the fakes before the picker first builds (e.g.
///   `hold()` a server so its probe stays in flight).
Future<Wi97Picker> pumpVaultPicker(
  WidgetTester tester, {
  List<SavedServer> savedServers = const [wi97Nas],
  List<VaultRef> recents = const [],
  VaultRef? last,
  bool binary = true,
  Size size = const Size(1280, 800),
  Map<VaultRef, RecentRowOutcome> recorded = const {},
  void Function(Map<String, FakeVaultServer> servers)? beforePump,
  void Function(Wi97OpenController opener)? configureOpener,
}) async {
  SharedPreferences.setMockInitialValues({
    'memex.binary_path': 'fake-memex',
    'memex.recent_refs': [for (final r in recents) _encodeRef(r)],
    'memex.last_vault_ref': ?(last == null ? null : _encodeRef(last)),
    'memex.vault_servers': [
      for (final s in savedServers)
        jsonEncode({'id': s.id, 'name': s.name, 'url': s.url}),
    ],
  });
  final tokens = FakeTokenStore({
    for (final s in savedServers) s.id: wi97TokenFor(s.id),
  });
  final settings = (await tester.runAsync(
    () => SettingsController.load(tokenStore: tokens),
  ))!;

  final servers = {
    for (final s in savedServers)
      s.id: FakeVaultServer(token: wi97TokenFor(s.id), url: s.url)
        ..serveDomain('server'),
  };
  beforePump?.call(servers);
  final router = MockClient((request) async {
    for (final s in servers.values) {
      if (s.url.host == request.url.host && s.url.port == request.url.port) {
        // MockClient hands over a finalized Request; the fake server's own
        // MockClient finalizes again, so forward a fresh copy.
        final copy = http.Request(request.method, request.url)
          ..headers.addAll(request.headers)
          ..bodyBytes = request.bodyBytes;
        return http.Response.fromStream(await s.client.send(copy));
      }
    }
    throw StateError('no fake vault server for ${request.url}');
  });

  final actions = Wi97PickerActions();
  final clock = FakeClock();
  final db = FakeVaultDb.v5();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith((_) => settings),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(binary ? FakeMemexCli() : null),
      clockProvider.overrideWithValue(clock),
      utcOffsetProvider.overrideWithValue(() => const Duration(hours: 2)),
      tokenStoreProvider.overrideWithValue(tokens),
      hostedHttpClientProvider.overrideWithValue(router),
      appFocusProvider.overrideWith(() => FakeAppFocus()),
      pickerActionsProvider.overrideWithValue(actions),
      vaultOpenControllerProvider.overrideWith((ref) {
        final c = Wi97OpenController(ref);
        configureOpener?.call(c);
        return c;
      }),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  addTearDown(tester.view.reset);
  for (final MapEntry(:key, :value) in recorded.entries) {
    container.read(recentRowOutcomeProvider(key).notifier).state = value;
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const OpenMemexApp(),
    ),
  );
  await wi97Settle(tester);
  expect(find.byType(VaultPickerScreen), findsOneWidget);
  return Wi97Picker(
    container: container,
    tokens: tokens,
    servers: servers,
    actions: actions,
    clock: clock,
  );
}

/// [matching] inside the widget keyed [key].
Finder wi97Inside(String key, Finder matching) =>
    find.descendant(of: find.byKey(Key(key)), matching: matching);

/// The state of the single StatusDot inside the widget keyed [key].
StatusDotState wi97DotIn(WidgetTester tester, String key) =>
    tester.widget<StatusDot>(wi97Inside(key, find.byType(StatusDot))).state;

/// The OmButton inside the widget keyed [key] (the key may be on the button
/// itself or on a wrapper).
OmButton wi97ButtonIn(WidgetTester tester, String key) {
  final self = find.byKey(Key(key));
  final widget = tester.widget(self);
  if (widget is OmButton) return widget;
  return tester.widget<OmButton>(wi97Inside(key, find.byType(OmButton)).first);
}

/// The colour of the Text [text] inside the widget keyed [key].
Color? wi97TextColorIn(WidgetTester tester, String key, String text) =>
    tester.widget<Text>(wi97Inside(key, find.text(text))).style?.color;

/// The L9 api-mismatch copy for [server] running memex [version].
String wi97L9(String server, String version) =>
    '$server runs memex $version, which this app can\'t use. update the '
    'app or memex on the server so both are the same release.';
