// WI #69 (D12): vault_state.dart's data providers move into
// `state/{notes_list,note,canvas,links}_state.dart` and stay re-exported from
// vault_state.dart. These imports fail to load until the split exists.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/canvas_state.dart' as canvas;
import 'package:open_memex_app/src/state/links_state.dart' as links;
import 'package:open_memex_app/src/state/note_state.dart' as note;
import 'package:open_memex_app/src/state/notes_list_state.dart' as notes_list;
import 'package:open_memex_app/src/state/vault_state.dart' as vault;

import '../support/fake_vault_db.dart';

void main() {
  group('vault_state split (AC8)', () {
    test(
      'notes list state imports from notes_list_state and from vault_state',
      () {
        expect(
          identical(notes_list.notesListProvider, vault.notesListProvider),
          isTrue,
        );
        expect(
          identical(notes_list.sidebarSortProvider, vault.sidebarSortProvider),
          isTrue,
        );
        expect(notes_list.NoteSortMode.values, vault.NoteSortMode.values);
        expect(
          notes_list.NoteSortMode.alphabetical,
          same(vault.NoteSortMode.alphabetical),
        );
      },
    );

    test('note state imports from note_state and from vault_state', () {
      expect(
        identical(note.selectedNoteProvider, vault.selectedNoteProvider),
        isTrue,
      );
      expect(
        identical(note.noteTitlesProvider, vault.noteTitlesProvider),
        isTrue,
      );
      expect(
        identical(note.linkKindsProvider, vault.linkKindsProvider),
        isTrue,
      );
    });

    test(
      'canvas list state imports from canvas_state and from vault_state',
      () {
        expect(
          identical(canvas.canvasesProvider, vault.canvasesProvider),
          isTrue,
        );
        expect(
          identical(canvas.canvasDetailProvider, vault.canvasDetailProvider),
          isTrue,
        );
        // canvas_state.dart keeps its viewport, selection and zoom state.
        expect(canvas.canvasViewportProvider, isNotNull);
        expect(canvas.canvasSelectionProvider, isNotNull);
        expect(canvas.canvasZoomProvider, isNotNull);
      },
    );

    test('links state imports from links_state and from vault_state', () {
      expect(identical(links.linksOutProvider, vault.linksOutProvider), isTrue);
      expect(
        identical(links.backlinksProvider, vault.backlinksProvider),
        isTrue,
      );
      expect(identical(links.orderedLinkKinds, vault.orderedLinkKinds), isTrue);
      expect(
        identical(links.backlinkLabelForKind, vault.backlinkLabelForKind),
        isTrue,
      );
      final entry = links.BacklinkEntry(
        linkId: 'l1',
        fromNoteId: 'n1',
        fromTitle: 'From',
        kind: 'extends',
        label: null,
        source: 'manual',
      );
      expect(entry, isA<vault.BacklinkEntry>());
    });

    test('vault_state keeps the vault, revision and editor state', () {
      // Each name still resolves from vault_state.dart.
      expect(vault.currentVaultProvider, isNotNull);
      expect(vault.vaultDbProvider, isNotNull);
      expect(vault.memexCliProvider, isNotNull);
      expect(vault.vaultRevisionProvider, isNotNull);
      expect(vault.vaultOpenProvider, isNotNull);
      expect(vault.vaultV5ReadyProvider, isNotNull);
      expect(vault.selectedNoteIdProvider, isNotNull);
      expect(vault.rightPanelOpenProvider, isNotNull);
      expect(vault.SaveStatus.values, isNotEmpty);
      const editor = vault.EditorStateValue(
        title: 't',
        contentMd: 'c',
        status: vault.SaveStatus.idle,
      );
      expect(
        editor.copyWith(status: vault.SaveStatus.clean).status,
        vault.SaveStatus.clean,
      );
    });

    test('the moved providers still read the open vault', () async {
      final db = FakeVaultDb.v5()
        ..seedNote(
          id: '01J9BBBBBBBBBBBBBBBBBBBBBB',
          title: 'Beta',
          content: 'b\n',
        )
        ..seedNote(
          id: '01J9AAAAAAAAAAAAAAAAAAAAAA',
          title: 'alpha',
          content: 'a\n',
        );
      final c = ProviderContainer(
        overrides: [
          vault.vaultDbProvider.overrideWithValue(db),
          vault.currentVaultProvider.overrideWith(
            (_) => const vault.LocalVaultRef('/tmp/om-86-split'),
          ),
          vault.memexCliProvider.overrideWithValue(null),
        ],
      );
      addTearDown(db.close);
      addTearDown(c.dispose);

      c.read(notes_list.sidebarSortProvider.notifier).state =
          notes_list.NoteSortMode.alphabetical;
      await c.read(notes_list.notesListAsyncProvider.future);
      expect(
        [for (final n in c.read(notes_list.notesListProvider)) n.title],
        ['alpha', 'Beta'],
      );
      expect(c.read(note.noteTitlesProvider), hasLength(2));
      expect(c.read(canvas.canvasesProvider), isEmpty);
      expect(
        c.read(links.linksOutProvider('01J9AAAAAAAAAAAAAAAAAAAAAA')),
        isEmpty,
      );
      expect(links.orderedLinkKinds(['zeta', 'extends', 'references']), [
        'references',
        'extends',
        'zeta',
      ]);
      expect(links.backlinkLabelForKind('contradicts'), 'Contradicted by');
    });
  });
}
