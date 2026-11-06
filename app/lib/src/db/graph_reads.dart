import '../db.dart';

/// One note as the Graph view sees it. [role] is the frontmatter's
/// `$.role` string, or null when absent, not a string, or when the
/// frontmatter is not valid JSON.
class GraphNoteRow {
  const GraphNoteRow({
    required this.id,
    required this.title,
    required this.role,
  });

  final String id;
  final String title;
  final String? role;
}

/// One `links` row whose target is an existing note (ghost links have no
/// target and are left out).
class GraphLinkRow {
  const GraphLinkRow({
    required this.from,
    required this.to,
    required this.kind,
    required this.label,
  });

  final String from;
  final String to;
  final String kind;
  final String? label;
}

/// Graph view reads (D21). `notes` and `links` exist from V1, so these work
/// on every schema version. Smart Folders come from `TopicsReads` and footer
/// chips from `DailyReads`.
extension GraphReads on VaultDb {
  /// SQL true when the note aliased [alias] is not the Vault Guide.
  static String _notGuide(String alias) =>
      "COALESCE(CASE WHEN json_valid($alias.frontmatter) "
      "THEN json_extract($alias.frontmatter, '\$.role') END, '') != 'guide'";

  /// Every note with its role, ordered by id. The Vault Guide is left out.
  List<GraphNoteRow> graphNotes() {
    final rows = db.select(
      'SELECT id, title, role FROM ('
      'SELECT id, title, (CASE WHEN json_valid(frontmatter) '
      "THEN json_extract(frontmatter, '\$.role') END) AS role "
      'FROM notes) '
      "WHERE role IS NULL OR role != 'guide' ORDER BY id",
    );
    return rows.map((r) {
      final role = r['role'];
      return GraphNoteRow(
        id: r['id'] as String,
        title: r['title'] as String,
        role: role is String ? role : null,
      );
    }).toList();
  }

  /// Every link whose target note exists, ordered by source note and
  /// position. Links from or to the Vault Guide are left out.
  List<GraphLinkRow> graphLinks() {
    final rows = db.select(
      'SELECT l.from_note_id AS from_id, l.to_note_id AS to_id, '
      'l.link_kind AS kind, l.label AS label FROM links l '
      'JOIN notes t ON t.id = l.to_note_id '
      'JOIN notes f ON f.id = l.from_note_id '
      'WHERE ${_notGuide('t')} AND ${_notGuide('f')} '
      'ORDER BY l.from_note_id, l.position',
    );
    return rows
        .map(
          (r) => GraphLinkRow(
            from: r['from_id'] as String,
            to: r['to_id'] as String,
            kind: r['kind'] as String,
            label: r['label'] as String?,
          ),
        )
        .toList();
  }
}
