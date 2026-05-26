import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui_state_store.dart';
import 'vault_state.dart';

/// One tab in the workspace. A tab is either a note (NoteTab) or a canvas
/// (CanvasTab). Identity is `(kind, id)`.
sealed class WorkspaceTab {
  const WorkspaceTab(this.id);
  final String id;

  String get tabId; // unique key for selectors (`tab-$tabId`)

  PersistedTab toPersisted();

  static WorkspaceTab? fromPersisted(PersistedTab p) {
    if (p.isNote) return NoteTab(p.id);
    if (p.isCanvas) return CanvasTab(p.id);
    return null;
  }
}

class NoteTab extends WorkspaceTab {
  const NoteTab(super.id);
  @override
  String get tabId => 'note-$id';
  @override
  PersistedTab toPersisted() =>
      PersistedTab(kind: PersistedTab.kindNote, id: id);

  @override
  bool operator ==(Object other) => other is NoteTab && other.id == id;

  @override
  int get hashCode => Object.hash('note', id);
}

class CanvasTab extends WorkspaceTab {
  const CanvasTab(super.id);
  @override
  String get tabId => 'canvas-$id';
  @override
  PersistedTab toPersisted() =>
      PersistedTab(kind: PersistedTab.kindCanvas, id: id);

  @override
  bool operator ==(Object other) => other is CanvasTab && other.id == id;

  @override
  int get hashCode => Object.hash('canvas', id);
}

/// Soft cap on open tabs. Past this, opening a new tab evicts the
/// least-recently-used non-active tab.
const int kMaxOpenTabs = 20;

class TabsState {
  const TabsState({required this.tabs, required this.activeIndex});

  final List<WorkspaceTab> tabs;
  final int activeIndex;

  static const empty = TabsState(tabs: [], activeIndex: 0);

  WorkspaceTab? get activeTab =>
      tabs.isEmpty ? null : tabs[activeIndex.clamp(0, tabs.length - 1)];

  TabsState copyWith({List<WorkspaceTab>? tabs, int? activeIndex}) => TabsState(
    tabs: tabs ?? this.tabs,
    activeIndex: activeIndex ?? this.activeIndex,
  );
}

class TabsNotifier extends StateNotifier<TabsState> {
  TabsNotifier({required this.store, required this.onPersistedSelection})
    : super(TabsState.empty) {
    _hydrate();
  }

  final UiStateStore store;

  /// Called with the active note id (or null) so legacy
  /// `selectedNoteIdProvider`-driven widgets stay in sync.
  final void Function(String? activeNoteId) onPersistedSelection;

  bool _hydrated = false;

  /// Most-recently-used order, most recent first. Used for LRU eviction.
  final List<WorkspaceTab> _mru = [];

  void _hydrate() {
    final persisted = store.read();
    final restored = persisted.tabs
        .map(WorkspaceTab.fromPersisted)
        .whereType<WorkspaceTab>()
        .toList();
    if (restored.isEmpty) {
      state = TabsState.empty;
      _hydrated = true;
      return;
    }
    final active = persisted.activeTabIndex.clamp(0, restored.length - 1);
    state = TabsState(tabs: restored, activeIndex: active);
    _mru
      ..clear()
      ..add(restored[active])
      ..addAll(restored.where((t) => t != restored[active]));
    _hydrated = true;
    _emitSelection();
  }

  /// Open a tab for `tab`, or switch to it if already open. Returns the
  /// resulting active index.
  int openOrFocus(WorkspaceTab tab) {
    final existing = state.tabs.indexOf(tab);
    if (existing >= 0) {
      _touchMru(tab);
      state = state.copyWith(activeIndex: existing);
      _persist();
      _emitSelection();
      return existing;
    }
    var newTabs = List<WorkspaceTab>.from(state.tabs)..add(tab);
    var newActive = newTabs.length - 1;
    // LRU eviction once over cap.
    if (newTabs.length > kMaxOpenTabs) {
      final active = newTabs[newActive];
      final victim = _pickEvictionVictim(newTabs, active);
      if (victim != null) {
        newTabs = newTabs.where((t) => t != victim).toList();
        newActive = newTabs.indexOf(active);
        _mru.remove(victim);
      }
    }
    state = TabsState(tabs: newTabs, activeIndex: newActive);
    _touchMru(tab);
    _persist();
    _emitSelection();
    return newActive;
  }

  void close(WorkspaceTab tab) {
    final idx = state.tabs.indexOf(tab);
    if (idx < 0) return;
    final remaining = List<WorkspaceTab>.from(state.tabs)..removeAt(idx);
    _mru.remove(tab);
    if (remaining.isEmpty) {
      state = TabsState.empty;
      _persist();
      _emitSelection();
      return;
    }
    int newActive;
    if (state.activeIndex == idx) {
      // Activate the previous tab if available, otherwise the new index at idx.
      newActive = (idx == 0) ? 0 : idx - 1;
    } else if (state.activeIndex > idx) {
      newActive = state.activeIndex - 1;
    } else {
      newActive = state.activeIndex;
    }
    state = TabsState(tabs: remaining, activeIndex: newActive);
    _persist();
    _emitSelection();
  }

  void setActive(int index) {
    if (index < 0 || index >= state.tabs.length) return;
    state = state.copyWith(activeIndex: index);
    _touchMru(state.tabs[index]);
    _persist();
    _emitSelection();
  }

  void _touchMru(WorkspaceTab tab) {
    _mru.remove(tab);
    _mru.insert(0, tab);
  }

  WorkspaceTab? _pickEvictionVictim(
    List<WorkspaceTab> tabs,
    WorkspaceTab active,
  ) {
    // Walk MRU from tail forward, return the first that's still in `tabs`
    // and isn't the active tab.
    for (var i = _mru.length - 1; i >= 0; i--) {
      final candidate = _mru[i];
      if (candidate != active && tabs.contains(candidate)) {
        return candidate;
      }
    }
    // No prior MRU info — fall back to the oldest non-active tab.
    for (final t in tabs) {
      if (t != active) return t;
    }
    return null;
  }

  void _persist() {
    if (!_hydrated) return;
    final existing = store.read();
    final next = UiState(
      tabs: state.tabs.map((t) => t.toPersisted()).toList(),
      activeTabIndex: state.activeIndex,
      canvasViewports: existing.canvasViewports,
    );
    // Fire-and-forget; persistence is best-effort and shouldn't block the UI.
    unawaited(store.write(next));
  }

  void _emitSelection() {
    final active = state.activeTab;
    if (active is NoteTab) {
      onPersistedSelection(active.id);
    } else {
      onPersistedSelection(null);
    }
  }
}

/// `unawaited` polyfill — avoids pulling in `dart:async` just for the helper.
void unawaited(Future<void> _) {}

/// Provider that yields a fresh `TabsNotifier` per vault. The vault path
/// drives both the persistence file location and the `selectedNoteIdProvider`
/// emission.
final tabsProvider = StateNotifierProvider<TabsNotifier, TabsState>((ref) {
  final vaultPath = ref.watch(currentVaultProvider);
  final store = UiStateStore(vaultPath: vaultPath ?? '/dev/null');
  final notifier = TabsNotifier(
    store: store,
    onPersistedSelection: (noteId) {
      // Keep the legacy provider in sync so existing widgets (note editor,
      // right panel) still respond to tab changes.
      ref.read(selectedNoteIdProvider.notifier).state = noteId;
    },
  );
  return notifier;
});

/// Lookup the active tab from anywhere in the widget tree.
final activeTabProvider = Provider<WorkspaceTab?>(
  (ref) => ref.watch(tabsProvider).activeTab,
);
