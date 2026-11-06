// WI #269 (N6, Spec #232 R1, R2, R7): an excerpt card's day link goes through
// the navigation seam. A plain click navigates the current tab; a Cmd+click
// focuses or opens a tab. The lookup waits on a gate of Completers, and both
// the tab and the Cmd state are read at the click, before the lookup.
//
// Click tests assert `TabsRecorder.followed` (the seam), then the tab state it
// leaves. The card's rows have no `LinkRegion`: `card_rows_test.dart` and
// `card_table_test.dart` pin that.
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';
import '../support/editor_access_doubles.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/recording_tabs.dart';

/// Text segment 0, card 1 (the C4 range token), text segment 2.
const _card = 1;

/// Everything a card test needs after [_launch].
class _Card {
  _Card(this.r, this.tabs, this.doubles);

  final SegmentedEditorRobot r;
  final TabsRecorder tabs;
  final EditorVaultDoubles doubles;

  WorkspaceHarness get h => r.h;
  WidgetTester get tester => r.tester;

  List<WorkspaceTab> get open => h.read(tabsProvider).tabs;
  WorkspaceTab? get active => h.read(tabsProvider).activeTab;

  /// The middle of the card's day link.
  Offset get caption => tester.getCenter(r.cardCaption(_card));
}

/// Pumps the workspace on [seedSegmentedVault] with a gated daily domain and
/// opens the topic note [body] (by default text, a card, text). Nothing has been
/// recorded yet when it returns.
Future<_Card> _launch(
  WidgetTester tester, {
  String body = fixtureTopicBody,
}) async {
  final vault = seedSegmentedVault(topicBody: body);
  final tabs = TabsRecorder();
  final doubles = EditorVaultDoubles(
    notesDb: vault.db,
    dailyDb: vault.db,
    cli: vault.cli,
  );
  final h = await pumpWorkspace(
    tester,
    db: vault.db,
    cli: vault.cli,
    overrides: [tabs.override, editorSingleVaultOverride(doubles)],
  );
  final r = SegmentedEditorRobot(tester, h);
  await r.open(fixtureTopicId);
  await pumpFrames(tester);
  expect(r.card(_card), findsOneWidget);
  tabs.followed.clear();
  tabs.navigated.clear();
  return _Card(r, tabs, doubles);
}

