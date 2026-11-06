// WI #261 (F9) verify: contracts of the Comment and Feedback rows that the red
// tests left unpinned (malformed Corrections, the refusal message, a double
// Save, failed edit and delete, an empty reply, the Vault Guide merge order).
// Same harness as feedback_rows_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';

import '../support/comment_activity_harness.dart';
import '../support/fake_vault_db.dart';
import '../support/feedback_seeds.dart';

void _seedOpenComment(FakeVaultDb db, String id, String text) =>
    db.seedFeedback(
      id,
      noteId: commentNoteId,
      day: olderEntryDay,
      agentChangeId: olderEntryId,
      text: text,
      createdAt: 1000,
    );

void _expectNoActions(ActivityRig r, String id) {
  expect(r.key('feedback-edit-$id'), findsNothing);
  expect(r.key('feedback-delete-$id'), findsNothing);
}

String _long(int n) => List.filled(n, 'a').join();

void main() {
  testWidgets(
    'a Correction whose stored change cannot be decoded renders nothing at all',
    (tester) async {
      final db = seedCommentVault();
      db.seedFeedback(
        'fb-unknown',
        kind: 'correction',
        noteId: commentNoteId,
        day: newerEntryDay,
        agentChangeId: newerEntryId,
        text: 'unknown kind why',
        correctionJson: '{"kind":"mystery","detail":"x"}',
        createdAt: 3000,
      );
      db.seedFeedback(
        'fb-garbled',
        kind: 'correction',
        noteId: commentNoteId,
        text: 'garbled why',
        correctionJson: 'not json at all',
        status: 'handled',
        reply: 'garbled reply',
        createdAt: 2500,
      );
      _seedOpenComment(db, 'fb-ok', 'a normal comment');
      final r = await pumpActivityRig(tester, db: db);

      expect(r.rowText('fb-ok'), contains('You: a normal comment'));
      for (final id in ['fb-unknown', 'fb-garbled']) {
        expect(r.key('feedback-$id'), findsNothing);
        expect(r.key('feedback-status-$id'), findsNothing);
        _expectNoActions(r, id);
      }
      expect(find.textContaining('unknown kind why'), findsNothing);
      expect(find.textContaining('garbled why'), findsNothing);
      expect(find.textContaining('garbled reply'), findsNothing);
      expect(find.textContaining('You made a change'), findsNothing);
    },
  );

  testWidgets(
    'a refused Save shows an inline error that Dismiss clears and a later valid Save sends the text',
    (tester) async {
      final r = await pumpActivityRig(tester);

      await r.openComment(olderEntryId);
      expect(r.key('inline-error'), findsNothing);
      await r.save();
      expect(r.key('inline-error'), findsOneWidget);
      expect(find.textContaining('write a comment first'), findsOneWidget);

      await r.type(_long(2001));
      await r.save();
      expect(r.key('inline-error'), findsOneWidget);
      expect(find.textContaining('at most 2000'), findsOneWidget);

      await r.tap('inline-error-dismiss');
      expect(r.key('inline-error'), findsNothing);
      expect(r.calls('addComment'), isEmpty);

      await r.type('now it is fine');
      await r.save();
      expect(r.calls('addComment'), hasLength(1));
      expect(r.key('inline-error'), findsNothing);
    },
  );

  testWidgets('a second Save while the first is in flight sends one comment', (
    tester,
  ) async {
    final r = await pumpActivityRig(tester);
    r.feedback.gate('addComment');

    await r.openComment(olderEntryId);
    await r.type('only once please');
    await r.tap('comment-save');
    await r.tap('comment-save');
    expect(r.calls('addComment'), hasLength(1));

    r.feedback.gates['addComment']!.single.complete();
    r.feedback.ungate('addComment');
    await r.settle();

    expect(r.calls('addComment'), hasLength(1));
    expect(r.field, findsNothing);
    expect(r.key('feedback-fb-new-1'), findsOneWidget);
  });

  testWidgets(
    'a failed edit that is not feedback_handled keeps the input open with the typed text',
    (tester) async {
      final db = seedCommentVault();
      _seedOpenComment(db, 'fb-open', 'coyote time is game feel');
      final r = await pumpActivityRig(tester, db: db);
      r.feedback.failNext('editComment', MemexException('edit failed: boom'));

      await r.tap('feedback-edit-fb-open');
      await r.type('my longer thought');
      await r.save();

      expect(r.calls('editComment'), hasLength(1));
      expect(r.key('inline-error'), findsOneWidget);
      expect(find.textContaining('boom'), findsOneWidget);
      expect(r.field, findsOneWidget);
      expect(r.fieldText(), 'my longer thought');
      expect(r.status('fb-open'), 'Open');
    },
  );

  testWidgets(
    'a failed Delete shows an inline error on the row and keeps the comment and its actions',
    (tester) async {
      final db = seedCommentVault();
      _seedOpenComment(db, 'fb-open', 'coyote time is game feel');
      final r = await pumpActivityRig(tester, db: db);
      r.feedback.failNext(
        'deleteComment',
        MemexException('delete failed: boom'),
      );

      await r.tap('feedback-delete-fb-open');

      expect(r.calls('deleteComment'), hasLength(1));
      expect(
        find.descendant(
          of: r.key('feedback-fb-open'),
          matching: r.key('inline-error'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('boom'), findsOneWidget);
      expect(r.rowText('fb-open'), contains('You: coyote time is game feel'));
      expect(r.key('feedback-edit-fb-open'), findsOneWidget);
      expect(r.key('feedback-delete-fb-open'), findsOneWidget);

      await r.tap('inline-error-dismiss');
      expect(r.key('inline-error'), findsNothing);
    },
  );

  testWidgets(
    'an unreachable vault server shows the snackbar on Delete and keeps the comment',
    (tester) async {
      final db = seedCommentVault();
      _seedOpenComment(db, 'fb-open', 'coyote time is game feel');
      final r = await pumpActivityRig(tester, db: db);
      r.feedback.failNext(
        'deleteComment',
        const VaultUnreachableException(
          serverName: 'nas',
          mayHaveCommitted: false,
        ),
      );

      await r.tap('feedback-delete-fb-open');

      expect(find.text("couldn't reach nas. try again."), findsOneWidget);
      expect(r.rowText('fb-open'), contains('coyote time is game feel'));
    },
  );

  testWidgets(
    'a Handled row with no reply or an empty reply shows just Handled',
    (tester) async {
      final db = seedCommentVault();
      db.seedFeedback(
        'fb-nil',
        noteId: commentNoteId,
        agentChangeId: olderEntryId,
        text: 'handled quietly',
        status: 'handled',
        createdAt: 1100,
      );
      db.seedFeedback(
        'fb-empty',
        noteId: commentNoteId,
        agentChangeId: olderEntryId,
        text: 'handled with nothing to say',
        status: 'handled',
        reply: '',
        createdAt: 1200,
      );
      final r = await pumpActivityRig(tester, db: db);

      expect(r.status('fb-nil'), 'Handled');
      expect(r.status('fb-empty'), 'Handled');
      _expectNoActions(r, 'fb-nil');
      _expectNoActions(r, 'fb-empty');
    },
  );

  testWidgets(
    'a comment never shows a Why label and a Correction with an empty Why note shows none',
    (tester) async {
      final db = seedCommentVault();
      _seedOpenComment(db, 'fb-open', 'plain words');
      db.seedFeedback(
        'fb-corr',
        kind: 'correction',
        noteId: commentNoteId,
        day: newerEntryDay,
        agentChangeId: newerEntryId,
        text: '',
        correction: correctionSamples['folder_moved'],
        createdAt: 2000,
      );
      final r = await pumpActivityRig(tester, db: db);

      expect(r.rowText('fb-open'), isNot(contains('Why')));
      expect(r.rowText('fb-corr'), contains('You moved Design'));
      expect(r.rowText('fb-corr'), isNot(contains('Why')));
    },
  );

  testWidgets(
    'on the Vault Guide tab own and no-note Feedback above the entries interleave newest first',
    (tester) async {
      final db = seedCommentVault();
      db.seedNote(id: 'guide-1', title: 'Vault Guide', role: 'guide');
      db.seedFeedback(
        'fb-own-new',
        noteId: 'guide-1',
        text: 'own newest',
        createdAt: 4000,
      );
      db.seedFeedback(
        'fb-loose-new',
        kind: 'correction',
        correction: correctionSamples['folder_deleted'],
        createdAt: 3000,
      );
      db.seedFeedback(
        'fb-own-old',
        noteId: 'guide-1',
        text: 'own older',
        createdAt: 2000,
      );
      db.seedFeedback(
        'fb-loose-old',
        kind: 'correction',
        correction: correctionSamples['folder_moved'],
        createdAt: 1000,
      );
      final r = await pumpActivityRig(tester, db: db, noteId: 'guide-1');

      final tops = [
        for (final id in [
          'fb-own-new',
          'fb-loose-new',
          'fb-own-old',
          'fb-loose-old',
        ])
          r.top('feedback-$id'),
      ];
      expect(tops, orderedEquals([...tops]..sort()));
      expect(tops.toSet(), hasLength(4));
    },
  );

  testWidgets(
    'on the Vault Guide tab Feedback stamped at the same time shows the notes own row first',
    (tester) async {
      final db = seedCommentVault();
      db.seedNote(id: 'guide-1', title: 'Vault Guide', role: 'guide');
      db.seedFeedback(
        'fb-loose',
        kind: 'correction',
        correction: correctionSamples['folder_deleted'],
        createdAt: 2000,
      );
      db.seedFeedback(
        'fb-own',
        noteId: 'guide-1',
        text: 'own at the same moment',
        createdAt: 2000,
      );
      final r = await pumpActivityRig(tester, db: db, noteId: 'guide-1');

      expect(r.top('feedback-fb-own'), lessThan(r.top('feedback-fb-loose')));
    },
  );
}
