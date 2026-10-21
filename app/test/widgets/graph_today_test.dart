// WI #30 (A12) with #22's virtual Today note: its tab chip reads its ISO
// date, and its note menu offers no Open graph item (the unsaved note is in
// no graph yet). Implementer tests, launched through #22's TodayRobot.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';

import '../robots/today_robot.dart';
import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/graph_access_doubles.dart';
import '../support/graph_seeds.dart';

void main() {
  testWidgets('the virtual Today tab chip reads its ISO date', (tester) async {
    final r = TodayRobot(tester);
    await r.launch(db: FakeVaultDb.v5(), cli: FakeMemexCli());
    r.expectVirtualToday('2026-10-03');

    final chip = find.byKey(const Key('tab-note-virtual-today:2026-10-03'));
    expect(chip, findsOneWidget);
    expect(
      find.descendant(of: chip, matching: find.text('2026-10-03')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chip, matching: find.text('note')),
      findsNothing,
    );
  });

  testWidgets(
    'the note menu has no Open graph item for the virtual Today note',
    (tester) async {
      final r = TodayRobot(tester);
      await r.launch(db: FakeVaultDb.v5(), cli: FakeMemexCli());
      r.expectVirtualToday('2026-10-03');

      await r.openNoteMenu();

      expect(find.byKey(const Key('note-menu')), findsOneWidget);
      expect(find.byKey(const Key('note-menu-delete')), findsOneWidget);
      expect(find.byKey(const Key('note-menu-open-graph')), findsNothing);
    },
  );

  // WI #88 (W4) AC8: a note tab chip reads its title through VaultAccess.
  // The access double renames or hides a note the database still holds, so
  // a chip read from vaultDbProvider shows the database title instead.
  group('note tab chip through VaultAccess (WI 88)', () {
    Finder chipText(String noteId, String text) => find.descendant(
      of: find.byKey(Key('tab-note-$noteId')),
      matching: find.text(text),
    );

    Future<void> openNote(WidgetTester tester, String noteId) async {
      final ref = tester.element(find.byType(Workspace)) as WidgetRef;
      ref.read(tabsProvider.notifier).openOrFocus(NoteTab(noteId));
      await pumpFrames(tester);
    }

    FakeVaultDb seeded() => FakeVaultDb.v5()..seedTopicNote(G.alpha, 'Alpha');

    testWidgets('a note tab chip reads the note title through VaultAccess', (
      tester,
    ) async {
      await pumpWorkspace(
        tester,
        db: seeded(),
        overrides: [
          wi88RewritingAccessOverride(
            noteTitles: {G.alpha: 'Alpha via access'},
          ),
        ],
      );
      await openNote(tester, G.alpha);

      expect(chipText(G.alpha, 'Alpha via access'), findsOneWidget);
      expect(chipText(G.alpha, 'Alpha'), findsNothing);
    });

    testWidgets(
      'a note tab chip reads note when VaultAccess has no such note',
      (tester) async {
        await pumpWorkspace(
          tester,
          db: seeded(),
          overrides: [
            wi88RewritingAccessOverride(hiddenNotes: {G.alpha}),
          ],
        );
        await openNote(tester, G.alpha);

        expect(chipText(G.alpha, 'note'), findsOneWidget);
        expect(chipText(G.alpha, 'Alpha'), findsNothing);
      },
    );

    testWidgets(
      'the virtual Today tab chip reads its ISO date with VaultAccess in place',
      (tester) async {
        await pumpWorkspace(tester, overrides: [wi88RewritingAccessOverride()]);

        final chip = find.byKey(const Key('tab-note-virtual-today:2026-10-03'));
        expect(chip, findsOneWidget);
        expect(
          find.descendant(of: chip, matching: find.text('2026-10-03')),
          findsOneWidget,
        );
      },
    );

    test('the workspace screen reads no vaultDbProvider', () {
      final source = File('lib/src/screens/workspace.dart').readAsStringSync();
      expect(source, isNot(contains('vaultDbProvider')));
    });
  });
}
