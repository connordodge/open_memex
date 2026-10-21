// WI #22 (A5), beyond the ACs: the unsaved virtual Today note has no meta
// rail and no review chip (it was never updated or reviewed), while a saved
// daily note keeps both.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/today_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/widgets/editor/note_header.dart';

import '../support/fake_clock.dart';
import '../support/fake_vault_db.dart';

Future<void> _pump(WidgetTester tester, Note note) async {
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        clockProvider.overrideWithValue(FakeClock()),
        currentVaultProvider.overrideWith((_) => LocalVaultRef('/vaults/v')),
        vaultDbProvider.overrideWithValue(db),
        memexCliProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: NoteHeader(
              note: note,
              titleCtrl: TextEditingController(text: note.title),
              onTitleChanged: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  // TEST-CHANGE (#78): the review chip reads reviewStateAsyncProvider; one
  // pump lets that read land (so the virtual Today case's findsNothing is
  // not just a still-loading read).
  await tester.pump();
}

void main() {
  testWidgets(
    'the virtual Today note header shows the date and badge but no updated meta rail and no review chip',
    (tester) async {
      await _pump(tester, virtualTodayNote('2026-10-03'));

      expect(find.text('Saturday, 3 October 2026'), findsOneWidget);
      expect(find.byKey(const Key('daily-today-badge')), findsOneWidget);
      expect(find.textContaining('updated '), findsNothing);
      expect(find.byKey(const Key('review-chip')), findsNothing);
      expect(find.byKey(const Key('editor-title')), findsNothing);
    },
  );

  testWidgets(
    'a saved daily note header keeps the updated meta rail and the review chip',
    (tester) async {
      await _pump(
        tester,
        Note(
          id: '01J9TTTTTTTTTTTTTTTTTTTTTT',
          title: '2026-10-03',
          contentMd: 'Morning pages\n',
          frontmatter: '{"role":"daily"}',
          version: 3,
          createdAt: 1759474800000,
          updatedAt: 1759474800000,
          tags: const [],
        ),
      );

      expect(find.textContaining('updated '), findsOneWidget);
      expect(find.byKey(const Key('review-chip')), findsOneWidget);
      expect(find.text('Saturday, 3 October 2026'), findsOneWidget);
    },
  );
}
