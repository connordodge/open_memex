import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/main.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/editor/segment_editing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_harness.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/segment_editing_finder.dart';
import '../support/token_store_fakes.dart';

/// Robot for the launch-on-today journeys (WI #22). Finds widgets by Key:
/// `daily-date-header`, `daily-today-badge`, `editor-title`, `editor-body`,
/// `note-menu-button`, `note-menu-delete`.
class TodayRobot {
  TodayRobot(this.tester);

  final WidgetTester tester;
  late WorkspaceHarness h;

  /// Launch the app on a vault whose `ui_state.json` already holds
  /// [restoredTabs] (the tabs open when the app last quit), like
  /// `pumpWorkspace` otherwise: [FakeVaultDb], [FakeMemexCli] (with the
  /// `settings get` handler added) and [FakeClock] seams.
  Future<WorkspaceHarness> launch({
    required FakeVaultDb db,
    required FakeMemexCli cli,
    FakeClock? clock,
    List<PersistedTab> restoredTabs = const [],
    int activeTabIndex = 0,
  }) async {
    final vaultDir = Directory.systemTemp.createTempSync('omv-today');
    if (restoredTabs.isNotEmpty) {
      final state = UiState(
        tabs: restoredTabs,
        activeTabIndex: activeTabIndex,
        canvasViewports: const {},
      );
      final memexDir = Directory('${vaultDir.path}/.memex')
        ..createSync(recursive: true);
      // Synchronous IO: real async file IO does not complete inside the
      // fake-async zone of testWidgets.
      File(
        '${memexDir.path}/ui_state.json',
      ).writeAsStringSync(jsonEncode(state.toJson()));
    }
    cli.on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout));
    final fakeClock = clock ?? FakeClock();

    SharedPreferences.setMockInitialValues({
      'memex.binary_path': 'fake-memex',
      'memex.recent_vaults': <String>[vaultDir.path],
      'memex.last_vault': vaultDir.path,
    });
    final settings = await loadSettingsKeepingPickedBinary();

    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 0.5;

    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith((_) => settings),
        currentVaultProvider.overrideWith((_) => LocalVaultRef(vaultDir.path)),
        vaultDbProvider.overrideWithValue(db),
        memexCliProvider.overrideWithValue(cli),
        clockProvider.overrideWithValue(fakeClock),
      ],
    );

    addTearDown(() => _deleteQuietly(vaultDir));
    addTearDown(db.close);
    addTearDown(container.dispose);
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OpenMemexApp(),
      ),
    );
    await pumpFrames(tester, frames: 8);

    h = WorkspaceHarness(
      container: container,
      db: db,
      cli: cli,
      clock: fakeClock,
      vaultPath: vaultDir.path,
    );
    return h;
  }

  // ---------------------------------------------------------------- finders

  Finder get dateHeader => find.byKey(const Key('daily-date-header'));
  Finder get todayBadge => find.byKey(const Key('daily-today-badge'));
  Finder get titleField => find.byKey(const Key('editor-title'));

  /// The body field (Key `editor-body`, the first text segment). Read and
  /// drive it through [bodySegment].
  Finder get body => find.byKey(editorBodyKey);

  /// The body field's [SegmentEditing] handle (re-found on every call).
  SegmentEditing get bodySegment => editorBodySegment(tester);

  // ------------------------------------------------------------------ state

  TabsState get tabs => h.read(tabsProvider);
  WorkspaceTab? get activeTab => tabs.activeTab;
  String get bodyText => bodySegment.text;
  TextSelection get bodySelection => bodySegment.selection;
  bool get bodyHasFocus => bodySegment.focusedRow != null;

  List<FakeCliCall> get adds => h.cli.callsFor('add');
  List<FakeCliCall> get updates => h.cli.callsFor('update');

  // ---------------------------------------------------------------- actions

  /// Replace the body text as the person typing would.
  ///
  /// TEST-CHANGE (#167): through the body segment's handle, after focusing
  /// the editor row holding its end.
  Future<void> type(String text) => typeSegmentText(tester, body, text);

  /// Let the editor's debounce and any CLI round trip finish: moves both the
  /// test binding's time and the [FakeClock] (in case the save timer is
  /// scheduled through `clockProvider`) by 800 ms, then pumps frames.
  Future<void> waitForSave() async {
    for (var i = 0; i < 4; i++) {
      h.clock.advance(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
    }
    await pumpFrames(tester);
  }

  /// Move the [FakeClock] by [by] (firing the midnight timer) and pump.
  Future<void> advanceClock(Duration by) async {
    h.clock.advance(by);
    await pumpFrames(tester);
  }

  /// Open the note menu when its button is enabled.
  Future<void> openNoteMenu() async {
    final button = find.byKey(const Key('note-menu-button'));
    expect(button, findsOneWidget);
    await tester.tap(button, warnIfMissed: false);
    await pumpFrames(tester, frames: 3);
  }

  // ------------------------------------------------------------- assertions

  /// The fixed date header reads [text] and the editable title is gone.
  void expectDateHeader(String text) {
    expect(dateHeader, findsOneWidget);
    expect(
      find.descendant(of: dateHeader, matching: find.text(text)),
      findsOneWidget,
    );
    expect(titleField, findsNothing);
  }

  void expectTodayBadge({required bool shown}) {
    if (!shown) {
      expect(todayBadge, findsNothing);
      return;
    }
    expect(todayBadge, findsOneWidget);
    expect(
      find.descendant(of: todayBadge, matching: find.text('Today')),
      findsOneWidget,
    );
  }

  /// The active tab is the virtual Today tab for [date].
  void expectVirtualToday(String date) {
    final active = activeTab;
    expect(active, isA<VirtualTodayTab>());
    expect((active! as VirtualTodayTab).date, date);
  }

  /// The active tab is the real note tab for [noteId].
  void expectRealNoteTab(String noteId) {
    final active = activeTab;
    expect(active, isNot(isA<VirtualTodayTab>()));
    expect(active, isA<NoteTab>());
    expect(active!.id, noteId);
  }
}

void _deleteQuietly(Directory dir) {
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      // A queued UiStateStore write raced the delete; try again.
    }
  }
}
