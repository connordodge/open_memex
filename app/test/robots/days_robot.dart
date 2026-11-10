import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/main.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_harness.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/token_store_fakes.dart';

/// Robot for the sidebar Days mode and the Days/Topics switch (WI #23).
/// Finds widgets by the WI's stable Keys: `sidebar-mode-days`,
/// `sidebar-mode-topics`, `days-pane`, `days-month-<yyyy-mm>`,
/// `days-row-today`, `days-row-<yyyy-mm-dd>`, `days-dot-<yyyy-mm-dd>`,
/// `days-empty`, plus #19's `notes-rail`.
class DaysRobot {
  DaysRobot(this.tester);

  final WidgetTester tester;
  late WorkspaceHarness h;

  /// Launch the app like `pumpWorkspace` ([FakeVaultDb], [FakeMemexCli] with
  /// the `settings get` handler, [FakeClock]) on a temp vault whose
  /// `.memex/ui_state.json` holds [uiState] when given.
  Future<WorkspaceHarness> launch({
    required FakeVaultDb db,
    FakeMemexCli? cli,
    FakeClock? clock,
    Map<String, Object?>? uiState,
  }) async {
    final vaultDir = Directory.systemTemp.createTempSync('omv-days');
    if (uiState != null) {
      final memexDir = Directory('${vaultDir.path}/.memex')
        ..createSync(recursive: true);
      // Synchronous IO: real async file IO does not complete inside the
      // fake-async zone of testWidgets.
      File(
        '${memexDir.path}/ui_state.json',
      ).writeAsStringSync(jsonEncode(uiState));
    }
    final fakeCli = (cli ?? FakeMemexCli())
      ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout));
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
        memexCliProvider.overrideWithValue(fakeCli),
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
      cli: fakeCli,
      clock: fakeClock,
      vaultPath: vaultDir.path,
    );
    return h;
  }

  // ---------------------------------------------------------------- finders

  Finder get daysSwitch => find.byKey(const Key('sidebar-mode-days'));
  Finder get topicsSwitch => find.byKey(const Key('sidebar-mode-topics'));
  Finder get daysPane => find.byKey(const Key('days-pane'));
  Finder get notesRail => find.byKey(const Key('notes-rail'));
  Finder get todayRow => find.byKey(const Key('days-row-today'));
  Finder get empty => find.byKey(const Key('days-empty'));
  Finder row(String date) => find.byKey(Key('days-row-$date'));
  Finder dot(String date) => find.byKey(Key('days-dot-$date'));
  Finder month(String yyyyMm) => find.byKey(Key('days-month-$yyyyMm'));

  /// Every widget whose Key starts with [prefix] (e.g. `days-month-`).
  Finder keyedWithPrefix(String prefix) => find.byWidgetPredicate((w) {
    final k = w.key;
    return k is ValueKey<String> && k.value.startsWith(prefix);
  });

  /// Dated rows (`days-row-<date>`), excluding the Today row.
  Finder get datedRows => find.byWidgetPredicate((w) {
    final k = w.key;
    return k is ValueKey<String> &&
        k.value.startsWith('days-row-') &&
        k.value != 'days-row-today';
  });

  /// Every string drawn by Text / RichText under [of].
  List<String> textsUnder(Finder of) {
    final out = <String>[];
    for (final e
        in find
            .descendant(
              of: of,
              matching: find.byType(RichText),
              matchRoot: true,
            )
            .evaluate()) {
      out.add((e.widget as RichText).text.toPlainText());
    }
    return out;
  }

  /// Every colour a dot under [of] paints with: `OmDot.color`, a
  /// `Container`/`DecoratedBox` decoration colour, a `ColoredBox` or `Icon`.
  Set<Color> colorsUnder(Finder of) {
    final out = <Color>{};
    for (final e
        in find
            .descendant(
              of: of,
              matching: find.byWidgetPredicate((_) => true),
              matchRoot: true,
            )
            .evaluate()) {
      final w = e.widget;
      if (w is OmDot) out.add(w.color);
      if (w is Container) {
        if (w.color != null) out.add(w.color!);
        final d = w.decoration;
        if (d is BoxDecoration && d.color != null) out.add(d.color!);
      }
      if (w is DecoratedBox) {
        final d = w.decoration;
        if (d is BoxDecoration && d.color != null) out.add(d.color!);
      }
      if (w is ColoredBox) out.add(w.color);
      if (w is Icon && w.color != null) out.add(w.color!);
    }
    return out;
  }

  /// The label lines of the semantics node that carries the dot for [date].
  /// Call with semantics enabled (`tester.ensureSemantics()`).
  List<String> dotSemanticsLabels(String date) {
    final SemanticsNode node = tester.getSemantics(dot(date));
    return node
        .getSemanticsData()
        .label
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  // ------------------------------------------------------------------ state

  TabsState get tabs => h.read(tabsProvider);
  WorkspaceTab? get activeTab => tabs.activeTab;

  // ---------------------------------------------------------------- actions

  Future<void> tap(Finder f) async {
    expect(f, findsOneWidget);
    await tester.tap(f);
    await pumpFrames(tester);
  }

  Future<void> chooseTopics() => tap(topicsSwitch);
  Future<void> chooseDays() => tap(daysSwitch);
  Future<void> openRow(String date) => tap(row(date));
  Future<void> openToday() => tap(todayRow);

  /// Move the [FakeClock] by [by] (firing the midnight timer) and pump.
  Future<void> advanceClock(Duration by) async {
    h.clock.advance(by);
    await pumpFrames(tester);
  }

  /// Bump `vaultRevisionProvider` as a save or the poller would, and pump.
  Future<void> bumpRevision() async {
    h.container.read(vaultRevisionProvider.notifier).state++;
    await pumpFrames(tester);
  }

  // ------------------------------------------------------------- assertions

  /// The dated row for [date] shows its ISO date and [preview], and none of
  /// [hidden] (e.g. the second line of the first block).
  void expectDatedRow(
    String date, {
    required String preview,
    List<String> hidden = const [],
  }) {
    expect(row(date), findsOneWidget);
    final texts = textsUnder(row(date));
    expect(
      texts.any((t) => t.contains(date)),
      isTrue,
      reason: 'row $date shows its ISO date, got $texts',
    );
    expect(
      texts.any((t) => t.contains(preview)),
      isTrue,
      reason: 'row $date shows the preview "$preview", got $texts',
    );
    for (final h in hidden) {
      expect(
        texts.any((t) => t.contains(h)),
        isFalse,
        reason: 'row $date must not show "$h", got $texts',
      );
    }
  }

  /// The month header [yyyyMm] reads [header] (an eyebrow may upper-case
  /// it).
  void expectMonthHeader(String yyyyMm, String header) {
    expect(month(yyyyMm), findsOneWidget);
    expect(
      textsUnder(month(yyyyMm)).map((t) => t.trim().toLowerCase()),
      contains(header.toLowerCase()),
    );
  }

  /// The global top edge of [e]'s render box.
  double topOf(Element e) =>
      (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy;

  /// The global top edge of the one widget [f] finds.
  double top(Finder f) => tester.getTopLeft(f).dy;

  /// The dot of [date] is labelled exactly [state]'s label (and no other
  /// state's label) for screen readers.
  void expectDotLabel(String date, ReviewState state) {
    expect(dot(date), findsOneWidget);
    final lines = dotSemanticsLabels(date);
    expect(lines, contains(state.label));
    for (final other in ReviewState.values.where((s) => s != state)) {
      expect(lines, isNot(contains(other.label)));
    }
  }

  /// The Today row reads `Today` and sits above every dated row and month
  /// header.
  void expectTodayRowFirst() {
    expect(todayRow, findsOneWidget);
    expect(
      textsUnder(todayRow).any((t) => t.trim() == 'Today'),
      isTrue,
      reason: 'the Today row reads Today, got ${textsUnder(todayRow)}',
    );
    final todayTop = top(todayRow);
    for (final e in [
      ...datedRows.evaluate(),
      ...keyedWithPrefix('days-month-').evaluate(),
    ]) {
      expect(
        topOf(e),
        greaterThan(todayTop),
        reason: '${e.widget.key} is below Today',
      );
    }
  }

  /// The Today row has no review dot (the virtual note has nothing to
  /// review).
  void expectTodayRowHasNoDot() {
    expect(
      find.descendant(of: todayRow, matching: keyedWithPrefix('days-dot-')),
      findsNothing,
    );
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
