// WI #262 (F10), fix round r1 (ruling D42): Restore stores a pending edit
// first, so the text the dialog promises to keep ("The current text is kept
// as a version you can return to") really is kept as a revision. A save that
// fails (or waits) stops the Restore: nothing is replaced, the typed text and
// the stored note stay as they were, and the person sees why.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';

import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/review_fakes.dart';
import '../support/segment_editing_finder.dart';
import '../support/vault_guide_fixture.dart';

const _confirm = Key('guide-restore-confirm');
const _typed = 'current guide text and my unsaved words';

Future<void> _tap(WidgetTester tester, Finder f) async {
  expect(f, findsOneWidget, reason: '$f');
  await tester.tap(f);
  await pumpFrames(tester);
}

Future<GuideEnv> _openGuideActivity(WidgetTester tester) async {
  final db = guideDb()..seedGuideActivity();
  final env = await launchGuideWorkspace(tester, db: db, topicsMode: false);
  await openNoteTab(tester, env.h, guideNoteId);
  await showActivityTab(tester, env.h);
  return env;
}

/// Types [text] and leaves the save debounce pending (no clock advance).
Future<void> _typePending(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(editorBodyKey), text);
  await tester.pump();
}

Future<void> _restoreAndConfirm(WidgetTester tester) async {
  await _tap(tester, find.byKey(const Key('guide-restore-ac-1')));
  await _tap(tester, find.byKey(_confirm));
}

String _storedBody(GuideEnv env) =>
    env.db.db.select('SELECT content_md FROM notes WHERE id = ?', [
          guideNoteId,
        ]).first['content_md']
        as String;

List<String> _revisionBodies(GuideEnv env) => [
  for (final r in env.db.db.select(
    'SELECT previous_md FROM vault_guide_revisions WHERE note_id = ?',
    [guideNoteId],
  ))
    r['previous_md'] as String,
];

