// WI #76 (56-A2, Spec #59 D17): the Command palette test pump. #77 and #78
// use it unchanged; this Spec owns it (and recording_tabs.dart) this run.
// Call `holdFontFetches()` at the top of `main()` in a file that uses it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import 'app_harness.dart' show pumpFrames;
import 'canvas_seeds.dart';
import 'daily_seed.dart';
import 'fake_clock.dart';
import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';
import 'font_fetch_hold.dart';
import 'recording_tabs.dart';
import 'search_fakes.dart';

/// The wide-card window (preview pane shown, Spec #59 req 9).
const paletteWideSize = Size(1280, 800);

/// The narrow window (list-only card, req 10; req 40's overflow check).
const paletteNarrowSize = Size(900, 640);

/// The local vault folder the pump opens (never created on disk).
const paletteVaultPath = '/vaults/My Vault';

/// "Now" for the pump's [FakeClock]: 2026-11-18 09:00 local.
final paletteNow = DateTime(2026, 11, 18, 9);

/// [hours] hours before [paletteNow], in ms.
int paletteHoursAgo(int hours) =>
    paletteNow.subtract(Duration(hours: hours)).millisecondsSinceEpoch;

/// The seeded notes, daily notes and canvases (ids and titles), newest first
/// within each kind. Daily note titles are their ISO dates.
abstract final class PaletteSeeds {
  static const backlog = 'n-76-backlog';
  static const feedbackLog = 'n-76-feedback-log';
  static const pricingModel = 'n-76-pricing-model';
  static const today = 'daily-2026-11-18';
  static const yesterday = 'daily-2026-11-17';
  static const backendMigration = 'cv-76-backend-migration';

  /// (id, title, hours ago) of the plain notes.
  static const notes = [
    (pricingModel, 'Pricing model', 2),
    (backlog, 'Backlog', 96),
    (feedbackLog, 'Feedback log', 144),
  ];

  /// (id, ISO date, hours ago) of the daily notes.
  static const dailies = [
    (today, '2026-11-18', 1),
    (yesterday, '2026-11-17', 24),
  ];

  /// (id, title, hours ago) of the canvases.
  static const canvases = [(backendMigration, 'Backend migration', 336)];
}

/// Everything a test needs after [pumpPaletteHost].
class PaletteHarness {
  PaletteHarness({
    required this.container,
    required this.search,
    required this.tabs,
    required this.clock,
    required this.cli,
    required this.db,
    required this.navigatorKey,
  });

  final ProviderContainer container;

  /// `vaultAccessProvider.search`.
  final FakeSearchAccess search;

  /// Records `tabsProvider`'s follow and navigate targets.
  final TabsRecorder tabs;

  /// `clockProvider`: debounces and relative times run on it.
  final FakeClock clock;

  /// `memexCliProvider` and the vault's CLI (null: no CLI configured).
  final FakeMemexCli? cli;

  /// `vaultDbProvider`, holding [PaletteSeeds] unless told not to.
  final FakeVaultDb db;

  /// The root navigator (D13: the palette is a root-navigator dialog).
  final GlobalKey<NavigatorState> navigatorKey;

  /// The root navigator's context, to show the palette dialog from.
  BuildContext get context => navigatorKey.currentContext!;

  T read<T>(ProviderListenable<T> provider) => container.read(provider);
}

/// Pump a host for the Command palette over its fakes:
/// - `vaultAccessProvider`: a `LocalVaultAccess` for [paletteVaultPath] over
///   [db], [cli] and [search] (a [FakeSearchAccess] answering no hits by
///   default);
/// - `currentVaultProvider` (a `LocalVaultRef`), `vaultDbProvider`,
///   `memexCliProvider`, `clockProvider` (a [FakeClock] at [paletteNow]) and
///   the [TabsRecorder]'s observer;
/// - the database holds [PaletteSeeds] unless [seed] is false.
///
/// The window is [size] ([paletteWideSize] or [paletteNarrowSize]) at device
/// pixel ratio 1, with text laid out at [textScale]. [child] is the
/// Scaffold's body (empty by default); a dialog is shown over
/// [PaletteHarness.context]. [overrides] are appended (e.g. a filler's
/// source); they must not repeat a provider the pump overrides.
Future<PaletteHarness> pumpPaletteHost(
  WidgetTester tester, {
  Size size = paletteWideSize,
  double textScale = 1.0,
  Widget? child,
  FakeSearchAccess? search,
  FakeClock? clock,
  FakeMemexCli? cli,
  bool memexConfigured = true,
  FakeVaultDb? db,
  bool seed = true,
  List<Override> overrides = const [],
}) async {
  expect(
    fontFetchesHeld,
    isTrue,
    reason: 'call holdFontFetches() at the top of main()',
  );
  final fakeCli = memexConfigured ? (cli ?? FakeMemexCli()) : null;
  final fakeSearch =
      search ?? FakeSearchAccess(vaultPath: paletteVaultPath, cli: fakeCli);
  final fakeClock = clock ?? FakeClock(paletteNow);
  final fakeDb = db ?? FakeVaultDb.v5();
  final tabs = TabsRecorder();
  final navigatorKey = GlobalKey<NavigatorState>();
  if (seed) {
    for (final (id, title, hours) in PaletteSeeds.notes) {
      fakeDb.seedNote(id: id, title: title, updatedAt: paletteHoursAgo(hours));
    }
    for (final (id, date, hours) in PaletteSeeds.dailies) {
      fakeDb.seedDailyNote(date, id: id, updatedAt: paletteHoursAgo(hours));
    }
    for (final (id, title, hours) in PaletteSeeds.canvases) {
      fakeDb.seedCanvas(id, title, updatedAt: paletteHoursAgo(hours));
    }
  }

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;

  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith(
        (_) => const LocalVaultRef(paletteVaultPath),
      ),
      vaultDbProvider.overrideWithValue(fakeDb),
      memexCliProvider.overrideWithValue(fakeCli),
      clockProvider.overrideWithValue(fakeClock),
      tabs.override,
      vaultAccessProvider.overrideWith(
        (ref) => LocalVaultAccess(
          vaultPath: paletteVaultPath,
          db: fakeDb,
          cli: fakeCli,
          search: fakeSearch,
        ),
      ),
      ...overrides,
    ],
  );

  addTearDown(fakeDb.close);
  addTearDown(container.dispose);
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        theme: buildOmTheme(),
        home: Scaffold(body: child ?? const SizedBox.expand()),
      ),
    ),
  );
  await pumpFrames(tester);

  return PaletteHarness(
    container: container,
    search: fakeSearch,
    tabs: tabs,
    clock: fakeClock,
    cli: fakeCli,
    db: fakeDb,
    navigatorKey: navigatorKey,
  );
}
