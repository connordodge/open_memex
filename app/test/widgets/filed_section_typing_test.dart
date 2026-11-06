// WI #260 (F8), fix round r3. Two things a person did must survive whatever
// else is going on: text typed while a rebase reads the note (D23; the rebase
// path is shared with F10's Restore and the footer and tag paths), and a fix
// confirmed in a dialog after the section that opened it is gone.
// Test names use no apostrophes.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/topic_actions.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';

import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/filed_section_fakes.dart';
import '../support/review_fakes.dart';
import '../support/segment_editing_finder.dart';
import '../support/topics_access_doubles.dart';
import '../support/vault_guide_fixture.dart';

const _pending = 'pending thought';
const _typed = 'pending thought typed during the read';

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(editorBodyKey), text);
  await tester.pump();
}

/// Lets every read held on `getNote` go and pumps, so the reads they lead to
/// are the ones held next.
Future<void> _releaseReads(WidgetTester tester, RecordingNotesAccess n) async {
  final held = n.gates.remove('getNote') ?? const [];
  for (final gate in held) {
    gate.complete();
  }
  await pumpFrames(tester);
}

/// Runs the save debounce out.
Future<void> _runDebounce(WidgetTester tester, WorkspaceHarness h) async {
  h.clock.advance(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));
  await pumpFrames(tester);
}

/// The section's tab goes away, which disposes the section's State.
Future<void> _closeSection(WidgetTester tester, F260 f) async {
  f.h.container.read(rightPanelTabProvider.notifier).state =
      RightPanelTab.connections;
  await pumpFrames(tester);
  expect(find.byKey(f260Section), findsNothing);
}

