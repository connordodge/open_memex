// WI #96 (H2, D21): the hosted-vault test harness. It runs the app, or a
// bare ProviderContainer, against FakeVaultServers (no network), a
// FakeTokenStore (never the real Keychain), a FakeClock and a temp
// app-support dir. #97, #101, #102 and #105 build on it; its public
// signatures are frozen once #96 merges (add, never change).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_memex_app/main.dart';
import 'package:open_memex_app/src/state/app_exit.dart';
import 'package:open_memex_app/src/state/app_support_dir.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/token_store.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_fixtures.dart';
import 'app_exit_fakes.dart';
import 'app_harness.dart';
import 'fake_clock.dart';
import 'fake_memex_cli.dart';
import 'fake_vault_server.dart';
import 'token_store_fakes.dart';

/// The fixture domains a seeded fake vault server serves for the `seed`
/// vault (`/vaults/seed/api/v1/...`), plus `server` (`/api/v1/info`, the
/// vault info route).
const hostedFixtureDomains = [
  'server',
  'notes',
  'daily',
  'topics',
  'canvas',
  'graph',
  'revision',
];

/// The hosted ref of the fixture vault on the default fake server.
const seedHostedRef = HostedVaultRef(fakeServerId, seedVaultName);

/// One saved vault server in a test: its saved entry, the fake that answers
/// for its URL, and the access token the fake token store holds for it
/// (null: no token saved). A [seeded] fake serves every fixture domain for
/// the vault [vaultName] (the fixture rows, renamed from `seed`).
class HostedServerFixture {
  HostedServerFixture({
    String id = fakeServerId,
    String name = fakeServerName,
    String url = fakeServerUrl,
    String token = fakeServerToken,
    String? storedToken,
    bool storeToken = true,
    bool seeded = true,
    String vaultName = seedVaultName,
  }) : saved = SavedServer(id: id, name: name, url: url),
       server = FakeVaultServer(token: token, url: url),
       storedToken = storeToken ? (storedToken ?? token) : null {
    if (seeded) serveFixturesAs(vaultName);
  }

  /// Serves every fixture domain's rows for the vault [vaultName] too (the
  /// `seed` rows, renamed).
  void serveFixturesAs(String vaultName) {
    for (final d in hostedFixtureDomains) {
      server.serveRows(
        loadFixtureRows(
          p.join(apiV1FixturesDir, d),
        ).map((r) => _wi96Renamed(r, vaultName)),
      );
    }
  }

  final SavedServer saved;
  final FakeVaultServer server;

  /// The token the fake token store holds for [saved]'s id.
  final String? storedToken;

  String get id => saved.id;
  String get name => saved.name;

  /// A hosted ref to [vaultName] on this server.
  HostedVaultRef ref(String vaultName) => HostedVaultRef(id, vaultName);

  /// Answers a save of [noteId] in [vaultName] (`PATCH /notes/<id>`) with
  /// [version]; the fixture's own update row carries a placeholder
  /// timestamp, so it can't be replayed as is.
  void serveSave(String vaultName, String noteId, {int version = 2}) =>
      server.route(
        'PATCH',
        '/vaults/$vaultName/api/v1/notes/$noteId',
        json: {
          'note_id': noteId,
          'version': version,
          'updated_at': 1792535790000,
        },
      );

  /// Serves `GET /vaults/<name>/api/v1/info` for an extra vault [name].
  void serveVault(
    String name, {
    int schemaVersion = 5,
    String vaultId = '01M5DK9Z8CWPQGFA893JX9VRZF',
  }) => server.route(
    'GET',
    '/vaults/$name/api/v1/info',
    json: {'name': name, 'schema_version': schemaVersion, 'vault_id': vaultId},
  );
}

/// [row] with its `/vaults/seed/` path served as `/vaults/<vaultName>/`.
FixtureRow _wi96Renamed(FixtureRow row, String vaultName) =>
    vaultName == seedVaultName
    ? row
    : FixtureRow(
        domainDir: row.domainDir,
        method: row.method,
        path: row.path.replaceFirst(
          '/vaults/$seedVaultName/',
          '/vaults/$vaultName/',
        ),
        request: row.request,
        response: row.response,
        status: row.status,
        headers: row.headers,
        dartOnly: row.dartOnly,
      );

