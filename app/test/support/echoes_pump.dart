// #424 (391-A0): pumps the right panel's echoes tab over the echoes fakes.
// Call `holdFontFetches()` at the top of `main()` in a file that uses it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/echo_link_actions.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';

import 'app_harness.dart' show pumpFrames;
import 'echoes_fakes.dart';
import 'fake_clock.dart';
import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';

/// The note [pumpEchoesTab] selects unless told otherwise.
const echoesOpenNoteId = '01JECHOOPEN00000000000000A';

/// The local vault folder [pumpEchoesTab] opens (never created on disk).
const echoesVaultPath = '/tmp/om-echoes-vault';

/// Everything a test needs after [pumpEchoesTab].
class EchoesTabHarness {
  EchoesTabHarness({
    required this.container,
    required this.echoes,
    required this.links,
    required this.clock,
    required this.cli,
    required this.db,
    required this.noteId,
  });

  final ProviderContainer container;

  /// The echoes domain behind `vaultAccessProvider.echoes`.
  final FakeEchoesAccess echoes;

  /// `echoLinkActionsProvider`.
  final FakeEchoLinkActions links;

  /// `clockProvider`.
  final FakeClock clock;

  /// `memexCliProvider` and the vault's CLI (null: no CLI configured).
  final FakeMemexCli? cli;

  /// `vaultDbProvider`; holds the open note when one was seeded.
  final FakeVaultDb db;

  /// The selected note id (`selectedNoteIdProvider`), or null.
  final String? noteId;

  T read<T>(ProviderListenable<T> provider) => container.read(provider);
}

/// Pump `RightPanel` on its echoes tab with the echoes seams:
/// - `vaultAccessProvider`: a `LocalVaultAccess` for [echoesVaultPath] over
///   [db], [cli] and [echoes];
/// - `currentVaultProvider` (a `LocalVaultRef`), `vaultDbProvider`,
///   `memexCliProvider`, `clockProvider` and `echoLinkActionsProvider`;
/// - `selectedNoteIdProvider` = [noteId] (pass null for no note),
///   `rightPanelOpenProvider` = [panelOpen], `rightPanelTabProvider` = [tab].
///
/// Defaults: a [FakeEchoesAccess] answering no echoes, a
/// [FakeEchoLinkActions] that completes, a [FakeClock] at 2026-10-03 09:00
/// local, a [FakeMemexCli] with no handlers ([memexConfigured] false gives no
/// CLI), and a fresh V5 [FakeVaultDb]. When [noteId] is a real note id and
/// [seedOpenNote] is true, the database holds it with [openTitle],
/// [openContent] and [openRole]. Text is laid out at [textScale] (0.5 by
/// default: the test font is far wider than the app's, see `pumpWorkspace`).
/// [overrides] are appended to the seams (e.g. a notes double's
/// providers); they must not repeat a provider the pump already overrides.
Future<EchoesTabHarness> pumpEchoesTab(
  WidgetTester tester, {
  FakeEchoesAccess? echoes,
  FakeEchoLinkActions? links,
  FakeClock? clock,
  FakeMemexCli? cli,
  bool memexConfigured = true,
  FakeVaultDb? db,
  String? noteId = echoesOpenNoteId,
  bool seedOpenNote = true,
  String openTitle = 'Open note',
  String openContent = '',
  String? openRole,
  bool panelOpen = true,
  RightPanelTab tab = RightPanelTab.echoes,
  double textScale = 0.5,
  Size surfaceSize = const Size(800, 1000),
  List<Override> overrides = const [],
}) async {
  final fakeEchoes = echoes ?? FakeEchoesAccess(vaultPath: echoesVaultPath);
  final fakeLinks = links ?? FakeEchoLinkActions();
  final fakeClock = clock ?? FakeClock();
  final fakeCli = memexConfigured ? (cli ?? FakeMemexCli()) : null;
  final fakeDb = db ?? FakeVaultDb.v5();
  if (noteId != null && seedOpenNote && !noteId.startsWith('virtual-today:')) {
    fakeDb.seedNote(
      id: noteId,
      title: openTitle,
      content: openContent,
      role: openRole,
    );
  }

  tester.view.physicalSize = surfaceSize;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;

  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith(
        (_) => const LocalVaultRef(echoesVaultPath),
      ),
      vaultDbProvider.overrideWithValue(fakeDb),
      memexCliProvider.overrideWithValue(fakeCli),
      clockProvider.overrideWithValue(fakeClock),
      echoLinkActionsProvider.overrideWithValue(fakeLinks),
      vaultAccessProvider.overrideWith(
        (ref) => LocalVaultAccess(
          vaultPath: echoesVaultPath,
          db: fakeDb,
          cli: fakeCli,
          echoes: fakeEchoes,
        ),
      ),
      ...overrides,
    ],
  );
  container.read(selectedNoteIdProvider.notifier).state = noteId;
  container.read(rightPanelOpenProvider.notifier).state = panelOpen;
  container.read(rightPanelTabProvider.notifier).state = tab;

  addTearDown(fakeDb.close);
  addTearDown(container.dispose);
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(body: RightPanel(onClose: () {})),
      ),
    ),
  );
  await pumpFrames(tester);

  return EchoesTabHarness(
    container: container,
    echoes: fakeEchoes,
    links: fakeLinks,
    clock: fakeClock,
    cli: fakeCli,
    db: fakeDb,
    noteId: noteId,
  );
}
