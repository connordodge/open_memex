// WI #270 (N7): scroll offsets live on Tab history entries. `NoteEditor` reports
// through `recordScrollOffset`, and Back, Forward and a chip switch mark the
// arrival as a restore that `takeScrollRestore` hands out once (Spec TD7, R26).
// `*` in a test comment marks the active tab. The editor's side is in
// `app/test/widgets/scroll_restore_test.dart`.
//
// Answers from `targetExists` come from Completers, never wall waits.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';

const _a = NoteTab('a');
const _b = NoteTab('b');
const _c = NoteTab('c');
const _d = NoteTab('d');
const _board = CanvasTab('board');
const _zoomedA = CanvasTab('board', zoomedNoteId: 'a');

const _today = '2026-10-03';
const _virtual = VirtualTodayTab(_today);
const _realId = 'real-today';

/// A UiStateStore that never touches disk and counts its writes.
class _MemoryStore extends UiStateStore {
  _MemoryStore()
    : _last = UiState(
        tabs: const [],
        activeTabIndex: 0,
        canvasViewports: const {},
      ),
      super(vaultPath: '/nonexistent/tabs-scroll');

  UiState _last;
  int writes = 0;

  @override
  UiState read() => _last;

  @override
  Future<void> write(UiState state) {
    _last = state;
    writes++;
    return Future<void>.value();
  }

  @override
  Future<void> flush() => Future<void>.value();
}

/// A `targetExists` a test controls: [gone] answers false at once; with
/// [holding], every call waits until the test completes its entry in [held].
class _Exists {
  final gone = <WorkspaceTab>{};
  final held = <Completer<bool>>[];
  bool holding = false;

  Future<bool> call(WorkspaceTab target) {
    if (holding) {
      final answer = Completer<bool>();
      held.add(answer);
      return answer.future;
    }
    return Future<bool>.value(!gone.contains(target));
  }
}

/// A notifier on a memory store, with its side effects counted.
class _Probe {
  _Probe({_Exists? exists}) {
    notifier = TabsNotifier(
      store: store,
      onPersistedSelection: selections.add,
      onBeforeLeave: () => leaves++,
      isNewTabModifierPressed: () => false,
      targetExists: exists?.call,
    );
    notifier.addListener((_) => stateWrites++, fireImmediately: false);
    addTearDown(notifier.dispose);
  }

  final store = _MemoryStore();
  final selections = <String?>[];
  late final TabsNotifier notifier;
  int stateWrites = 0;
  int leaves = 0;

  /// A tab on [first], history `[first, ...rest]`, on the last entry.
  void walk(WorkspaceTab first, [List<WorkspaceTab> rest = const []]) {
    notifier.navigate(first);
    rest.forEach(notifier.navigate);
  }

  /// Records [offset] for [tab]'s note, which the active entry shows.
  void scroll(String noteId, double offset) =>
      notifier.recordScrollOffset(noteId, offset);

  double? take(String noteId) => notifier.takeScrollRestore(noteId);
}

/// Lets a `targetExists` answer reach the notifier.
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.value();
  }
}