/// An [http.Client] that hands each request to the [FakeVaultServer] whose
/// URL (scheme, host and port) it is sent to. A request to any other origin
/// fails like a refused connection.
class FakeVaultServerRouter extends http.BaseClient {
  FakeVaultServerRouter(this.servers);

  final List<FakeVaultServer> servers;

  /// Every request sent through the router, in order.
  final List<http.BaseRequest> sent = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sent.add(request);
    for (final s in servers) {
      if (s.url.origin == request.url.origin) return s.client.send(request);
    }
    throw fakeTransportException(FakeServerFailure.refused, request.url)!;
  }
}

/// SharedPreferences entries for [servers] (saved), the typed [recents] and
/// [lastVault] (D18 encoding), a configured `fake-memex` binary path, and
/// the local-only mirror keys.
Map<String, Object> hostedPrefs({
  List<SavedServer> servers = const [],
  List<VaultRef> recents = const [],
  VaultRef? lastVault,
}) {
  String encode(VaultRef r) => jsonEncode(switch (r) {
    LocalVaultRef(:final path) => {'kind': 'local', 'path': path},
    HostedVaultRef(:final serverId, :final vaultName) => {
      'kind': 'hosted',
      'server': serverId,
      'vault': vaultName,
    },
  });
  return {
    'memex.binary_path': 'fake-memex',
    'memex.recent_refs': [for (final r in recents) encode(r)],
    'memex.recent_vaults': [
      for (final r in recents)
        if (r is LocalVaultRef) r.path,
    ],
    'memex.last_vault_ref': ?(lastVault == null ? null : encode(lastVault)),
    'memex.last_vault': ?lastVault.localPath,
    'memex.vault_servers': [
      for (final s in servers)
        jsonEncode({'id': s.id, 'name': s.name, 'url': s.url}),
    ],
  };
}

/// Everything a hosted test needs after [hostedContainer] or
/// [pumpHostedApp].
class HostedHarness {
  HostedHarness({
    required this.container,
    required this.servers,
    required this.router,
    required this.tokens,
    required this.clock,
    required this.appSupport,
    required this.windowTitle,
    required this.cli,
  });

  final ProviderContainer container;
  final List<HostedServerFixture> servers;
  final FakeVaultServerRouter router;
  final FakeTokenStore tokens;
  final FakeClock clock;

  /// The temp dir behind `appSupportDirProvider`.
  final Directory appSupport;

  /// Records every native window title set.
  final RecordingWindowTitle windowTitle;

  /// The fake CLI behind `memexCliProvider`, or null when none is configured.
  final FakeMemexCli? cli;

  /// The first server.
  HostedServerFixture get first => servers.first;

  T read<T>(ProviderListenable<T> provider) => container.read(provider);

  VaultOpenController get controller => read(vaultOpenControllerProvider);

  /// Every file under the app-support dir, as paths relative to it.
  List<String> appSupportFiles() => [
    for (final e in appSupport.listSync(recursive: true))
      if (e is File) p.relative(e.path, from: appSupport.path),
  ]..sort();
}

Future<
  ({
    ProviderContainer container,
    FakeVaultServerRouter router,
    FakeTokenStore tokens,
    FakeClock clock,
    Directory appSupport,
    RecordingWindowTitle title,
  })
