import '../../cli/note_cli.dart';
import '../../db.dart';
import '../../memex_cli.dart';
import '../notes_access.dart';
import 'hosted_client.dart';

/// [NotesAccess] for a hosted vault (D11 V1, D13): every read and write is
/// one `/vaults/<vaultName>/api/v1` route through [client] (D17).
class HostedNotesAccess implements NotesAccess {
  HostedNotesAccess({required this.client, required this.vaultName});

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

  // ---------- reads ----------

  @override
  Future<List<NoteListItem>> listNotes({int limit = 200}) =>
      throw UnimplementedError('#81');

  @override
  Future<Note?> getNote(String id) => throw UnimplementedError('#81');

  @override
  Future<List<NoteTitle>> allTitles({int limit = 1000}) =>
      throw UnimplementedError('#81');

  @override
  Future<List<LinkRow>> linksOutFor(String noteId) =>
      throw UnimplementedError('#81');

  @override
  Future<List<LinkRow>> linksInFor(String noteId, {String? kind}) =>
      throw UnimplementedError('#81');

  @override
  Future<Map<String, String>> titlesForIds(List<String> ids) =>
      throw UnimplementedError('#81');

  @override
  Future<List<String>> distinctLinkKinds() => throw UnimplementedError('#81');

  // ---------- writes ----------

  @override
  Future<String> addNote({
    String? title,
    List<String> tags = const [],
    required String contentMd,
    String? role,
  }) => throw UnimplementedError('#81');

  @override
  Future<NoteUpdateResult> updateNote({
    required String noteId,
    required int expectedVersion,
    String? title,
    required String contentMd,
    bool noRenameLinks = false,
  }) => throw UnimplementedError('#81');

  @override
  Future<NoteDeleteResult> deleteNote({
    required String noteId,
    required int expectedVersion,
  }) => throw UnimplementedError('#81');

  @override
  Future<AddLinkResult> addLink({
    required String fromNoteId,
    required String toNoteId,
    String kind = 'references',
    String? label,
  }) => throw UnimplementedError('#81');

  @override
  Future<UpdateLinkResult> updateLink({
    required String linkId,
    String? kind,
    String? label,
    bool clearLabel = false,
  }) => throw UnimplementedError('#81');
}
