import '../db.dart';
import '../editor/tag_grammar.dart';

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
/// null when absent or not a string, or when the frontmatter is not valid
/// JSON. [updatedAt] is unix ms.
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
  /// Every tag, alphabetical ignoring ASCII case, with its note count and
  /// `system`.
  List<TagRow> allTags() {
    if (!hasColumns('tags', VaultDb.v6TagColumns)) return const [];
    return db
        .select(
          'SELECT tag, COUNT(*) AS note_count FROM tags GROUP BY tag '
          'ORDER BY tag COLLATE NOCASE, tag',
        )
        .map((r) {
          final tag = r['tag'] as String;
          return TagRow(
            tag: tag,
            noteCount: (r['note_count'] as num).toInt(),
            system: isSystemTag(tag),
          );
        })
        .toList();
  }

  /// The notes holding exactly [tag], most recently updated first.
  List<TagNoteRow> notesForTag(String tag) {
    if (!hasColumns('tags', VaultDb.v6TagColumns)) return const [];
    return db
        .select(
          'SELECT n.id AS id, n.title AS title, '
          '(CASE WHEN json_valid(n.frontmatter) '
          "THEN json_extract(n.frontmatter, '\$.role') END) AS role, "
          't.first_line AS first_line, n.updated_at AS updated_at '
          'FROM tags t JOIN notes n ON n.id = t.note_id WHERE t.tag = ? '
          'ORDER BY n.updated_at DESC',
          [tag],
        )
        .map((r) {
          final role = r['role'];
          return TagNoteRow(
            noteId: r['id'] as String,
            title: r['title'] as String,
            role: role is String ? role : null,
            firstLine: r['first_line'] as String?,
            updatedAt: (r['updated_at'] as num).toInt(),
          );
        })
        .toList();
  }
}
