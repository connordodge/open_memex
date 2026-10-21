// WI #87 (W3, verify): `rebaseEditorOnVersion` is async now (it reads the
// stored note through VaultAccess.notes) and its callers leave it unawaited.
// A rebase that finishes after the user opened another note must not load the
// first daily note back into the editor: that would put the old note id,
// version and text under the note on screen and the next save would write the
// wrong note.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';

import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/footer_cli_fakes.dart';
import '../support/today_cli_fakes.dart';
import '../support/topics_access_doubles.dart';
import '../support/topics_launch.dart';

const _today = '2026-10-03';
const _todayId = 'daily-2026-10-03';
const _earlier = '2026-09-30';
const _earlierId = 'daily-2026-09-30';

void main() {
  testWidgets(
    'a rebase that finishes after the user opened another note does not load the first note back into the editor',
    (tester) async {
      final db = FakeVaultDb.v5()
        ..seedDailyNote(_today, id: _todayId)
        ..seedDailyNote(_earlier, id: _earlierId);
      final cli = FakeMemexCli()
        ..onUpdateWrites(db)
        ..onAddCreates(db)
        ..onFooterAdd(db);
      late RecordingNotesAccess notes;
      final doubles = AccessDoubles(configureNotes: (_, n) => notes = n);
      final r = await launchTopics(
        tester,
        doubles,
        db: db,
        cli: cli,
        topicsMode: false,
      );
      final h = r.h;
      h.read(tabsProvider.notifier).openOrFocus(const NoteTab(_earlierId));
      await pumpFrames(tester);

      // Hold the rebase's read of the stored note.
      h.read(vaultAccessProvider); // builds the recording doubles
      final heldBefore = notes.callsTo('getNote').length;
      notes.gate('getNote');
      final body = find.descendant(
        of: find.byKey(const Key('editor-body')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(body, 'Slept badly [[Sleep');
      await tester.pump();
      await tester.tap(find.byKey(const Key('wikilink-popover-create')));
      await pumpFrames(tester);
      // TEST-CHANGE (#78): the selected note is read through
      // VaultAccess.notes too, and the create's revision bump refreshes it.
      // Two reads are held: the rebase's (first) and that refresh (second).
      // The refresh lands now, so only the rebase stays pending.
      expect(
        notes.callsTo('getNote').length,
        heldBefore + 2,
        reason: 'the rebase is waiting on its read',
      );
      expect(notes.gates['getNote'], hasLength(2));
      notes.ungate('getNote');
      notes.gates['getNote']!.removeAt(1).complete();
      await pumpFrames(tester);
      expect(
        h.read(editorControllerProvider).lastSavedVersion,
        1,
        reason: 'the held read is the rebase: it has not rebased yet',
      );

      // The user opens the other daily note while the rebase is pending.
      h.read(tabsProvider.notifier).openOrFocus(const NoteTab(_todayId));
      await pumpFrames(tester);
      expect(h.read(editorControllerProvider).title, _today);

      notes.gates['getNote']!.single.complete();
      await pumpFrames(tester);

      final editor = h.read(editorControllerProvider);
      expect(
        editor.title,
        _today,
        reason: 'the editor still holds the note on screen',
      );
      expect(editor.contentMd, isNot(contains('Slept badly')));
    },
  );
}
