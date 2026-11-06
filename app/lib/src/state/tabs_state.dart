import 'dart:async' show scheduleMicrotask;
import 'dart:math' show max, min;

import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/daily_reads.dart' show DailyNoteRow;
import '../graph/graph_scope.dart';
import '../vault_access/vault_scoped.dart';
import 'daily_state.dart';
import 'editor_controller.dart' show editorControllerProvider;
import 'tab_history.dart';
import 'ui_state_store.dart';
import 'vault_access_state.dart';
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
  const CanvasTab(super.id, {this.zoomedNoteId});

  /// The note this canvas tab is zoomed into, or null when it shows the canvas.
  ///
  /// Part of `==` and `hashCode` (a zoomed entry is a different history entry
  /// from the canvas itself) but not of [tabId] or [toPersisted]: the tab is
  /// the same tab and a relaunch shows it unzoomed (R5).
  final String? zoomedNoteId;

  @override
  String get tabId => 'canvas-$id';
  @override
  PersistedTab toPersisted() =>
      PersistedTab(kind: PersistedTab.kindCanvas, id: id);

  @override
  bool operator ==(Object other) =>
      other is CanvasTab &&
      other.id == id &&
      other.zoomedNoteId == zoomedNoteId;

  @override
  int get hashCode => Object.hash('canvas', id, zoomedNoteId);
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
  const TabsState({
    required this.tabs,
    required this.activeIndex,
    this.canGoBack = false,
    this.canGoForward = false,
    this.arrivals = 0,
  });

  final List<WorkspaceTab> tabs;
  final int activeIndex;

  /// Whether the active tab's Tab history has an entry before the current one.
  final bool canGoBack;

  /// Whether the active tab's Tab history has an entry after the current one.
  final bool canGoForward;

  /// How many times the active tab has been arrived at: Back, Forward, a chip
  /// switch, a navigate, a focus, landing on a neighbour. Moves only then, so
  /// the editor can act on an arrival that keeps the same note on screen (two
  /// tabs on one note), and not on a write that only moves the index (#270).
  final int arrivals;

  static const empty = TabsState(tabs: [], activeIndex: 0);

  WorkspaceTab? get activeTab =>
      tabs.isEmpty ? null : tabs[activeIndex.clamp(0, tabs.length - 1)];

  /// The note the active entry shows: a note tab's note or the note a canvas
  /// tab is zoomed into, else null.
  String? get activeNoteId => TabsNotifier._shownNoteId(activeTab);

  TabsState copyWith({
    List<WorkspaceTab>? tabs,
    int? activeIndex,
    bool? canGoBack,
    bool? canGoForward,
    int? arrivals,
  }) => TabsState(
    tabs: tabs ?? this.tabs,
    activeIndex: activeIndex ?? this.activeIndex,
    canGoBack: canGoBack ?? this.canGoBack,
    canGoForward: canGoForward ?? this.canGoForward,
    arrivals: arrivals ?? this.arrivals,
  );
}

/// Told about every target that goes through the navigation seam. Null in the
/// app; `app/test/support/recording_tabs.dart` supplies one to tests through
/// [tabsNavigationObserverProvider], so they record clicks on the real
/// notifier.
abstract interface class TabsNavigationObserver {
  /// [target] was passed to [TabsNotifier.follow] or to a function that
  /// [TabsNotifier.followLater] returned.
  void followed(WorkspaceTab target);

  /// [target] reached [TabsNotifier.navigate], including through `follow`.
  void navigated(WorkspaceTab target);
}

/// One open tab: what it has shown (its Tab history) and a counter that moves
/// on every step of that history. The object itself is the tab's instance id,
/// so two tabs showing one value stay apart (#266).
class _TabRecord {
  _TabRecord(WorkspaceTab target) : history = TabHistory.initial(target);

  TabHistory<WorkspaceTab> history;

  /// Bumped on every move of [history] (navigate, back, forward, a gone
  /// entry's removal), so a late answer or a late `followLater` result can
  /// tell whether the tab is still where it was. A scroll is not a move: it
  /// sets [history] directly (`recordScrollOffset`).
  int generation = 0;

  WorkspaceTab get current => history.current;

  void move(TabHistory<WorkspaceTab> next) {
    history = next;
    generation++;
  }
}

