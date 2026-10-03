import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../db/topics_reads.dart';
import '../graph/graph_scope.dart';
import 'tabs_state.dart';
import 'vault_state.dart';

/// Opens the Graph view for [scope] as the active workspace tab, or focuses
/// the existing Graph tab for the same scope. Used by the note menu (#30) and
/// by the Topics sidebar's folder menu and `Graph` header action (#25).
void openGraph(WidgetRef ref, GraphScope scope) =>
    ref.read(tabsProvider.notifier).openOrFocus(GraphTab(scope));

/// The nodes, edges and hulls of a Graph scope, re-read whenever the vault
/// changes. Empty when no vault is open.
final graphDataProvider = Provider.autoDispose.family<GraphData, GraphScope>((
  ref,
  scope,
) {
  ref.watch(vaultRevisionProvider);
  return switch (ref.watch(vaultDbProvider)) {
    final db? => buildGraph(db, scope),
    null => GraphData.empty,
  };
});

/// The Graph tab chip label: `Graph · <folder name | note title | Whole
/// vault>`. Falls back to the scope id when the folder or note is gone.
String graphTabTitle(VaultDb? db, GraphScope scope) {
  final name = switch (scope.kind) {
    GraphScopeKind.vault => 'Whole vault',
    GraphScopeKind.folder =>
      db
          ?.smartFolders()
          .folders
          .where((f) => f.id == scope.id)
          .firstOrNull
          ?.name,
    GraphScopeKind.topic || GraphScopeKind.day => db?.getNote(scope.id)?.title,
  };
  return 'Graph · ${name ?? scope.id}';
}
