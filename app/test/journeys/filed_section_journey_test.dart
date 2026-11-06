// WI #260 (F8) robot-style journeys: open a reviewed day, open its Activity
// tab from the Reviewed chip, fix where a block is filed.
//
// No domain doubles: FakeMemexCli plays `memex` over an F260Server and a
// FakeVaultDb, and the app reads the result back through VaultAccess.
//
// Lead ruling: Open Correction rows are rendered by F9 (#261), which this WI
// does not depend on. Here the journey asserts the vault holds the open
// ExcerptMovedCorrection with the Why? text after the section re-reads; F9
// AC 6 pins how the row looks.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/feedback_reads.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';

import '../support/app_harness.dart';
import '../support/filed_section_fakes.dart';
import '../support/footer_cli_fakes.dart';
import '../support/review_fakes.dart' show openNoteTab;

Finder _chipLabel(String text) => find.descendant(
  of: find.byKey(const Key('review-chip')),
  matching: find.text(text),
);

void main() {
  testWidgets(
    'open a reviewed day and its Activity tab then Move to with a Why and the row moves and an Open Correction is recorded',
    (tester) async {
      final db = f260Db();
      final server = f260DefaultServer(db);
      final cli = f260Cli(db, server);
      final h = await pumpWorkspace(tester, db: db, cli: cli);
      await openNoteTab(tester, h, f260DailyId);
      expect(_chipLabel('Reviewed'), findsOneWidget);
      expect(find.byKey(f260Section), findsNothing, reason: 'tab not open yet');

      // The review chip opens the Activity tab (the existing way).
      await f260OpenFromChip(tester);
      expect(find.byKey(f260Section), findsOneWidget);
      expect(find.byKey(f260Row(f260Loop, f260B1)), findsOneWidget);

      await f260Tap(tester, f260Move(f260Loop, f260B1));
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

      // An Open Correction exists with the Why? text (F9 renders it).
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

  testWidgets(
    'open a reviewed day and File in a Not filed block under a topic created on the spot',
    (tester) async {
      final db = f260Db();
      final server = f260DefaultServer(db);
      final cli = f260Cli(db, server);
      final h = await pumpWorkspace(tester, db: db, cli: cli);
      await openNoteTab(tester, h, f260DailyId);
      await f260OpenFromChip(tester);

      await f260Tap(tester, f260FileIn(f260N1));
      await f260TypeTopic(tester, 'Errands');
      await f260Tap(tester, f260Create);
      await f260Tap(tester, f260Confirm);

      expect(cli.callsFor('add').single.flag('role'), 'topic');
      final file = cli.callsFor('excerpt add').single;
      expect(file.flag('topic-note-id'), createdTopicId);
      expect(file.flag('block-id'), f260N1);
      expect(file.hasFlag('note'), isFalse);
      expect(find.byKey(f260NotFiledRow(f260N1)), findsNothing);
      expect(find.byKey(f260Row(createdTopicId, f260N1)), findsOneWidget);
      expect(find.byKey(f260Section), findsOneWidget);
      expect(_chipLabel('Reviewed'), findsOneWidget);
    },
  );
}
