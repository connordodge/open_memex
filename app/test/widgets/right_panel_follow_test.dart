// WI #271 (N8, Spec #232 R1, R2, R6, TD5): a click on a right panel outgoing
// link or backlink goes through the navigation seam. A plain click navigates
// the current tab and Back returns; a Cmd click focuses or opens a tab; a
// pending edit is saved before either; a ghost link and a link to the note
// already showing do nothing.
//
// The whole app runs on a FakeVaultDb with the links in its `links` table, so
// the panel reads them as it does in the app. Time is a FakeClock: the save
// debounce never fires unless a test advances it, so "with the clock not
// advanced" is exact. Never pumpAndSettle the workspace (OmDot pulses
// forever): pumpFrames only.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/graph_seeds.dart';
import '../support/recording_tabs.dart';
import '../support/segment_editing_finder.dart';
import '../support/today_cli_fakes.dart';

const _planId = 'n271-plan';
const _alphaId = 'n271-alpha';
const _mikeId = 'n271-mike';
const _plan = NoteTab(_planId);
const _alpha = NoteTab(_alphaId);
const _mike = NoteTab(_mikeId);

/// The FakeClock's start (the harness default): a test that ends here never
/// fired a timer.
final _launchedAt = DateTime(2026, 10, 3, 9);

/// Plan links out to Alpha, to a ghost and to itself, and Mike links to Plan.
FakeVaultDb _vault() {
  final db = FakeVaultDb.v5()
    ..seedNote(id: _planId, title: 'Plan', content: 'old', version: 3)
    ..seedNote(id: _alphaId, title: 'Alpha', content: 'alpha body', version: 2)
    ..seedNote(id: _mikeId, title: 'Mike', content: 'mike body', version: 5);
  db.seedLink(_planId, _alphaId, id: 'out-alpha', linkText: 'Alpha');
  db.seedLink(_planId, null, id: 'out-ghost', linkText: 'Nowhere');
  db.seedLink(_planId, _planId, id: 'out-self', linkText: 'Plan');
  db.seedLink(_mikeId, _planId, id: 'in-mike', linkText: 'Plan');
  return db;
}

/// Counts every `flushPendingSave`: the one call `onBeforeLeave` makes.
class _CountingEditor extends EditorController {
  _CountingEditor(super.ref, this.flushes);

  final List<String> flushes;

  @override
  void flushPendingSave() {
    flushes.add('flush');
    super.flushPendingSave();
  }
}

class _Panel {
  _Panel(this.tester, this.h, this.tabs, this.flushes);

  final WidgetTester tester;
  final WorkspaceHarness h;
  final TabsRecorder tabs;
  final List<String> flushes;

  TabsNotifier get notifier => h.read(tabsProvider.notifier);
  TabsState get state => h.read(tabsProvider);
  EditorStateValue get editor => h.read(editorControllerProvider);
  List<FakeCliCall> get updates => h.cli.callsFor('update');

  Finder get outgoingAlpha => find.byKey(const Key('outgoing-link-out-alpha'));
  Finder get ghost => find.byKey(const Key('outgoing-link-out-ghost'));
  Finder get self => find.byKey(const Key('outgoing-link-out-self'));
  Finder get backlinkMike =>
      find.byKey(const Key('backlink-item-$_mikeId-in-mike'));

  /// Shows [tab] in a tab of its own, active.
  Future<void> show(WorkspaceTab tab) async {
    notifier.openOrFocus(tab);
    await pumpFrames(tester);
  }

