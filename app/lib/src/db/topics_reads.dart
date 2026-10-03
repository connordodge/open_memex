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
extension TopicsReads on VaultDb {
  SmartFolderData smartFolders() => throw UnimplementedError();

  List<UnsortedNoteRow> unsortedNotes() => throw UnimplementedError();
}
