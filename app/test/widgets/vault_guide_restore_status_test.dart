// WI #262 (F10), fix round r2: Restore only goes on when the editor holds
// nothing unsaved. A first Restore whose flushed save failed, an earlier
// debounced save that failed or conflicted, and a save still in flight all
// stop the Restore: nothing is replaced, the typed text stays on screen, and
// the person is told why (a retry would otherwise drop the text unrecorded).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';

import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/review_fakes.dart';
import '../support/segment_editing_finder.dart';
import '../support/today_cli_fakes.dart';
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

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(editorBodyKey), text);
  await tester.pump();
}

/// Lets the 500 ms save debounce fire and the save settle.
Future<void> _letDebounceFire(WidgetTester tester, GuideEnv env) async {
  env.h.clock.advance(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));
  await pumpFrames(tester);
}

Future<void> _restoreAndConfirm(WidgetTester tester) async {
  await _tap(tester, find.byKey(const Key('guide-restore-ac-1')));
  await _tap(tester, find.byKey(_confirm));
}

/// Runs the snackbar (4 s) out so the next Restore tap is not covered.
Future<void> _clearSnackbar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6));
  await pumpFrames(tester);
}

/// A slow `memex update` that lands one version above the guide.
Future<MemexResult> _slowUpdate(Completer<void> gate) async {
  await gate.future;
  return FakeMemexCli.ok(
    jsonEncode({
      'vault_id': '01HV0000000000000000000000',
      'note_id': guideNoteId,
      'version': guideVersion + 1,
      'updated_at': 1759478400000,
    }),
  );
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

Finder _snack(String text) =>
    find.descendant(of: find.byType(SnackBar), matching: find.text(text));

void _expectNothingRestored(GuideEnv env, WidgetTester tester, String text) {
  expect(tester.takeException(), isNull);
  expect(env.feedback.callsTo('restoreGuide'), isEmpty);
  expect(env.cli.callsFor('guide restore'), isEmpty);
  expect(_storedBody(env), guideBody, reason: 'the note is unchanged');
  expect(_revisionBodies(env), isNot(contains(text)));
  expect(env.h.read(editorControllerProvider).contentMd, text);
  expect(editorBodyText(tester), text);
}

void main() {
  group('Restore retried after a Restore whose flushed save failed', () {
    testWidgets(
      'a second Restore after a failed flush stops again and keeps the typed text',
      (tester) async {
        final env = await _openGuideActivity(tester);
        env.cli.on(
          'update',
          (_) => FakeMemexCli.error('internal', 'disk is full'),
        );
        await _type(tester, _typed);

        await _restoreAndConfirm(tester);
        expect(_snack('update failed: disk is full'), findsOneWidget);
        expect(env.cli.callsFor('update'), hasLength(1));
        await _clearSnackbar(tester);

        await _restoreAndConfirm(tester);

        _expectNothingRestored(env, tester, _typed);
        expect(env.h.read(editorControllerProvider).status, SaveStatus.error);
        expect(
          _snack('update failed: disk is full'),
          findsOneWidget,
          reason: 'the retry tells the person why too',
        );
        expect(
          env.cli.callsFor('update'),
          hasLength(1),
          reason: 'nothing is pending, so the retry saves nothing new',
        );
      },
    );

    testWidgets(
      'a Restore after the failed text was edited and saved keeps that text as a version',
      (tester) async {
        final env = await _openGuideActivity(tester);
        env.cli.on(
          'update',
          (_) => FakeMemexCli.error('internal', 'disk is full'),
        );
        await _type(tester, _typed);
        await _restoreAndConfirm(tester);
        await _clearSnackbar(tester);

        // The disk recovers and the next edit is saved by the debounce.
        env.cli.onUpdateWrites(env.db);
        await _type(tester, '$_typed again');
        await _letDebounceFire(tester, env);
        expect(env.h.read(editorControllerProvider).status, SaveStatus.clean);

        await _restoreAndConfirm(tester);

        expect(env.feedback.callsTo('restoreGuide'), hasLength(1));
        expect(_revisionBodies(env), contains('$_typed again'));
        expect(
          env.h.read(editorControllerProvider).contentMd,
          guidePreviousBody,
        );
      },
    );
  });

  group('Restore started while the editor holds unsaved text', () {
    testWidgets(
      'Restore after an ordinary debounced save failed stops and keeps the text',
      (tester) async {
        final env = await _openGuideActivity(tester);
        env.cli.on('update', (_) => FakeMemexCli.error('internal', 'no space'));
        await _type(tester, _typed);
        await _letDebounceFire(tester, env);
        expect(env.h.read(editorControllerProvider).status, SaveStatus.error);
        expect(env.cli.callsFor('update'), hasLength(1));

        await _restoreAndConfirm(tester);

        _expectNothingRestored(env, tester, _typed);
        expect(env.h.read(editorControllerProvider).status, SaveStatus.error);
        expect(_snack('update failed: no space'), findsOneWidget);
        expect(env.cli.callsFor('update'), hasLength(1));
      },
    );

    testWidgets('Restore after a save conflicted stops and keeps the text', (
      tester,
    ) async {
      final env = await _openGuideActivity(tester);
      env.cli.on(
        'update',
        (_) => FakeMemexCli.error('version_conflict', 'stale version'),
      );
      await _type(tester, _typed);
      await _letDebounceFire(tester, env);
      expect(env.h.read(editorControllerProvider).status, SaveStatus.conflict);

      await _restoreAndConfirm(tester);

      _expectNothingRestored(env, tester, _typed);
      expect(env.h.read(editorControllerProvider).status, SaveStatus.conflict);
      expect(
        find.descendant(of: find.byType(SnackBar), matching: find.byType(Text)),
        findsOneWidget,
        reason: 'the person is told why the Restore did not run',
      );
    });

    testWidgets(
      'Restore while a save is in flight stops and the in-flight save lands as the kept text',
      (tester) async {
        final env = await _openGuideActivity(tester);
        final gate = Completer<void>();
        env.cli.on('update', (_) => _slowUpdate(gate));
        await _type(tester, _typed);
        await _letDebounceFire(tester, env);
        expect(env.cli.callsFor('update'), hasLength(1), reason: 'in flight');
        expect(env.h.read(editorControllerProvider).status, SaveStatus.saving);

        await _restoreAndConfirm(tester);

        expect(tester.takeException(), isNull);
        expect(env.feedback.callsTo('restoreGuide'), isEmpty);
        expect(env.cli.callsFor('guide restore'), isEmpty);
        expect(editorBodyText(tester), _typed);
        expect(_snack('Could not save your changes first.'), findsOneWidget);
        expect(env.cli.callsFor('update'), hasLength(1), reason: 'no 2nd save');

        gate.complete();
        await pumpFrames(tester);
        expect(env.h.read(editorControllerProvider).status, SaveStatus.clean);
        expect(env.h.read(editorControllerProvider).contentMd, _typed);
        expect(env.feedback.callsTo('restoreGuide'), isEmpty);
      },
    );
  });

  group('EditorController.flushPendingSaveAndWait with nothing pending', () {
    testWidgets('is false when an earlier save failed, and saves nothing', (
      tester,
    ) async {
      final env = await _openGuideActivity(tester);
      env.cli.on('update', (_) => FakeMemexCli.error('internal', 'no space'));
      await _type(tester, _typed);
      await _letDebounceFire(tester, env);
      final controller = env.h.read(editorControllerProvider.notifier);

      final result = await tester.runAsync(
        () => controller.flushPendingSaveAndWait(),
      );

      expect(result, isFalse);
      expect(env.cli.callsFor('update'), hasLength(1));
      expect(env.h.read(editorControllerProvider).status, SaveStatus.error);
      expect(env.h.read(editorControllerProvider).contentMd, _typed);
    });

    testWidgets('is false when an earlier save conflicted, and saves nothing', (
      tester,
    ) async {
      final env = await _openGuideActivity(tester);
      env.cli.on(
        'update',
        (_) => FakeMemexCli.error('version_conflict', 'stale version'),
      );
      await _type(tester, _typed);
      await _letDebounceFire(tester, env);
      final controller = env.h.read(editorControllerProvider.notifier);

      final result = await tester.runAsync(
        () => controller.flushPendingSaveAndWait(),
      );

      expect(result, isFalse);
      expect(env.cli.callsFor('update'), hasLength(1));
      expect(env.h.read(editorControllerProvider).status, SaveStatus.conflict);
    });

    testWidgets(
      'is false while a save is in flight, and does not wait for it',
      (tester) async {
        final env = await _openGuideActivity(tester);
        final gate = Completer<void>();
        env.cli.on('update', (_) => _slowUpdate(gate));
        await _type(tester, _typed);
        await _letDebounceFire(tester, env);
        final controller = env.h.read(editorControllerProvider.notifier);
        expect(env.h.read(editorControllerProvider).status, SaveStatus.saving);

        final result = await tester.runAsync(
          () => controller.flushPendingSaveAndWait(),
        );

        expect(result, isFalse);
        expect(env.cli.callsFor('update'), hasLength(1));
        gate.complete();
        await pumpFrames(tester);
      },
    );

    testWidgets('is true once an earlier save landed', (tester) async {
      final env = await _openGuideActivity(tester);
      await _type(tester, _typed);
      await _letDebounceFire(tester, env);
      expect(env.h.read(editorControllerProvider).status, SaveStatus.clean);
      final controller = env.h.read(editorControllerProvider.notifier);

      final result = await tester.runAsync(
        () => controller.flushPendingSaveAndWait(),
      );

      expect(result, isTrue);
      expect(env.cli.callsFor('update'), hasLength(1));
    });
  });
}