  Future<void> click(Finder link, {bool cmd = false}) async {
    expect(link, findsOneWidget);
    await tester.ensureVisible(link);
    await tester.pump();
    if (cmd) {
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.metaLeft,
        platform: 'macos',
      );
    }
    try {
      await tester.tap(link);
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

  Future<void> typeBody(String text) async {
    await typeSegmentText(tester, find.byKey(editorBodyKey), text);
    expect(updates, isEmpty, reason: 'still inside the debounce');
  }

  /// The one save sent is Plan's [text] on its stored version, the clock did
  /// not move and the stored note holds the text.
  void expectPlanSavedInsideDebounce(String text) {
    expect(h.clock.now(), _launchedAt, reason: 'the clock was not advanced');
    expect(updates, hasLength(1), reason: 'exactly one save was sent');
    expect(updates.single.flag('note-id'), _planId);
    expect(updates.single.flag('expected-version'), '3');
    expect(updates.single.stdinBody, text);
    expect(h.db.getNote(_planId)!.contentMd, text);
  }
}

/// The app on [_vault] with the Connections tab showing, a Today tab to the
/// left and Plan in the active tab: `[today] [plan*]`.
Future<_Panel> _onPlan(WidgetTester tester) async {
  final db = _vault();
  final cli = FakeMemexCli()
    ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
    ..onUpdateWrites(db);
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
  final panel = _Panel(tester, h, tabs, flushes);
  h.container.read(rightPanelOpenProvider.notifier).state = true;
  await panel.show(_plan);
  expect(panel.state.activeTab, _plan);
  expect(panel.outgoingAlpha, findsOneWidget, reason: 'the links are shown');
  tabs.followed.clear();
  tabs.navigated.clear();
  flushes.clear();
  return panel;
}

void main() {
  group('a plain click navigates the current tab', () {
    testWidgets(
      'a plain click on a right panel outgoing link navigates the current tab and Back returns to the previous note',
      (tester) async {
        final p = await _onPlan(tester);
        final tabsBefore = p.state.tabs.length;

        await p.click(p.outgoingAlpha);

        expect(p.tabs.followed, [_alpha]);
        expect(p.tabs.navigated, [_alpha]);
        expect(p.state.activeTab, _alpha);
        expect(p.state.tabs.length, tabsBefore, reason: 'no tab was added');
        expect(p.state.canGoBack, isTrue);
        expect(p.editor.title, 'Alpha');
        expect(p.h.read(selectedNoteIdProvider), _alphaId);

        await p.tapBack();

        expect(p.state.activeTab, _plan);
        expect(p.editor.title, 'Plan');
        expect(p.h.read(selectedNoteIdProvider), _planId);
        expect(p.state.canGoForward, isTrue);
      },
    );

    testWidgets(
      'a plain click on a right panel backlink navigates the current tab and Back returns to the previous note',
      (tester) async {
        final p = await _onPlan(tester);
        final tabsBefore = p.state.tabs.length;

        await p.click(p.backlinkMike);

        expect(p.tabs.followed, [_mike]);
        expect(p.tabs.navigated, [_mike]);
        expect(p.state.activeTab, _mike);
        expect(p.state.tabs.length, tabsBefore, reason: 'no tab was added');
        expect(p.state.canGoBack, isTrue);
        expect(p.editor.title, 'Mike');
        expect(p.h.read(selectedNoteIdProvider), _mikeId);

        await p.tapBack();

        expect(p.state.activeTab, _plan);
        expect(p.editor.title, 'Plan');
        expect(p.h.read(selectedNoteIdProvider), _planId);
      },
    );

    testWidgets(
      'a plain click on a right panel link stays in the current tab when another tab already shows the target',
      (tester) async {
        final p = await _onPlan(tester);
        await p.show(_alpha);
        p.notifier.setActive(1); // [today] [plan*] [alpha]
        await pumpFrames(tester);

        await p.click(p.outgoingAlpha);

        expect(p.state.tabs.sublist(1), [_alpha, _alpha]);
        expect(p.state.activeIndex, 1);
      },
    );
  });

  group('a Cmd click focuses or opens a tab', () {
    testWidgets(
      'a Cmd click on a right panel outgoing link opens a tab at the end and leaves the first tab history alone',
      (tester) async {
        final p = await _onPlan(tester);
        final before = p.state.tabs;

        await p.click(p.outgoingAlpha, cmd: true);

        expect(p.tabs.followed, [_alpha]);
        expect(p.tabs.navigated, isEmpty, reason: 'Cmd does not navigate');
        expect(p.state.tabs, [...before, _alpha]);
        expect(p.state.activeIndex, before.length);
        expect(p.state.canGoBack, isFalse, reason: 'a new tab holds one entry');
        expect(p.editor.title, 'Alpha');

        p.notifier.setActive(before.length - 1);
        await pumpFrames(tester);
        expect(p.state.activeTab, _plan);
        expect(p.state.canGoBack, isFalse);
        expect(p.state.canGoForward, isFalse, reason: 'Plan did not navigate');
        expect(p.editor.title, 'Plan');
      },
    );

    testWidgets(
      'a Cmd click on a right panel backlink opens a tab at the end and leaves the first tab history alone',
      (tester) async {
        final p = await _onPlan(tester);
        final before = p.state.tabs;

        await p.click(p.backlinkMike, cmd: true);

        expect(p.tabs.followed, [_mike]);
        expect(p.tabs.navigated, isEmpty);
        expect(p.state.tabs, [...before, _mike]);
        expect(p.state.activeIndex, before.length);
        expect(p.state.canGoBack, isFalse);
        expect(p.editor.title, 'Mike');
        p.notifier.setActive(before.length - 1);
        await pumpFrames(tester);
        expect(p.state.canGoForward, isFalse);
      },
    );

    testWidgets(
      'a Cmd click on a right panel link focuses the leftmost tab already showing the target',
      (tester) async {
        final p = await _onPlan(tester);
        await p.show(_alpha);
        await p.show(_mike);
        p.notifier.setActive(1); // [today] [plan*] [alpha] [mike]
        await pumpFrames(tester);
        p.tabs.followed.clear();
        final before = p.state.tabs;

        await p.click(p.outgoingAlpha, cmd: true);
        expect(p.state.tabs, before, reason: 'no tab was opened');
        expect(p.state.activeIndex, 2);
        expect(p.state.activeTab, _alpha);
        expect(p.tabs.followed, [_alpha]);
        expect(p.tabs.navigated, isEmpty);
        expect(p.editor.title, 'Alpha');
      },
    );

    testWidgets(
      'a Cmd click on a right panel backlink focuses the leftmost tab already showing the source note',
      (tester) async {
        final p = await _onPlan(tester);
        await p.show(_mike);
        p.notifier.setActive(1); // [today] [plan*] [mike]
        await pumpFrames(tester);
        final before = p.state.tabs;

        await p.click(p.backlinkMike, cmd: true);

        expect(p.state.tabs, before);
        expect(p.state.activeIndex, 2);
        expect(p.editor.title, 'Mike');
      },
    );
  });

  group('a pending edit is saved before the click leaves', () {
    testWidgets(
      'an edit typed less than 500 ms before a right panel outgoing link click is saved with the leaving note id and onBeforeLeave runs once',
      (tester) async {
        final p = await _onPlan(tester);
        await p.typeBody('new text');

        await p.click(p.outgoingAlpha);

        p.expectPlanSavedInsideDebounce('new text');
        expect(p.flushes, hasLength(1), reason: 'onBeforeLeave ran once');
        expect(p.state.activeTab, _alpha);
        expect(p.editor.title, 'Alpha');
        expect(p.editor.contentMd, 'alpha body');
      },
    );

    testWidgets(
      'an edit typed less than 500 ms before a right panel backlink click is saved with the leaving note id and onBeforeLeave runs once',
      (tester) async {
        final p = await _onPlan(tester);
        await p.typeBody('new text');

        await p.click(p.backlinkMike);

        p.expectPlanSavedInsideDebounce('new text');
        expect(p.flushes, hasLength(1), reason: 'onBeforeLeave ran once');
        expect(p.state.activeTab, _mike);
        expect(p.editor.contentMd, 'mike body');
      },
    );

    testWidgets(
      'an edit typed less than 500 ms before a Cmd click on a right panel link is saved with the leaving note id and onBeforeLeave runs once',
      (tester) async {
        final p = await _onPlan(tester);
        await p.typeBody('new text');

        await p.click(p.outgoingAlpha, cmd: true);

        p.expectPlanSavedInsideDebounce('new text');
        expect(p.flushes, hasLength(1), reason: 'onBeforeLeave ran once');
        expect(p.state.activeTab, _alpha);
      },
    );

    testWidgets(
      'a click on a right panel link to the note already showing runs onBeforeLeave zero times and saves nothing',
      (tester) async {
        final p = await _onPlan(tester);
        await p.typeBody('new text');

        await p.click(p.self);

        expect(p.flushes, isEmpty, reason: 'nothing was left');
        expect(p.updates, isEmpty, reason: 'the edit is still pending');
        expect(p.state.activeTab, _plan);
        expect(p.state.canGoBack, isFalse, reason: 'no history entry');
        expect(p.editor.contentMd, 'new text');

        // Control: a real leave runs it once and saves the edit.
        await p.click(p.outgoingAlpha);
        expect(p.flushes, hasLength(1));
        p.expectPlanSavedInsideDebounce('new text');
      },
    );
  });

  group('a link with no target does nothing', () {
    testWidgets(
      'a click on a ghost outgoing link follows nothing and leaves the tab and its pending edit alone',
      (tester) async {
        final p = await _onPlan(tester);
        await p.typeBody('new text');
        final before = p.state;

        expect(p.ghost, findsOneWidget);
        await p.tester.ensureVisible(p.ghost);
        await p.tester.tap(p.ghost, warnIfMissed: false);
        await pumpFrames(tester);

        expect(p.tabs.followed, isEmpty);
        expect(p.tabs.navigated, isEmpty);
        expect(p.flushes, isEmpty);
        expect(p.updates, isEmpty);
        expect(p.state.activeTab, _plan);
        expect(p.state.tabs, before.tabs);
        expect(p.state.canGoBack, isFalse);

        // Control: a resolved link next to it follows.
        await p.click(p.outgoingAlpha);
        expect(p.tabs.followed, [_alpha]);
      },
    );
  });
}
