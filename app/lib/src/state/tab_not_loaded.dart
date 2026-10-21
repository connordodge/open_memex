import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart' show CanvasRow;
import '../vault_access/errors.dart';
import '../vault_access/vault_access.dart';
import 'canvas_state.dart';
import 'graph_state.dart';
import 'hosted_connection_state.dart';
import 'hosted_identity.dart';
import 'tabs_state.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// The title a tab's chip shows, and the not-loaded state names. One
/// function for both so they can't drift apart.
String workspaceTabTitle(WidgetRef ref, WorkspaceTab tab) {
  if (tab is NoteTab) {
    // The virtual Today note has no row yet: its chip reads its ISO date,
    // like a real daily note's title.
    if (VirtualTodayTab.dateOf(tab.id) case final date?) return date;
    // Read through VaultAccess; `note` until it loads or when it's gone.
    return ref.watch(noteTitleProvider(tab.id)).valueOrNull ?? 'note';
  }
  if (tab is CanvasTab) {
    final summary = watchVaultValue(
      ref,
      canvasesAsyncProvider,
      const <CanvasRow>[],
    ).where((c) => c.canvasId == tab.id).toList();
    if (summary.isNotEmpty) return summary.first.title;
    return 'canvas';
  }
  if (tab is GraphTab) {
    return ref.watch(graphTabTitleProvider(tab.scope)).valueOrNull ?? 'Graph';
  }
  return tab.id;
}

/// The tabs (per vault) whose content a read has loaded at least once. A tab
/// in this set never shows the not-loaded state, whatever later reads do.
final _loadedTabsProvider = Provider<Set<(VaultRef, String)>>((ref) => {});

/// One content read of a tab through `vaultAccessProvider`, re-run on every
/// `vaultRevisionProvider` bump. True when the read failed because the vault
/// server can't be reached. A read that completes records the tab as loaded.
final _tabReadUnreachableProvider = FutureProvider.autoDispose
    .family<bool, (VaultRef, WorkspaceTab)>((ref, key) async {
      final (vault, tab) = key;
      ref.watch(vaultRevisionProvider);
      final access = ref.watch(vaultAccessProvider);
      if (access == null) return false;
      try {
        await _readContent(access, tab);
      } on VaultUnreachableException {
        return true;
      } catch (_) {
        // Any other failure is the tab body's to show; it is not evidence
        // that the server can't be reached.
        return false;
      }
      ref.read(_loadedTabsProvider).add((vault, tab.tabId));
      return false;
    });

Future<void> _readContent(VaultAccess access, WorkspaceTab tab) async {
  switch (tab) {
    case NoteTab():
      await access.notes.getNote(tab.id);
    case CanvasTab():
      await access.canvas.getCanvasDetail(tab.id);
    case GraphTab():
      await access.graph.graphNotes();
      await access.graph.graphLinks();
  }
}

/// The display name of the server to show the not-loaded state for [tab], or
/// null when the tab shows its body. The state holds when the open vault is
/// hosted, its server is unreachable, and no read of the tab has completed
/// yet (A11 state 3). A tab that loaded before the outage keeps its content.
///
/// Only a never-loaded tab of a hosted vault reads here, so a loaded tab
/// costs no extra request.
final tabNotLoadedProvider = Provider.autoDispose.family<String?, WorkspaceTab>(
  (ref, tab) {
    final vault = ref.watch(currentVaultProvider);
    if (vault is! HostedVaultRef) return null;
    final status = ref.watch(hostedConnectionStatusProvider(vault.serverId));
    if (ref.read(_loadedTabsProvider).contains((vault, tab.tabId))) {
      return null;
    }
    final failed = ref
        .watch(_tabReadUnreachableProvider((vault, tab)))
        .valueOrNull;
    if (status != HostedConnectionStatus.unreachable || failed != true) {
      return null;
    }
    return ref.watch(hostedServerNameProvider(vault.serverId));
  },
);
