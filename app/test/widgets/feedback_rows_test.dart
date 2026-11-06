// WI #261 (F9): comments, Open and Handled, and the Feedback homes of the
// Activity tab (Spec #233 R17-R23, L13). Every test drives the real workspace
// on the Activity tab: a V6 FakeVaultDb answers the reads, a stateful
// FakeMemexCli plays the vault server for the writes, and a recording
// RecordingFeedbackAccess counts what the app asked the vault to do.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';

import '../support/activity_seeds.dart';
import '../support/comment_activity_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_vault_db.dart';
import '../support/feedback_seeds.dart';
import '../support/topics_launch.dart';

const _empty = Key('activity-empty');

/// A Correction row on the newer entry, with an optional `Why?` note.
void _seedCorrection(
  FakeVaultDb db,
  String id,
  String kind, {
  String? why,
  String status = 'open',
  String? reply,
}) => db.seedFeedback(
  id,
  kind: 'correction',
  noteId: commentNoteId,
  day: newerEntryDay,
  agentChangeId: newerEntryId,
  text: why,
  correction: correctionSamples[kind],
  status: status,
  reply: reply,
  createdAt: 2000,
);

/// An Open comment from the person on the older entry.
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
  group('Comment input (AC1, AC2, AC3)', () {
    testWidgets(
      'Comment on an entry opens the input and Save calls addComment once with the note day and entry id then shows the comment under that entry marked Open',
      (tester) async {
        final r = await pumpActivityRig(tester);
        final counter = RevisionCounter(r.h);

        expect(r.field, findsNothing);
        expect(r.key('activity-comment-$olderEntryId'), findsOneWidget);
        expect(r.key('activity-comment-$newerEntryId'), findsOneWidget);

        await r.openComment(olderEntryId);
        expect(r.key('comment-save'), findsOneWidget);
        expect(r.key('comment-cancel'), findsOneWidget);
        await r.type('coyote time is game feel');
        await r.save();

        final adds = r.calls('addComment');
        expect(adds, hasLength(1));
        expect(adds.single.args, {
          'noteId': commentNoteId,
          'date': olderEntryDay,
          'changeId': olderEntryId,
          'text': 'coyote time is game feel',
        });
        expect(r.field, findsNothing, reason: 'Save closes the input');
        expect(r.key('feedback-fb-new-1'), findsOneWidget);
        expect(
          r.rowText('fb-new-1'),
          contains('You: coyote time is game feel'),
        );
        expect(r.status('fb-new-1'), 'Open');
        // Under the older entry: at or below its top.
        expect(
          r.top('feedback-fb-new-1'),
          greaterThanOrEqualTo(r.top('activity-entry-$olderEntryId')),
        );
        // The write bumped the vault revision once (FeedbackActions owns it).
        expect(counter.bumps, 1);
      },
    );

    testWidgets(
      'Save on the newer entry sends that entry day and id and the comment sits between that entry and the older one',
      (tester) async {
        final r = await pumpActivityRig(tester);

        await r.openComment(newerEntryId);
        await r.type('second thought');
        await r.save();

        final adds = r.calls('addComment');
        expect(adds, hasLength(1));
        expect(adds.single.args['date'], newerEntryDay);
        expect(adds.single.args['changeId'], newerEntryId);
        expect(r.key('feedback-fb-new-1'), findsOneWidget);
        expect(
          r.top('feedback-fb-new-1'),
          greaterThanOrEqualTo(r.top('activity-entry-$newerEntryId')),
        );
        expect(
          r.top('feedback-fb-new-1'),
          lessThan(r.top('activity-entry-$olderEntryId')),
        );
      },
    );

    testWidgets('Save sends the comment text trimmed', (tester) async {
      final r = await pumpActivityRig(tester);

      await r.openComment(olderEntryId);
      await r.type('  padded words \n');
      await r.save();

      expect(r.calls('addComment').single.args['text'], 'padded words');
    });

    testWidgets('Cancel calls nothing and clears the input', (tester) async {
      final r = await pumpActivityRig(tester);

      await r.openComment(olderEntryId);
      await r.type('a draft I give up on');
      await r.cancel();

      expect(r.field, findsNothing);
      expect(r.calls('addComment'), isEmpty);
      expect(r.cli.callsFor('feedback add'), isEmpty);

      await r.openComment(olderEntryId);
      expect(r.fieldText(), isEmpty, reason: 'Cancel discards the draft');
    });

    testWidgets('Save with empty text is refused with no call', (tester) async {
      final r = await pumpActivityRig(tester);

      await r.openComment(olderEntryId);
      await r.save();

      expect(r.calls('addComment'), isEmpty);
      expect(r.cli.callsFor('feedback add'), isEmpty);
      expect(r.field, findsOneWidget, reason: 'the input stays open');
    });

    testWidgets('Save with whitespace only text is refused with no call', (
      tester,
    ) async {
      final r = await pumpActivityRig(tester);

      await r.openComment(olderEntryId);
      await r.type('  \n\t  ');
      await r.save();

      expect(r.calls('addComment'), isEmpty);
      expect(r.cli.callsFor('feedback add'), isEmpty);
      expect(r.field, findsOneWidget);
    });

    testWidgets('Save with exactly 2000 characters calls addComment', (
      tester,
    ) async {
      final r = await pumpActivityRig(tester);

      await r.openComment(olderEntryId);
      await r.type(_long(2000));
      await r.save();

      expect(r.calls('addComment'), hasLength(1));
      expect(r.calls('addComment').single.args['text'], _long(2000));
    });

    testWidgets('Save with 2001 characters is refused with no call', (
      tester,
    ) async {
      final r = await pumpActivityRig(tester);

      await r.openComment(olderEntryId);
      await r.type(_long(2001));
      await r.save();

      expect(r.calls('addComment'), isEmpty);
      expect(r.cli.callsFor('feedback add'), isEmpty);
      expect(r.field, findsOneWidget, reason: 'the text is not thrown away');
      expect(r.fieldText(), _long(2001));
    });

    testWidgets(
      'a failed addComment shows an inline error and keeps the typed text',
      (tester) async {
        final r = await pumpActivityRig(tester);
        r.feedback.failNext('addComment', MemexException('add failed: boom'));

        await r.openComment(olderEntryId);
        await r.type('this will not save');
        await r.save();

        expect(r.key('inline-error'), findsOneWidget);
        expect(r.field, findsOneWidget);
        expect(r.fieldText(), 'this will not save');
        expect(find.textContaining('You: this will not save'), findsNothing);
      },
    );

    testWidgets(
      'an unreachable vault server shows the snackbar on addComment and adds no row',
      (tester) async {
        final r = await pumpActivityRig(tester);
        r.feedback.failNext(
          'addComment',
          const VaultUnreachableException(
            serverName: 'nas',
            mayHaveCommitted: false,
          ),
        );

        await r.openComment(olderEntryId);
        await r.type('lost on the wire');
        await r.save();

        expect(find.text("couldn't reach nas. try again."), findsOneWidget);
        expect(find.textContaining('You: lost on the wire'), findsNothing);
      },
    );
  });

  group('Edit and Delete (AC4, AC5)', () {
    testWidgets(
      'an Open comment shows Edit and Delete and Edit saves through editComment once',
      (tester) async {
        final db = seedCommentVault();
        _seedOpenComment(db, 'fb-open', 'coyote time is game feel');
        final r = await pumpActivityRig(tester, db: db);

        expect(r.rowText('fb-open'), contains('You: coyote time is game feel'));
        expect(r.status('fb-open'), 'Open');
        expect(r.key('feedback-delete-fb-open'), findsOneWidget);

        await r.tap('feedback-edit-fb-open');
        expect(r.field, findsOneWidget);
        expect(r.fieldText(), 'coyote time is game feel');
        await r.type('coyote time is the whole game');
        await r.save();

        final edits = r.calls('editComment');
        expect(edits, hasLength(1));
        expect(edits.single.args, {
          'id': 'fb-open',
          'text': 'coyote time is the whole game',
        });
        expect(r.calls('addComment'), isEmpty);
        expect(r.field, findsNothing);
        expect(
          r.rowText('fb-open'),
          contains('You: coyote time is the whole game'),
        );
        expect(r.status('fb-open'), 'Open');
      },
    );

    testWidgets('Edit then Cancel calls nothing and keeps the comment', (
      tester,
    ) async {
      final db = seedCommentVault();
      _seedOpenComment(db, 'fb-open', 'coyote time is game feel');
      final r = await pumpActivityRig(tester, db: db);

      await r.tap('feedback-edit-fb-open');
      await r.type('never mind');
      await r.cancel();

      expect(r.calls('editComment'), isEmpty);
      expect(r.cli.callsFor('feedback edit'), isEmpty);
      expect(r.field, findsNothing);
      expect(r.rowText('fb-open'), contains('You: coyote time is game feel'));
    });

    testWidgets('Edit with 2001 characters is refused with no call', (
      tester,
    ) async {
      final db = seedCommentVault();
      _seedOpenComment(db, 'fb-open', 'short');
      final r = await pumpActivityRig(tester, db: db);

      await r.tap('feedback-edit-fb-open');
      await r.type(_long(2001));
      await r.save();

      expect(r.calls('editComment'), isEmpty);
      expect(r.field, findsOneWidget);
    });

    testWidgets('Edit with whitespace only text is refused with no call', (
      tester,
    ) async {
      final db = seedCommentVault();
      _seedOpenComment(db, 'fb-open', 'short');
      final r = await pumpActivityRig(tester, db: db);

      await r.tap('feedback-edit-fb-open');
      await r.type('   ');
      await r.save();

      expect(r.calls('editComment'), isEmpty);
      expect(r.field, findsOneWidget);
    });

    testWidgets(
      'Delete on an Open comment calls deleteComment once and the row goes',
      (tester) async {
        final db = seedCommentVault();
        _seedOpenComment(db, 'fb-open', 'coyote time is game feel');
        final r = await pumpActivityRig(tester, db: db);

        await r.tap('feedback-delete-fb-open');

        final deletes = r.calls('deleteComment');
        expect(deletes, hasLength(1));
        expect(deletes.single.args, {'id': 'fb-open'});
        expect(r.calls('editComment'), isEmpty);
        expect(r.key('feedback-fb-open'), findsNothing);
        expect(find.textContaining('coyote time'), findsNothing);
      },
    );

    testWidgets(
      'a Handled comment shows Handled with the reply and no Edit or Delete',
      (tester) async {
        final db = seedCommentVault();
        db.seedFeedback(
          'fb-done',
          noteId: commentNoteId,
          day: newerEntryDay,
          agentChangeId: newerEntryId,
          text: 'file this under Framework',
          status: 'handled',
          reply: 'added to Framework in the Vault Guide',
          createdAt: 1000,
          handledAt: 1500,
        );
        final r = await pumpActivityRig(tester, db: db);

        expect(
          r.rowText('fb-done'),
          contains('You: file this under Framework'),
        );
        expect(
          r.status('fb-done'),
          'Handled: added to Framework in the Vault Guide',
        );
        _expectNoActions(r, 'fb-done');
      },
    );

    testWidgets(
      'an Open comment that came from chat offers no Edit or Delete',
      (tester) async {
        final db = seedCommentVault();
        db.seedFeedback(
          'fb-chat-open',
          source: 'chat',
          noteId: commentNoteId,
          day: newerEntryDay,
          agentChangeId: newerEntryId,
          text: 'said in chat',
          createdAt: 1000,
        );
        final r = await pumpActivityRig(tester, db: db);

        expect(r.rowText('fb-chat-open'), contains('said in chat'));
        _expectNoActions(r, 'fb-chat-open');
      },
    );

    testWidgets(
      'Save on an edit the agent already handled shows an inline error and the row turns Handled',
      (tester) async {
        final db = seedCommentVault();
        _seedOpenComment(db, 'fb-open', 'coyote time is game feel');
        final r = await pumpActivityRig(tester, db: db);
        final counter = RevisionCounter(r.h);

        await r.tap('feedback-edit-fb-open');
        await r.type('too late');
        r.agentHandles('fb-open', 'added to Framework');
        await r.save();

        expect(r.calls('editComment'), hasLength(1));
        expect(r.key('inline-error'), findsOneWidget);
        expect(r.status('fb-open'), 'Handled: added to Framework');
        _expectNoActions(r, 'fb-open');
        expect(r.rowText('fb-open'), isNot(contains('too late')));
        expect(counter.bumps, 1, reason: 'the failed write still refreshes');
      },
    );
  });

  group('Wording (AC6, AC7)', () {
    for (final (name, kind, wording) in <(String, String, String)>[
      (
        'a Correction of kind excerpt_moved renders You moved with the preview and the target topic then the Why note with no Edit or Delete',
        'excerpt_moved',
        'You moved "Tune the loop" to Economy',
      ),
      (
        'a Correction of kind excerpt_removed renders You removed with the preview and the topic then the Why note with no Edit or Delete',
        'excerpt_removed',
        'You removed "Two blocks about pacing" from Player Loop',
      ),
      (
        'a Correction of kind excerpt_added renders You filed with the preview and the topic then the Why note with no Edit or Delete',
        'excerpt_added',
        'You filed "Add a gold sink" in Economy',
      ),
      (
        'a Correction of kind membership_removed renders You removed the topic from the Smart Folder then the Why note with no Edit or Delete',
        'membership_removed',
        'You removed Pacing from Design',
      ),
      (
        'a Correction of kind folder_renamed renders You renamed the old name to the new name then the Why note with no Edit or Delete',
        'folder_renamed',
        'You renamed Design to Game design',
      ),
      (
        'a Correction of kind folder_moved renders You moved the Smart Folder then the Why note with no Edit or Delete',
        'folder_moved',
        'You moved Design',
      ),
      (
        'a Correction of kind folder_deleted renders You deleted the Smart Folder then the Why note with no Edit or Delete',
        'folder_deleted',
        'You deleted Design',
      ),
      (
        'a Correction of kind tag_removed renders You removed the tag then the Why note with no Edit or Delete',
        'tag_removed',
        'You removed #gardening',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final db = seedCommentVault();
        _seedCorrection(db, 'fb-corr', kind, why: 'Because it fits elsewhere');
        final r = await pumpActivityRig(tester, db: db);

        final text = r.rowText('fb-corr');
        expect(text, contains(wording));
        // The Why note follows the wording.
        expect(text, contains('Because it fits elsewhere'));
        expect(
          text.indexOf('Because it fits elsewhere'),
          greaterThan(text.indexOf(wording)),
        );
        expect(r.status('fb-corr'), 'Open');
        _expectNoActions(r, 'fb-corr');
      });
    }

    testWidgets('a Correction without a Why note shows only its wording', (
      tester,
    ) async {
      final db = seedCommentVault();
      _seedCorrection(db, 'fb-corr', 'excerpt_moved');
      final r = await pumpActivityRig(tester, db: db);

      final text = r.rowText('fb-corr');
      expect(text, contains('You moved "Tune the loop" to Economy'));
      expect(text, isNot(contains('Why')));
    });

    testWidgets(
      'a Handled Correction shows Handled with the reply and stays read only',
      (tester) async {
        final db = seedCommentVault();
        _seedCorrection(
          db,
          'fb-corr',
          'folder_renamed',
          status: 'handled',
          reply: 'renamed it in the guide',
        );
        final r = await pumpActivityRig(tester, db: db);

        expect(
          r.rowText('fb-corr'),
          contains('You renamed Design to Game design'),
        );
        expect(r.status('fb-corr'), 'Handled: renamed it in the guide');
        _expectNoActions(r, 'fb-corr');
      },
    );

    testWidgets(
      'an open tag Correction row tag-n renders You removed the tag and offers no Edit or Delete',
      (tester) async {
        final db = seedCommentVault();
        final n = db.seedTagCorrection(
          noteId: commentNoteId,
          noteTitle: 'Pacing',
          tag: 'gardening',
          createdAt: 3000,
        );
        final r = await pumpActivityRig(tester, db: db);

        expect(r.rowText('tag-$n'), contains('You removed #gardening'));
        expect(r.status('tag-$n'), 'Open');
        _expectNoActions(r, 'tag-$n');
      },
    );

    testWidgets(
      'a chat comment shows From chat with its words verbatim and its reply and no Edit or Delete',
      (tester) async {
        final db = seedCommentVault();
        db.seedFeedback(
          'fb-chat',
          source: 'chat',
          noteId: commentNoteId,
          day: newerEntryDay,
          agentChangeId: newerEntryId,
          text: 'the 2 blocks about coyote time belong in Player Feel',
          status: 'handled',
          reply: 'moved them to Player Feel',
          createdAt: 1000,
          handledAt: 1100,
        );
        final r = await pumpActivityRig(tester, db: db);

        final text = r.rowText('fb-chat');
        expect(text, contains('From chat'));
        expect(
          text,
          contains('the 2 blocks about coyote time belong in Player Feel'),
        );
        expect(r.status('fb-chat'), 'Handled: moved them to Player Feel');
        _expectNoActions(r, 'fb-chat');
      },
    );

    testWidgets('a comment from the person is not labelled From chat', (
      tester,
    ) async {
      final db = seedCommentVault();
      _seedOpenComment(db, 'fb-open', 'mine');
      final r = await pumpActivityRig(tester, db: db);

      expect(r.rowText('fb-open'), isNot(contains('From chat')));
    });
  });

  group('Homes (AC8, AC9, AC10)', () {
    testWidgets(
      'Feedback with an agent change id shows under that entry and not under the other',
      (tester) async {
        final db = seedCommentVault();
        db.seedFeedback(
          'fb-on-newer',
          noteId: commentNoteId,
          day: newerEntryDay,
          agentChangeId: newerEntryId,
          text: 'on the newer entry',
          createdAt: 1000,
        );
        db.seedFeedback(
          'fb-on-older',
          noteId: commentNoteId,
          day: olderEntryDay,
          agentChangeId: olderEntryId,
          text: 'on the older entry',
          createdAt: 1100,
        );
        final r = await pumpActivityRig(tester, db: db);

        final newerTop = r.top('activity-entry-$newerEntryId');
        final olderTop = r.top('activity-entry-$olderEntryId');
        expect(newerTop, lessThan(olderTop));
        expect(r.top('feedback-fb-on-newer'), greaterThanOrEqualTo(newerTop));
        expect(r.top('feedback-fb-on-newer'), lessThan(olderTop));
        expect(r.top('feedback-fb-on-older'), greaterThanOrEqualTo(olderTop));
      },
    );

    testWidgets('two Feedback rows on one entry show under it newest first', (
      tester,
    ) async {
      final db = seedCommentVault();
      db.seedFeedback(
        'fb-early',
        noteId: commentNoteId,
        day: newerEntryDay,
        agentChangeId: newerEntryId,
        text: 'the earlier one',
        createdAt: 1000,
      );
      db.seedFeedback(
        'fb-late',
        noteId: commentNoteId,
        day: newerEntryDay,
        agentChangeId: newerEntryId,
        text: 'the later one',
        createdAt: 2000,
      );
      final r = await pumpActivityRig(tester, db: db);

      final entryTop = r.top('activity-entry-$newerEntryId');
      expect(r.top('feedback-fb-late'), greaterThanOrEqualTo(entryTop));
      expect(r.top('feedback-fb-late'), lessThan(r.top('feedback-fb-early')));
      expect(
        r.top('feedback-fb-early'),
        lessThan(r.top('activity-entry-$olderEntryId')),
      );
    });

    testWidgets(
      'Feedback with a note but no entry shows above the entries newest first',
      (tester) async {
        final db = seedCommentVault();
        db.seedFeedback(
          'fb-first',
          kind: 'correction',
          noteId: commentNoteId,
          day: newerEntryDay,
          correction: correctionSamples['membership_removed'],
          createdAt: 3000,
        );
        db.seedFeedback(
          'fb-second',
          kind: 'correction',
          noteId: commentNoteId,
          day: newerEntryDay,
          correction: correctionSamples['folder_deleted'],
          createdAt: 2000,
        );
        final r = await pumpActivityRig(tester, db: db);

        final firstEntryTop = r.top('activity-entry-$newerEntryId');
        expect(r.bottom('feedback-fb-first'), lessThanOrEqualTo(firstEntryTop));
        expect(
          r.bottom('feedback-fb-second'),
          lessThanOrEqualTo(firstEntryTop),
        );
        expect(
          r.top('feedback-fb-first'),
          lessThan(r.top('feedback-fb-second')),
        );
      },
    );

    testWidgets(
      'Feedback naming an entry that no longer exists is not dropped and shows above the entries',
      (tester) async {
        final db = seedCommentVault();
        db.seedFeedback(
          'fb-orphan',
          noteId: commentNoteId,
          day: newerEntryDay,
          agentChangeId: 'ac-gone',
          text: 'its entry was deleted',
          createdAt: 1000,
        );
        final r = await pumpActivityRig(tester, db: db);

        expect(r.rowText('fb-orphan'), contains('its entry was deleted'));
        expect(
          r.bottom('feedback-fb-orphan'),
          lessThanOrEqualTo(r.top('activity-entry-$newerEntryId')),
        );
      },
    );

    testWidgets(
      'a note with Feedback but no agent entries shows the Feedback and not the empty state',
      (tester) async {
        final db = seedCommentVault();
        db.seedTopicNote('topic-1', 'Player Feel');
        db.seedFeedback(
          'fb-topic',
          kind: 'correction',
          noteId: 'topic-1',
          correction: correctionSamples['membership_removed'],
          createdAt: 1000,
        );
        final r = await pumpActivityRig(tester, db: db, noteId: 'topic-1');

        expect(r.key('activity-empty'), findsNothing);
        expect(find.byKey(_empty), findsNothing);
        expect(
          r.rowText('fb-topic'),
          contains('You removed Pacing from Design'),
        );
      },
    );

    testWidgets(
      'a note with no entries and no Feedback still shows the empty state',
      (tester) async {
        final db = seedCommentVault();
        db.seedTopicNote('topic-1', 'Player Feel');
        db.seedFeedback(
          'fb-elsewhere',
          noteId: commentNoteId,
          text: 'belongs to another note',
          createdAt: 1000,
        );
        final r = await pumpActivityRig(tester, db: db, noteId: 'topic-1');

        expect(find.byKey(_empty), findsOneWidget);
        expect(r.key('feedback-fb-elsewhere'), findsNothing);
      },
    );

    testWidgets(
      'the Vault Guide tab shows no-note Feedback above its entries including a tag removed from a deleted note',
      (tester) async {
        final db = seedCommentVault();
        db.seedNote(id: 'guide-1', title: 'Vault Guide', role: 'guide');
        db.seedAgentChange(
          'ac-guide',
          'guide-1',
          day: '2026-09-04',
          createdAt: DateTime(2026, 9, 6, 9).millisecondsSinceEpoch,
          bullets: ['Added a Framework section'],
        );
        db.seedFeedback(
          'fb-nonote',
          kind: 'correction',
          correction: correctionSamples['folder_renamed'],
          createdAt: 2000,
        );
        db.seedFeedback(
          'fb-guide-own',
          noteId: 'guide-1',
          text: 'a comment on the guide itself',
          createdAt: 1500,
        );
        final tag = db.seedTagCorrection(
          noteTitle: 'Gone note',
          tag: 'gardening',
          createdAt: 3000,
        );
        final r = await pumpActivityRig(tester, db: db, noteId: 'guide-1');

        final entryTop = r.top('activity-entry-ac-guide');
        expect(
          r.rowText('fb-nonote'),
          contains('You renamed Design to Game design'),
        );
        expect(r.bottom('feedback-fb-nonote'), lessThanOrEqualTo(entryTop));
        final tagText = r.rowText('tag-$tag');
        expect(tagText, contains('removed #gardening from a deleted note'));
        expect(tagText, contains('Gone note'));
        expect(r.bottom('feedback-tag-$tag'), lessThanOrEqualTo(entryTop));
        _expectNoActions(r, 'tag-$tag');
        expect(
          r.rowText('fb-guide-own'),
          contains('a comment on the guide itself'),
        );
        expect(r.bottom('feedback-fb-guide-own'), lessThanOrEqualTo(entryTop));
      },
    );

    testWidgets(
      'a note that is not the Vault Guide does not show no-note Feedback',
      (tester) async {
        final db = seedCommentVault();
        db.seedFeedback(
          'fb-nonote',
          kind: 'correction',
          correction: correctionSamples['folder_renamed'],
          createdAt: 2000,
        );
        db.seedTagCorrection(noteTitle: 'Gone note', createdAt: 3000);
        _seedOpenComment(db, 'fb-own', 'a comment on this note');
        final r = await pumpActivityRig(tester, db: db);

        expect(r.rowText('fb-own'), contains('You: a comment on this note'));
        expect(r.key('feedback-fb-nonote'), findsNothing);
        expect(find.textContaining('from a deleted note'), findsNothing);
        expect(r.key('activity-entry-$newerEntryId'), findsOneWidget);
      },
    );

    testWidgets(
      'the Vault Guide tab with no entries shows its no-note Feedback and not the empty state',
      (tester) async {
        final db = seedCommentVault();
        db.seedNote(id: 'guide-1', title: 'Vault Guide', role: 'guide');
        db.seedFeedback(
          'fb-nonote',
          kind: 'correction',
          correction: correctionSamples['folder_deleted'],
          createdAt: 2000,
        );
        final r = await pumpActivityRig(tester, db: db, noteId: 'guide-1');

        expect(find.byKey(_empty), findsNothing);
        expect(r.rowText('fb-nonote'), contains('You deleted Design'));
      },
    );
  });

  group('Below V6 (AC12)', () {
    testWidgets(
      'a vault that is not at V6 shows the entries but no Comment action and no Feedback rows',
      (tester) async {
        final db = seedCommentVault();
        _seedOpenComment(db, 'fb-open', 'visible at V6');
        final r = await pumpActivityRig(tester, db: db);

        // At V6 both are there.
        expect(r.key('activity-comment-$olderEntryId'), findsOneWidget);
        expect(r.key('feedback-fb-open'), findsOneWidget);

        // The vault drops below V6 and the app re-probes on the next bump.
        db.db.execute('DROP TABLE feedback');
        bumpRevision(r);
        await r.settle();

        expect(r.key('activity-entry-$olderEntryId'), findsOneWidget);
        expect(r.key('activity-entry-$newerEntryId'), findsOneWidget);
        expect(r.key('activity-comment-$olderEntryId'), findsNothing);
        expect(r.key('activity-comment-$newerEntryId'), findsNothing);
        expect(r.key('feedback-fb-open'), findsNothing);
      },
    );

    testWidgets('a V5 only vault shows its entries with no Comment action', (
      tester,
    ) async {
      final db = FakeVaultDb.v5Only();
      seedCommentVault(db);
      final r = await pumpActivityRig(tester, db: db);

      expect(r.key('activity-entry-$olderEntryId'), findsOneWidget);
      expect(r.key('activity-comment-$olderEntryId'), findsNothing);
      expect(r.key('activity-comment-$newerEntryId'), findsNothing);
    });
  });
}
