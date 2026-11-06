// WI #260 (F8), fix round r1: the D23 rebase of a fix that finishes after the
// section is gone, and the Filed section next to the Feedback rows of F9.
// Test names use no apostrophes.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';

import '../support/app_harness.dart';
import '../support/feedback_seeds.dart';
import '../support/filed_section_fakes.dart';
import '../support/segment_editing_finder.dart';

void main() {
  group('a fix that finishes after the section unmounted (D23)', () {
    testWidgets(
      'the pending edit is rebased and its next save has no conflict',
      (tester) async {
        final f = await pumpF260(tester);
        await tester.enterText(find.byKey(editorBodyKey), 'pending thought');
        await tester.pump();
        f.feedback.gate('moveBlock');

        await f260Tap(tester, f260Move(f260Loop, f260B1));
        await f260Tap(tester, f260Option(f260Sleep));
        await f260Tap(tester, f260Confirm);
        expect(f.moves, hasLength(1));

        f.h.container.read(rightPanelTabProvider.notifier).state =
            RightPanelTab.connections;
        await pumpFrames(tester);
        expect(find.byKey(f260Section), findsNothing);

        f.feedback.gates['moveBlock']!.single.complete();
        await pumpFrames(tester);

        final editor = f.h.read(editorControllerProvider);
        expect(editor.lastSavedVersion, 2, reason: 'the chip add version');
        expect(editor.contentMd, 'pending thought');
        expect(editor.status, SaveStatus.dirty);
        expect(find.text('conflict — reload'), findsNothing);

        f.h.clock.advance(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 600));
        await pumpFrames(tester);
        final update = f.cli.callsFor('update').single;
        expect(update.flag('expected-version'), '2');
        expect(update.stdinBody, 'pending thought');
        expect(f.h.read(editorControllerProvider).status, SaveStatus.clean);
        expect(find.text('conflict — reload'), findsNothing);
      },
    );
  });

  group('the Filed section with the Feedback rows (F8 with F9)', () {
    testWidgets(
      'a comment on the day shows under the section, which stays usable',
      (tester) async {
        final db = f260Db();
        db.seedFeedback(
          'fb-1',
          noteId: f260DailyId,
          day: f260Date,
          agentChangeId: 'ac-1',
          text: 'Looks right to me',
        );
        final f = await pumpF260(tester, db: db);

        final entry = find.byKey(const Key('activity-entry-ac-1'));
        expect(find.byKey(f260Section), findsOneWidget);
        expect(find.byKey(const Key('feedback-fb-1')), findsOneWidget);
        expect(entry, findsOneWidget);
        expect(find.byKey(const Key('activity-comment-ac-1')), findsOneWidget);
        expect(
          tester.getTopLeft(find.byKey(f260Section)).dy,
          lessThan(tester.getTopLeft(entry).dy),
        );

        await f260MoveTo(
          tester,
          from: f260Loop,
          block: f260B1,
          target: f260Economy,
        );
        expect(f.moves, hasLength(1));
        expect(find.byKey(f260Row(f260Economy, f260B1)), findsOneWidget);
        expect(find.byKey(const Key('feedback-fb-1')), findsOneWidget);
      },
    );
  });
}
