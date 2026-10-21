// WI #69 (D12): vault_state.dart's data providers move into
// `state/{notes_list,note,canvas,links}_state.dart` and stay re-exported from
// vault_state.dart. These imports fail to load until the split exists.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart'
    show CanvasRow, LinkRow, NoteListItem, NoteTitle;
import 'package:open_memex_app/src/state/canvas_state.dart' as canvas;
import 'package:open_memex_app/src/state/links_state.dart' as links;
import 'package:open_memex_app/src/state/note_state.dart' as note;
import 'package:open_memex_app/src/state/notes_list_state.dart' as notes_list;
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/state/vault_state.dart' as vault;

import '../support/fake_vault_db.dart';
import '../support/vault_scoped_reads.dart';

void main() {
  group('vault_state split (AC8)', () {
    test(
      'notes list state imports from notes_list_state and from vault_state',
      () {
        expect(
          identical(
            notes_list.notesListAsyncProvider,
            vault.notesListAsyncProvider,
          ),
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
        identical(
          note.selectedNoteAsyncProvider,
          vault.selectedNoteAsyncProvider,
        ),
        isTrue,
      );
      expect(
        identical(note.noteTitlesAsyncProvider, vault.noteTitlesAsyncProvider),
        isTrue,
      );
      expect(
        identical(note.linkKindsAsyncProvider, vault.linkKindsAsyncProvider),
        isTrue,
      );
    });

    test(
      'canvas list state imports from canvas_state and from vault_state',
      () {
        // canvas_state.dart keeps its viewport, selection and zoom state.
        expect(canvas.canvasViewportProvider, isNotNull);
        expect(canvas.canvasSelectionProvider, isNotNull);
        expect(canvas.canvasZoomProvider, isNotNull);
      },
    );

    test('links state imports from links_state and from vault_state', () {
      expect(
        identical(links.linksOutAsyncProvider, vault.linksOutAsyncProvider),
        isTrue,
      );
      expect(
        identical(links.backlinksAsyncProvider, vault.backlinksAsyncProvider),
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
      // TEST-CHANGE (#78): the note titles read is an async read through
      // vaultAccessProvider, which needs an open vault.
      final c = ProviderContainer(
        overrides: [
          vault.currentVaultProvider.overrideWith(
            (_) => const LocalVaultRef('/om78-split-vault'),
          ),
          vault.vaultDbProvider.overrideWithValue(db),
          vault.memexCliProvider.overrideWithValue(null),
        ],
      );
      addTearDown(db.close);
      addTearDown(c.dispose);

      c.read(notes_list.sidebarSortProvider.notifier).state =
          notes_list.NoteSortMode.alphabetical;
      await c.read(notes_list.notesListAsyncProvider.future);
      expect(
        [
          for (final n in readScoped(
            c,
            notes_list.notesListAsyncProvider,
            const <NoteListItem>[],
          ))
            n.title,
        ],
        ['alpha', 'Beta'],
      );
      expect(
        await settledScoped(
          c,
          note.noteTitlesAsyncProvider,
          const <NoteTitle>[],
        ),
        hasLength(2),
      );
      expect(
        readScoped(c, canvas.canvasesAsyncProvider, const <CanvasRow>[]),
        isEmpty,
      );
      expect(
        readScoped(
          c,
          links.linksOutAsyncProvider('01J9AAAAAAAAAAAAAAAAAAAAAA'),
          const <LinkRow>[],
        ),
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