class TabsNotifier extends StateNotifier<TabsState> {
  /// Restores the tabs from [store]. With a [todayDate] (the launch, #22),
  /// today's tab then becomes active: the leftmost restored tab of
  /// [todayNoteId] when it is open, otherwise today's tab ([todayNoteId]'s, or
  /// a [VirtualTodayTab] for [todayDate] when it is null) is inserted first.
  TabsNotifier({
    required this.store,
    required this.onPersistedSelection,
    this.onBeforeLeave,
    String? todayDate,
    String? todayNoteId,
    this.isNewTabModifierPressed,
    this.navigationObserver,
    this.targetExists,
  }) : super(TabsState.empty) {
    _hydrate(todayDate, todayNoteId);
  }

  final UiStateStore store;

  /// Runs before a call changes which tab is active, changes what the active
  /// tab shows, or removes the active tab, so what is being left can save a
  /// pending edit (#264, D9).
  final void Function()? onBeforeLeave;

  /// Called with the active note id (or null) so legacy
  /// `selectedNoteIdProvider`-driven widgets stay in sync.
  final void Function(String? activeNoteId) onPersistedSelection;

  /// Whether a click should open a new tab. Null means Cmd, read from
  /// `HardwareKeyboard.instance.isMetaPressed`.
  final bool Function()? isNewTabModifierPressed;

  /// See [TabsNavigationObserver].
  final TabsNavigationObserver? navigationObserver;

  /// Whether a Tab history entry's target still exists (#266, TD9). Null means
  /// every target exists; a throw counts as existing.
  final Future<bool> Function(WorkspaceTab target)? targetExists;

  bool _hydrated = false;

  /// One record per open tab, in step with `state.tabs`.
  List<_TabRecord> _records = [];

  /// Most-recently-used order of tab instances, most recent first. Used for
  /// LRU eviction.
  final List<_TabRecord> _mru = [];

  /// See [TabsState.arrivals].
  int _arrivals = 0;

  /// Whether the last arrival on the active tab returned to an entry (Back,
  /// Forward, a chip switch, focusing an open tab, landing on a neighbour) and
  /// [takeScrollRestore] hasn't handed it out. A flag and not an offset: a gone
  /// entry can still be skipped, so the offset is read when taken.
  bool _restorePending = false;

  _TabRecord? get _activeRecord =>
      _records.isEmpty ? null : _records[state.activeIndex];

  /// Whether [current] is what a click on [target] focuses. A plain canvas
  /// target matches a tab on that canvas, zoomed or not (R2); every other
  /// target, a zoomed canvas included, matches an equal tab. A note is never
  /// matched by a canvas zoomed into it.
  static bool _shows(WorkspaceTab current, WorkspaceTab target) =>
      target is CanvasTab && target.zoomedNoteId == null
      ? current is CanvasTab && current.id == target.id
      : current == target;

  /// The note [tab] shows: a note tab's note or the note a canvas tab is
  /// zoomed into, else null.
  static String? _shownNoteId(WorkspaceTab? tab) => switch (tab) {
    NoteTab(:final id) => id,
    CanvasTab(:final zoomedNoteId) => zoomedNoteId,
    _ => null,
  };

  /// The index of the leftmost tab showing [tab], or -1.
  int _indexShowing(WorkspaceTab tab) =>
      _records.indexWhere((r) => _shows(r.current, tab));

  /// Makes [records] the open tabs, [activeIndex] the active one, and writes
  /// the state they give, `canGoBack` and `canGoForward` included.
  void _write(List<_TabRecord> records, int activeIndex) {
    _records = records;
    if (records.isEmpty) {
      state = TabsState.empty;
      return;
    }
    final active = records[activeIndex];
    state = TabsState(
      tabs: [for (final r in records) r.current],
      activeIndex: activeIndex,
      canGoBack: active.history.canGoBack,
      canGoForward: active.history.canGoForward,
      arrivals: _arrivals,
    );
  }

  /// Marks an arrival on the active tab, before the [_write] that shows it.
  /// A [restore] returns the note to its entry's offset (#270, D39); any other
  /// arrival lands at the top and drops a restore not yet taken.
  void _arrive({bool restore = false}) {
    _restorePending = restore;
    _arrivals++;
  }

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

