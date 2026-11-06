import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../db/tags_reads.dart';
import '../vault_access/vault_scoped.dart';
import 'topic_actions.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// Below V6 the local tag columns are missing; probed only when a local db is
/// open (a hosted vault has none, the server answers for itself).
bool _belowV6(Ref ref) =>
    ref.watch(vaultDbProvider) != null && !ref.watch(vaultV6ReadyProvider);

/// Every tag of the open vault through `VaultAccess.tags`, stamped with the
/// vault it was loaded for (D14a). Empty with no vault access and, on a local
/// vault, below V6 (`vaultV6ReadyProvider`). Re-reads on every
/// `vaultRevisionProvider` bump and on a vault switch.
final tagsAsyncProvider = FutureProvider<VaultScoped<List<TagRow>>>((
  ref,
) async {
  ref.watch(vaultRevisionProvider);
  final vault = ref.watch(currentVaultProvider);
  final access = ref.watch(vaultAccessProvider);
  if (access == null || _belowV6(ref)) {
    return VaultScoped(vault, const <TagRow>[]);
  }
  return VaultScoped(vault, await access.tags.allTags());
});

/// The notes holding a tag, under the same rules as [tagsAsyncProvider].
final notesForTagAsyncProvider =
    FutureProvider.family<VaultScoped<List<TagNoteRow>>, String>((
      ref,
      tag,
    ) async {
      ref.watch(vaultRevisionProvider);
      final vault = ref.watch(currentVaultProvider);
      final access = ref.watch(vaultAccessProvider);
      if (access == null || _belowV6(ref)) {
        return VaultScoped(vault, const <TagNoteRow>[]);
      }
      return VaultScoped(vault, await access.tags.notesForTag(tag));
    });

/// Removes [tag] from [note] (the x on a footer tag, R33). When [note] is the
/// open note the editor rebases on the returned version with its pending edit
/// kept (`rebaseEditorAfterWrite`); then `vaultRevisionProvider` is bumped
/// exactly once. A clean editor takes the stored body instead, and stays
/// clean: its copy still has the removed tag's footer line, and keeping it
/// would write again (the server drops the line, R12, but the version and
/// `updated_at` move). A rejected write propagates with nothing bumped. A tag
/// already gone (`removed: false`) is a success. Once the write has succeeded
/// nothing reports it as failed, even when [ref]'s widget is gone by then: a
/// read that fails rebases on the returned version, keeping the editor's text,
/// and still bumps.
Future<void> removeTagFromNote(
  WidgetRef ref, {
  required Note note,
  required String tag,
}) async {
  final access = ref.read(vaultAccessProvider);
  if (access == null) throw StateError('No vault is open.');
  // Taken before the write: the x may be gone by the time it returns, and
  // reading through [ref] would then throw.
  final container = ProviderScope.containerOf(ref.context, listen: false);
  final result = await access.tags.removeTag(note.id, tag);
  try {
    await rebaseEditorAfterWrite(
      container,
      access,
      note: note,
      version: result.version,
    );
  } finally {
    container.read(vaultRevisionProvider.notifier).state++;
  }
}
