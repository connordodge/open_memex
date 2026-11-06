// WI #262 (F10): Restore on the Vault Guide's Activity tab. An agent entry
// that has a guide revision shows `Restore`; confirming replaces the guide's
// text with that revision (the current text is kept as a version) and the
// open editor rebases onto the new version without a conflict banner (D23).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/activity_seeds.dart';
import '../support/app_harness.dart';
import '../support/feedback_seeds.dart';
import '../support/review_fakes.dart';
import '../support/segment_editing_finder.dart';
import '../support/topics_access_doubles.dart';
import '../support/topics_seed.dart';
import '../support/vault_guide_fixture.dart';

const _confirmText =
    'Restore this version? The current text is kept as a version you can return to.';

Finder _restore(String entry) => find.byKey(Key('guide-restore-$entry'));
const _confirm = Key('guide-restore-confirm');
const _cancel = Key('guide-restore-cancel');

Finder get _anyRestore => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('guide-restore-') &&
      !const {
        'guide-restore-confirm',
        'guide-restore-cancel',
      }.contains((w.key! as ValueKey<String>).value),
);

Future<GuideEnv> _openGuideActivity(
  WidgetTester tester, {
  AccessDoubles? doubles,
}) async {
  final db = guideDb()..seedGuideActivity();
  final env = await launchGuideWorkspace(
    tester,
    db: db,
    doubles: doubles,
    topicsMode: false,
  );
  await openNoteTab(tester, env.h, guideNoteId);
  await showActivityTab(tester, env.h);
  return env;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  expect(f, findsOneWidget, reason: '$f');
  await tester.tap(f);
  await pumpFrames(tester);
}

/// Restore on entry `ac-1`, then Restore in the dialog.
Future<void> _restoreAndConfirm(WidgetTester tester) async {
  await _tap(tester, _restore('ac-1'));
  await _tap(tester, find.byKey(_confirm));
}

