import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../graph/graph_scope.dart';
import '../vault_access/vault_access.dart';
import '../vault_access/vault_scoped.dart';
import 'tabs_state.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// Opens the Graph view for [scope] as the active workspace tab, or focuses
/// the existing Graph tab for the same scope. Used by the note menu (#30) and
/// by the Topics sidebar's folder menu and `Graph` header action (#25).
void openGraph(WidgetRef ref, GraphScope scope) =>
    ref.read(tabsProvider.notifier).openOrFocus(GraphTab(scope));

/// The nodes, edges and hulls of a Graph scope, read through `VaultAccess`
/// (D13) and re-read whenever the vault changes. Stamped with the vault it
/// was loaded for (D14a); `GraphData.empty` when no vault is open.
final graphDataAsyncProvider = FutureProvider.autoDispose
    .family<VaultScoped<GraphData>, GraphScope>((ref, scope) async {
      ref.watch(vaultRevisionProvider);
      final vault = ref.watch(currentVaultProvider);
      final access = ref.watch(vaultAccessProvider);
      if (access == null) return VaultScoped(vault, GraphData.empty);
      return VaultScoped(vault, await buildGraph(access, scope));
    });

/// The D14a synchronous facade over [graphDataAsyncProvider]: the current
/// vault's graph (a same-vault reload keeps the previous one), else
/// `GraphData.empty` (no vault, first load in flight or failed, or data from
/// the previous vault after a switch).
final graphDataProvider = Provider.autoDispose.family<GraphData, GraphScope>(
  (ref, scope) => vaultFacadeValue(
    ref,
    ref.watch(graphDataAsyncProvider(scope)),
    GraphData.empty,
  ),
);

/// The Graph tab chip label: `Graph · <folder name | note title | Whole
/// vault>`, read through [access]. Falls back to the scope id when the
/// folder or note is gone, or with no vault open.
Future<String> graphTabTitle(VaultAccess? access, GraphScope scope) async {
  final name = switch (scope.kind) {
    GraphScopeKind.vault => 'Whole vault',
    GraphScopeKind.folder =>
      (await access?.topics.smartFolders())?.folders
          .where((f) => f.id == scope.id)
          .firstOrNull
          ?.name,
    GraphScopeKind.topic ||
    GraphScopeKind.day => (await access?.notes.getNote(scope.id))?.title,
  };
  return 'Graph · ${name ?? scope.id}';
}

/// [graphTabTitle] for the open vault, re-read whenever the vault changes.
final graphTabTitleProvider = FutureProvider.autoDispose
    .family<String, GraphScope>((ref, scope) {
      ref.watch(vaultRevisionProvider);
      return graphTabTitle(ref.watch(vaultAccessProvider), scope);
    });

/// A note's title read through `VaultAccess`, re-read whenever the vault
/// changes; null when the note is missing or no vault is open. The note tab
/// chip reads it.
final noteTitleProvider = FutureProvider.autoDispose.family<String?, String>((
  ref,
  noteId,
) async {
  ref.watch(vaultRevisionProvider);
  final access = ref.watch(vaultAccessProvider);
  return (await access?.notes.getNote(noteId))?.title;
});
