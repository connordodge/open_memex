import '../../db/tags_reads.dart';
import '../../memex_cli.dart';
import '../tags_access.dart';
import 'hosted_client.dart';

/// [TagsAccess] for a hosted vault: every read and write is one
/// `/vaults/<vaultName>/api/v1` route through [client] (D17), frozen in #242
/// (T4b). Writes leave `vaultRevisionProvider` to their call sites.
class HostedTagsAccess implements TagsAccess {
  HostedTagsAccess({required this.client, required this.vaultName});

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

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
