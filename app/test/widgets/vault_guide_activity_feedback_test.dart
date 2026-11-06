// WI #262 (F10) x WI #261 (F9): the Vault Guide's Activity tab carries both
// features at once. F9: the no-note Feedback above the entries and the
// Comment action under every entry. F10: Restore on an entry that a guide
// revision names. Neither feature's own tests had both on one tab, so a merge
// that kept only one of them would have passed both suites.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';
import '../support/feedback_seeds.dart';
import '../support/review_fakes.dart';
import '../support/vault_guide_fixture.dart';

Finder _key(String k) => find.byKey(Key(k));
double _top(WidgetTester tester, String k) {
  expect(_key(k), findsOneWidget, reason: k);
  return tester.getTopLeft(_key(k)).dy;
}

/// A guide Activity tab: ac-2 (older, no revision), ac-1 (newer, rev-1),
/// a no-note Feedback row, and a comment hanging on ac-2.
Future<GuideEnv> _openTab(WidgetTester tester) async {
  final db = guideDb()..seedGuideActivity();
  db
    ..seedFeedback(
      'fb-loose',
      text: 'the guide misses the daily note rule',
      createdAt: 5000,
    )
    ..seedFeedback(
      'fb-on-entry',
      noteId: guideNoteId,
      day: '2026-10-01',
      agentChangeId: 'ac-2',
      text: 'this read was useful',
      createdAt: 4000,
    );
  final env = await launchGuideWorkspace(tester, db: db, topicsMode: false);
  await openNoteTab(tester, env.h, guideNoteId);
  await showActivityTab(tester, env.h);
  return env;
}

void main() {
  testWidgets(
    'a guide Activity tab shows the no-note Feedback above the entries and Restore on the entry with a revision',
    (tester) async {
      await _openTab(tester);

      expect(_key('feedback-home-fb-loose'), findsOneWidget);
      expect(_key('guide-restore-ac-1'), findsOneWidget);
      expect(
        _key('guide-restore-ac-2'),
        findsNothing,
        reason: 'ac-2 has no revision',
      );
      expect(_key('activity-empty'), findsNothing);
      // The no-note row sits above the first entry (newest first: ac-1).
      expect(
        _top(tester, 'feedback-home-fb-loose'),
        lessThan(_top(tester, 'activity-entry-ac-1')),
      );
      expect(
        _top(tester, 'activity-entry-ac-1'),
        lessThan(_top(tester, 'activity-entry-ac-2')),
      );
    },
  );

  testWidgets(
    'a guide Activity entry shows its own Feedback and the Comment action beside Restore',
    (tester) async {
      await _openTab(tester);

      // ac-1: Restore and the Comment action, in the same entry.
      for (final k in ['guide-restore-ac-1', 'activity-comment-ac-1']) {
        expect(
          find.descendant(of: _key('activity-entry-ac-1'), matching: _key(k)),
          findsOneWidget,
          reason: '$k belongs to entry ac-1',
        );
      }
      // ac-2: its Feedback row and the Comment action, and no Restore.
      expect(
        find.descendant(
          of: _key('activity-entry-ac-2'),
          matching: _key('feedback-fb-on-entry'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _key('activity-entry-ac-2'),
          matching: _key('activity-comment-ac-2'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _key('activity-entry-ac-2'),
          matching: _key('guide-restore-ac-2'),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Restore on a guide tab that also shows Feedback restores once and keeps the Feedback rows',
    (tester) async {
      final env = await _openTab(tester);

      await tester.tap(_key('guide-restore-ac-1'));
      await pumpFrames(tester);
      await tester.tap(_key('guide-restore-confirm'));
      await pumpFrames(tester);

      final calls = env.feedback.callsTo('restoreGuide');
      expect(calls, hasLength(1));
      expect(calls.single.args['revisionId'], 'rev-1');
      expect(_key('feedback-home-fb-loose'), findsOneWidget);
      expect(_key('feedback-fb-on-entry'), findsOneWidget);
      expect(_key('guide-restore-ac-1'), findsOneWidget);
    },
  );

  testWidgets(
    'a guide with Feedback but no entries lists the Feedback and no Restore and not the empty message',
    (tester) async {
      final db = guideDb()
        ..seedFeedback('fb-loose', text: 'no entries yet', createdAt: 5000);
      final env = await launchGuideWorkspace(tester, db: db, topicsMode: false);
      await openNoteTab(tester, env.h, guideNoteId);
      await showActivityTab(tester, env.h);

      expect(_key('feedback-home-fb-loose'), findsOneWidget);
      expect(_key('activity-empty'), findsNothing);
      expect(find.text('Restore'), findsNothing);
    },
  );

  testWidgets(
    'a guide with no entries and no Feedback shows the empty message',
    (tester) async {
      final db = guideDb();
      final env = await launchGuideWorkspace(tester, db: db, topicsMode: false);
      await openNoteTab(tester, env.h, guideNoteId);
      await showActivityTab(tester, env.h);

      expect(_key('activity-empty'), findsOneWidget);
      expect(find.text('Restore'), findsNothing);
    },
  );
}
