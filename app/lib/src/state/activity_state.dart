import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/activity_reads.dart';
import '../vault_access/vault_scoped.dart';
import 'vault_state.dart';

/// A note's agent change log through `VaultAccess`, stamped with the vault it
/// was loaded for (D14a). Skeleton: WI #90 fills it.
final agentChangesAsyncProvider =
    FutureProvider.family<VaultScoped<List<AgentChangeRow>>, String>(
      (ref, noteId) => throw UnimplementedError(),
    );

/// A note's agent change log, newest first. Empty on a vault below V5 and for
/// a note with no entries; re-reads on every `vaultRevisionProvider` bump.
final agentChangesProvider = Provider.family<List<AgentChangeRow>, String>((
  ref,
  noteId,
) {
  ref.watch(vaultRevisionProvider);
  if (!ref.watch(vaultV5ReadyProvider)) return const [];
  return ref.watch(vaultDbProvider)?.agentChanges(noteId) ?? const [];
});