void main() {
  group('Restore with an edit still waiting on the save debounce', () {
    testWidgets(
      'a pending edit before Restore is stored first and appears in the revision list',
      (tester) async {
        final env = await _openGuideActivity(tester);
        await _typePending(tester, _typed);
        expect(env.cli.callsFor('update'), isEmpty, reason: 'still pending');

        await _restoreAndConfirm(tester);

        expect(
          _revisionBodies(env),
          contains(_typed),
          reason: 'the typed text is kept as a version',
        );
        final subs = [for (final c in env.cli.calls) c.subcommand];
        expect(subs.where((s) => s == 'update'), hasLength(1));
        expect(
          subs.indexOf('update'),
          lessThan(subs.indexOf('guide restore')),
          reason: 'the edit is stored before the restore replaces it',
        );
        final update = env.cli.callsFor('update').single;
        expect(update.stdinBody, _typed);
        expect(update.flag('expected-version'), '$guideVersion');
        // The restore ran on the version the flush stored.
        expect(_storedBody(env), guidePreviousBody);
        final editor = env.h.read(editorControllerProvider);
        expect(editor.contentMd, guidePreviousBody);
        expect(editor.lastSavedVersion, guideVersion + 2);
        expect(editor.status, SaveStatus.clean);
      },
    );

    testWidgets(
      'the flushed edit is not saved a second time when the debounce would have fired',
      (tester) async {
        final env = await _openGuideActivity(tester);
        await _typePending(tester, _typed);

        await _restoreAndConfirm(tester);
        env.h.clock.advance(const Duration(seconds: 2));
        await tester.pump(const Duration(seconds: 2));
        await pumpFrames(tester);

        expect(env.cli.callsFor('update'), hasLength(1));
        expect(_storedBody(env), guidePreviousBody);
        expect(
          env.h.read(editorControllerProvider).contentMd,
          guidePreviousBody,
        );
      },
    );

    testWidgets('with no pending edit Restore saves nothing first', (
      tester,
    ) async {
      final env = await _openGuideActivity(tester);

      await _restoreAndConfirm(tester);

      expect(env.cli.callsFor('update'), isEmpty);
      expect(env.cli.callsFor('guide restore'), hasLength(1));
      expect(env.feedback.callsTo('restoreGuide'), hasLength(1));
      expect(env.h.read(editorControllerProvider).contentMd, guidePreviousBody);
    });

    testWidgets(
      'a failed flush leaves the note and the pending edit unchanged and restores nothing',
      (tester) async {
        final env = await _openGuideActivity(tester);
        env.cli.on(
          'update',
          (_) => FakeMemexCli.error('internal', 'disk is full'),
        );
        await _typePending(tester, _typed);

        await _restoreAndConfirm(tester);

        expect(tester.takeException(), isNull);
        expect(env.feedback.callsTo('restoreGuide'), isEmpty);
        expect(env.cli.callsFor('guide restore'), isEmpty);
        expect(_storedBody(env), guideBody, reason: 'the note is unchanged');
        expect(_revisionBodies(env), isNot(contains(_typed)));
        final editor = env.h.read(editorControllerProvider);
        expect(editor.contentMd, _typed, reason: 'the typed text stays');
        expect(editor.status, SaveStatus.error);
        expect(editor.lastSavedVersion, guideVersion);
        expect(editorBodyText(tester), _typed);
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text('update failed: disk is full'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a flush that waits behind an earlier save stops the Restore and tells the person to retry',
      (tester) async {
        final env = await _openGuideActivity(tester);
        final gate = Completer<void>();
        // The first save is slow: it is in flight while the next edit waits.
        env.cli.on('update', (_) async {
          await gate.future;
          return FakeMemexCli.ok(
            jsonEncode({
              'vault_id': '01HV0000000000000000000000',
              'note_id': guideNoteId,
              'version': guideVersion + 1,
              'updated_at': 1759478400000,
            }),
          );
        });
        await _typePending(tester, 'first words');
        env.h.clock.advance(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        expect(env.cli.callsFor('update'), hasLength(1), reason: 'in flight');
        await _typePending(tester, 'first words and more');

        await _restoreAndConfirm(tester);

        expect(env.feedback.callsTo('restoreGuide'), isEmpty);
        expect(env.cli.callsFor('guide restore'), isEmpty);
        expect(editorBodyText(tester), 'first words and more');
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text('Could not save your changes first.'),
          ),
          findsOneWidget,
        );
        gate.complete();
        await pumpFrames(tester);
      },
    );
  });

  group('EditorController.flushPendingSaveAndWait', () {
    testWidgets('is true and saves nothing when no save is pending', (
      tester,
    ) async {
      final env = await _openGuideActivity(tester);
      final controller = env.h.read(editorControllerProvider.notifier);

      final result = await tester.runAsync(
        () => controller.flushPendingSaveAndWait(),
      );

      expect(result, isTrue);
      expect(env.cli.callsFor('update'), isEmpty);
    });

    testWidgets(
      'is true once the flushed save landed, and the editor is clean',
      (tester) async {
        final env = await _openGuideActivity(tester);
        await _typePending(tester, _typed);
        final controller = env.h.read(editorControllerProvider.notifier);

        final result = await tester.runAsync(
          () => controller.flushPendingSaveAndWait(),
        );
        await tester.pump();

        expect(result, isTrue);
        expect(env.h.read(editorControllerProvider).status, SaveStatus.clean);
        expect(_storedBody(env), _typed);
        expect(env.cli.callsFor('update'), hasLength(1));
      },
    );

    testWidgets('is false when the flushed save failed', (tester) async {
      final env = await _openGuideActivity(tester);
      env.cli.on('update', (_) => FakeMemexCli.error('internal', 'no space'));
      await _typePending(tester, _typed);
      final controller = env.h.read(editorControllerProvider.notifier);

      final result = await tester.runAsync(
        () => controller.flushPendingSaveAndWait(),
      );
      await tester.pump();

      expect(result, isFalse);
      expect(env.h.read(editorControllerProvider).status, SaveStatus.error);
      expect(env.h.read(editorControllerProvider).contentMd, _typed);
    });

    testWidgets('a second call right after a flush is true and saves nothing', (
      tester,
    ) async {
      final env = await _openGuideActivity(tester);
      await _typePending(tester, _typed);
      final controller = env.h.read(editorControllerProvider.notifier);

      final results = await tester.runAsync(() async {
        final a = await controller.flushPendingSaveAndWait();
        final b = await controller.flushPendingSaveAndWait();
        return [a, b];
      });
      await tester.pump();

      expect(results, [true, true]);
      expect(env.cli.callsFor('update'), hasLength(1));
    });
  });
}
