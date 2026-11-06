import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui_state_store.dart';

export 'ui_state_store.dart' show SidebarMode;

/// The sidebar mode of the current vault (Req 50, TD8): `Days`, `Topics` or `Tags`,
/// persisted per vault as `sidebar_mode` in `<vault>/.memex/ui_state.json`.
/// A vault with no stored (or an unknown) mode is in [SidebarMode.days].
final sidebarModeProvider = NotifierProvider<SidebarModeNotifier, SidebarMode>(
  SidebarModeNotifier.new,
);

class SidebarModeNotifier extends Notifier<SidebarMode> {
  @override
  SidebarMode build() {
    final store = ref.watch(uiStateStoreProvider);
    return store == null ? SidebarMode.days : store.read().sidebarMode;
  }

  /// Switch to [mode] and persist it for the current vault. The returned
  /// future completes once `ui_state.json` holds the new mode.
  Future<void> select(SidebarMode mode) {
    state = mode;
    final store = ref.read(uiStateStoreProvider);
    if (store == null) return Future<void>.value();
    // Read-modify-write: keep the tabs and canvas viewports already stored.
    final existing = store.read();
    return store.write(
      UiState(
        tabs: existing.tabs,
        activeTabIndex: existing.activeTabIndex,
        canvasViewports: existing.canvasViewports,
        sidebarMode: mode,
      ),
    );
  }
}
