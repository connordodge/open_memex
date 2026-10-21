import 'dart:async' show scheduleMicrotask;
import 'dart:math' show max, min;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/daily_reads.dart' show DailyNoteRow;
import '../graph/graph_scope.dart';
import '../vault_access/vault_scoped.dart';
import 'daily_state.dart';
import 'ui_state_store.dart';
import 'vault_state.dart';

/// One tab in the workspace: a note (NoteTab), a canvas (CanvasTab) or a
/// Graph view (GraphTab). Identity is `(kind, id)`.
sealed class WorkspaceTab {
  const WorkspaceTab(this.id);
  final String id;

  String get tabId; // unique key for selectors (`tab-$tabId`)

  PersistedTab toPersisted();

  static WorkspaceTab? fromPersisted(PersistedTab p) {
    if (p.isNote) return NoteTab(p.id);
    if (p.isCanvas) return CanvasTab(p.id);
    // A graph entry with an unknown or malformed scope is dropped.
    if (p.isGraph) {
      return switch (GraphScope.parse(p.id)) {
        final scope? => GraphTab(scope),
        null => null,
      };
    }
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

/// The virtual (unsaved) Today note (Req 48, WI #22): shown when today has
/// no daily note yet. It keeps the ISO [date] it opened with across local
/// midnight (D14) and is never persisted to `ui_state.json` (D26). A
/// [NoteTab], so the workspace's note branch renders it.
class VirtualTodayTab extends NoteTab {
  const VirtualTodayTab(this.date) : super('$_idPrefix$date');

  /// The ISO date (`YYYY-MM-DD`) this tab was opened for.
  final String date;

  static const _idPrefix = 'virtual-today:';

  /// The date of the virtual Today tab whose id is [noteId], or null when
  /// [noteId] is a real note id (or null).
  static String? dateOf(String? noteId) {
    if (noteId == null || !noteId.startsWith(_idPrefix)) return null;
    return noteId.substring(_idPrefix.length);
  }
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

/// A read-only Graph view tab (D26). [id] is the scope's persisted id
/// (`topic:<noteId>`, `day:<noteId>`, `folder:<smartFolderId>`, `vault:all`);
/// persisted as kind `graph`.
class GraphTab extends WorkspaceTab {
  GraphTab(this.scope) : super(scope.persistedId);

  final GraphScope scope;

  /// `graph-<scope>:<id>`.
  @override
  String get tabId => 'graph-$id';

  @override
  PersistedTab toPersisted() =>
      PersistedTab(kind: PersistedTab.kindGraph, id: id);

  @override
  bool operator ==(Object other) => other is GraphTab && other.scope == scope;

  @override
  int get hashCode => Object.hash('graph', scope);
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
  /// Restores the tabs from [store]. With a [todayDate] (the launch, #22),
  /// today's tab then becomes active: the restored tab of [todayNoteId] when
  /// it is open, otherwise today's tab ([todayNoteId]'s, or a
  /// [VirtualTodayTab] for [todayDate] when it is null) is inserted first.
  TabsNotifier({
    required this.store,
    required this.onPersistedSelection,
    String? todayDate,
    String? todayNoteId,
  }) : super(TabsState.empty) {
    _hydrate(todayDate, todayNoteId);
  }

  final UiStateStore store;

  /// Called with the active note id (or null) so legacy
  /// `selectedNoteIdProvider`-driven widgets stay in sync.
  final void Function(String? activeNoteId) onPersistedSelection;

  bool _hydrated = false;

  /// Most-recently-used order, most recent first. Used for LRU eviction.
  final List<WorkspaceTab> _mru = [];

  void _hydrate(String? todayDate, String? todayNoteId) {
    _restore();
    if (todayDate != null) {
      _focusToday(_todayTab(todayDate, todayNoteId));
    }
    // Deferred: the notifier is built inside `tabsProvider`, and a provider
    // may not modify another provider (`selectedNoteIdProvider`) while it
    // initializes.
    scheduleMicrotask(() {
      if (mounted) _emitSelection();
    });
  }

  /// Restores the tabs written to [store]. Neither persists nor emits.
  void _restore() {
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
  }

  static WorkspaceTab _todayTab(String date, String? noteId) =>
      noteId == null ? VirtualTodayTab(date) : NoteTab(noteId);

  /// Make [today] the active tab: focus it when open, otherwise insert it
  /// first. Neither persists nor emits.
  void _focusToday(WorkspaceTab today) {
    final existing = state.tabs.indexOf(today);
    if (existing >= 0) {
      state = state.copyWith(activeIndex: existing);
    } else {
      final tabs = _evictOverCap([today, ...state.tabs], today);
      state = TabsState(tabs: tabs, activeIndex: tabs.indexOf(today));
    }
    _touchMru(today);
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
    final newTabs = _evictOverCap([...state.tabs, tab], tab);
    final newActive = newTabs.indexOf(tab);
    state = TabsState(tabs: newTabs, activeIndex: newActive);
    _touchMru(tab);
    _persist();
    _emitSelection();
    return newActive;
  }

  /// Open today's note (#23's `Today` row entry point): focus the tab of
  /// today's daily note [noteId] when it is open, otherwise open it; when
  /// [noteId] is null (no daily note for [date] yet), focus the open
  /// [VirtualTodayTab] for [date] or insert one as the active tab.
  void openToday({required String date, String? noteId}) {
    _focusToday(_todayTab(date, noteId));
    _persist();
    _emitSelection();
  }

  /// The virtual Today tab for [date] became the real note [noteId] (its
  /// first edit created or found the daily note, #22): the note's tab takes
  /// the virtual tab's place, or, when [noteId] is already open, the virtual
  /// tab closes. The active tab stays the active tab. A no-op when the
  /// virtual tab was closed meanwhile.
  void resolveVirtualToday({required String date, required String noteId}) {
    final virtual = VirtualTodayTab(date);
    final idx = state.tabs.indexOf(virtual);
    if (idx < 0) return;
    final real = NoteTab(noteId);
    final tabs = List<WorkspaceTab>.from(state.tabs);
    if (tabs.contains(real)) {
      tabs.removeAt(idx);
    } else {
      tabs[idx] = real;
    }
    final active = state.activeTab == virtual ? real : state.activeTab!;
    state = TabsState(tabs: tabs, activeIndex: tabs.indexOf(active));
    _mru.remove(virtual);
    _persist();
    _emitSelection();
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

  /// [tabs] with the least-recently-used tab other than [active] removed
  /// when they are over [kMaxOpenTabs] (LRU eviction).
  List<WorkspaceTab> _evictOverCap(
    List<WorkspaceTab> tabs,
    WorkspaceTab active,
  ) {
    if (tabs.length <= kMaxOpenTabs) return tabs;
    final victim = _pickEvictionVictim(tabs, active);
    if (victim == null) return tabs;
    _mru.remove(victim);
    return tabs.where((t) => t != victim).toList();
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
    // The virtual Today tab is never written (D26); the active index moves
    // onto the remaining tabs (to the next one when the virtual tab is
    // active).
    final kept = state.tabs.where((t) => t is! VirtualTodayTab).toList();
    final before = state.tabs
        .take(state.activeIndex)
        .where((t) => t is! VirtualTodayTab)
        .length;
    final next = UiState(
      tabs: kept.map((t) => t.toPersisted()).toList(),
      activeTabIndex: min(before, max(0, kept.length - 1)),
      canvasViewports: existing.canvasViewports,
      sidebarMode: existing.sidebarMode,
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
  final vaultPath = ref.watch(currentVaultProvider).localPath;
  final store =
      ref.watch(uiStateStoreProvider) ?? UiStateStore(vaultPath: '/dev/null');
  final notifier = TabsNotifier(
    store: store,
    onPersistedSelection: (noteId) {
      // Keep the legacy provider in sync so existing widgets (note editor,
      // right panel) still respond to tab changes.
      ref.read(selectedNoteIdProvider.notifier).state = noteId;
    },
    // Opening a vault lands on today's note (#22). Read once: the launch
    // date sticks to the tab across midnight (D14).
    todayDate: vaultPath == null ? null : ref.read(todayDateProvider),
    todayNoteId: vaultPath == null ? null : _readTodayNote(ref)?.noteId,
  );
  // Today's note is an async read (#78, D14a): until it lands the launch
  // shows the virtual Today tab, which then resolves onto today's stored
  // daily note when there is one.
  final launchDate = vaultPath == null ? null : ref.read(todayDateProvider);
  if (launchDate != null && _readTodayNote(ref) == null) {
    final vault = ref.read(currentVaultProvider);
    ref.read(todayNoteAsyncProvider.future).then((today) {
      final row = today.value;
      if (!notifier.mounted || today.vault != vault || row == null) return;
      if (row.date != launchDate) return;
      notifier.resolveVirtualToday(date: launchDate, noteId: row.noteId);
    }, onError: (Object _) {});
  }
  return notifier;
});

/// Today's daily note as loaded for the open vault right now (no
/// subscription), or null before it loads, while it reloads, or when there is
/// none. Nothing listens to today's note, so a value being reloaded can be
/// the note of the day before midnight; the launch then waits for the fresh
/// read instead.
DailyNoteRow? _readTodayNote(Ref<Object?> ref) {
  final today = ref.read(todayNoteAsyncProvider);
  if (today.isLoading) return null;
  return currentVaultData(today, ref.read(currentVaultProvider))?.value;
}

/// Lookup the active tab from anywhere in the widget tree.
final activeTabProvider = Provider<WorkspaceTab?>(
  (ref) => ref.watch(tabsProvider).activeTab,
);