  /// Restores the tabs written to [store], each with a history of its own.
  /// Neither persists nor emits.
  void _restore() {
    final persisted = store.read();
    final restored = [
      for (final t in persisted.tabs.map(WorkspaceTab.fromPersisted))
        if (t != null) _TabRecord(t),
    ];
    _hydrated = true;
    if (restored.isEmpty) {
      _write([], 0);
      return;
    }
    final active = persisted.activeTabIndex.clamp(0, restored.length - 1);
    _write(restored, active);
    _mru
      ..clear()
      ..add(restored[active])
      ..addAll(restored.where((r) => !identical(r, restored[active])));
  }

  static WorkspaceTab _todayTab(String date, String? noteId) =>
      noteId == null ? VirtualTodayTab(date) : NoteTab(noteId);

  /// Make [today] the active tab: focus the leftmost tab showing it,
  /// otherwise insert it first. Neither persists nor emits.
  void _focusToday(WorkspaceTab today) {
    final existing = _indexShowing(today);
    if (existing >= 0) {
      _touchMru(_records[existing]);
      _write(_records, existing);
      return;
    }
    final record = _TabRecord(today);
    final records = _evictOverCap([record, ..._records], record);
    _touchMru(record);
    _write(records, records.indexOf(record));
  }

  /// Whether moving the active tab to [index] (-1: a new tab) leaves the
  /// active tab. With no tab open nothing is left.
  bool _leavesActive(int index) =>
      _records.isNotEmpty && index != state.activeIndex;

  /// Focus the leftmost tab showing `tab`, restoring its saved scroll offset,
  /// or open a new tab for it at the end, at the top (the Cmd+click path).
  /// Returns the resulting active index.
  int openOrFocus(WorkspaceTab tab) {
    final existing = _indexShowing(tab);
    if (_leavesActive(existing)) {
      onBeforeLeave?.call();
      _arrive(restore: existing >= 0);
    }
    if (existing >= 0) {
      _touchMru(_records[existing]);
      _write(_records, existing);
      _persist();
      _emitSelection();
      return existing;
    }
    final record = _TabRecord(tab);
    final records = _evictOverCap([..._records, record], record);
    final newActive = records.indexOf(record);
    _touchMru(record);
    _write(records, newActive);
    _persist();
    _emitSelection();
    return newActive;
  }

  /// Open today's note (#23's `Today` row entry point) through [follow]: a
  /// plain call navigates the active tab to today's daily note [noteId], or to
  /// the virtual Today note for [date] when [noteId] is null (no daily note
  /// yet); with the new-tab modifier it focuses the leftmost tab showing today
  /// or opens one at the end. The launch alone still inserts today's tab first
  /// ([_focusToday]).
  void openToday({required String date, String? noteId}) =>
      follow(_todayTab(date, noteId));

  /// The virtual Today note for [date] became the real note [noteId] (its
  /// first edit created or found the daily note, #22): every history entry of
  /// it, in every tab, becomes the real note. A tab that showed only the
  /// virtual note closes when [noteId] is already open in another tab. The
  /// active tab stays the active tab; when it closed, the leftmost tab showing
  /// [noteId] becomes active. A no-op when no history holds the virtual note.
  void resolveVirtualToday({required String date, required String noteId}) {
    final virtual = VirtualTodayTab(date);
    if (!_records.any((r) => r.history.entries.contains(virtual))) return;
    final real = NoteTab(noteId);
    final showing = _records.where((r) => r.current == virtual).toSet();
    final realOpen = _records.any(
      (r) => !showing.contains(r) && r.current == real,
    );
    final closing = realOpen
        ? showing
              .where((r) => r.history.entries.every((e) => e == virtual))
              .toSet()
        : const <_TabRecord>{};
    final active = _activeRecord!;
    for (final r in _records) {
      r.history = r.history.rewrite(virtual, real);
    }
    final remaining = _records.where((r) => !closing.contains(r)).toList();
    _mru.removeWhere(closing.contains);
    final activeIndex = closing.contains(active)
        ? remaining.indexWhere((r) => r.current == real)
        : remaining.indexOf(active);
    _write(remaining, activeIndex);
    _persist();
    _emitSelection();
  }