void main() {
  group('text typed while a fix rebases the daily note', () {
    testWidgets(
      'typing during the second read survives and saves on the new version',
      (tester) async {
        final f = await pumpF260(tester);
        await _type(tester, _pending);
        f.feedback.gate('moveBlock');
        await f260Tap(tester, f260Move(f260Loop, f260B1));
        await f260Tap(tester, f260Option(f260Sleep));
        await f260Tap(tester, f260Confirm);

        f.notes.gate('getNote');
        f.feedback.gates['moveBlock']!.single.complete();
        await pumpFrames(tester);
        // The fix read the note for its version; the rebase read is next.
        await _releaseReads(tester, f.notes);
        expect(f.notes.gates['getNote'], isNotEmpty);
        expect(
          f.h.read(editorControllerProvider).lastSavedVersion,
          1,
          reason: 'the held read is the rebase: it has not rebased yet',
        );

        await _type(tester, _typed);
        f.notes.ungate('getNote');
        await _releaseReads(tester, f.notes);

        final editor = f.h.read(editorControllerProvider);
        expect(editor.lastSavedVersion, 2, reason: 'the chip add version');
        expect(editor.contentMd, _typed);
        expect(editor.status, SaveStatus.dirty);
        expect(find.text('conflict — reload'), findsNothing);

        await _runDebounce(tester, f.h);
        final update = f.cli.callsFor('update').single;
        expect(update.flag('expected-version'), '2');
        expect(update.stdinBody, _typed);
        expect(f.h.read(editorControllerProvider).status, SaveStatus.clean);
        expect(find.text('conflict — reload'), findsNothing);
      },
    );

    testWidgets('typing during the first read survives too', (tester) async {
      final f = await pumpF260(tester);
      await _type(tester, _pending);
      f.feedback.gate('moveBlock');
      await f260Tap(tester, f260Move(f260Loop, f260B1));
      await f260Tap(tester, f260Option(f260Sleep));
      await f260Tap(tester, f260Confirm);

      f.notes.gate('getNote');
      f.feedback.gates['moveBlock']!.single.complete();
      await pumpFrames(tester);
      await _type(tester, _typed);
      f.notes.ungate('getNote');
      await _releaseReads(tester, f.notes);

      final editor = f.h.read(editorControllerProvider);
      expect(editor.lastSavedVersion, 2);
      expect(editor.contentMd, _typed);
    });
  });

  group('the shared rebase path', () {
    testWidgets('rebaseEditorOnVersion keeps text typed during its read', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      await _type(tester, _pending);
      final ref = tester.element(find.byType(NoteEditor)) as WidgetRef;
      f.notes.gate('getNote');

      final rebase = rebaseEditorOnVersion(
        ref,
        fallback: f.db.getNote(f260DailyId)!,
        version: 5,
        content: _pending,
      );
      await pumpFrames(tester);
      await _type(tester, _typed);
      f.notes.ungate('getNote');
      await _releaseReads(tester, f.notes);
      await rebase;

      final editor = f.h.read(editorControllerProvider);
      expect(editor.lastSavedVersion, 5);
      expect(editor.contentMd, _typed);
    });

    testWidgets('rebaseEditorOnVersionIn keeps a title typed during its read', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      f.notes.gate('getNote');

      final rebase = rebaseEditorOnVersionIn(
        f.h.container,
        fallback: f.db.getNote(f260DailyId)!,
        version: 5,
        content: _pending,
      );
      await pumpFrames(tester);
      f.h.read(editorControllerProvider.notifier).onTitleChanged('A new title');
      f.notes.ungate('getNote');
      await _releaseReads(tester, f.notes);
      await rebase;

      final editor = f.h.read(editorControllerProvider);
      expect(editor.lastSavedVersion, 5);
      expect(editor.title, 'A new title');
      expect(
        editor.contentMd,
        _pending,
        reason: 'no body was typed: the text the caller passed goes on top',
      );
    });

    testWidgets(
      'with nothing typed during the read the caller text goes on top',
      (tester) async {
        final f = await pumpF260(tester);
        await _type(tester, _pending);

        await rebaseEditorOnVersionIn(
          f.h.container,
          fallback: f.db.getNote(f260DailyId)!,
          version: 5,
          content: 'the caller text',
        );
        await pumpFrames(tester);

        final editor = f.h.read(editorControllerProvider);
        expect(editor.lastSavedVersion, 5);
        expect(editor.contentMd, 'the caller text');
      },
    );
  });

  group('text typed while Restore runs (F10)', () {
    Future<GuideEnv> openGuide(WidgetTester tester) async {
      final db = guideDb()..seedGuideActivity();
      final env = await launchGuideWorkspace(tester, db: db, topicsMode: false);
      await openNoteTab(tester, env.h, guideNoteId);
      await showActivityTab(tester, env.h);
      return env;
    }

    Future<void> pressRestore(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('guide-restore-ac-1')));
      await pumpFrames(tester);
      await tester.tap(find.byKey(const Key('guide-restore-confirm')));
      await pumpFrames(tester);
    }

    void expectKept(GuideEnv env, String text) {
      final editor = env.h.read(editorControllerProvider);
      expect(editor.lastSavedVersion, guideVersion + 1);
      expect(editor.contentMd, text);
      expect(editor.status, SaveStatus.dirty);
    }

    testWidgets('typing during the read of the rebase survives', (
      tester,
    ) async {
      final env = await openGuide(tester);
      final notes = env.doubles.notesAt(env.h.vaultPath);
      notes.gate('getNote');
      await pressRestore(tester);
      // The read of the restored text; the rebase read is next.
      await _releaseReads(tester, notes);
      expect(notes.gates['getNote'], isNotEmpty);
      expect(
        env.h.read(editorControllerProvider).lastSavedVersion,
        guideVersion,
        reason: 'the held read is the rebase: it has not rebased yet',
      );

      await _type(tester, 'typed during the restore');
      notes.ungate('getNote');
      await _releaseReads(tester, notes);

      expectKept(env, 'typed during the restore');
      await _runDebounce(tester, env.h);
      final update = env.cli.callsFor('update').single;
      expect(update.flag('expected-version'), '${guideVersion + 1}');
      expect(update.stdinBody, 'typed during the restore');
    });

    testWidgets('typing during the restore write survives', (tester) async {
      final env = await openGuide(tester);
      env.feedback.gate('restoreGuide');
      await pressRestore(tester);

      await _type(tester, 'typed during the restore');
      env.feedback.gates['restoreGuide']!.single.complete();
      await pumpFrames(tester);

      expectKept(env, 'typed during the restore');
    });

    testWidgets('typing before Restore is stored first, not kept on top', (
      tester,
    ) async {
      final env = await openGuide(tester);
      await _type(tester, 'typed before the restore');

      await pressRestore(tester);
      await pumpFrames(tester);

      final editor = env.h.read(editorControllerProvider);
      expect(editor.contentMd, guidePreviousBody);
      expect(editor.status, SaveStatus.clean);
    });
  });

  group('a fix confirmed after the section is gone', () {
    testWidgets('Move to still moves and rebases the open daily note', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      await _type(tester, _pending);

      await f260Tap(tester, f260Move(f260Loop, f260B1));
      await f260Tap(tester, f260Option(f260Sleep));
      await _closeSection(tester, f);
      await f260Tap(tester, f260Confirm);

      expect(tester.takeException(), isNull);
      expect(f.moves, hasLength(1));
      expect(f.moves.single.args['date'], f260Date);
      final editor = f.h.read(editorControllerProvider);
      expect(editor.lastSavedVersion, 2);
      expect(editor.contentMd, _pending);
    });

    testWidgets('Remove still removes', (tester) async {
      final f = await pumpF260(tester);

      await f260Tap(tester, f260Remove(f260Loop, f260B1));
      await _closeSection(tester, f);
      await f260Tap(tester, f260Confirm);

      expect(tester.takeException(), isNull);
      expect(f.removes, hasLength(1));
      expect(f.removes.single.args['date'], f260Date);
    });

    testWidgets('File in still files', (tester) async {
      final f = await pumpF260(tester);

      await f260Tap(tester, f260FileIn(f260N1));
      await f260Tap(tester, f260Option(f260Economy));
      await _closeSection(tester, f);
      await f260Tap(tester, f260Confirm);

      expect(tester.takeException(), isNull);
      expect(f.files, hasLength(1));
      expect(f.files.single.args['date'], f260Date);
    });

    testWidgets('a Create chosen in the dialog still creates and moves', (
      tester,
    ) async {
      final f = await pumpF260(tester);

      await f260Tap(tester, f260Move(f260Loop, f260B1));
      await f260TypeTopic(tester, 'Fresh Topic');
      await f260Tap(tester, f260Create);
      await _closeSection(tester, f);
      await f260Tap(tester, f260Confirm);

      expect(tester.takeException(), isNull);
      expect(f.notes.callsTo('addNote'), hasLength(1));
      expect(f.moves, hasLength(1));
    });

    testWidgets('a failed fix throws nothing with the section gone', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      f.feedback.failAlways('moveBlock', StateError('write failed'));

      await f260Tap(tester, f260Move(f260Loop, f260B1));
      await f260Tap(tester, f260Option(f260Sleep));
      await _closeSection(tester, f);
      await f260Tap(tester, f260Confirm);

      expect(tester.takeException(), isNull);
    });

    testWidgets('a vault error on a fix with the section gone throws nothing', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      f.server.nextWriteError = FakeMemexCli.error('internal', 'boom');

      await f260Tap(tester, f260Move(f260Loop, f260B1));
      await f260Tap(tester, f260Option(f260Sleep));
      await _closeSection(tester, f);
      await f260Tap(tester, f260Confirm);

      expect(tester.takeException(), isNull);
      expect(f.moves, hasLength(1), reason: 'the write was tried once');
    });

    testWidgets('topics load through the dialog when the section just left', (
      tester,
    ) async {
      final f = await pumpF260(tester);

      await f260Tap(tester, f260Move(f260Loop, f260B1));
      await _closeSection(tester, f);

      expect(tester.takeException(), isNull);
      expect(find.byKey(f260Option(f260Sleep)), findsOneWidget);
    });

    testWidgets('a fix confirmed after the vault changed writes nothing', (
      tester,
    ) async {
      final f = await pumpF260(tester);
      final writesTo = f.feedback;

      await f260Tap(tester, f260Move(f260Loop, f260B1));
      await f260Tap(tester, f260Option(f260Sleep));
      f.h.container.read(currentVaultProvider.notifier).state = LocalVaultRef(
        '${f.h.vaultPath}-other',
      );
      await pumpFrames(tester);
      await f260Tap(tester, f260Confirm);

      expect(tester.takeException(), isNull);
      expect(writesTo.callsTo('moveBlock'), isEmpty);
      expect(
        f.doubles.feedbackAt('${f.h.vaultPath}-other').callsTo('moveBlock'),
        isEmpty,
        reason: 'the block belongs to the vault the row was pressed in',
      );
      expect(f.notes.callsTo('addNote'), isEmpty);
    });
  });
}
