// WI #407 (SH): the one pump helper every Agents sheet WI uses (#407 shell,
// #410 Live, #411 Connect, #412 Tools, #413 Semantic recall). #407 only:
// tab WIs add their fakes through `overrides`, never by editing this file.
//
// It wires a ProviderContainer with #390's agents seam (`agentsOverrides`:
// a FakeAgentsAccess on the open vault, a FakeClock, window focus), mock
// SharedPreferences settings with saved servers, a FakeTokenStore, a
// FakeMemexCli, a RecordingUrlOpener and a FakeWindowMenuHost, then pumps a
// MaterialApp whose page holds a focused origin field (or the caller's
// `host`). No real `memex`, network, Keychain, timer or `~/Library`. Call
// `holdFontFetches()` at the top of the test file's `main()`.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/agents_sheet/connect/claude_config_reader.dart';
import 'package:open_memex_app/src/state/agents_sheet/connect_tab_state.dart';
import 'package:open_memex_app/src/state/app_exit.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/token_store.dart';
import 'package:open_memex_app/src/state/url_opener.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/agents_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agents_fakes.dart';
import 'claude_config_reader_fakes.dart';
import 'editor_scope.dart' show RecordingUrlOpener;
import 'fake_clock.dart';
import 'fake_memex_cli.dart';
import 'token_store_fakes.dart';
import 'window_menu_fakes.dart';

export 'agents_fakes.dart';
export 'editor_scope.dart' show RecordingUrlOpener;
export 'window_menu_fakes.dart';

/// The local vault the harness opens by default: chip `Studio · local vault`.
const agentsSheetLocalVault = LocalVaultRef('/Users/tester/vaults/Studio');

/// The saved server the hosted helpers use, and its vault.
const agentsSheetServer = SavedServer(
  id: 'srv-nas',
  name: 'nas',
  url: 'http://nas.local:7878/',
);
const agentsSheetHostedVault = HostedVaultRef('srv-nas', 'studio');

/// The access token [FakeTokenStore] holds for [agentsSheetServer] by default.
const agentsSheetToken = 'om-407-sentinel-token-0123456789abcd';

/// The page's origin field: focused before every [AgentsSheetHarness.open].
const agentsSheetOriginKey = Key('agents-harness-origin');

/// The Agents sheet panel (Key `agents-sheet`, on its box).
final agentsSheetFinder = find.byKey(const Key('agents-sheet'));

/// Records every route the app's navigator pushes and pops.
class AgentsSheetRouteLog extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];
  final List<Route<dynamic>> popped = [];

  /// Pushed popup routes (dialogs and sheets), in order.
  List<Route<dynamic>> get dialogs => [
    for (final r in pushed)
      if (r is PopupRoute) r,
  ];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      pushed.add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      popped.add(route);
}

/// Everything an Agents sheet test drives and inspects.
class AgentsSheetHarness {
  AgentsSheetHarness._(
    this._tester, {
    required this.container,
    required this.clock,
    required this.agents,
    required this.cli,
    required this.tokens,
    required this.opener,
    required this.menuHost,
    required this.routes,
    required this.originFocus,
    required GlobalKey hostKey,
  }) : _hostKey = hostKey;

  final WidgetTester _tester;
  final ProviderContainer container;

  /// Manual time (`clockProvider`): nothing fires until `clock.advance`.
  final FakeClock clock;

  /// The open local vault's `VaultAccess.agents` (unused for a hosted vault).
  final FakeAgentsAccess agents;
  final FakeMemexCli cli;
  final FakeTokenStore tokens;
  final RecordingUrlOpener opener;

  /// Behind `windowMenuHostProvider`.
  final FakeWindowMenuHost menuHost;

  /// Every route the app's navigator pushed.
  final AgentsSheetRouteLog routes;

  /// The focus node of the default page's origin field.
  final FocusNode originFocus;

  final GlobalKey _hostKey;

  /// A context inside the page (the default page or the caller's `host`).
  BuildContext get hostContext => _hostKey.currentContext!;

  T read<T>(ProviderListenable<T> provider) => container.read(provider);

  /// How many `openAgentsSheet` calls made through [launch] have completed
  /// (the sheet's future completes when it closes).
  int openCallsCompleted = 0;

  /// Calls `openAgentsSheet` from the page and pumps the 150 ms fade, but
  /// leaves the FakeClock where it is: the opening-tab decision (300 ms on
  /// the clock) has not been made yet. Does not wait for the sheet to close.
  Future<void> launch() async {
    unawaited(
      openAgentsSheet(hostContext).then((_) => openCallsCompleted++),
    );
    await _tester.pump();
    await _tester.pump(const Duration(milliseconds: 100));
    await _tester.pump(const Duration(milliseconds: 100));
  }