  /// Closes every tab showing [tab] (the delete path), in one state write. A
  /// canvas closes every tab on it, zoomed or not. A note closes the tabs
  /// showing it, and a canvas tab zoomed into it stays open and zooms out: its
  /// current entry becomes the plain canvas, with no new entry (R29-R35).
  /// Older entries zoomed into the note stay and fall to [targetExists].
  void close(WorkspaceTab tab) {
    final closing = _records.where((r) => _shows(r.current, tab)).toSet();
    final zoomedNote = tab is NoteTab ? tab.id : null;
    final zoomOut = zoomedNote == null
        ? const <_TabRecord>{}
        : _records
              .where(
                (r) =>
                    r.current is CanvasTab &&
                    (r.current as CanvasTab).zoomedNoteId == zoomedNote,
              )
              .toSet();
    if (closing.isEmpty && zoomOut.isEmpty) return;
    _closeRecords(closing, zoomOut: zoomOut);
  }

  /// Closes the tab at [index], and only that tab.
  void closeAt(int index) {
    if (index < 0 || index >= _records.length) return;
    _closeRecords({_records[index]});
  }

  /// Closes [closing] and discards their histories; each of [zoomOut] stays
  /// open with its current, zoomed entry replaced by the plain canvas. When the
  /// active tab is among those closed, the nearest remaining tab before it
  /// becomes active, else the first remaining one, at its saved scroll offset;
  /// otherwise the active tab stays active. [onBeforeLeave] runs once when the
  /// active tab is closed or zoomed out, and not otherwise.
  void _closeRecords(
    Set<_TabRecord> closing, {
    Set<_TabRecord> zoomOut = const {},
  }) {
    final active = _activeRecord!;
    final activeCloses = closing.contains(active);
    if (activeCloses || zoomOut.contains(active)) {
      onBeforeLeave?.call();
      _arrive(restore: activeCloses && closing.length < _records.length);
    }
    for (final r in zoomOut) {
      final canvas = r.current as CanvasTab;
      r.move(r.history.replaceCurrent(CanvasTab(canvas.id)));
    }
    final remaining = _records.where((r) => !closing.contains(r)).toList();
    _mru.removeWhere(closing.contains);
    int newActive;
    if (remaining.isEmpty) {
      newActive = 0;
    } else if (activeCloses) {
      final before = _records
          .take(state.activeIndex)
          .where((r) => !closing.contains(r));
      newActive = before.isEmpty ? 0 : remaining.indexOf(before.last);
    } else {
      newActive = remaining.indexOf(active);
    }
    _write(remaining, newActive);
    _persist();
    _emitSelection();
  }

  /// Activates the tab at [index] (a chip switch). Adds no history entry.
  void setActive(int index) {
    if (index < 0 || index >= _records.length) return;
    if (index != state.activeIndex) {
      onBeforeLeave?.call();
      _arrive(restore: true);
    }
    _touchMru(_records[index]);
    _write(_records, index);
    _persist();
    _emitSelection();
  }

  void _touchMru(_TabRecord record) {
    _mru.remove(record);
    _mru.insert(0, record);
  }

  /// The call for any click that goes somewhere (#230): with the new-tab
  /// modifier held, [openOrFocus] the [target]; otherwise [navigate] to it.
  void follow(WorkspaceTab target) {
    navigationObserver?.followed(target);
    _goTo(target, newTab: _newTabModifierHeld);
  }

  /// Shows [target] in the active tab and adds it to that tab's history. With
  /// no tab open, opens the first tab on it. A no-op when the active tab
  /// already shows [target].
  void navigate(WorkspaceTab target) {
    navigationObserver?.navigated(target);
    final active = _activeRecord;
    if (active == null) {
      final record = _TabRecord(target);
      _touchMru(record);
      _write([record], 0);
      _persist();
      _emitSelection();
      return;
    }
    _navigateRecord(active, target);
  }

  /// Pushes [target] onto [record]'s history. Runs [onBeforeLeave] and emits
  /// the selection only when [record] is the active tab. A no-op when
  /// [record] already shows [target].
  void _navigateRecord(_TabRecord record, WorkspaceTab target) {
    if (record.current == target) return;
    final isActive = identical(record, _activeRecord);
    if (isActive) {
      onBeforeLeave?.call();
      _arrive();
    }
    record.move(record.history.push(target));
    _write(_records, state.activeIndex);
    _persist();
    if (isActive) _emitSelection();
  }

