// WI #262 (F10), verify round: the error and race paths of the Vault Guide row
// and of Restore that the red-mode tests left unpinned. A failure that is not
// a MemexException shows its own text; an unreachable server shows the guard
// snackbar and changes nothing; a Restore whose Activity entry is gone before
// the person confirms restores nothing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/smart_folder_actions.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';

import '../support/app_harness.dart';
import '../support/review_fakes.dart';
import '../support/topics_seed.dart';
import '../support/vault_guide_fixture.dart';

const _unreachable = VaultUnreachableException(
  serverName: 'nas',
  mayHaveCommitted: false,
);

const _row = Key('vault-guide-row');
const _restoreAc1 = Key('guide-restore-ac-1');
const _confirm = Key('guide-restore-confirm');

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

void main() {
  group('the Vault Guide row error paths', () {
    testWidgets(
      'a guide failure that is not a CLI error shows its own text in the Topics inline error',
      (tester) async {
        final env = await launchGuideWorkspace(tester);
        env.feedback.failNext('guide', const FormatException('guide is odd'));

        await tester.tap(find.byKey(_row));
        await pumpFrames(tester);

        expect(env.tabs.followed, isEmpty);
        expect(
          env.h.read(smartFolderErrorProvider),
          'FormatException: guide is odd',
        );
        expect(find.byKey(const Key('inline-error')), findsOneWidget);
      },
    );

    testWidgets(
      'with no memex CLI configured clicking the Vault Guide row tells the person in the Topics error',
      (tester) async {
        final env = await launchGuideWorkspace(tester, memexConfigured: false);

        await tester.tap(find.byKey(_row));
        await pumpFrames(tester);

        expect(
          env.h.read(smartFolderErrorProvider),
          'The memex CLI is not available.',
        );
        expect(find.byKey(const Key('inline-error')), findsOneWidget);
        expect(env.tabs.followed, isEmpty);
      },
    );

    testWidgets(
      'a CLI failure shows exactly the CLI message in the Topics error state',
      (tester) async {
        final env = await launchGuideWorkspace(tester);
        env.feedback.failNext(
          'guide',
          MemexException('guide get failed: disk full', code: 'internal'),
        );

        await tester.tap(find.byKey(_row));
        await pumpFrames(tester);

        expect(
          env.h.read(smartFolderErrorProvider),
          'guide get failed: disk full',
        );
      },
    );

    testWidgets(
      'an unreachable vault server shows the snackbar, follows nothing and sets no Topics error',
      (tester) async {
        final env = await launchGuideWorkspace(tester);
        env.feedback.failNext('guide', _unreachable);

        await tester.tap(find.byKey(_row));
        await pumpFrames(tester);

        expect(find.text("couldn't reach nas. try again."), findsOneWidget);
        expect(env.tabs.followed, isEmpty);
        expect(env.h.read(smartFolderErrorProvider), isNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('an unreachable guide does not clear an earlier Topics error', (
      tester,
    ) async {
      final env = await launchGuideWorkspace(tester);
      env.feedback.failNext(
        'guide',
        MemexException('guide get failed: first', code: 'internal'),
      );
      await tester.tap(find.byKey(_row));
      await pumpFrames(tester);
      env.feedback.failNext('guide', _unreachable);

      await tester.tap(find.byKey(_row));
      await pumpFrames(tester);

      expect(env.tabs.followed, isEmpty);
      expect(env.h.read(smartFolderErrorProvider), 'guide get failed: first');
    });
  });

  group('Restore error paths', () {
    testWidgets(
      'a failed Restore tells the person the CLI message in a snackbar',
      (tester) async {
        final env = await _openGuideActivity(tester);
        env.feedback.failNext(
          'restoreGuide',
          MemexException('guide restore failed: gone', code: 'not_found'),
        );

        await _tap(tester, find.byKey(_restoreAc1));
        await _tap(tester, find.byKey(_confirm));

        expect(find.text('guide restore failed: gone'), findsOneWidget);
        expect(env.h.read(editorControllerProvider).contentMd, guideBody);
      },
    );

    testWidgets(
      'a Restore failure that is not a CLI error shows its own text in a snackbar',
      (tester) async {
        final env = await _openGuideActivity(tester);
        env.feedback.failNext(
          'restoreGuide',
          const FormatException('restore is odd'),
        );

        await _tap(tester, find.byKey(_restoreAc1));
        await _tap(tester, find.byKey(_confirm));

        expect(find.text('FormatException: restore is odd'), findsOneWidget);
        expect(env.h.read(editorControllerProvider).contentMd, guideBody);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'an unreachable vault server on Restore shows the guard snackbar and leaves the editor alone',
      (tester) async {
        final env = await _openGuideActivity(tester);
        env.feedback.failNext('restoreGuide', _unreachable);

        await _tap(tester, find.byKey(_restoreAc1));
        await _tap(tester, find.byKey(_confirm));

        expect(find.text("couldn't reach nas. try again."), findsOneWidget);
        expect(env.h.read(editorControllerProvider).contentMd, guideBody);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'confirming Restore after the Activity entry is gone restores nothing',
      (tester) async {
        final env = await _openGuideActivity(tester);
        await _tap(tester, find.byKey(_restoreAc1));
        expect(find.byKey(_confirm), findsOneWidget);
        // The person (or a sync) moves the tab to another note while the
        // dialog is still up: the guide's Activity entry is disposed.
        env.h.container
            .read(tabsProvider.notifier)
            .openOrFocus(const NoteTab(TP.loop));
        await pumpFrames(tester);
        expect(find.byKey(_restoreAc1), findsNothing);

        await tester.tap(find.byKey(_confirm));
        await pumpFrames(tester);

        expect(env.feedback.callsTo('restoreGuide'), isEmpty);
        expect(env.cli.callsFor('guide restore'), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