  /// Focuses the origin field (default page), [launch]es the sheet, then
  /// moves the clock past the 300 ms opening-tab decision and pumps.
  Future<void> open() async {
    if (originFocus.context != null) {
      originFocus.requestFocus();
      await _tester.pump();
    }
    await launch();
    await decide();
    expect(
      agentsSheetFinder,
      findsOneWidget,
      reason: 'openAgentsSheet shows the agents-sheet panel',
    );
  }

  /// Moves the clock past the opening-tab decision and pumps.
  Future<void> decide() async {
    clock.advance(const Duration(milliseconds: 300));
    await settle();
  }

  /// A few frames, for provider futures and short animations.
  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await _tester.pump(const Duration(milliseconds: 50));
    }
  }
}

/// Pumps an Agents sheet test app and returns the harness.
///
/// - [vault]: the open vault, [agentsSheetLocalVault] by default; a
///   [HostedVaultRef] names a server in [servers] (default
///   [agentsSheetServer]).
/// - [agents]: the FakeAgentsAccess the real `agentActivityAsyncProvider`
///   reads on a local vault (a new one at the vault's path by default).
/// - [tokens]: the FakeTokenStore's tokens by server id (default
///   [agentsSheetToken] for [agentsSheetServer]).
/// - [binaryPath]: the picked memex binary in settings; null leaves none
///   (`memexCliProvider` is still the FakeMemexCli unless overridden).
/// - [size] and [textScale]: the window and the platform text scale.
/// - [host]: the page body (default: an origin TextField that the harness
///   focuses before opening).
/// - [open]: open the sheet and make the opening-tab decision before
///   returning.
/// - [overrides] come last, so a test's own override wins.
Future<AgentsSheetHarness> pumpAgentsSheet(
  WidgetTester tester, {
  List<Override> overrides = const [],
  VaultRef vault = agentsSheetLocalVault,
  List<SavedServer> servers = const [agentsSheetServer],
  Map<String, String>? tokens,
  FakeAgentsAccess? agents,
  FakeClock? clock,
  FakeMemexCli? cli,
  String? binaryPath = '/Users/tester/.cargo/bin/memex',
  Size size = const Size(1000, 800),
  double textScale = 1.0,
  Widget? host,
  bool open = true,
  ClaudeConfigReader? claudeConfig,
}) async {
  SharedPreferences.setMockInitialValues({
    'memex.binary_path': ?binaryPath,
    'memex.vault_servers': [
      for (final s in servers)
        jsonEncode({'id': s.id, 'name': s.name, 'url': s.url}),
    ],
  });
  final fakeTokens = FakeTokenStore(
    tokens ?? {agentsSheetServer.id: agentsSheetToken},
  );
  final settings = await loadSettingsKeepingPickedBinary(
    tokenStore: fakeTokens,
  );
  final fakeClock = clock ?? FakeClock();
  final fakeAgents =
      agents ??
      FakeAgentsAccess(
        vaultPath: vault is LocalVaultRef ? vault.path : fakeAgentsVaultPath,
      );
  final fakeCli = cli ?? FakeMemexCli();
  final opener = RecordingUrlOpener();
  final menuHost = FakeWindowMenuHost();
  final routes = AgentsSheetRouteLog();

  final container = ProviderContainer(
    overrides: [
      ...agentsOverrides(access: fakeAgents, clock: fakeClock),
      currentVaultProvider.overrideWith((_) => vault),
      settingsProvider.overrideWith((_) => settings),
      tokenStoreProvider.overrideWithValue(fakeTokens),
      memexCliProvider.overrideWithValue(fakeCli),
      urlOpenerProvider.overrideWithValue(opener),
      windowMenuHostProvider.overrideWithValue(menuHost),
      claudeConfigReaderProvider.overrideWithValue(
        claudeConfig ?? FakeClaudeConfigReader.missing(),
      ),
      ...overrides,
    ],
  );

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  final originFocus = FocusNode(debugLabel: 'agents harness origin');
  addTearDown(originFocus.dispose);
  addTearDown(container.dispose);
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final hostKey = GlobalKey(debugLabel: 'agents harness host');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildOmTheme(),
        navigatorObservers: [routes],
        home: Scaffold(
          body: KeyedSubtree(
            key: hostKey,
            child:
                host ??
                Align(
                  alignment: Alignment.bottomLeft,
                  child: SizedBox(
                    width: 200,
                    child: TextField(
                      key: agentsSheetOriginKey,
                      focusNode: originFocus,
                    ),
                  ),
                ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  final harness = AgentsSheetHarness._(
    tester,
    container: container,
    clock: fakeClock,
    agents: fakeAgents,
    cli: fakeCli,
    tokens: fakeTokens,
    opener: opener,
    menuHost: menuHost,
    routes: routes,
    originFocus: originFocus,
    hostKey: hostKey,
  );
  if (open) await harness.open();
  return harness;
}
