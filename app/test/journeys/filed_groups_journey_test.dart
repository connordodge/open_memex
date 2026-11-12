// WI #399 (F3, Spec #393 Testing Strategy: the journey): a person opens a
// reviewed day and its Activity tab, clicks a topic link and lands on the topic
// note in the active tab, goes Back to the day, then hovers a row and uses
// `Move to…` with a `Why?`. The row moves and the vault holds the open
// Correction with the `Why?` text.
//
// No domain doubles: FakeMemexCli plays `memex` over an F260Server and a
// FakeVaultDb, and the app reads the result back through VaultAccess. Real
// mouse presses throughout. A fix button answers only once its row is hovered
// (WI #398), so the journey hovers the row with a mouse of its own before it
// presses `Move to…`: it holds with or without that reveal. Never
// pumpAndSettle the workspace (OmDot pulses forever): pumpFrames only.
//
// The Correction assertion follows filed_section_journey_test.dart (WI #260):
// Open Correction rows are rendered by WI #261; here the vault holds the open
// ExcerptMovedCorrection with the Why? text after the section re-reads.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/feedback_reads.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';

import '../support/app_harness.dart';
import '../support/filed_section_fakes.dart';
import '../support/font_fetch_hold.dart';
import '../support/review_fakes.dart' show openNoteTab;

Finder _chipLabel(String text) => find.descendant(
  of: find.byKey(const Key('review-chip')),
  matching: find.text(text),
);

Finder _topicLink(String topic) => find.byKey(Key('filed-topic-link-$topic'));

/// Hovers the row [row] with a mouse of its own, then taps [key] inside it.
Future<void> _hoverRowThenTap(WidgetTester tester, Key row, Key key) async {
  expect(find.byKey(row), findsOneWidget, reason: '$row');
  final mouse = TestGesture(
    dispatcher: tester.sendEventToBinding,
    pointer: 0x7fff0399,
    device: 0x7fff0399,
    kind: PointerDeviceKind.mouse,
  );
  await mouse.addPointer(location: tester.getCenter(find.byKey(row)));
  await tester.pump();
  expect(find.byKey(key), findsOneWidget, reason: '$key');
  await tester.tap(find.byKey(key));
  await mouse.removePointer();
  await pumpFrames(tester);
}

void main() {
  holdFontFetches();

  testWidgets(
    'open a reviewed day and Activity then click a topic link and go Back then hover a row and Move it with a Why and the vault holds the open Correction',
    (tester) async {
      final db = f260Db();
      final server = f260DefaultServer(db);
      final cli = f260Cli(db, server);
      final h = await pumpWorkspace(tester, db: db, cli: cli);
      await openNoteTab(tester, h, f260DailyId);
      expect(_chipLabel('Reviewed'), findsOneWidget);

      // The review chip opens the Activity tab (the existing way).
      await f260OpenFromChip(tester);
      expect(find.byKey(f260Section), findsOneWidget);
      final tabsBefore = h.read(tabsProvider).tabs;

      // A click on a topic link opens the topic note in the active tab.
      expect(_topicLink(f260Loop), findsOneWidget);
      await tester.tap(_topicLink(f260Loop));
      await pumpFrames(tester);
      var tabs = h.read(tabsProvider);
      expect(tabs.activeTab, const NoteTab(f260Loop));
      expect(tabs.tabs, hasLength(tabsBefore.length), reason: 'in place');
      expect(tabs.canGoBack, isTrue);

      // Back, as the app does it: the toolbar button. The day is active again
      // and its Activity tab shows the section.
      expect(find.byKey(const Key('nav-back-button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('nav-back-button')));
      await pumpFrames(tester);
      tabs = h.read(tabsProvider);
      expect(tabs.activeTab, const NoteTab(f260DailyId));
      expect(
        tabs.tabs,
        hasLength(tabsBefore.length),
        reason: 'Back adds no tab',
      );
      expect(find.byKey(f260Section), findsOneWidget);
      expect(find.byKey(f260Row(f260Loop, f260B1)), findsOneWidget);

      // Hover the row and press Move to…: the dialog names the block and the
      // topic it is filed in.
      await _hoverRowThenTap(
        tester,
        f260Row(f260Loop, f260B1),
        f260Move(f260Loop, f260B1),
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('“$f260B1Text” from Player Loop'),
        ),
        findsOneWidget,
        reason: 'the dialog shows the block it moves and its topic',
      );
      await f260TypeTopic(tester, 'econ');
      expect(find.byKey(f260Option(f260Economy)), findsOneWidget);
      await f260Tap(tester, f260Option(f260Economy));
      await f260TypeWhy(tester, 'this is about pricing');
      await f260Tap(tester, f260Confirm);

      // The row moved after the re-read, and nothing else did.
      expect(find.byKey(f260Row(f260Loop, f260B1)), findsNothing);
      expect(find.byKey(f260Row(f260Economy, f260B1)), findsOneWidget);
      expect(find.byKey(f260Row(f260Loop, f260B2)), findsOneWidget);
      expect(find.byKey(f260Row(f260Economy, f260B3)), findsOneWidget);
      final move = cli.callsFor('excerpt move').single;
      expect(move.flag('from-topic-note-id'), f260Loop);
      expect(move.flag('to-topic-note-id'), f260Economy);
      expect(move.flag('block-id'), f260B1);
      expect(move.flag('date'), f260Date);
      expect(move.flag('note'), 'this is about pricing');

      // An Open Correction exists with the Why? text.
      final feedback = await h
          .read(vaultAccessProvider)!
          .feedback
          .feedbackForNote(f260DailyId);
      final open = feedback.where(
        (r) =>
            r.status == FeedbackStatus.open &&
            r.correction is ExcerptMovedCorrection,
      );
      expect(open, hasLength(1));
      final correction = open.single.correction! as ExcerptMovedCorrection;
      expect(open.single.text, 'this is about pricing');
      expect(correction.date, f260Date);
      expect(correction.blockId, f260B1);
      expect(correction.fromTopicNoteId, f260Loop);
      expect(correction.toTopicNoteId, f260Economy);
      expect(correction.fromTitle, 'Player Loop');
      expect(correction.toTitle, 'Economy');

      // The fix did not touch the day's review.
      expect(_chipLabel('Reviewed'), findsOneWidget);
      expect(cli.callsFor('update'), isEmpty);
    },
  );
}