  /// Moves the active tab one entry back in its Tab history, then checks the
  /// entry it landed on still exists.
  void back() => _step(forward: false);

  /// Moves the active tab one entry forward in its Tab history, then checks
  /// the entry it landed on still exists.
  void forward() => _step(forward: true);

  void _step({required bool forward}) {
    final record = _activeRecord;
    if (record == null) return;
    final history = record.history;
    if (forward ? !history.canGoForward : !history.canGoBack) return;
    onBeforeLeave?.call();
    _arrive(restore: true);
    record.move(forward ? history.forward() : history.back());
    _write(_records, state.activeIndex);
    _persist();
    _emitSelection();
    _check(record, forward: forward);
  }

  /// Asks [targetExists] about [record]'s current entry. When it is gone and
  /// the tab is still on that entry, the entry is removed and the same
  /// direction continues (TD9).
  void _check(_TabRecord record, {required bool forward}) {
    final exists = targetExists;
    if (exists == null) return;
    final generation = record.generation;
    final Future<bool> answer;
    try {
      answer = exists(record.current);
    } catch (_) {
      return;
    }
    answer.then((there) {
      if (there || !mounted) return;
      if (!_records.contains(record) || record.generation != generation) {
        return;
      }
      _skipGone(record, forward: forward);
    }, onError: (Object _) {});
  }

  /// Removes [record]'s current, gone entry and moves on in the same
  /// direction; with no entry left that way the tab stays on the entry it
  /// left, unchecked.
  void _skipGone(_TabRecord record, {required bool forward}) {
    final history = record.history;
    if (history.entries.length < 2) return;
    final gone = history.index;
    var next = history.remove(gone);
    final bool goOn;
    if (forward) {
      // A later entry took the gone one's place, or the tab is back on the
      // entry it left.
      goOn = next.index == gone;
    } else {
      // The entry it left took the gone one's place; step back past it.
      goOn = next.canGoBack;
      if (goOn) next = next.back();
    }
    final isActive = identical(record, _activeRecord);
    // The restore of the entry that turned out gone may already be taken.
    if (isActive) _arrive(restore: true);
    record.move(next);
    _write(_records, state.activeIndex);
    _persist();
    if (isActive) _emitSelection();
    if (goOn) _check(record, forward: forward);
  }

  /// Sets the active entry's scroll offset when that entry shows [noteId];
  /// otherwise writes nothing, so a stale controller can't write to the wrong
  /// entry (#270, TD7).
  ///
  /// Not a move of the tab: no generation bump (a scroll must not drop a
  /// pending `followLater` or stop a gone entry being skipped), no state write
  /// (the tab bar would rebuild on every tick) and nothing persisted.
  void recordScrollOffset(String noteId, double offset) {
    final active = _activeRecord;
    if (active == null || _shownNoteId(active.current) != noteId) return;
    active.history = active.history.withScrollOffset(offset);
  }

  /// The offset to restore [noteId] to, once, when Back, Forward, a chip
  /// switch, focusing an open tab or landing on a neighbour just arrived on it
  /// (`0.0` for an entry never scrolled). Null for any other arrival and for
  /// any note the active entry doesn't show (#270, TD7, D39). A call for another
  /// note leaves the restore for the right one.
  double? takeScrollRestore(String noteId) {
    final active = _activeRecord;
    if (!_restorePending ||
        active == null ||
        _shownNoteId(active.current) != noteId) {
      return null;
    }
    _restorePending = false;
    return active.history.scrollOffset ?? 0.0;
  }

  /// For a click whose target needs an async lookup: reads the modifier and
  /// the active tab now and returns the function to call with the target
  /// later (Spec R7). With the modifier, it focuses or opens a tab; without,
  /// it navigates the tab it was taken on, active or not, and does nothing
  /// once that tab closed or moved in its history. It does nothing once this
  /// notifier is disposed.
  void Function(WorkspaceTab target) followLater() {
    final newTab = _newTabModifierHeld;
    final taken = _activeRecord;
    final generation = taken?.generation;
    return (WorkspaceTab target) {
      if (!mounted) return;
      navigationObserver?.followed(target);
      if (newTab || taken == null) {
        _goTo(target, newTab: newTab);
        return;
      }
      if (!_records.contains(taken) || taken.generation != generation) return;
      navigationObserver?.navigated(target);
      _navigateRecord(taken, target);
    };
  }

