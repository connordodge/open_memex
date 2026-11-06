// WI #262 (F10) journey: open the Vault Guide from the Topics sidebar, then
// edit and save its body in the normal editor. The title stays read-only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';

import '../support/app_harness.dart';
import '../support/segment_editing_finder.dart';
import '../support/vault_guide_fixture.dart';

void main() {
  testWidgets(
    'the journey opens the Vault Guide from the sidebar then edits and saves its body',
    (tester) async {
      final env = await launchGuideWorkspace(tester);

      expect(find.byKey(const Key('vault-guide-row')), findsOneWidget);
      await tester.tap(find.byKey(const Key('vault-guide-row')));
      await pumpFrames(tester);

      expect(env.tabs.followed, [const NoteTab(guideNoteId)]);
      expect(env.h.read(activeTabProvider), const NoteTab(guideNoteId));
      expect(
        env.h.read(editorControllerProvider.notifier).activeNoteId,
        guideNoteId,
      );
      expect(find.byKey(const Key('guide-title')), findsOneWidget);
      expect(find.byKey(const Key('editor-title')), findsNothing);
      expect(editorBodyText(tester), guideBody);

      await tester.enterText(
        find.byKey(editorBodyKey),
        '$guideBody\nA new rule.',
      );
      await tester.pump();
      env.h.clock.advance(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      await pumpFrames(tester);

      final update = env.cli.callsFor('update').single;
      expect(update.flag('note-id'), guideNoteId);
      expect(update.flag('expected-version'), '$guideVersion');
      expect(update.stdinBody, '$guideBody\nA new rule.');
      expect(env.h.read(editorControllerProvider).status, SaveStatus.clean);
      expect(
        env.db.db.select('SELECT content_md, version FROM notes WHERE id = ?', [
          guideNoteId,
        ]).first['content_md'],
        '$guideBody\nA new rule.',
      );
      expect(find.byKey(const Key('inline-error')), findsNothing);
    },
  );

  testWidgets(
    'the guide title keeps its name through an edit and save of the body',
    (tester) async {
      final env = await launchGuideWorkspace(tester);
      expect(find.byKey(const Key('vault-guide-row')), findsOneWidget);
      await tester.tap(find.byKey(const Key('vault-guide-row')));
      await pumpFrames(tester);

      await tester.enterText(find.byKey(editorBodyKey), 'rewritten');
      await tester.pump();
      env.h.clock.advance(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      await pumpFrames(tester);

      expect(env.cli.callsFor('update').single.flag('title'), guideNoteTitle);
      expect(
        env.db.db.select('SELECT title FROM notes WHERE id = ?', [
          guideNoteId,
        ]).first['title'],
        guideNoteTitle,
      );
    },
  );
}
