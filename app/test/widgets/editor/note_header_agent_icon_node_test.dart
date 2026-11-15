// Mutation-batch follow-up (run 20261113-1, ticket #1): the agent read-only
// icon owns its semantics node. Its Semantics widget is a container, so the
// label `Read-only for agents` sits on a node of its own, sized to the icon,
// and is not merged into an ancestor node (the title row or the page).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/widgets/agent_edits_keys.dart';
import 'package:open_memex_app/src/widgets/editor/note_header.dart';

import '../../support/agent_edits_fakes.dart';
import '../../support/app_harness.dart' show pumpFrames;
import '../../support/fake_vault_db.dart';
import '../../support/font_fetch_hold.dart';

const _mutNoteId = '01JMUTBATCHHEADER0000000A1';

void main() {
  holdFontFetches();

  testWidgets(
    'the agent read-only icon keeps its own semantics node apart from its ancestors',
    (tester) async {
      final db = FakeVaultDb.v5()
        ..seedNote(
          id: _mutNoteId,
          title: 'Pricing notes',
          content: 'Pricing.',
          role: 'topic',
          version: 4,
        )
        ..setAgentReadOnlyForTest(_mutNoteId, true);
      final note = Note(
        id: _mutNoteId,
        title: 'Pricing notes',
        contentMd: 'Pricing.',
        frontmatter: '{"role":"topic"}',
        version: 4,
        createdAt: 1759500000000,
        updatedAt: 1759500000000,
        tags: const [],
        agentReadOnly: true,
      );
      final ctrl = TextEditingController(text: note.title);
      addTearDown(ctrl.dispose);
      await pumpAgentEdits(
        tester,
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            child: NoteHeader(
              note: note,
              titleCtrl: ctrl,
              onTitleChanged: (_) {},
            ),
          ),
        ),
        db: db,
        noteId: _mutNoteId,
        surfaceSize: const Size(600, 400),
      );
      await pumpFrames(tester);

      final icon = find.byKey(agentReadOnlyIconKey);
      expect(icon, findsOneWidget);
      final node = tester.getSemantics(icon);
      final iconRect = tester.getRect(icon);
      expect(node.label, 'Read-only for agents');
      expect(node.childrenCount, 0, reason: 'the label sits on a leaf');
      expect(node.rect.size, iconRect.size);
      // The container Semantics gives the icon a node of its own: its parent
      // is that container, as small as the icon and holding only the leaf, not
      // the page level node the title row shares with the other controls.
      final parent = node.parent;
      expect(parent, isNotNull);
      expect(parent!.label, isEmpty, reason: 'the label is not merged upward');
      expect(parent.childrenCount, 1);
      expect(parent.rect.size, iconRect.size);
    },
  );
}
