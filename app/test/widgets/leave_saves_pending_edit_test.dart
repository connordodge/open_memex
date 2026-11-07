// WI #264 (N1, ruling D9): an edit typed less than the 500 ms save debounce
// before leaving a note is saved with the leaving note's id, text and version.
// The whole app runs with the real editor hydrating on each switch, which is
// what drops the edit on main: `EditorController.loadNote` cancels the debounce.
//
// Time is a FakeClock: `tester.pump` never moves it, so the debounce can only
// fire when a test advances it, and "with the clock not advanced" is exact.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/topic_actions.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/segment_editing_finder.dart';
import '../support/today_cli_fakes.dart';

const _today = '2026-10-03';
const _planId = '01J9PLAN000000000000000264';
const _otherId = '01J9OTHER00000000000000264';
const _dailyId = '01J9DAILY00000000000000264';
const _plan = NoteTab(_planId);
const _other = NoteTab(_otherId);
const _virtual = VirtualTodayTab(_today);

/// The harness's FakeClock start: a test that ends here never fired a timer.
final _launchedAt = DateTime(2026, 10, 3, 9);

/// The chip of [tab] in the tab bar, and its close button.
Finder _chip(WorkspaceTab tab) => find.byKey(Key('tab-${tab.tabId}'));
Finder _chipClose(WorkspaceTab tab) =>
    find.byKey(Key('tab-close-${tab.tabId}'));
Finder get _todayRow => find.byKey(const Key('days-row-today'));

FakeVaultDb _vault() => FakeVaultDb.v5()
  ..seedNote(id: _planId, title: 'Plan', content: 'old', version: 3)
  ..seedNote(id: _otherId, title: 'Other', content: 'other body', version: 7);

FakeMemexCli _cli(FakeVaultDb db) => FakeMemexCli()
  ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
  ..onUpdateWrites(db)
  ..onAddDailyCreates(db);

extension on WorkspaceHarness {
  TabsNotifier get tabs => read(tabsProvider.notifier);
  EditorStateValue get editor => read(editorControllerProvider);
  List<FakeCliCall> get updates => cli.callsFor('update');
  List<FakeCliCall> get adds => cli.callsFor('add');
}

/// The app on a vault with the notes Plan and Other, both tabs open, on Plan.
Future<WorkspaceHarness> _onPlan(
  WidgetTester tester, {
  List<Override> overrides = const [],
}) async {
  final db = _vault();
  final h = await pumpWorkspace(
    tester,
    db: db,
    cli: _cli(db),
    overrides: overrides,
  );
  await _show(tester, h, _other);
  await _show(tester, h, _plan);
  return h;
}

Future<void> _show(
  WidgetTester tester,
  WorkspaceHarness h,
  WorkspaceTab tab,
) async {
  h.tabs.openOrFocus(tab);
  await pumpFrames(tester);
}

Future<void> _typeBody(WidgetTester tester, String text) =>
    typeSegmentText(tester, find.byKey(editorBodyKey), text);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await tester.tap(finder);
  await pumpFrames(tester);
}

/// The one save sent is note [id]'s [text] on [version], it reached the vault,
/// and the FakeClock has not moved.
void _expectSavedInsideDebounce(
  WorkspaceHarness h,
  String id,
  String text,
  int version,
) {
  expect(h.clock.now(), _launchedAt, reason: 'the clock was not advanced');
  expect(h.updates, hasLength(1), reason: 'exactly one save was sent');
  final call = h.updates.single;
  expect(call.flag('note-id'), id);
  expect(call.flag('expected-version'), '$version');
  expect(call.stdinBody, text);
  final stored = h.db.getNote(id)!;
  expect(stored.contentMd, text);
  expect(stored.version, version + 1);
}

/// The editor shows Other with its stored text, none of what was typed.
void _expectEditorOnOther(WorkspaceHarness h) {
  expect(h.editor.title, 'Other');
  expect(h.editor.contentMd, 'other body');
  expect(h.editor.lastSavedVersion, 7);
}

