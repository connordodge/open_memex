// Mutation-batch follow-up (run 20261113-1, ticket #1): when the open note
// editor is in Source mode, its field follows text the editor took from the
// server only while the field still shows the editor's previous text, so the
// next keystroke builds on the server's text.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../robots/segmented_editor_robot.dart' show fixtureTopicId;
import '../support/app_harness.dart';
import '../support/font_fetch_hold.dart';
import '../support/spelling_editor_pump.dart';

const _mutBase = 'Alpha\nBravo\n';
const _mutServer = 'Zero\nAlpha\nBravo\n';

void _mutServerWrites(WorkspaceHarness h, String body, int version) {
  h.db.db.execute('UPDATE notes SET content_md = ?, version = ? WHERE id = ?', [
    body,
    version,
    fixtureTopicId,
  ]);
}

void main() {
  holdFontFetches();

  testWidgets(
    'Source mode follows a polled server change when it shows the previous editor text',
    (tester) async {
      final s = await pumpSpellingEditor(tester, body: _mutBase, source: true);
      expect(find.byType(NoteEditor), findsOneWidget);
      final controller = tester.widget<EditableText>(s.sourceField).controller;
      expect(controller.text, _mutBase);
      _mutServerWrites(s.workspace, _mutServer, 5);

      final changed = await s.container
          .read(editorControllerProvider.notifier)
          .serverChanged(fixtureTopicId);
      await pumpFrames(tester);

      expect(changed, isTrue);
      expect(s.container.read(editorControllerProvider).contentMd, _mutServer);
      expect(controller.text, _mutServer);
    },
  );
}
