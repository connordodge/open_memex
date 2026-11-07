// WI #271 (N8, Spec #232 R1, R2, R6, TD1): the sidebar Today row is a
// navigation like every other row. A plain click navigates the current tab to
// today's daily note (or the virtual Today note while there is none), a Cmd
// click focuses the leftmost tab showing today or opens one at the end, and a
// pending edit is saved when today is left behind, exactly once.
//
// The whole app runs on a FakeVaultDb. Time is a FakeClock: the save debounce
// never fires unless a test advances it. Never pumpAndSettle the workspace
// (OmDot pulses forever): pumpFrames only.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';

import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/recording_tabs.dart';
import '../support/segment_editing_finder.dart';
import '../support/today_cli_fakes.dart';

// The harness clock's date, so a seeded daily note is the launch tab.
const _date = '2026-10-03';
const _todayId = 'daily-2026-10-03';
const _otherId = 'n271-other';
const _todayNote = NoteTab(_todayId);
const _virtual = VirtualTodayTab(_date);
const _other = NoteTab(_otherId);

final _launchedAt = DateTime(2026, 10, 3, 9);

class _CountingEditor extends EditorController {
  _CountingEditor(super.ref, this.flushes);

  final List<String> flushes;

  @override
  void flushPendingSave() {
    flushes.add('flush');
    super.flushPendingSave();
  }
}

class _Row {
  _Row(this.tester, this.h, this.tabs, this.flushes);

  final WidgetTester tester;
  final WorkspaceHarness h;
  final TabsRecorder tabs;
  final List<String> flushes;

  TabsNotifier get notifier => h.read(tabsProvider.notifier);
  TabsState get state => h.read(tabsProvider);
  EditorStateValue get editor => h.read(editorControllerProvider);
  List<FakeCliCall> get updates => h.cli.callsFor('update');
  List<FakeCliCall> get adds => h.cli.callsFor('add');

  Finder get todayRow => find.byKey(const Key('days-row-today'));

  Future<void> show(WorkspaceTab tab) async {
    notifier.openOrFocus(tab);
    await pumpFrames(tester);
  }

  Future<void> clickToday({bool cmd = false}) async {
    expect(todayRow, findsOneWidget);
    if (cmd) {
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.metaLeft,
        platform: 'macos',
      );
    }
    try {
      await tester.tap(todayRow);
      await pumpFrames(tester);
    } finally {
      if (cmd) {
        await tester.sendKeyUpEvent(
          LogicalKeyboardKey.metaLeft,
          platform: 'macos',
        );
        await tester.pump();
      }
    }
  }

  Future<void> tapBack() async {
    await tester.tap(find.byKey(const Key('nav-back-button')));
    await pumpFrames(tester);
  }

  Future<void> tapForward() async {
    await tester.tap(find.byKey(const Key('nav-forward-button')));
    await pumpFrames(tester);
  }

  Future<void> typeBody(String text) async {
    await typeSegmentText(tester, find.byKey(editorBodyKey), text);
    expect(updates, isEmpty, reason: 'still inside the debounce');
    expect(adds, isEmpty, reason: 'still inside the debounce');
  }

  void forget() {
    tabs.followed.clear();
    tabs.navigated.clear();
    flushes.clear();
  }
}

/// The app on a vault with the note Other, and a daily note for today when
/// [withDaily] (else the launch shows the virtual Today note), with Other open
/// in a tab to the right of the launch tab: `[today] [other*]`.
Future<_Row> _launch(WidgetTester tester, {bool withDaily = true}) async {
  final db = FakeVaultDb.v5()
    ..seedNote(id: _otherId, title: 'Other', content: 'other body', version: 4);
  if (withDaily) db.seedDailyNote(_date, id: _todayId, version: 2);
  final cli = FakeMemexCli()
    ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
    ..onUpdateWrites(db)
    ..onAddDailyCreates(db);
  final tabs = TabsRecorder();
  final flushes = <String>[];
  final h = await pumpWorkspace(
    tester,
    db: db,
    cli: cli,
    overrides: [
      tabs.override,
      editorControllerProvider.overrideWith(
        (ref) => _CountingEditor(ref, flushes),
      ),
    ],
  );
  final row = _Row(tester, h, tabs, flushes);
  expect(row.state.tabs, [withDaily ? _todayNote : _virtual]);
  await row.show(_other);
  expect(row.state.tabs, [withDaily ? _todayNote : _virtual, _other]);
  row.forget();
  return row;
}