>
_wi96Build({
  required List<HostedServerFixture> servers,
  required List<VaultRef> recents,
  required VaultRef? lastVault,
  required VaultRef? current,
  required FakeMemexCli? cli,
  required FakeClock? clock,
  required List<Override> overrides,
}) async {
  SharedPreferences.setMockInitialValues(
    hostedPrefs(
      servers: [for (final s in servers) s.saved],
      recents: recents,
      lastVault: lastVault,
    ),
  );
  final tokens = FakeTokenStore({
    for (final s in servers) s.id: ?s.storedToken,
  });
  final settings = await SettingsController.load(tokenStore: tokens);
  final router = FakeVaultServerRouter([for (final s in servers) s.server]);
  final fakeClock = clock ?? FakeClock(DateTime(2026, 10, 19, 9));
  final appSupport = Directory.systemTemp.createTempSync('om96_support_');
  final title = RecordingWindowTitle();
  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith((_) => settings),
      tokenStoreProvider.overrideWithValue(tokens),
      hostedHttpClientProvider.overrideWithValue(router),
      appSupportDirProvider.overrideWithValue(appSupport.path),
      memexCliProvider.overrideWithValue(cli),
      clockProvider.overrideWithValue(fakeClock),
      utcOffsetProvider.overrideWithValue(() => const Duration(hours: 2)),
      windowTitleProvider.overrideWithValue(title),
      appExitHostProvider.overrideWithValue(FakeAppExitHost()),
      if (current != null) currentVaultProvider.overrideWith((_) => current),
      ...overrides,
    ],
  );
  addTearDown(() => _wi96DeleteQuietly(appSupport));
  addTearDown(container.dispose);
  return (
    container: container,
    router: router,
    tokens: tokens,
    clock: fakeClock,
    appSupport: appSupport,
    title: title,
  );
}

/// A bare [ProviderContainer] wired like the app for hosted vaults: settings
/// loaded from [hostedPrefs] (each server saved, [recents], [lastVault]),
/// a [FakeTokenStore] holding each server's token behind both the settings
/// and `tokenStoreProvider`, `hostedHttpClientProvider` routing to the
/// servers' fakes, `appSupportDirProvider` at a temp dir, [cli] behind
/// `memexCliProvider` (null by default: no `memex` binary), a [FakeClock]
/// and a fixed +02:00 UTC offset. No vault is open unless [current] is set.
Future<HostedHarness> hostedContainer({
  List<HostedServerFixture>? servers,
  List<VaultRef> recents = const [],
  VaultRef? lastVault,
  VaultRef? current,
  FakeMemexCli? cli,
  FakeClock? clock,
  List<Override> overrides = const [],
}) async {
  final s = servers ?? [HostedServerFixture()];
  final b = await _wi96Build(
    servers: s,
    recents: recents,
    lastVault: lastVault,
    current: current,
    cli: cli,
    clock: clock,
    overrides: overrides,
  );
  return HostedHarness(
    container: b.container,
    servers: s,
    router: b.router,
    tokens: b.tokens,
    clock: b.clock,
    appSupport: b.appSupport,
    windowTitle: b.title,
    cli: cli,
  );
}

/// Pumps the whole app (`OpenMemexApp`, router → picker or workspace) over
/// the [hostedContainer] seams. No vault is open at first (the picker shows)
/// unless [current] is set. [overrides] are appended.
Future<HostedHarness> pumpHostedApp(
  WidgetTester tester, {
  List<HostedServerFixture>? servers,
  List<VaultRef> recents = const [],
  VaultRef? lastVault,
  VaultRef? current,
  FakeMemexCli? cli,
  FakeClock? clock,
  Size surfaceSize = const Size(1600, 1000),
  List<Override> overrides = const [],
}) async {
  final h = await tester.runAsync(
    () => hostedContainer(
      servers: servers,
      recents: recents,
      lastVault: lastVault,
      current: current,
      cli: cli,
      clock: clock,
      overrides: overrides,
    ),
  );
  tester.view.physicalSize = surfaceSize;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = 0.5;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h!.container,
      child: const OpenMemexApp(),
    ),
  );
  await pumpFrames(tester);
  return h;
}

/// Runs [open] (an open call on the controller) while pumping frames, so the
/// fake server's answers, the settings writes and the rebuilds all land.
Future<T> pumpWhile<T>(WidgetTester tester, Future<T> Function() open) async {
  final f = open();
  T? result;
  var done = false;
  f.then((v) {
    result = v;
    done = true;
  });
  for (var i = 0; i < 40 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await pumpFrames(tester);
  expect(done, isTrue, reason: 'the open call completed');
  return result as T;
}

/// Lets real-async work (UI-state file writes) land, then pumps frames.
/// Never await a UiStateStore future inside `runAsync`: a write queued from
/// the test zone completes only as frames pump.
Future<void> settleHosted(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  await pumpFrames(tester);
}

void _wi96DeleteQuietly(Directory dir) {
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      // A queued UiStateStore write raced the delete; try again.
    }
  }
}
