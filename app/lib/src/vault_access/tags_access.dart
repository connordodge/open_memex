import '../db/tags_reads.dart';
import '../memex_cli.dart';

/// The open vault's tags (#249, TD6). Same rules as `NotesAccess`: async
/// mirrors of `TagsReads` / the `MemexCli` wrappers, empty reads without a
/// database, today's exceptions from writes, [StateError] from a write when
/// `VaultAccess.canWrite` is false.
///
/// Test doubles `extends LocalTagsAccess` (D21).
abstract interface class TagsAccess {
  // ---------- reads ----------

  /// `TagsReads.allTags` / `GET /tags`: alphabetical.
  Future<List<TagRow>> allTags();

  /// `TagsReads.notesForTag` / `GET /tags/{tag}/notes`: most recently updated
  /// first.
  Future<List<TagNoteRow>> notesForTag(String tag);

  // ---------- writes ----------

  /// `memex tag rm` / `DELETE /notes/{note_id}/tags/{tag}`. A tag already gone
  /// is a success with `removed` false.
  Future<TagRmResult> removeTag(String noteId, String tag);
}
