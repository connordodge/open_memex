// WI #260 (F8), verify round r1: which parts of the Activity tab show beside
// the Filed section (the agent header block follows the entries and the
// Feedback homes, the empty state needs all three to be absent).
// Test names use no apostrophes.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';
import '../support/feedback_seeds.dart';
import '../support/segment_editing_finder.dart';
import '../support/filed_section_fakes.dart';

const _eyebrow = 'AGENT ACTIVITY · THIS NOTE';

void main() {
  group('a fix that leaves the daily note version alone', () {
    testWidgets('does not restart the save timer of a pending edit', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      f.server.chipBumpsDaily = false;
      await tester.enterText(find.byKey(editorBodyKey), 'pending thought');
      await tester.pump();
      f.h.clock.advance(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(f.cli.callsFor('update'), isEmpty);

      await f260MoveTo(
        tester,
        from: f260Loop,
        block: f260B1,
        target: f260Economy,
      );
      expect(f.moves, hasLength(1));
      expect(f.cli.callsFor('update'), isEmpty);

      // 550 ms after the edit: the original 500 ms timer fires. A rebase
      // would have restarted it at 300 ms.
      f.h.clock.advance(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));
      await pumpFrames(tester);
      expect(f.cli.callsFor('update'), hasLength(1));
    });
  });

  group('the Filed section with the rest of the Activity tab', () {
    testWidgets(
      'entries and no Feedback rows show the agent header under the section',
      (tester) async {
        await pumpF260(tester);

        expect(find.byKey(f260Section), findsOneWidget);
        expect(find.text(_eyebrow), findsOneWidget);
        expect(find.byKey(const Key('activity-entry-ac-1')), findsOneWidget);
        expect(
          tester.getTopLeft(find.byKey(f260Section)).dy,
          lessThan(tester.getTopLeft(find.text(_eyebrow)).dy),
        );
      },
    );

    testWidgets(
      'no entries and no Feedback rows show the section without the agent header',
      (tester) async {
        await pumpF260(tester, db: f260Db(agentEntry: false));

        expect(find.byKey(f260Section), findsOneWidget);
        expect(find.text(_eyebrow), findsNothing);
        expect(find.byKey(const Key('activity-entry-ac-1')), findsNothing);
      },
    );

    testWidgets(
      'a Feedback row on a day with no entries shows the agent header under the section',
      (tester) async {
        final db = f260Db(agentEntry: false);
        db.seedFeedback(
          'fb-day',
          noteId: f260DailyId,
          day: f260Date,
          text: 'A day level thought',
        );
        await pumpF260(tester, db: db);

        final feedback = find.byKey(const Key('feedback-fb-day'));
        expect(find.byKey(f260Section), findsOneWidget);
        expect(feedback, findsOneWidget);
        expect(find.text(_eyebrow), findsOneWidget);
        expect(
          tester.getTopLeft(find.byKey(f260Section)).dy,
          lessThan(tester.getTopLeft(feedback).dy),
        );
      },
    );

    testWidgets(
      'a Feedback row on a day with nothing filed shows the tab without the section',
      (tester) async {
        final db = f260Db(agentEntry: false, reviewedRow: false);
        db.seedFeedback(
          'fb-day',
          noteId: f260DailyId,
          day: f260Date,
          text: 'A day level thought',
        );
        await pumpF260(
          tester,
          db: db,
          server: f260DefaultServer(db)..reviewed = false,
        );

        expect(find.byKey(f260Section), findsNothing);
        expect(find.byKey(const Key('feedback-fb-day')), findsOneWidget);
        expect(find.text(_eyebrow), findsOneWidget);
      },
    );
  });
}