void main() {
  group('takeScrollRestore on a restore arrival (AC 10)', () {
    test('takeScrollRestore returns the offset once for a back arrival', () {
      final p = _Probe()..walk(_a);
      p.scroll('a', 250);
      p.notifier.navigate(_b);

      p.notifier.back();

      expect(p.take('a'), 250);
      expect(p.take('a'), isNull, reason: 'handed out once');
    });

    test('takeScrollRestore returns the offset once for a forward arrival', () {
      final p = _Probe()..walk(_a, [_b]);
      p.scroll('b', 310);
      p.notifier.back();
      expect(p.take('a'), isNotNull, reason: 'the arrival on a, used up');

      p.notifier.forward();

      expect(p.take('b'), 310);
      expect(p.take('b'), isNull);
    });

    test('takeScrollRestore returns the offset once for a chip switch', () {
      final p = _Probe()..walk(_a);
      p.scroll('a', 420);
      p.notifier.openOrFocus(_b);
      expect(p.notifier.state.activeIndex, 1);

      p.notifier.setActive(0);

      expect(p.take('a'), 420);
      expect(p.take('a'), isNull);
    });

    test(
      'takeScrollRestore returns null for a navigate arrival and for a navigate to a note visited earlier and left scrolled',
      () {
        final p = _Probe()..walk(_a);
        expect(p.take('a'), isNull, reason: 'the first entry was navigated to');
        p.scroll('a', 250);

        p.notifier.navigate(_b);
        expect(p.take('b'), isNull);

        p.notifier.navigate(_a); // [a, b, a]
        expect(p.take('a'), isNull, reason: 'a new entry, never scrolled');

        p.notifier.back();
        p.notifier.back();
        expect(p.take('a'), 250, reason: 'the first entry kept its offset');
      },
    );

    test(
      'takeScrollRestore for a different note id returns null and does not consume the restore',
      () {
        final p = _Probe()..walk(_a);
        p.scroll('a', 250);
        p.notifier.navigate(_b);
        p.notifier.back();

        expect(p.take('b'), isNull, reason: 'the note just left');
        expect(p.take('c'), isNull, reason: 'a note this tab never showed');

        expect(p.take('a'), 250);
      },
    );

    test(
      'a restore not yet taken is dropped by a navigate so that the note lands at the top',
      () {
        final p = _Probe()..walk(_a);
        p.scroll('a', 250);
        p.notifier.navigate(_b);
        p.notifier.back();

        p.notifier.navigate(_c);

        expect(p.take('c'), isNull);
        expect(p.take('a'), isNull);
        p.notifier.back();
        expect(p.take('a'), 250, reason: 'Back marks a new arrival');
      },
    );

    test(
      'the arrival is read when taken so back then forward hands out the entry reached last',
      () {
        final p = _Probe()..walk(_a);
        p.scroll('a', 100);
        p.notifier.navigate(_b);
        p.scroll('b', 200);
        p.notifier.back();
        p.notifier.forward();

        expect(p.take('a'), isNull);
        expect(p.take('b'), 200);
      },
    );

    test('a back or forward with nowhere to go marks no arrival', () {
      final p = _Probe()..walk(_a);
      p.scroll('a', 250);

      p.notifier.back();
      expect(p.take('a'), isNull, reason: 'no entry before it');

      p.notifier.forward();
      expect(p.take('a'), isNull, reason: 'no entry after it');
    });

    test(
      'a chip switch to the active tab or to no tab marks no arrival and keeps a pending restore',
      () {
        final p = _Probe()..walk(_a);
        p.scroll('a', 250);

        p.notifier.setActive(0);
        expect(p.take('a'), isNull, reason: 'the current tab is no arrival');

        p.notifier.setActive(7);
        expect(p.take('a'), isNull, reason: 'past the end');
        p.notifier.setActive(-1);
        expect(p.take('a'), isNull, reason: 'before the start');

        p.notifier.navigate(_b);
        p.notifier.back();
        p.notifier.setActive(0);
        expect(p.take('a'), 250, reason: 'the Back arrival is still pending');
      },
    );

    test(
      'an entry never scrolled returns 0.0 on a restore arrival and null when navigated to',
      () {
        final p = _Probe()..walk(_a, [_b]);

        p.notifier.back();
        expect(p.take('a'), 0.0, reason: 'null would run the daily caret jump');
        p.notifier.forward();
        expect(p.take('b'), 0.0);

        p.notifier.navigate(_c);
        expect(p.take('c'), isNull);
      },
    );

    test(
      'a chip switch from another note and back hands out each tab its own offset',
      () {
        final p = _Probe()..walk(_a);
        p.scroll('a', 111);
        p.notifier.navigate(_b); // [b*] with history a, b
        p.notifier.openOrFocus(_c); // [b] [c*]
        p.scroll('c', 333);

        p.notifier.setActive(0);
        expect(p.take('b'), 0.0, reason: 'its current entry never scrolled');

        p.notifier.setActive(1);
        expect(p.take('c'), 333);
      },
    );
  });

  group('any other arrival lands at the top (TD7, read from R26)', () {
    test(
      'openOrFocus focusing a tab is no restore and drops a pending one',
      () {
        final p = _Probe()..walk(_a);
        p.scroll('a', 250);
        p.notifier.openOrFocus(_b); // [a] [b*]

        p.notifier.openOrFocus(_a); // [a*] [b]
        expect(p.take('a'), isNull);

        p.notifier.setActive(1); // a pending restore on b
        p.notifier.openOrFocus(_a);
        expect(p.take('b'), isNull);
        expect(p.take('a'), isNull);
      },
    );

    test(
      'openOrFocus onto a tab on the same note is no restore and openOrFocus opening a tab is none',
      () {
        final p = _Probe()..walk(_a);
        p.scroll('a', 250);
        p.notifier.openOrFocus(_b);
        p.notifier.navigate(_a); // [a] [a*], the second has history b, a
        p.scroll('a', 90);
        expect(p.notifier.state.activeIndex, 1);

        p.notifier.openOrFocus(_a); // the leftmost: [a*] [a]
        expect(p.notifier.state.activeIndex, 0);
        expect(p.take('a'), isNull);

        p.notifier.setActive(1);
        p.notifier.openOrFocus(_c); // a pending restore, then a new tab
        expect(p.take('a'), isNull);
        expect(p.take('c'), isNull);
      },
    );

    test(
      'landing on a neighbour after closing the active tab is no restore',
      () {
        final p = _Probe()..walk(_a);
        p.scroll('a', 250);
        p.notifier.openOrFocus(_b); // [a] [b*]
        p.notifier.close(_b); // [a*]
        expect(p.take('a'), isNull);

        p.notifier.openOrFocus(_c); // [a] [c*]
        p.notifier.setActive(0); // a pending restore on a
        p.notifier.closeAt(0); // [c*]
        expect(p.take('a'), isNull);
        expect(p.take('c'), isNull);
      },
    );

    test('closing another tab leaves a pending restore', () {
      final p = _Probe()..walk(_a);
      p.scroll('a', 250);
      p.notifier.openOrFocus(_b);
      p.notifier.setActive(0); // [a*] [b], a pending restore on a

      p.notifier.close(_b);

      expect(p.take('a'), 250);
    });

    test('openToday is no restore and drops a pending one', () {
      final p = _Probe()..walk(_a);
      p.scroll('a', 250);
      p.notifier.openOrFocus(_b);
      p.scroll('b', 80);
      p.notifier.openOrFocus(_c); // [a] [b] [c*]
      p.notifier.setActive(0); // a pending restore on a

      p.notifier.openToday(date: _today, noteId: 'b');

      expect(p.notifier.state.activeTab, _b);
      expect(p.take('a'), isNull);
      expect(p.take('b'), isNull);
    });

    test(
      'a followLater result that navigates an inactive tab is no arrival and keeps the active tab restore',
      () {
        final p = _Probe()..walk(_a);
        p.scroll('a', 250);
        final later = p.notifier.followLater();
        p.notifier.openOrFocus(_b); // [a] [b*]
        p.scroll('b', 80);
        p.notifier.openOrFocus(_d); // [a] [b] [d*]
        p.notifier.setActive(1); // a pending restore on b

        later(_c); // the lookup taken on the first tab comes back

        expect(p.notifier.state.tabs, [_c, _b, _d]);
        expect(p.notifier.state.activeTab, _b);
        expect(p.take('b'), 80);
      },
    );

    test(
      'a followLater result that navigates the active tab drops a restore',
      () {
        final p = _Probe()..walk(_a);
        final later = p.notifier.followLater();
        p.notifier.openOrFocus(_b);
        p.notifier.setActive(0); // a pending restore on a, generation unchanged

        later(_c);

        expect(p.notifier.state.activeTab, _c);
        expect(p.take('c'), isNull);
        expect(p.take('a'), isNull);
      },
    );
  });

  group('recordScrollOffset writes only to the active entry (AC 9)', () {
    test(
      'recordScrollOffset for a note the active entry does not show writes nothing',
      () {
        final p = _Probe()..walk(_a, [_b]); // on b

        p.scroll('a', 300);
        p.scroll('zzz', 301);

        p.notifier.back();
        expect(p.take('a'), 0.0, reason: 'a was not the active entry');
        p.notifier.forward();
        expect(p.take('b'), 0.0, reason: 'b is not the note reported');
      },
    );

    test(
      'recordScrollOffset writes to the active tab only when two tabs show one note',
      () {
        final p = _Probe()..walk(_a);
        p.notifier.openOrFocus(_b);
        p.notifier.navigate(_a); // [a] [a*]
        p.scroll('a', 90);

        p.notifier.setActive(0);
        expect(p.take('a'), 0.0, reason: 'the other tab never scrolled');

        p.notifier.setActive(1);
        expect(p.take('a'), 90);
      },
    );

    test(
      'recordScrollOffset with a Graph view a plain canvas or no tab active writes nothing and does not throw',
      () {
        final p = _Probe();
        p.scroll('a', 10); // no tab open
        expect(p.notifier.state.tabs, isEmpty);

        p.walk(_a);
        p.notifier.navigate(_board);
        p.scroll('a', 20);
        p.scroll('board', 21);
        p.notifier.navigate(GraphTab(const GraphScope.topic('a')));
        p.scroll('a', 30);
        p.scroll('topic:a', 31);

        p.notifier.back();
        expect(p.take('board'), isNull, reason: 'a canvas shows no note');
        p.notifier.back();
        expect(p.take('a'), 0.0, reason: 'nothing reached the entry on a');
      },
    );

    test(
      'a zoomed note counts as the active entry note and keeps its own offset on back and forward',
      () {
        final p = _Probe()..walk(_board, [_zoomedA]);
        p.scroll('a', 640);

        p.notifier.back(); // the plain canvas
        expect(p.notifier.state.activeTab, _board);
        expect(p.take('a'), isNull, reason: 'the canvas shows no note');
        p.scroll('a', 999);

        p.notifier.forward();
        expect(p.take('a'), 640);

        p.notifier.navigate(_b);
        p.notifier.back();
        expect(p.take('b'), isNull);
        expect(p.take('a'), 640);
      },
    );

    test('a zoomed entry and a note tab on one note keep separate offsets', () {
      final p = _Probe()..walk(_a);
      p.scroll('a', 111);
      p.notifier.navigate(_zoomedA);
      p.scroll('a', 222);

      p.notifier.back();
      expect(p.take('a'), 111);
      p.notifier.forward();
      expect(p.take('a'), 222);
    });

    test('the last offset recorded for an entry is the one handed out', () {
      final p = _Probe()..walk(_a);
      p.scroll('a', 100);
      p.scroll('a', 400);
      p.scroll('a', 0);
      p.notifier.navigate(_b);

      p.notifier.back();

      expect(p.take('a'), 0.0);
    });
  });

  group('a scroll is not a move of the tab', () {
    test(
      'recordScrollOffset writes no state persists nothing and runs no leave or selection',
      () {
        final p = _Probe()..walk(_a);
        final (writes, saved, leaves, selected) = (
          p.stateWrites,
          p.store.writes,
          p.leaves,
          p.selections.length,
        );

        p.scroll('a', 500);

        expect(p.stateWrites, writes, reason: 'the tab bar would rebuild');
        expect(p.store.writes, saved, reason: 'histories are never persisted');
        expect(p.leaves, leaves);
        expect(p.selections, hasLength(selected));
        p.notifier.navigate(_b);
        p.notifier.back();
        expect(p.take('a'), 500, reason: 'the offset still reached the entry');
      },
    );

    test(
      'a scroll during a pending followLater lookup does not drop the click',
      () {
        final p = _Probe()..walk(_a);
        final later = p.notifier.followLater();

        p.scroll('a', 500);
        later(_b);

        expect(p.notifier.state.activeTab, _b);
        p.notifier.back();
        expect(p.take('a'), 500);
      },
    );

    test(
      'a scroll during a pending targetExists answer does not stop a gone entry being skipped',
      () async {
        final exists = _Exists();
        final p = _Probe(exists: exists)..walk(_a);
        p.scroll('a', 100);
        p.notifier.navigate(_b);
        p.notifier.navigate(_c);
        exists.holding = true;

        p.notifier.back(); // onto b, held
        p.scroll('b', 700);
        exists.held.single.complete(false);
        await _settle();

        expect(p.notifier.state.activeTab, _a, reason: 'b is gone');
        expect(p.take('a'), 100);
      },
    );
  });

  group('a gone entry on the way back or forward', () {
    test(
      'back onto a gone note lands on the earlier entry at its own offset',
      () async {
        final exists = _Exists();
        final p = _Probe(exists: exists)..walk(_a);
        p.scroll('a', 100);
        p.notifier.navigate(_b);
        p.scroll('b', 200);
        p.notifier.navigate(_c);
        exists.gone.add(_b);

        p.notifier.back();
        await _settle();

        expect(p.notifier.state.activeTab, _a);
        expect(p.take('b'), isNull);
        expect(p.take('a'), 100);
        expect(p.take('a'), isNull);
      },
    );

    test(
      'forward onto a gone note lands on the later entry at its own offset',
      () async {
        final exists = _Exists();
        final p = _Probe(exists: exists)..walk(_a, [_b]);
        p.scroll('b', 200);
        p.notifier.navigate(_c);
        p.scroll('c', 300);
        p.notifier.back();
        p.notifier.back(); // on a, the two arrivals not taken
        expect(p.notifier.state.activeTab, _a);
        exists.gone.add(_b);

        p.notifier.forward();
        await _settle();

        expect(p.notifier.state.activeTab, _c);
        expect(p.take('c'), 300);
      },
    );

    test(
      'a restore taken before the entry turned out gone is marked again for the entry it skips to',
      () async {
        final exists = _Exists();
        final p = _Probe(exists: exists)..walk(_a);
        p.scroll('a', 100);
        p.notifier.navigate(_b);
        p.scroll('b', 200);
        p.notifier.navigate(_c);
        exists.holding = true;

        p.notifier.back();
        expect(p.take('b'), 200, reason: 'the note was still readable');
        exists.held.single.complete(false);
        await _settle();

        expect(p.notifier.state.activeTab, _a);
        expect(p.take('a'), 100);
      },
    );

    test(
      'back with every earlier entry gone stays on the entry it left at its own offset',
      () async {
        final exists = _Exists();
        final p = _Probe(exists: exists)..walk(_a);
        p.notifier.navigate(_b);
        p.scroll('b', 200);
        exists.gone.add(_a);

        p.notifier.back();
        await _settle();

        expect(p.notifier.state.activeTab, _b);
        expect(p.take('b'), 200);
      },
    );

    test(
      'a gone entry skipped in a tab no longer active marks no arrival on the active tab',
      () async {
        final exists = _Exists();
        final p = _Probe(exists: exists)..walk(_a);
        p.scroll('a', 100);
        p.notifier.navigate(_b);
        p.notifier.navigate(_c); // [c*], history a, b, c
        p.notifier.openOrFocus(_d); // [c] [d*]
        p.scroll('d', 400);
        p.notifier.setActive(0);
        exists.holding = true;

        p.notifier.back(); // the first tab onto b, held
        p.notifier.setActive(1);
        expect(p.take('d'), 400, reason: 'the chip switch, used up');
        exists.held.single.complete(false);
        await _settle();

        expect(p.notifier.state.tabs, [_a, _d], reason: 'b was skipped');
        expect(p.notifier.state.activeTab, _d);
        expect(p.take('d'), isNull, reason: 'the skip was in the other tab');
      },
    );
  });

  group('a virtual Today note becoming real', () {
    test(
      'a virtual Today note resolving does not consume a pending restore and its entry keeps its offset',
      () {
        final p = _Probe()..walk(_virtual);
        p.scroll(_virtual.id, 120);
        p.notifier.navigate(_a);
        p.notifier.back(); // a pending restore on the virtual note

        p.notifier.resolveVirtualToday(date: _today, noteId: _realId);

        expect(p.notifier.state.activeTab, const NoteTab(_realId));
        expect(p.take(_virtual.id), isNull, reason: 'the entry is real now');
        expect(p.take(_realId), 120);
      },
    );

    test('a virtual Today note resolving is no arrival by itself', () {
      final p = _Probe()..walk(_virtual);
      p.scroll(_virtual.id, 120);

      p.notifier.resolveVirtualToday(date: _today, noteId: _realId);

      expect(p.take(_realId), isNull);
      p.notifier.navigate(_a);
      p.notifier.back();
      expect(p.take(_realId), 120, reason: 'the rewrite kept the offset');
    });
  });

  group('TabsState arrivals', () {
    test(
      'TabsState arrivals defaults to zero and copyWith carries or replaces it',
      () {
        const plain = TabsState(tabs: [_a], activeIndex: 0);
        expect(plain.arrivals, 0);
        expect(TabsState.empty.arrivals, 0);

        final counted = plain.copyWith(arrivals: 3);
        expect(counted.arrivals, 3);
        expect(counted.copyWith(activeIndex: 0).arrivals, 3, reason: 'kept');
        expect(counted.copyWith(arrivals: 4).arrivals, 4, reason: 'replaced');
        expect(counted.copyWith(canGoBack: true).arrivals, 3);
        expect(plain.copyWith(arrivals: 1).tabs, [_a]);
      },
    );

    test(
      'TabsState arrivals counts each arrival and not a scroll or a chip tap on the active tab',
      () {
        final p = _Probe()..walk(_a);
        final start = p.notifier.state.arrivals;

        p.notifier.navigate(_b);
        expect(p.notifier.state.arrivals, start + 1);
        p.scroll('b', 40);
        p.notifier.setActive(0);
        expect(p.notifier.state.arrivals, start + 1, reason: 'no arrival');
        p.notifier.back();
        expect(p.notifier.state.arrivals, start + 2);
        p.notifier.forward();
        expect(p.notifier.state.arrivals, start + 3);
        expect(p.notifier.state.activeNoteId, 'b');
      },
    );
  });
}
