// WI #87 (W3, verify): `EditorController.activeNoteId` is the id of the note
// the editor holds, null when none; `rebaseEditorOnVersion` relies on it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';

Note _note(String id) => Note(
  id: id,
  title: 'Title $id',
  contentMd: 'body',
  frontmatter: '{}',
  version: 1,
  createdAt: 1759500000000,
  updatedAt: 1759500000000,
  tags: [],
);

void main() {
  test(
    'activeNoteId is null with nothing open and the open note id otherwise',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final editor = container.read(editorControllerProvider.notifier);

      expect(editor.activeNoteId, isNull);

      editor.loadNote(_note('n1'));
      expect(editor.activeNoteId, 'n1');

      editor.loadNote(_note('n2'));
      expect(editor.activeNoteId, 'n2');

      editor.loadNote(null);
      expect(editor.activeNoteId, isNull);
    },
  );
}
