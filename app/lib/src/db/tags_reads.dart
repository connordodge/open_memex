import '../db.dart';

/// One tag with its note count. [system] is `isSystemTag` (D17).
class TagRow {
  const TagRow({
    required this.tag,
    required this.noteCount,
    required this.system,
  });

  final String tag;
  final int noteCount;
  final bool system;
}

/// One note holding a tag. [firstLine] is the first person-section line
/// holding the tag; null when there is none (a footer-only tag). [role] is
/// null when absent or when the frontmatter is not valid JSON. [updatedAt]
/// is unix ms.
class TagNoteRow {
  const TagNoteRow({
    required this.noteId,
    required this.title,
    required this.role,
    required this.firstLine,
    required this.updatedAt,
  });

  final String noteId;
  final String title;
  final String? role;
  final String? firstLine;
  final int updatedAt;
}

/// Tag reads (V6). Both are empty below V6, never throw. Synchronous.
extension TagsReads on VaultDb {
  /// Every tag, alphabetical, with its note count and `system`.
  List<TagRow> allTags() => const [];

  /// The notes holding exactly [tag], most recently updated first.
  List<TagNoteRow> notesForTag(String tag) => const [];
}