void main() {
  group('an edit typed before leaving is saved (AC5)', () {
    testWidgets(
      'an edit typed less than the debounce before openOrFocus of another note is saved with its id text and version',
      (tester) async {
        final h = await _onPlan(tester);
        await _typeBody(tester, 'new text');
        expect(h.updates, isEmpty, reason: 'still inside the debounce');

        h.tabs.openOrFocus(_other);
        await pumpFrames(tester);

        _expectSavedInsideDebounce(h, _planId, 'new text', 3);
        _expectEditorOnOther(h);
      },
    );

    testWidgets(
      'an edit typed less than the debounce before a tab chip switch is saved with its id text and version',
      (tester) async {
        final h = await _onPlan(tester);
        await _typeBody(tester, 'new text');
        expect(h.updates, isEmpty, reason: 'still inside the debounce');

        await _tap(tester, _chip(_other));

        _expectSavedInsideDebounce(h, _planId, 'new text', 3);
        _expectEditorOnOther(h);

        // Coming back shows what was typed, on the version the save stored.
        await _tap(tester, _chip(_plan));
        expect(editorBodyText(tester), 'new text');
        expect(h.editor.lastSavedVersion, 4);
        expect(h.updates, hasLength(1));
      },
    );

    testWidgets(
      'an edit typed less than the debounce before closing the active tab with its chip is saved with its id text and version',
      (tester) async {
        final h = await _onPlan(tester);
        await _typeBody(tester, 'new text');
        expect(h.updates, isEmpty, reason: 'still inside the debounce');

        await _tap(tester, _chipClose(_plan));

        _expectSavedInsideDebounce(h, _planId, 'new text', 3);
        expect(h.read(tabsProvider).tabs, isNot(contains(_plan)));
        _expectEditorOnOther(h);

        // Reopened, it holds what was typed.
        await _show(tester, h, _plan);
        expect(editorBodyText(tester), 'new text');
        expect(h.editor.lastSavedVersion, 4);
      },
    );

    testWidgets(
      'an edit typed less than the debounce before closing the last open tab with its chip is saved with its id text and version',
      (tester) async {
        final h = await _onPlan(tester);
        await _tap(tester, _chipClose(_other));
        await _tap(tester, _chipClose(_virtual));
        expect(h.read(tabsProvider).tabs, [_plan]);
        await _typeBody(tester, 'new text');

        await _tap(tester, _chipClose(_plan));

        expect(h.read(tabsProvider).tabs, isEmpty);
        expect(find.byKey(const Key('empty-workspace')), findsOneWidget);
        _expectSavedInsideDebounce(h, _planId, 'new text', 3);
      },
    );

    testWidgets(
      'an edit typed less than the debounce before the Today row is saved with its id text and version',
      (tester) async {
        final h = await _onPlan(tester);
        await _typeBody(tester, 'new text');
        expect(h.updates, isEmpty, reason: 'still inside the debounce');

        await _tap(tester, _todayRow);

        _expectSavedInsideDebounce(h, _planId, 'new text', 3);
        expect(h.read(tabsProvider).activeTab, _virtual);
        expect(h.editor.title, _today);
      },
    );

    testWidgets(
      'an edit typed less than the debounce before leaving a daily note is saved on the daily note',
      (tester) async {
        final db = _vault()
          ..seedDailyNote(_today, id: _dailyId, version: 5)
          ..db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
            assembleDailyBody('Morning pages\n', const []),
            _dailyId,
          ]);
        final h = await pumpWorkspace(tester, db: db, cli: _cli(db));
        expect(h.read(tabsProvider).activeTab, const NoteTab(_dailyId));
        await _show(tester, h, _other);
        await _tap(tester, _chip(const NoteTab(_dailyId)));
        await _typeBody(tester, 'Morning pages\nLunch with Sam.\n');
        expect(h.updates, isEmpty, reason: 'still inside the debounce');

        await _tap(tester, _chip(_other));

        expect(h.clock.now(), _launchedAt);
        expect(h.updates, hasLength(1));
        expect(h.updates.single.flag('note-id'), _dailyId);
        expect(h.updates.single.flag('expected-version'), '5');
        expect(
          splitDailyBody(h.db.getNote(_dailyId)!.contentMd).person.trimRight(),
          'Morning pages\nLunch with Sam.',
        );
        _expectEditorOnOther(h);
      },
    );
  });

  group('the edit is not merely late (AC5)', () {
    testWidgets(
      'an edit typed less than the debounce before a tab chip switch is in the vault once the debounce would have fired',
      (tester) async {
        final h = await _onPlan(tester);
        await _typeBody(tester, 'new text');

        await _tap(tester, _chip(_other));
        h.clock.advance(saveDebounce * 4);
        await pumpFrames(tester);

        expect(h.db.getNote(_planId)!.contentMd, 'new text');
        expect(h.updates, hasLength(1));
        _expectEditorOnOther(h);
      },
    );
  });

  group('rebasing is not leaving (AC4)', () {
    /// Another writer moved the note to [version]: what a footer add does
    /// before the rebase.
    void bumpStored(WorkspaceHarness h, String id, int version) => h.db.db
        .execute('UPDATE notes SET version = ? WHERE id = ?', [version, id]);

    testWidgets(
      'rebaseEditorOnVersion runs onBeforeLeave zero times and sends no extra save',
      (tester) async {
        var leaves = 0;
        final h = await _onPlan(
          tester,
          overrides: [
            // The real wiring, with a count on it.
            tabsProvider.overrideWith((ref) {
              final vaultPath = ref.watch(currentVaultProvider).localPath;
              return TabsNotifier(
                store:
                    ref.watch(uiStateStoreProvider) ??
                    UiStateStore(vaultPath: vaultPath ?? '/dev/null'),
                onPersistedSelection: (id) =>
                    ref.read(selectedNoteIdProvider.notifier).state = id,
                onBeforeLeave: () {
                  leaves++;
                  ref
                      .read(editorControllerProvider.notifier)
                      .flushPendingSave();
                },
              );
            }),
          ],
        );
        await _typeBody(tester, 'new text');
        bumpStored(h, _planId, 4);
        final leavesBefore = leaves;
        final ref = tester.element(find.byType(NoteEditor)) as WidgetRef;

        await rebaseEditorOnVersion(
          ref,
          fallback: h.db.getNote(_planId)!,
          version: 4,
          content: 'new text',
        );
        await pumpFrames(tester);

        expect(leaves, leavesBefore, reason: 'a rebase leaves nothing');
        expect(h.updates, isEmpty, reason: 'a rebase sends no save itself');
        expect(h.editor.lastSavedVersion, 4);

        // The edit it kept goes out once, when its debounce fires, on the
        // rebased version.
        h.clock.advance(saveDebounce);
        await pumpFrames(tester);
        expect(h.updates, hasLength(1));
        expect(h.updates.single.flag('expected-version'), '4');
        expect(h.updates.single.stdinBody, 'new text');

        // Control: the same count sees a real leave.
        h.tabs.openOrFocus(_other);
        expect(leaves, leavesBefore + 1);
      },
    );

    testWidgets(
      'an edit kept by rebaseEditorOnVersion and then left inside the debounce is saved once on the rebased version',
      (tester) async {
        final h = await _onPlan(tester);
        await _typeBody(tester, 'new text');
        bumpStored(h, _planId, 4);
        final ref = tester.element(find.byType(NoteEditor)) as WidgetRef;

        await rebaseEditorOnVersion(
          ref,
          fallback: h.db.getNote(_planId)!,
          version: 4,
          content: 'new text',
        );
        await pumpFrames(tester);
        expect(h.updates, isEmpty, reason: 'a rebase sends no save itself');

        await _tap(tester, _chip(_other));

        _expectSavedInsideDebounce(h, _planId, 'new text', 4);
      },
    );
  });

  group('leaving the virtual Today note through the app (AC6)', () {
    testWidgets(
      'a chip switch away from the virtual Today note with an edit pending sends one create as it leaves and none after',
      (tester) async {
        final db = _vault();
        final h = await pumpWorkspace(tester, db: db, cli: _cli(db));
        await _show(tester, h, _other);
        await _tap(tester, _chip(_virtual));
        await _typeBody(tester, 'Morning pages');
        expect(h.adds, isEmpty, reason: 'still inside the debounce');

        await tester.tap(_chip(_other));
        await tester.idle();
        expect(
          h.adds,
          hasLength(1),
          reason: 'the leave itself sent the create',
        );
        await pumpFrames(tester);

        h.clock.advance(saveDebounce);
        await pumpFrames(tester);
        h.clock.advance(saveDebounce);
        await pumpFrames(tester);

        expect(h.adds, hasLength(1));
        expect(h.adds.single.stdinBody, 'Morning pages');
        expect(
          splitDailyBody(
            h.db.getNote(createdDailyId)!.contentMd,
          ).person.trimRight(),
          'Morning pages',
        );
        expect(h.read(tabsProvider).activeTab, _other);
        _expectEditorOnOther(h);
      },
    );
  });

  group('no pending edit, no save through the app (AC7)', () {
    testWidgets(
      'a note with no pending edit sends no save through the chips and the Today row and an edit left after them sends one',
      (tester) async {
        final h = await _onPlan(tester);

        await _tap(tester, _chip(_other));
        await _tap(tester, _chip(_plan));
        await _tap(tester, _todayRow);
        // #271 TEST-CHANGE: the Today row navigates the Plan tab to today now,
        // so Plan is opened again in a tab of its own.
        await _show(tester, h, _plan);
        await _tap(tester, _chipClose(_plan));
        await _show(tester, h, _plan);
        h.clock.advance(saveDebounce);
        await pumpFrames(tester);
        expect(h.updates, isEmpty);
        expect(h.adds, isEmpty);

        await _typeBody(tester, 'new text');
        await _tap(tester, _chip(_other));

        expect(h.updates, hasLength(1), reason: 'control');
        expect(h.updates.single.flag('note-id'), _planId);
      },
    );
  });
}
