import '../db.dart';

class SmartFolderRow {
  const SmartFolderRow({
    required this.id,
    required this.name,
    required this.parentId,
    required this.pinned,
  });

  final String id;
  final String name;
  final String? parentId;
  final bool pinned;
}

class SmartFolderMemberRow {
  const SmartFolderMemberRow({
    required this.folderId,
    required this.noteId,
    required this.title,
    required this.pinned,
  });

  final String folderId;
  final String noteId;
  final String title;
  final bool pinned;
}

/// Every Smart Folder and every membership.
class SmartFolderData {
  const SmartFolderData({required this.folders, required this.members});

  final List<SmartFolderRow> folders;
  final List<SmartFolderMemberRow> members;
}

/// A non-daily note that no Smart Folder contains. [role] is `topic` or null.
class UnsortedNoteRow {
  const UnsortedNoteRow({
    required this.noteId,
    required this.title,
    required this.role,
  });

  final String noteId;
  final String title;
  final String? role;
}

/// Smart Folder reads (V5), shared by the Topics tree and the Graph view.
/// Both return empty on a vault below V5, never throw.
extension TopicsReads on VaultDb {
  /// Every folder and every membership, unordered.
  SmartFolderData smartFolders() {
    if (!hasTables(VaultDb.v5TableNames)) {
      return const SmartFolderData(folders: [], members: []);
    }
    final folders = db
        .select('SELECT id, name, parent_id, pinned FROM smart_folders')
        .map(
          (r) => SmartFolderRow(
            id: r['id'] as String,
            name: r['name'] as String,
            parentId: r['parent_id'] as String?,
            pinned: (r['pinned'] as num) != 0,
          ),
        )
        .toList();
    final members = db
        .select(
          'SELECT m.smart_folder_id AS folder_id, m.note_id AS note_id, '
          'n.title AS title, m.pinned AS pinned '
          'FROM smart_folder_members m JOIN notes n ON n.id = m.note_id',
        )
        .map(
          (r) => SmartFolderMemberRow(
            folderId: r['folder_id'] as String,
            noteId: r['note_id'] as String,
            title: r['title'] as String,
            pinned: (r['pinned'] as num) != 0,
          ),
        )
        .toList();
    return SmartFolderData(folders: folders, members: members);
  }

  /// Every non-daily, non-guide note (topic or role-less) in no Smart Folder, unordered.
  /// A note with invalid-JSON frontmatter counts as role-less.
  List<UnsortedNoteRow> unsortedNotes() {
    if (!hasTables(VaultDb.v5TableNames)) return const [];
    final rows = db.select(
      'SELECT id, title, role FROM ('
      'SELECT n.id AS id, n.title AS title, '
      '(CASE WHEN json_valid(n.frontmatter) '
      "THEN json_extract(n.frontmatter, '\$.role') END) AS role "
      'FROM notes n WHERE NOT EXISTS ('
      'SELECT 1 FROM smart_folder_members m WHERE m.note_id = n.id)) '
      "WHERE role IS NULL OR role NOT IN ('daily', 'guide')",
    );
    return rows
        .map(
          (r) => UnsortedNoteRow(
            noteId: r['id'] as String,
            title: r['title'] as String,
            role: r['role'] as String?,
          ),
        )
        .toList();
  }
}
