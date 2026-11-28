// WI #13 (Spec #7 A1, review watch list): a toggle moves `content_revision`
// (the vault revision) but not the note's version. The open `NoteEditor`
// hydrates on a note id change only (note_editor.dart `_hydrate`), so the
// text being typed survives the bump, and the re-read note carries the new
// flag. Pumped through the frozen `pumpAgentEdits` seam.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/note_edits_state.dart';
import 'package:open_memex_app/src/state/today_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../support/agent_edits_fakes.dart';
import '../support/app_harness.dart' show pumpFrames;
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';

const _wi13Note = '01JAGENTEDITSRELOAD0000013';
const _wi13Title = 'Pricing notes';
const _wi13Typed = 'Pricing notes, my working title';

void main() {
  holdFontFetches();

  testWidgets(
    'the editor does not reload its text when a toggle moves the vault revision but not the note version',
    (tester) async {
      final db = FakeVaultDb.v5()
        ..seedNote(
          id: _wi13Note,
          title: _wi13Title,
          content: 'Pricing.',
          role: 'topic',
          version: 5,
        );
      final h = await pumpAgentEdits(
        tester,
        NoteEditor(rightPanelOpen: false, onToggleRightPanel: () {}),
        db: db,
        noteId: _wi13Note,
        surfaceSize: const Size(1200, 800),
      );
      await pumpFrames(tester);
      final title = find.byKey(const Key('editor-title'));
      expect(title, findsOneWidget);
      expect(tester.widget<TextField>(title).controller!.text, _wi13Title);

      await tester.enterText(title, _wi13Typed);
      await tester.pump();
      expect(h.read(editorControllerProvider).status, SaveStatus.dirty);

      await h.read(noteEditsActionsProvider).setAgentReadOnly(_wi13Note, true);
      await pumpFrames(tester);

      expect(h.bumps, 1);
      expect(h.notes.setAgentReadOnlyCalls, hasLength(1));
      final reread = h.read(editorNoteAsyncProvider).valueOrNull?.value;
      expect(reread?.agentReadOnly, isTrue);
      expect(reread?.version, 5);
      expect(tester.widget<TextField>(title).controller!.text, _wi13Typed);
      final editor = h.read(editorControllerProvider);
      expect(editor.title, _wi13Typed);
      expect(editor.status, SaveStatus.dirty);
      expect(editor.lastSavedVersion, 5);
      expect(h.read(selectedNoteIdProvider), _wi13Note);
    },
  );
}
