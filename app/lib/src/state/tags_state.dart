import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../db/tags_reads.dart';
import '../vault_access/vault_scoped.dart';

/// Every tag of the open vault through `VaultAccess.tags`, stamped with the
/// vault it was loaded for (D14a). Empty with no vault access and, on a local
/// vault, below V6 (`vaultV6ReadyProvider`). Re-reads on every
/// `vaultRevisionProvider` bump and on a vault switch.
final tagsAsyncProvider = FutureProvider<VaultScoped<List<TagRow>>>(
  (ref) async => const VaultScoped(null, []),
);

/// The notes holding a tag, under the same rules as [tagsAsyncProvider].
final notesForTagAsyncProvider =
    FutureProvider.family<VaultScoped<List<TagNoteRow>>, String>(
      (ref, tag) async => const VaultScoped(null, []),
    );

/// Removes [tag] from [note] (the x on a footer tag, R33). When [note] is the
/// open note the editor rebases on the returned version with its pending edit
/// kept (`rebaseEditorOnVersion`); then `vaultRevisionProvider` is bumped
/// exactly once. A rejected write propagates with nothing bumped. A tag
/// already gone (`removed: false`) is a success.
Future<void> removeTagFromNote(
  WidgetRef ref, {
  required Note note,
  required String tag,
}) async {}