void main() {
  for (final (name, withDaily) in [
    (
      'a plain click on the Today row navigates the current tab to today daily note and Back returns to the previous note',
      true,
    ),
    (
      'a plain click on the Today row navigates the current tab to the virtual Today note when there is no daily note yet and Back returns',
      false,
    ),
  ]) {
    testWidgets(name, (tester) async {
      final r = await _launch(tester, withDaily: withDaily);
      final today = withDaily ? _todayNote : _virtual;

      await r.clickToday();

      expect(r.tabs.followed, [today]);
      expect(r.tabs.navigated, [today]);
      expect(r.state.tabs, [today, today], reason: 'no tab was added');
      expect(r.state.activeIndex, 1);
      expect(r.state.canGoBack, isTrue);
      expect(
        find.byKey(const Key('daily-today-badge')),
        findsOneWidget,
        reason: 'the editor shows today',
      );

      await r.tapBack();

      expect(r.state.activeTab, _other);
      expect(r.editor.title, 'Other');
      expect(r.state.canGoForward, isTrue);

      await r.tapForward();
      expect(r.state.activeTab, today);
    });
  }

  for (final (name, withDaily) in [
    (
      'a Cmd click on the Today row focuses the leftmost tab showing today and leaves the tab it came from alone',
      true,
    ),
    (
      'a Cmd click on the Today row focuses the leftmost tab showing the virtual Today note and leaves the tab it came from alone',
      false,
    ),
  ]) {
    testWidgets(name, (tester) async {
      final r = await _launch(tester, withDaily: withDaily);
      final today = withDaily ? _todayNote : _virtual;
      final before = r.state.tabs;

      await r.clickToday(cmd: true);

      expect(r.tabs.followed, [today]);
      expect(r.tabs.navigated, isEmpty, reason: 'Cmd does not navigate');
      expect(r.state.tabs, before, reason: 'no tab was opened');
      expect(r.state.activeIndex, 0);
      expect(r.state.canGoBack, isFalse, reason: 'its history is untouched');

      r.notifier.setActive(1);
      await pumpFrames(tester);
      expect(r.state.activeTab, _other);
      expect(r.state.canGoBack, isFalse, reason: 'Other did not navigate');
    });
  }

  for (final (name, withDaily) in [
    (
      'a Cmd click on the Today row with today not open opens a tab at the end and not first',
      true,
    ),
    (
      'a Cmd click on the Today row with the virtual Today note not open opens a tab at the end and not first',
      false,
    ),
  ]) {
    testWidgets(name, (tester) async {
      final r = await _launch(tester, withDaily: withDaily);
      final today = withDaily ? _todayNote : _virtual;
      r.notifier.closeAt(0);
      await pumpFrames(tester);
      expect(r.state.tabs, [_other]);
      r.forget();

      await r.clickToday(cmd: true);

      expect(r.tabs.followed, [today]);
      expect(r.tabs.navigated, isEmpty);
      expect(r.state.tabs, [_other, today], reason: 'appended, not first');
      expect(r.state.activeIndex, 1);
      expect(r.state.canGoBack, isFalse, reason: 'only today in its history');
    });
  }

  group('onBeforeLeave runs once for the Today row', () {
    testWidgets(
      'an edit typed less than 500 ms before a plain click on the Today row is saved with the leaving note id and onBeforeLeave runs once',
      (tester) async {
        final r = await _launch(tester);
        await r.typeBody('new text');

        await r.clickToday();

        expect(r.tabs.followed, [_todayNote]);
        expect(r.flushes, hasLength(1), reason: 'onBeforeLeave ran once');
        expect(r.h.clock.now(), _launchedAt, reason: 'clock not advanced');
        expect(r.updates, hasLength(1));
        expect(r.updates.single.flag('note-id'), _otherId);
        expect(r.updates.single.flag('expected-version'), '4');
        expect(r.updates.single.stdinBody, 'new text');
        expect(r.state.activeTab, _todayNote);
      },
    );

    testWidgets(
      'an edit typed less than 500 ms before a Cmd click on the Today row is saved with the leaving note id and onBeforeLeave runs once',
      (tester) async {
        final r = await _launch(tester);
        await r.typeBody('new text');

        await r.clickToday(cmd: true);

        expect(r.tabs.followed, [_todayNote]);
        expect(r.flushes, hasLength(1), reason: 'onBeforeLeave ran once');
        expect(r.updates, hasLength(1));
        expect(r.updates.single.flag('note-id'), _otherId);
        expect(r.updates.single.stdinBody, 'new text');
        expect(r.state.activeIndex, 0);
      },
    );

    testWidgets(
      'a click on the Today row with today already showing runs onBeforeLeave zero times and adds no history entry',
      (tester) async {
        final r = await _launch(tester);
        r.notifier.setActive(0);
        await pumpFrames(tester);
        await r.typeBody('new text');
        r.forget();
        final before = r.state.tabs;

        await r.clickToday();
        await r.clickToday(cmd: true);

        expect(r.tabs.followed, [
          _todayNote,
          _todayNote,
        ], reason: 'both clicks');
        expect(r.flushes, isEmpty, reason: 'nothing was left');
        expect(r.updates, isEmpty, reason: 'the edit is still pending');
        expect(r.state.tabs, before);
        expect(r.state.activeIndex, 0);
        expect(r.state.canGoBack, isFalse, reason: 'no history entry');
        expect(r.editor.contentMd, contains('new text'));

        // Control: a real leave runs it once.
        r.notifier.setActive(1);
        await pumpFrames(tester);
        expect(r.flushes, hasLength(1));
      },
    );

    testWidgets(
      'a click on the Today row with the virtual Today note already showing runs onBeforeLeave zero times and creates nothing',
      (tester) async {
        final r = await _launch(tester, withDaily: false);
        r.notifier.setActive(0);
        await pumpFrames(tester);
        await r.typeBody('Morning pages');
        r.forget();

        await r.clickToday();

        expect(r.tabs.followed, [_virtual]);
        expect(r.flushes, isEmpty);
        expect(r.adds, isEmpty, reason: 'the first edit is still pending');
        expect(r.state.tabs, [_virtual, _other]);
        expect(r.state.canGoBack, isFalse);

        r.notifier.setActive(1);
        await pumpFrames(tester);
        expect(r.flushes, hasLength(1), reason: 'control');
        expect(r.adds, hasLength(1));
      },
    );
  });

  group('the virtual Today note followed from a note', () {
    testWidgets(
      'text typed in a virtual Today note reached with a plain click is created when Back leaves it and the real note shows it on Forward',
      (tester) async {
        final r = await _launch(tester, withDaily: false);
        await r.clickToday(); // [virtual] [virtual*], other behind it
        expect(r.state.tabs, [_virtual, _virtual]);
        await r.typeBody('Morning pages');

        await r.tapBack();

        expect(r.adds, hasLength(1), reason: 'the leave sent the create');
        expect(r.adds.single.stdinBody, 'Morning pages');
        expect(r.state.activeTab, _other);
        expect(r.state.tabs, [
          const NoteTab(createdDailyId),
          _other,
        ], reason: 'the entry and the launch tab both became the real note');

        await r.tapForward();
        expect(r.state.activeTab, const NoteTab(createdDailyId));
        expect(editorBodyText(tester), contains('Morning pages'));
        expect(r.h.db.getNote(createdDailyId)!.contentMd, contains('Morning'));
        expect(r.adds, hasLength(1), reason: 'no second create');
      },
    );
  });
}