void main() {
  holdFontFetches();

  group('plain click', () {
    testWidgets(
      'a plain click on an excerpt card day link navigates to that daily note',
      (tester) async {
        final t = await _launch(tester);
        final before = t.open.length;

        await tester.tapAt(t.caption, kind: PointerDeviceKind.mouse);
        await pumpFrames(tester);

        expect(t.tabs.followed, [const NoteTab(fixtureDailyId)]);
        expect(t.tabs.navigated, [const NoteTab(fixtureDailyId)]);
        t.r.expectActiveNote(fixtureDailyId);
        expect(t.open.length, before, reason: 'the current tab navigated');
        expect(t.h.read(tabsProvider).canGoBack, isTrue);
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain click on an excerpt card day link with another tab showing that daily note stays in the current tab',
      (tester) async {
        final t = await _launch(tester);
        await t.r.open(fixtureDailyId);
        await t.r.open(fixtureTopicId);
        t.tabs.followed.clear();
        t.tabs.navigated.clear();
        final before = t.open.length;

        await tester.tapAt(t.caption, kind: PointerDeviceKind.mouse);
        await pumpFrames(tester);

        expect(t.tabs.navigated, [const NoteTab(fixtureDailyId)]);
        t.r.expectActiveNote(fixtureDailyId);
        expect(t.open.length, before);
        expect(
          t.open.where((tab) => tab == const NoteTab(fixtureDailyId)),
          hasLength(2),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain click on an excerpt card day link with no daily note for its date does nothing',
      (tester) async {
        final t = await _launch(
          tester,
          body: 'Intro line\n![[2026-09-09#^ab12]]\nOutro line\n',
        );
        final before = List.of(t.open);

        await tester.tapAt(t.caption, kind: PointerDeviceKind.mouse);
        await pumpFrames(tester);

        expect(
          t.doubles.daily.reads,
          contains('dailyNoteForDate:2026-09-09'),
          reason: 'it looked',
        );
        expect(t.tabs.followed, isEmpty);
        expect(t.open, before);
        t.r.expectActiveNote(fixtureTopicId);
      },
      variant: macOnly,
    );
  });

  group('Cmd click', () {
    testWidgets(
      'a Cmd click on an excerpt card day link follows it and opens a new tab',
      (tester) async {
        final t = await _launch(tester);
        final before = t.open.length;

        await tester.macCmdClick(t.caption);
        await pumpFrames(tester);

        expect(t.tabs.followed, [const NoteTab(fixtureDailyId)]);
        expect(t.tabs.navigated, isEmpty);
        t.r.expectActiveNote(fixtureDailyId);
        expect(t.open.length, before + 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'a Cmd click on an excerpt card day link follows it and focuses the tab already showing it',
      (tester) async {
        final t = await _launch(tester);
        await t.r.open(fixtureDailyId);
        await t.r.open(fixtureTopicId);
        t.tabs.followed.clear();
        t.tabs.navigated.clear();
        final before = t.open.length;

        await tester.macCmdClick(t.caption);
        await pumpFrames(tester);

        expect(t.tabs.followed, [const NoteTab(fixtureDailyId)]);
        expect(t.tabs.navigated, isEmpty);
        t.r.expectActiveNote(fixtureDailyId);
        expect(t.open.length, before);
      },
      variant: macOnly,
    );
  });

  group('a lookup that lands late', () {
    for (final (name, cmd, close) in [
      (
        'a plain click on an excerpt card day link is dropped when its tab navigated during the lookup',
        false,
        false,
      ),
      (
        'a plain click on an excerpt card day link is dropped when its tab closed during the lookup',
        false,
        true,
      ),
      (
        'a Cmd click on an excerpt card day link still opens its tab when the tab navigated during the lookup',
        true,
        false,
      ),
      (
        'a Cmd click on an excerpt card day link still opens its tab when the tab closed during the lookup',
        true,
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final t = await _launch(tester);
        final notifier = t.h.read(tabsProvider.notifier);
        final daily = t.doubles.daily;
        final at = t.caption;

        daily.gate.hold();
        await tester.macClick(at, cmd: cmd);
        expect(daily.reads, contains('dailyNoteForDate:2026-09-05'));
        expect(t.tabs.followed, isEmpty, reason: 'the lookup is still out');

        if (close) {
          notifier.close(const NoteTab(fixtureTopicId));
        } else {
          notifier.navigate(const NoteTab(fixtureZetaId));
        }
        await tester.pump();
        final openAfter = List.of(t.open);
        final activeAfter = t.active;

        daily.gate.release();
        await pumpFrames(tester);

        expect(t.tabs.followed, [const NoteTab(fixtureDailyId)]);
        if (cmd) {
          t.r.expectActiveNote(fixtureDailyId);
          expect(t.open.length, openAfter.length + 1);
        } else {
          expect(t.open, openAfter);
          expect(t.active, activeAfter);
        }
      }, variant: macOnly);
    }

    testWidgets(
      'a plain click on an excerpt card day link stays plain when Cmd goes down during the lookup',
      (tester) async {
        final t = await _launch(tester);
        final daily = t.doubles.daily;
        final before = t.open.length;

        daily.gate.hold();
        await tester.tapAt(t.caption, kind: PointerDeviceKind.mouse);
        await tester.pump();
        await tester.macHolding([LogicalKeyboardKey.metaLeft], () async {
          daily.gate.release();
          await pumpFrames(tester);
        });

        t.r.expectActiveNote(fixtureDailyId);
        expect(t.open.length, before, reason: 'navigated, no new tab');
      },
      variant: macOnly,
    );
  });
}