void main() {
  group('Restore shows on entries with a revision (AC6)', () {
    testWidgets(
      'a guide Activity entry with a revision shows Restore and an entry without one does not',
      (tester) async {
        await _openGuideActivity(tester);

        expect(find.byKey(const Key('activity-entry-ac-1')), findsOneWidget);
        expect(find.byKey(const Key('activity-entry-ac-2')), findsOneWidget);
        expect(_restore('ac-1'), findsOneWidget);
        expect(_restore('ac-2'), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const Key('activity-entry-ac-1')),
            matching: find.text('Restore'),
          ),
          findsOneWidget,
          reason: 'the button is inside its entry and says Restore',
        );
      },
    );

    testWidgets(
      'a revision with no agent change adds no Restore button to any entry',
      (tester) async {
        await _openGuideActivity(tester);

        expect(_anyRestore, findsOneWidget, reason: 'only ac-1 has one');
      },
    );

    testWidgets(
      'a topic note entry shows no Restore even when a guide revision names its agent change',
      (tester) async {
        final db = guideDb()..seedGuideActivity();
        db.seedAgentChange(
          'ac-topic',
          TP.loop,
          day: '2026-10-02',
          createdAt: DateTime(2026, 10, 2, 10, 0).millisecondsSinceEpoch,
          bullets: ['Edited the topic'],
        );
        db.seedGuideRevision(
          'rev-topic',
          noteId: guideNoteId,
          agentChangeId: 'ac-topic',
          createdAt: 3000,
        );
        final env = await launchGuideWorkspace(
          tester,
          db: db,
          topicsMode: false,
        );
        await openNoteTab(tester, env.h, guideNoteId);
        await showActivityTab(tester, env.h);
        expect(_restore('ac-1'), findsOneWidget, reason: 'the guide has one');
        await openNoteTab(tester, env.h, TP.loop);
        await pumpFrames(tester);

        expect(
          find.byKey(const Key('activity-entry-ac-topic')),
          findsOneWidget,
        );
        expect(_anyRestore, findsNothing);
      },
    );

    testWidgets('a daily note entry shows no Restore', (tester) async {
      final db = guideDb()..seedGuideActivity();
      db.seedAgentChange(
        'ac-day',
        TP.daily,
        day: '2026-10-02',
        createdAt: DateTime(2026, 10, 2, 11, 0).millisecondsSinceEpoch,
        bullets: ['Tidied the day'],
      );
      db.seedGuideRevision(
        'rev-day',
        noteId: guideNoteId,
        agentChangeId: 'ac-day',
        createdAt: 3100,
      );
      final env = await launchGuideWorkspace(tester, db: db, topicsMode: false);
      await openNoteTab(tester, env.h, guideNoteId);
      await showActivityTab(tester, env.h);
      expect(_restore('ac-1'), findsOneWidget, reason: 'the guide has one');
      await openNoteTab(tester, env.h, TP.daily);
      await pumpFrames(tester);

      expect(find.byKey(const Key('activity-entry-ac-day')), findsOneWidget);
      expect(_anyRestore, findsNothing);
    });
  });

  group('the confirm dialog (AC7)', () {
    testWidgets(
      'Restore opens a dialog with the exact text and Cancel and Restore buttons',
      (tester) async {
        final env = await _openGuideActivity(tester);

        await _tap(tester, _restore('ac-1'));

        expect(find.text(_confirmText), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(_cancel),
            matching: find.text('Cancel'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(_confirm),
            matching: find.text('Restore'),
          ),
          findsOneWidget,
        );
        expect(
          env.feedback.callsTo('restoreGuide'),
          isEmpty,
          reason: 'nothing is restored before the person confirms',
        );
      },
    );

    testWidgets('Cancel closes the dialog and calls nothing', (tester) async {
      final env = await _openGuideActivity(tester);
      var bumps = 0;
      final sub = env.h.container.listen<int>(
        vaultRevisionProvider,
        (_, _) => bumps++,
      );
      addTearDown(sub.close);

      await _tap(tester, _restore('ac-1'));
      await _tap(tester, find.byKey(_cancel));

      expect(find.text(_confirmText), findsNothing);
      expect(env.feedback.callsTo('restoreGuide'), isEmpty);
      expect(env.cli.callsFor('guide restore'), isEmpty);
      expect(bumps, 0);
      expect(env.h.read(editorControllerProvider).contentMd, guideBody);
      expect(_restore('ac-1'), findsOneWidget, reason: 'still offered');
    });

    testWidgets('dismissing the dialog by tapping outside calls nothing', (
      tester,
    ) async {
      final env = await _openGuideActivity(tester);

      await _tap(tester, _restore('ac-1'));
      await tester.tapAt(const Offset(2, 2));
      await pumpFrames(tester);

      expect(find.text(_confirmText), findsNothing);
      expect(env.feedback.callsTo('restoreGuide'), isEmpty);
    });
  });

  group('confirming Restore (AC7)', () {
    testWidgets(
      'confirming calls restoreGuide once with the revision id and the CLI restores that revision',
      (tester) async {
        final env = await _openGuideActivity(tester);

        await _restoreAndConfirm(tester);

        final calls = env.feedback.callsTo('restoreGuide');
        expect(calls, hasLength(1));
        expect(calls.single.args, {'revisionId': 'rev-1'});
        final cli = env.cli.callsFor('guide restore');
        expect(cli, hasLength(1));
        expect(cli.single.flag('revision-id'), 'rev-1');
        expect(find.text(_confirmText), findsNothing);
      },
    );

    testWidgets('the vault revision is bumped exactly once by a Restore', (
      tester,
    ) async {
      final env = await _openGuideActivity(tester);
      var bumps = 0;
      final sub = env.h.container.listen<int>(
        vaultRevisionProvider,
        (_, _) => bumps++,
      );
      addTearDown(sub.close);

      await _restoreAndConfirm(tester);

      expect(bumps, 1, reason: 'FeedbackActions bumps; the widget must not');
    });

    testWidgets(
      'the open editor shows the restored text on the new version with no conflict',
      (tester) async {
        final env = await _openGuideActivity(tester);
        expect(editorBodyText(tester), guideBody);

        await _restoreAndConfirm(tester);

        final editor = env.h.read(editorControllerProvider);
        expect(editor.contentMd, guidePreviousBody);
        expect(editorBodyText(tester), guidePreviousBody);
        expect(editor.lastSavedVersion, guideVersion + 1);
        expect(editor.status, isNot(SaveStatus.conflict));
        expect(editor.status, isNot(SaveStatus.error));
        expect(find.textContaining('conflict'), findsNothing);
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(
          env.db.db.select('SELECT content_md FROM notes WHERE id = ?', [
            guideNoteId,
          ]).first['content_md'],
          guidePreviousBody,
        );
      },
    );

    testWidgets(
      'a pending unsaved edit is replaced by the restored text, not re-applied over it',
      (tester) async {
        final env = await _openGuideActivity(tester);
        await tester.enterText(
          find.byKey(editorBodyKey),
          '$guideBody and my unsaved words',
        );
        await tester.pump();
        expect(
          env.h.read(editorControllerProvider).contentMd,
          '$guideBody and my unsaved words',
        );

        await _restoreAndConfirm(tester);

        final editor = env.h.read(editorControllerProvider);
        expect(editor.contentMd, guidePreviousBody);
        expect(editorBodyText(tester), guidePreviousBody);
        expect(find.textContaining('unsaved words'), findsNothing);
      },
    );

    testWidgets(
      'the next edit after a Restore saves against the restored version without a conflict',
      (tester) async {
        final env = await _openGuideActivity(tester);
        await _restoreAndConfirm(tester);

        await tester.enterText(
          find.byKey(editorBodyKey),
          '$guidePreviousBody plus more',
        );
        await tester.pump();
        env.h.clock.advance(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 600));
        await pumpFrames(tester);

        final update = env.cli.callsFor('update').single;
        expect(update.flag('note-id'), guideNoteId);
        expect(update.flag('expected-version'), '${guideVersion + 1}');
        expect(update.stdinBody, '$guidePreviousBody plus more');
        expect(env.h.read(editorControllerProvider).status, SaveStatus.clean);
      },
    );

    testWidgets(
      'the Activity tab and the tab strip keep showing the guide after a Restore',
      (tester) async {
        final env = await _openGuideActivity(tester);

        await _restoreAndConfirm(tester);

        expect(env.h.read(activeTabProvider), const NoteTab(guideNoteId));
        expect(find.byKey(const Key('activity-entry-ac-1')), findsOneWidget);
        expect(find.byKey(const Key('guide-title')), findsOneWidget);
      },
    );

    testWidgets(
      'a Restore that finishes after the person opened another note leaves that note in the editor',
      (tester) async {
        final env = await _openGuideActivity(
          tester,
          doubles: AccessDoubles(
            configureFeedback: (_, f) => f.gate('restoreGuide'),
          ),
        );

        await _restoreAndConfirm(tester);
        expect(env.feedback.callsTo('restoreGuide'), hasLength(1));
        await openNoteTab(tester, env.h, TP.loop);
        env.feedback.gates['restoreGuide']!.single.complete();
        await pumpFrames(tester);

        final controller = env.h.read(editorControllerProvider.notifier);
        expect(controller.activeNoteId, TP.loop);
        expect(env.h.read(editorControllerProvider).title, 'Player Loop');
      },
    );

    testWidgets(
      'a failed Restore leaves the editor text alone and throws nothing',
      (tester) async {
        final env = await _openGuideActivity(tester);
        env.feedback.failNext(
          'restoreGuide',
          MemexException('guide restore failed: gone', code: 'not_found'),
        );

        await _restoreAndConfirm(tester);

        expect(tester.takeException(), isNull);
        expect(env.feedback.callsTo('restoreGuide'), hasLength(1));
        expect(env.h.read(editorControllerProvider).contentMd, guideBody);
        expect(editorBodyText(tester), guideBody);
        expect(find.text(_confirmText), findsNothing);
      },
    );
  });
}
