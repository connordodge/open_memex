import '../../db.dart';
import '../../db/tags_reads.dart';
import '../../memex_cli.dart';
import '../tags_access.dart';

/// [TagsAccess] for a local vault: reads from [db], writes through [cli] with
/// `--vault` [vaultPath] (D13). Either may be null (see `TagsAccess`).
class LocalTagsAccess implements TagsAccess {
  LocalTagsAccess({required this.vaultPath, this.db, this.cli});

  final String vaultPath;
  final VaultDb? db;
  final MemexCli? cli;

  @override
  Future<List<TagRow>> allTags() async => const [];

  @override
  Future<List<TagNoteRow>> notesForTag(String tag) async => const [];

  @override
  Future<TagRmResult> removeTag(String noteId, String tag) async => TagRmResult(
    noteId: '',
    tag: '',
    removed: false,
    correctionId: null,
    version: 0,
  );
}