  bool get _newTabModifierHeld =>
      isNewTabModifierPressed?.call() ??
      HardwareKeyboard.instance.isMetaPressed;

  void _goTo(WorkspaceTab target, {required bool newTab}) {
    if (newTab) {
      openOrFocus(target);
    } else {
      navigate(target);
    }
  }

  /// [records] with the least-recently-used tab other than [keep] removed
  /// when they are over [kMaxOpenTabs] (LRU eviction, by tab instance).
  List<_TabRecord> _evictOverCap(List<_TabRecord> records, _TabRecord keep) {
    if (records.length <= kMaxOpenTabs) return records;
    final victim = _pickEvictionVictim(records, keep);
    if (victim == null) return records;
    _mru.remove(victim);
    return records.where((r) => !identical(r, victim)).toList();
  }

  _TabRecord? _pickEvictionVictim(List<_TabRecord> records, _TabRecord keep) {
    // Walk MRU from tail forward, return the first that's still in `records`
    // and isn't [keep].
    for (var i = _mru.length - 1; i >= 0; i--) {
      final candidate = _mru[i];
      if (!identical(candidate, keep) && records.contains(candidate)) {
        return candidate;
      }
    }
    // No prior MRU info — fall back to the oldest tab other than [keep].
    for (final r in records) {
      if (!identical(r, keep)) return r;
    }
    return null;
  }

  void _persist() {
    if (!_hydrated) return;
    final existing = store.read();
    // The virtual Today tab is never written (D26); the active index moves
    // onto the remaining tabs (to the next one when the virtual tab is
    // active). Tab histories are never written (R19).
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

  void _emitSelection() => onPersistedSelection(_shownNoteId(state.activeTab));
}

/// `unawaited` polyfill — avoids pulling in `dart:async` just for the helper.
void unawaited(Future<void> _) {}

/// The [TabsNavigationObserver] handed to the notifier [tabsProvider] builds.
final tabsNavigationObserverProvider = Provider<TabsNavigationObserver?>(
  (_) => null,
);

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
    // Read when a leave happens, not while this provider builds: the editor
    // controller reads `tabsProvider` too.
    onBeforeLeave: () =>
        ref.read(editorControllerProvider.notifier).flushPendingSave(),
    // Opening a vault lands on today's note (#22). Read once: the launch
    // date sticks to the tab across midnight (D14).
    todayDate: vaultPath == null ? null : ref.read(todayDateProvider),
    todayNoteId: vaultPath == null ? null : _readTodayNote(ref)?.noteId,
    navigationObserver: ref.watch(tabsNavigationObserverProvider),
    targetExists: (target) => _targetExists(ref, target),
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

/// Whether [target] still exists in the open vault (#266, TD9): false only
/// when `getNote` or `getCanvasDetail` answers null (a zoomed canvas entry
/// needs both its canvas and its note). A virtual Today note, a
/// folder-scoped or whole-vault Graph view, no vault access and any read
/// failure (`VaultUnreachableException` included) count as existing, with
/// no read where none is needed.
Future<bool> _targetExists(Ref<Object?> ref, WorkspaceTab target) async {
  if (target is VirtualTodayTab) return true;
  try {
    // Read when asked, not while `tabsProvider` builds.
    final access = ref.read(vaultAccessProvider);
    if (access == null) return true;
    switch (target) {
      case NoteTab(:final id):
        return await access.notes.getNote(id) != null;
      case CanvasTab(:final id, :final zoomedNoteId):
        // The canvas first: with it gone, no note is read.
        if (await access.canvas.getCanvasDetail(id) == null) return false;
        return zoomedNoteId == null ||
            await access.notes.getNote(zoomedNoteId) != null;
      case GraphTab(:final scope):
        return switch (scope.kind) {
          GraphScopeKind.topic ||
          GraphScopeKind.day => await access.notes.getNote(scope.id) != null,
          GraphScopeKind.folder || GraphScopeKind.vault => true,
        };
    }
  } catch (_) {
    return true;
  }
}

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
