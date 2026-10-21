import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/activity_reads.dart';
import '../vault_access/vault_scoped.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// A note's agent change log through `VaultAccess`, newest first, stamped with
/// the vault it was loaded for (D14a). Empty (stamped) with no vault access
/// and, on a local vault, below V5. Re-reads on every `vaultRevisionProvider`
/// bump.
final agentChangesAsyncProvider =
    FutureProvider.family<VaultScoped<List<AgentChangeRow>>, String>((
      ref,
      noteId,
    ) async {
      ref.watch(vaultRevisionProvider);
      final vault = ref.watch(currentVaultProvider);
      final access = ref.watch(vaultAccessProvider);
      // Below V5 the local table is missing; probe only when a local db is
      // open (a hosted vault has none, the server answers for itself).
      final belowV5 =
          ref.watch(vaultDbProvider) != null &&
          !ref.watch(vaultV5ReadyProvider);
      if (access == null || belowV5) {
        return VaultScoped(vault, const <AgentChangeRow>[]);
      }
      return VaultScoped(vault, await access.graph.agentChanges(noteId));
    });

/// A note's agent change log, newest first. Synchronous facade over
/// [agentChangesAsyncProvider]: empty before the first load, below V5, with no
/// entries, and for another vault's data.
final agentChangesProvider = Provider.family<List<AgentChangeRow>, String>(
  (ref, noteId) => vaultFacadeValue(
    ref,
    ref.watch(agentChangesAsyncProvider(noteId)),
    const <AgentChangeRow>[],
  ),
);
