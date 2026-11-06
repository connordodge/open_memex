// WI #262 (F10): the fixed `Vault Guide` row at the top of the Topics sidebar.
// It shows on a V6 vault only, and a click takes the navigation seam before
// the `guide()` await (D8, D24), then follows the guide note. Click tests
// assert `tabs.followed` on a TabsRecorder, never tab counts.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/smart_folder_actions.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/topics_access_doubles.dart';
import '../support/topics_seed.dart';
import '../support/vault_guide_fixture.dart';

const _row = Key('vault-guide-row');
const _pane = Key('topics-pane');

Future<void> _tapRow(WidgetTester tester) async {
  expect(find.byKey(_row), findsOneWidget);
  await tester.tap(find.byKey(_row));
  await pumpFrames(tester);
}

void main() {
  group('Vault Guide row shows on V6 only (AC1)', () {
    testWidgets(
      'the Vault Guide row shows at the top of the Topics sidebar on a V6 vault',
      (tester) async {
        await launchGuideWorkspace(tester);

        final row = find.byKey(_row);
        expect(row, findsOneWidget);
        expect(
          find.descendant(of: row, matching: find.text('Vault Guide')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: find.byKey(_pane), matching: row),
          findsOneWidget,
          reason: 'the row lives in the Topics pane',
        );
        // At the top: above the Smart Folder tree and below nothing of it.
        final firstFolder = find.byKey(Key('topics-folder-${TP.games}'));
        expect(firstFolder, findsOneWidget);
        expect(
          tester.getTopLeft(row).dy,
          lessThan(tester.getTopLeft(firstFolder).dy),
        );
      },
    );

    testWidgets('the Vault Guide row is full width in the Topics pane', (
      tester,
    ) async {
      await launchGuideWorkspace(tester);

      expect(find.byKey(_row), findsOneWidget);
      final paneWidth = tester.getSize(find.byKey(_pane)).width;
      final rowSize = tester.getSize(find.byKey(_row));
      expect(
        rowSize.width,
        greaterThanOrEqualTo(paneWidth - 16),
        reason: 'full width: the pane is $paneWidth wide',
      );
      expect(rowSize.width, lessThanOrEqualTo(paneWidth));
      expect(rowSize.height, greaterThan(0));
    });

    testWidgets(
      'a vault below V6 shows no Vault Guide row until it is migrated to V6',
      (tester) async {
        final db = guideDb(v6: false);
        final env = await launchGuideWorkspace(tester, db: db);
        expect(find.byKey(_row), findsNothing);
        expect(find.byKey(_pane), findsOneWidget);
        expect(find.byKey(Key('topics-folder-${TP.games}')), findsOneWidget);

        db.migrateToV6();
        env.h.container.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);

        expect(find.byKey(_row), findsOneWidget);
      },
    );
  });

  group('the guide is not an Unsorted row (AC5)', () {
    testWidgets(
      'the Topics sidebar lists the guide only as the Vault Guide row and not under Unsorted',
      (tester) async {
        await launchGuideWorkspace(tester);

        expect(find.byKey(Key('topics-unsorted-$guideNoteId')), findsNothing);
        expect(find.byKey(_row), findsOneWidget);
        // The other Unsorted notes are still listed.
        expect(find.byKey(Key('topics-unsorted-${TP.orphan}')), findsOneWidget);
        expect(
          find.byKey(Key('topics-unsorted-${TP.looseNote}')),
          findsOneWidget,
        );
      },
    );
  });

  group('clicking the Vault Guide row (AC2)', () {
    testWidgets(
      'clicking the Vault Guide row calls guide once and follows the guide note',
      (tester) async {
        final env = await launchGuideWorkspace(tester);

        await _tapRow(tester);

        expect(env.feedback.callsTo('guide'), hasLength(1));
        expect(env.tabs.followed, [const NoteTab(guideNoteId)]);
      },
    );

    testWidgets(
      'the Vault Guide row follows the note guide answers even when the guide is created by that call',
      (tester) async {
        final db = guideDb();
        final env = await launchGuideWorkspace(tester, db: db);
        // `guide get` creates a new guide note when there is none.
        db.db.execute("DELETE FROM notes WHERE id = '$guideNoteId'");
        env.cli.on(
          'guide get',
          (_) => FakeMemexCli.ok(
            '${jsonEncode({'vault_id': 'V', 'note_id': 'freshly-created-guide', 'version': 1, 'content_md': ''})}\n',
          ),
        );

        await _tapRow(tester);

        expect(env.tabs.followed, [const NoteTab('freshly-created-guide')]);
      },
    );

    testWidgets(
      'the navigation is taken before guide answers so a tab switch while it waits does not redirect the click',
      (tester) async {
        final env = await launchGuideWorkspace(
          tester,
          doubles: AccessDoubles(
            configureFeedback: (_, feedback) => feedback.gate('guide'),
          ),
        );
        final tabs = env.h.read(tabsProvider.notifier);
        tabs.openOrFocus(const NoteTab(TP.looseNote));
        await pumpFrames(tester);
        final clickedTabIndex = env.h.read(tabsProvider).activeIndex;
        expect(env.h.read(tabsProvider).tabs[clickedTabIndex], isA<NoteTab>());

        expect(find.byKey(_row), findsOneWidget);
        await tester.tap(find.byKey(_row));
        await pumpFrames(tester);
        expect(env.tabs.followed, isEmpty, reason: 'still waiting on guide');
        // The person switches to another note while guide is in flight.
        tabs.openOrFocus(const NoteTab(TP.orphan));
        await pumpFrames(tester);
        env.feedback.gates['guide']!.single.complete();
        await pumpFrames(tester);

        expect(env.tabs.followed, [const NoteTab(guideNoteId)]);
        final state = env.h.read(tabsProvider);
        expect(
          state.tabs[clickedTabIndex],
          const NoteTab(guideNoteId),
          reason: 'the tab that was active at the click shows the guide',
        );
        expect(
          state.tabs.where((t) => t == const NoteTab(TP.orphan)),
          isNotEmpty,
          reason: 'the note the person switched to is left alone',
        );
      },
    );

    testWidgets(
      'a failing guide shows the dismissible Topics inline error and follows nothing',
      (tester) async {
        final env = await launchGuideWorkspace(tester);
        env.feedback.failNext(
          'guide',
          MemexException('guide get failed: disk full', code: 'internal'),
        );

        await _tapRow(tester);

        expect(env.tabs.followed, isEmpty);
        final error = find.descendant(
          of: find.byKey(_pane),
          matching: find.byKey(const Key('inline-error')),
        );
        expect(error, findsOneWidget);
        expect(
          find.descendant(
            of: error,
            matching: find.textContaining('guide get failed: disk full'),
          ),
          findsOneWidget,
        );
        expect(
          env.h.read(smartFolderErrorProvider),
          contains('disk full'),
          reason: 'the Topics error state holds the CLI message',
        );

        await tester.tap(find.byKey(const Key('inline-error-dismiss')));
        await pumpFrames(tester);
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(env.tabs.followed, isEmpty);
      },
    );

    testWidgets(
      'a failing guide then a working one clears the error and follows the guide',
      (tester) async {
        final env = await launchGuideWorkspace(tester);
        env.feedback.failNext(
          'guide',
          MemexException('guide get failed: disk full', code: 'internal'),
        );
        await _tapRow(tester);
        expect(find.byKey(const Key('inline-error')), findsOneWidget);

        await _tapRow(tester);

        expect(env.tabs.followed, [const NoteTab(guideNoteId)]);
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(env.h.read(smartFolderErrorProvider), isNull);
      },
    );

    testWidgets(
      'with no memex CLI configured clicking the Vault Guide row follows nothing and throws nothing',
      (tester) async {
        final env = await launchGuideWorkspace(tester, memexConfigured: false);

        await _tapRow(tester);

        expect(env.tabs.followed, isEmpty);
        expect(tester.takeException(), isNull);
        expect(env.feedback.callsTo('guide'), isEmpty);
      },
    );

    testWidgets(
      'clicking the Vault Guide row twice follows the guide twice and never opens a tab itself',
      (tester) async {
        final env = await launchGuideWorkspace(tester);
        await _tapRow(tester);
        await _tapRow(tester);

        // Two clicks, two follows of the same target: the seam decides what
        // that means, the row never calls openOrFocus itself.
        expect(env.tabs.followed, [
          const NoteTab(guideNoteId),
          const NoteTab(guideNoteId),
        ]);
        expect(env.feedback.callsTo('guide'), hasLength(2));
      },
    );
  });
}
