import '../../cli/note_cli.dart';
import '../../db.dart';
import '../../memex_cli.dart';
import '../notes_access.dart';

/// [NotesAccess] for a local vault: reads from [db], writes through [cli]
/// with `--vault` [vaultPath] (D13). Either may be null (see `NotesAccess`).
class LocalNotesAccess implements NotesAccess {
  LocalNotesAccess({required this.vaultPath, this.db, this.cli});

  final String vaultPath;
  final VaultDb? db;
  final MemexCli? cli;

  // RED SKELETON (#70 test author): bodies are placeholders; the implementer
  // replaces every one with the delegation to [db] / [cli].

  @override
  Future<List<NoteListItem>> listNotes({int limit = 200}) async => const [];

  @override
  Future<Note?> getNote(String id) async => null;

  @override
  Future<List<NoteTitle>> allTitles({int limit = 1000}) async => const [];

  @override
  Future<List<LinkRow>> linksOutFor(String noteId) async => const [];

  @override
  Future<List<LinkRow>> linksInFor(String noteId, {String? kind}) async =>
      const [];

  @override
  Future<Map<String, String>> titlesForIds(List<String> ids) async => const {};

  @override
  Future<List<String>> distinctLinkKinds() async => const [];

  @override
  Future<String> addNote({
    String? title,
    List<String> tags = const [],
    required String contentMd,
    String? role,
  }) async => '';

  @override
  Future<NoteUpdateResult> updateNote({
    required String noteId,
    required int expectedVersion,
    String? title,
    required String contentMd,
    bool noRenameLinks = false,
  }) async => NoteUpdateResult(noteId: '', version: 0, updatedAt: 0);

  @override
  Future<NoteDeleteResult> deleteNote({
    required String noteId,
    required int expectedVersion,
  }) async => NoteDeleteResult(vaultId: '', noteId: '', deleted: false);

  @override
  Future<AddLinkResult> addLink({
    required String fromNoteId,
    required String toNoteId,
    String kind = 'references',
    String? label,
  }) async => AddLinkResult(
    linkId: null,
    fromNoteId: '',
    toNoteId: '',
    kind: '',
    source: '',
    wasExisting: false,
    noteVersion: 0,
  );

  @override
  Future<UpdateLinkResult> updateLink({
    required String linkId,
    String? kind,
    String? label,
    bool clearLabel = false,
  }) async => UpdateLinkResult(
    linkId: '',
    fromNoteId: '',
    toNoteId: null,
    kind: '',
    label: null,
    source: '',
    position: 0,
  );
}
