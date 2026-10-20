import '../../cli/note_cli.dart';
import '../../db.dart';
import '../../memex_cli.dart';
import '../notes_access.dart';
import 'write_guard.dart';

/// [NotesAccess] for a local vault: reads from [db], writes through [cli]
/// with `--vault` [vaultPath] (D13). Either may be null (see `NotesAccess`).
class LocalNotesAccess implements NotesAccess {
  LocalNotesAccess({required this.vaultPath, this.db, this.cli});

  final String vaultPath;
  final VaultDb? db;
  final MemexCli? cli;

  MemexCli get _cli => requireLocalCli(cli);

  // ---------- reads ----------

  @override
  Future<List<NoteListItem>> listNotes({int limit = 200}) async =>
      db?.listNotes(limit: limit) ?? const [];

  @override
  Future<Note?> getNote(String id) async => db?.getNote(id);

  @override
  Future<List<NoteTitle>> allTitles({int limit = 1000}) async =>
      db?.allTitles(limit: limit) ?? const [];

  @override
  Future<List<LinkRow>> linksOutFor(String noteId) async =>
      db?.linksOutFor(noteId) ?? const [];

  @override
  Future<List<LinkRow>> linksInFor(String noteId, {String? kind}) async =>
      db?.linksInFor(noteId, kind: kind) ?? const [];

  @override
  Future<Map<String, String>> titlesForIds(List<String> ids) async =>
      db?.titlesForIds(ids) ?? const {};

  @override
  Future<List<String>> distinctLinkKinds() async =>
      db?.distinctLinkKinds() ?? const [];

  // ---------- writes ----------

  @override
  Future<String> addNote({
    String? title,
    List<String> tags = const [],
    required String contentMd,
    String? role,
  }) async => _cli.addNote(
    vaultPath: vaultPath,
    title: title,
    tags: tags,
    contentMd: contentMd,
    role: role,
  );

  @override
  Future<NoteUpdateResult> updateNote({
    required String noteId,
    required int expectedVersion,
    String? title,
    required String contentMd,
    bool noRenameLinks = false,
  }) async => _cli.updateNote(
    vaultPath: vaultPath,
    noteId: noteId,
    expectedVersion: expectedVersion,
    title: title,
    contentMd: contentMd,
    noRenameLinks: noRenameLinks,
  );

  @override
  Future<NoteDeleteResult> deleteNote({
    required String noteId,
    required int expectedVersion,
  }) async => _cli.deleteNote(
    vaultPath: vaultPath,
    noteId: noteId,
    expectedVersion: expectedVersion,
  );

  @override
  Future<AddLinkResult> addLink({
    required String fromNoteId,
    required String toNoteId,
    String kind = 'references',
    String? label,
  }) async => _cli.addLink(
    vaultPath: vaultPath,
    fromNoteId: fromNoteId,
    toNoteId: toNoteId,
    kind: kind,
    label: label,
  );

  @override
  Future<UpdateLinkResult> updateLink({
    required String linkId,
    String? kind,
    String? label,
    bool clearLabel = false,
  }) async => _cli.updateLink(
    vaultPath: vaultPath,
    linkId: linkId,
    kind: kind,
    label: label,
    clearLabel: clearLabel,
  );
}
