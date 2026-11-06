// WI #266 (N3): plain clicks navigate the current tab, each tab keeps its own
// Tab history, Back and Forward walk it and skip a gone target. `*` in a test
// comment marks the active tab.
//
// Answers from `targetExists` come from Completers (`_Exists.hold`), never wall
// waits. Call sites are in `app/test/widgets/follow_call_sites_test.dart`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/canvas_seeds.dart';
import '../support/recording_tabs.dart';
import '../support/today_cli_fakes.dart';

const _a = NoteTab('a');
const _b = NoteTab('b');
const _c = NoteTab('c');
const _d = NoteTab('d');
const _x = NoteTab('x');
const _y = NoteTab('y');
const _target = NoteTab('target');
const _board = CanvasTab('board');

const _today = '2026-10-03';
const _virtual = VirtualTodayTab(_today);
const _realId = 'real-today';
const _real = NoteTab(_realId);

const _unreachable = VaultUnreachableException(
  serverName: 'nas',
  mayHaveCommitted: false,
);

/// A UiStateStore that never touches disk and counts its writes.
class _MemoryStore extends UiStateStore {
  _MemoryStore([List<WorkspaceTab> restored = const [], int active = 0])
    : _last = UiState(
        tabs: [for (final t in restored) t.toPersisted()],
        activeTabIndex: active,
        canvasViewports: const {},
      ),
      super(vaultPath: '/nonexistent/tabs-navigate');

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

/// A `targetExists` a test controls: [gone] answers false at once; after
/// [hold], every call waits until the test completes its entry in [held].
class _Exists {
  final gone = <WorkspaceTab>{};
  final calls = <WorkspaceTab>[];
  final held = <Completer<bool>>[];
  bool holding = false;

  void hold() => holding = true;

  /// Completes the [i]th held call with [exists].
  void answer(int i, bool exists) {
    expect(
      held.length,
      greaterThan(i),
      reason: 'targetExists was asked for the entry Back or Forward landed on',
    );
    held[i].complete(exists);
  }

  /// Completes the only held call with [exists].
  void answerOnly(bool exists) {
    expect(held, hasLength(1), reason: 'exactly one targetExists call waits');
    held.single.complete(exists);
  }

  Future<bool> call(WorkspaceTab target) {
    calls.add(target);
    if (holding) {
      final answer = Completer<bool>();
      held.add(answer);
      return answer.future;
    }
    return Future<bool>.value(!gone.contains(target));
  }
}

/// A notifier with a probe on its callbacks. Counters start after the launch.
class _Probe {
  _Probe(this.notifier, this.store, this.recorder);

  final TabsNotifier notifier;
  final _MemoryStore store;
  final TabsRecorder recorder;

  /// The selection each `onPersistedSelection` call carried.
  final selections = <String?>[];

  /// `state` as each `onBeforeLeave` call saw it.
  final seen = <TabsState>[];

  /// State writes the notifier's listeners saw.
  int writes = 0;

  TabsState get state => notifier.state;
  int get leaves => seen.length;

  /// Forgets the calls so far, so the expectations cover only what follows.
  void reset() {
    selections.clear();
    seen.clear();
    writes = 0;
    store.writes = 0;
  }

  /// `openOrFocus` of each of [tabs], ending on the last, then [reset].
  void open(List<WorkspaceTab> tabs, {int? active}) {
    for (final t in tabs) {
      notifier.openOrFocus(t);
    }
    if (active != null) notifier.setActive(active);
    reset();
  }

  /// `navigate` to each of [targets], then [reset].
  void walk(List<WorkspaceTab> targets) {
    for (final t in targets) {
      notifier.navigate(t);
    }
    reset();
  }
}

Future<_Probe> _probe({
  _MemoryStore? store,
  List<WorkspaceTab> restored = const [],
  int active = 0,
  _Exists? exists,
  bool Function()? modifier,
  String? todayDate,
  String? todayNoteId,
}) async {
  final memory = store ?? _MemoryStore(restored, active);
  final recorder = TabsRecorder();
  late final _Probe probe;
  final notifier = TabsNotifier(
    store: memory,
    onPersistedSelection: (id) => probe.selections.add(id),
    onBeforeLeave: () => probe.seen.add(probe.notifier.state),
    todayDate: todayDate,
    todayNoteId: todayNoteId,
    isNewTabModifierPressed: modifier ?? () => false,
    navigationObserver: recorder.observer,
    targetExists: exists?.call,
  );
  probe = _Probe(notifier, memory, recorder);
  addTearDown(() {
    if (notifier.mounted) notifier.dispose();
  });
  notifier.addListener((_) => probe.writes++, fireImmediately: false);
  // The launch's selection is emitted in a microtask.
  await pumpEventQueue();
  probe.reset();
  return probe;
}

void _expectTabs(
  _Probe p,
  List<WorkspaceTab> tabs,
  int active, {
  bool back = false,
  bool forward = false,
}) {
  expect(p.state.tabs, tabs, reason: 'what each tab shows');
  expect(p.state.activeIndex, active, reason: 'the active index');
  expect(p.state.canGoBack, back, reason: 'canGoBack');
  expect(p.state.canGoForward, forward, reason: 'canGoForward');
}

/// Exactly one leave, seen before the state changed.
void _expectLeftOnceFrom(_Probe p, TabsState before) {
  expect(p.leaves, 1, reason: 'onBeforeLeave runs exactly once');
  expect(p.seen.single.tabs, before.tabs, reason: 'it runs before the change');
  expect(p.seen.single.activeIndex, before.activeIndex);
}

List<NoteTab> _notes(int count) => [
  for (var i = 0; i < count; i++) NoteTab('n$i'),
];

void main() {
  group('navigate', () {
    test(
      'navigate replaces what the active tab shows and leaves other tabs and the active index alone',
      () async {
        final p = await _probe();
        p.open([_a, _b, _c], active: 1);

        p.notifier.navigate(_d);

        _expectTabs(p, [_a, _d, _c], 1, back: true);
        expect(p.selections, ['d']);
      },
    );

    test('navigate adds a history entry that back returns to', () async {
      final p = await _probe();
      p.open([_a, _b, _c], active: 1);

      p.notifier.navigate(_d);
      p.notifier.back();

      _expectTabs(p, [_a, _b, _c], 1, forward: true);
      expect(p.selections, ['d', 'b']);
    });

    test(
      'a canvas and a Graph view navigate in place and clear the note selection',
      () async {
        final graph = GraphTab(const GraphScope.vault());
        final p = await _probe();
        p.open([_a, _x], active: 0);

        p.notifier.navigate(_board);
        _expectTabs(p, [_board, _x], 0, back: true);
        expect(p.selections.last, isNull);

        p.notifier.navigate(graph);
        _expectTabs(p, [graph, _x], 0, back: true);
        expect(p.selections.last, isNull);

        p.notifier.back();
        p.notifier.back();
        _expectTabs(p, [_a, _x], 0, forward: true);
        expect(p.selections.last, 'a');
      },
    );

    test(
      'a plain click to B from A with B open gives two tabs showing B and back gives A',
      () async {
        final p = await _probe();
        p.open([_a, _b], active: 0);

        p.notifier.follow(_b);
        _expectTabs(p, [_b, _b], 0, back: true);

        p.notifier.back();
        _expectTabs(p, [_a, _b], 0, forward: true);
      },
    );

    test(
      'navigate from the last tab to the first tab value stays in the last tab',
      () async {
        final p = await _probe();
        p.open([_a, _b]);

        p.notifier.navigate(_a);

        _expectTabs(p, [_a, _a], 1, back: true);
      },
    );

    test(
      'navigate with no tabs creates the first tab active with canGoBack false',
      () async {
        final p = await _probe();

        p.notifier.navigate(_a);

        _expectTabs(p, [_a], 0);
        expect(p.selections, ['a']);
        expect(p.leaves, 0, reason: 'with nothing active nothing is left');

        p.notifier.navigate(_b);
        _expectTabs(p, [_b], 0, back: true);
      },
    );

    test(
      'navigate to what the active tab shows adds no entry leaves Forward in place and changes nothing',
      () async {
        final p = await _probe();
        p.open([_a, _x], active: 0);
        p.walk([_b, _c]);
        p.notifier.back();
        p.reset();

        p.notifier.navigate(_b);

        _expectTabs(p, [_b, _x], 0, back: true, forward: true);
        expect(p.writes, 0, reason: 'no state write');
        expect(p.store.writes, 0, reason: 'no persist');
        expect(p.selections, isEmpty, reason: 'no selection');
        p.notifier.forward();
        _expectTabs(p, [_c, _x], 0, back: true);
        p.notifier.back();
        p.notifier.back();
        _expectTabs(p, [_a, _x], 0, forward: true);
      },
    );

    test(
      'navigate to what the active tab shows at the end of history adds no entry',
      () async {
        final p = await _probe();
        p.open([_a]);
        p.walk([_b]);

        p.notifier.navigate(_b);
        p.notifier.back();

        _expectTabs(p, [_a], 0, forward: true);
      },
    );

    test('navigate at the tab cap evicts nothing', () async {
      final p = await _probe();
      p.open(_notes(kMaxOpenTabs));

      p.notifier.navigate(_target);

      expect(p.state.tabs, [..._notes(kMaxOpenTabs - 1), _target]);
      expect(p.state.activeIndex, kMaxOpenTabs - 1);
    });
  });

  group('follow with the modifier', () {
    test(
      'follow with the modifier focuses the leftmost tab showing the target and leaves its history untouched',
      () async {
        var held = false;
        final p = await _probe(modifier: () => held);
        p.open([_a, _b], active: 0);
        p.notifier.follow(_b); // [b*] [b], the left one with a behind it.
        p.notifier.setActive(1);
        p.reset();
        held = true;

        p.notifier.follow(_b);

        _expectTabs(p, [_b, _b], 0, back: true);
        expect(p.state.tabs, hasLength(2));
        p.notifier.back();
        _expectTabs(p, [_a, _b], 0, forward: true);
      },
    );

    test(
      'follow with the modifier focusing a tab keeps that tab at its history position',
      () async {
        var held = false;
        final p = await _probe(modifier: () => held);
        p.open([_a, _x], active: 0);
        p.walk([_b, _c]);
        p.notifier.back(); // [b*] [x], with a behind and c ahead.
        p.notifier.setActive(1);
        held = true;

        p.notifier.follow(_b);

        _expectTabs(p, [_b, _x], 0, back: true, forward: true);
      },
    );

    test(
      'follow with the modifier opens a new tab at the end whose history holds only the target',
      () async {
        final p = await _probe(modifier: () => true);
        p.open([_a, _b], active: 0);

        p.notifier.follow(_target);

        _expectTabs(p, [_a, _b, _target], 2);
        p.notifier.navigate(_c);
        p.notifier.back();
        _expectTabs(p, [_a, _b, _target], 2, forward: true);
      },
    );

    test(
      'a Cmd click to B from A focuses B and a Cmd click to C opens C at the end',
      () async {
        final p = await _probe(modifier: () => true);
        p.open([_a, _b], active: 0);
        p.notifier.navigate(_y);
        p.notifier.back();
        p.reset();

        p.notifier.follow(_b);
        _expectTabs(p, [_a, _b], 1);

        p.notifier.follow(_c);
        _expectTabs(p, [_a, _b, _c], 2);

        p.notifier.setActive(0);
        _expectTabs(p, [_a, _b, _c], 0, forward: true);
      },
    );

    test(
      'openOrFocus returns the index of the leftmost tab showing the value when values repeat',
      () async {
        final p = await _probe();
        p.open([_x, _b]);
        p.notifier.setActive(0);
        p.notifier.navigate(_b); // [b*] [b]
        p.notifier.setActive(1);

        expect(p.notifier.openOrFocus(_b), 0);
        expect(p.state.activeIndex, 0);
      },
    );
  });

  group('back and forward', () {
    test('back and forward move one entry on the active tab', () async {
      final p = await _probe();
      p.open([_a, _x], active: 0);
      p.walk([_b, _c]);

      p.notifier.back();
      _expectTabs(p, [_b, _x], 0, back: true, forward: true);

      p.notifier.back();
      _expectTabs(p, [_a, _x], 0, forward: true);

      p.notifier.forward();
      _expectTabs(p, [_b, _x], 0, back: true, forward: true);

      p.notifier.forward();
      _expectTabs(p, [_c, _x], 0, back: true);
      expect(p.selections, ['b', 'a', 'b', 'c']);
    });

    test('navigating after back drops the Forward entries', () async {
      final p = await _probe();
      p.open([_a]);
      p.walk([_b, _c]);
      p.notifier.back();

      p.notifier.navigate(_d);

      _expectTabs(p, [_d], 0, back: true);
      p.notifier.forward();
      _expectTabs(p, [_d], 0, back: true);
      p.notifier.back();
      _expectTabs(p, [_b], 0, back: true, forward: true);
      p.notifier.back();
      _expectTabs(p, [_a], 0, forward: true);
    });

    test(
      'back and forward at the ends of history write nothing and a real step after them moves',
      () async {
        final p = await _probe();
        p.open([_a]);

        p.notifier.back();
        p.notifier.forward();

        expect(p.writes, 0);
        expect(p.store.writes, 0);
        expect(p.selections, isEmpty);
        _expectTabs(p, [_a], 0);
        p.notifier.navigate(_b);
        p.notifier.forward();
        expect(p.state.activeTab, _b);
        p.notifier.back();
        expect(p.state.activeTab, _a);
        p.notifier.back();
        expect(p.state.activeTab, _a);
      },
    );

    test('back and forward with no tabs do nothing', () async {
      final p = await _probe();

      p.notifier.back();
      p.notifier.forward();

      _expectTabs(p, [], 0);
      expect(p.writes, 0);
      expect(p.leaves, 0);
    });

    test('back acts on the active tab and leaves other tabs alone', () async {
      final p = await _probe();
      p.open([_a, _x], active: 0);
      p.walk([_b]);
      p.notifier.setActive(1);
      p.walk([_y]);

      p.notifier.back();

      _expectTabs(p, [_b, _x], 1, forward: true);
      p.notifier.setActive(0);
      _expectTabs(p, [_b, _x], 0, back: true);
    });
  });

  group('canGoBack and canGoForward', () {
    test(
      'canGoBack and canGoForward track the active tab through navigate back forward a chip switch and closing a tab',
      () async {
        final p = await _probe();
        p.open([_x, _a]);
        expect(p.state.canGoBack, isFalse);

        p.notifier.navigate(_b);
        expect(p.state.canGoBack, isTrue);
        expect(p.state.canGoForward, isFalse);

        p.notifier.back();
        expect(p.state.canGoBack, isFalse);
        expect(p.state.canGoForward, isTrue);

        p.notifier.setActive(0);
        expect(p.state.canGoBack, isFalse);
        expect(p.state.canGoForward, isFalse);

        p.notifier.setActive(1);
        expect(p.state.canGoForward, isTrue);

        p.notifier.forward();
        expect(p.state.canGoBack, isTrue);
        expect(p.state.canGoForward, isFalse);

        // Close the tab with history: the state follows the tab left active.
        p.notifier.closeAt(1);
        _expectTabs(p, [_x], 0);

        p.notifier.navigate(_y);
        p.notifier.openOrFocus(_c);
        _expectTabs(p, [_y, _c], 1);
        p.notifier.close(_c);
        _expectTabs(p, [_y], 0, back: true);
      },
    );

    test(
      'TabsState canGoBack and canGoForward default to false and copyWith carries them',
      () {
        const plain = TabsState(tabs: [_a], activeIndex: 0);
        expect(plain.canGoBack, isFalse);
        expect(plain.canGoForward, isFalse);
        expect(TabsState.empty.canGoBack, isFalse);
        expect(TabsState.empty.canGoForward, isFalse);

        final back = plain.copyWith(canGoBack: true);
        expect(back.canGoBack, isTrue);
        expect(back.canGoForward, isFalse);

        final forward = plain.copyWith(canGoForward: true);
        expect(forward.canGoBack, isFalse);
        expect(forward.canGoForward, isTrue);

        final kept = const TabsState(
          tabs: [_a],
          activeIndex: 0,
          canGoBack: true,
          canGoForward: true,
        ).copyWith(activeIndex: 0);
        expect(kept.canGoBack, isTrue);
        expect(kept.canGoForward, isTrue);
      },
    );

    test(
      'a chip switch adds no entry and leaves each tab history position alone',
      () async {
        final p = await _probe();
        p.open([_a, _x], active: 0);
        p.walk([_b, _c]);
        p.notifier.back(); // Left tab on b, a behind and c ahead.

        p.notifier.setActive(1);
        _expectTabs(p, [_b, _x], 1);

        p.notifier.setActive(0);
        _expectTabs(p, [_b, _x], 0, back: true, forward: true);
        p.notifier.back();
        _expectTabs(p, [_a, _x], 0, forward: true);
        p.notifier.forward();
        p.notifier.forward();
        _expectTabs(p, [_c, _x], 0, back: true);
      },
    );

    test(
      'openToday inserting a tab first keeps each tab history with its tab',
      () async {
        final p = await _probe();
        p.open([_a]);
        p.walk([_b]);

        p.notifier.openToday(date: _today);
        _expectTabs(p, [_virtual, _b], 0);

        p.notifier.setActive(1);
        _expectTabs(p, [_virtual, _b], 1, back: true);
      },
    );

    test(
      'openToday focuses the leftmost tab showing today when values repeat and keeps its history',
      () async {
        final p = await _probe();
        p.open([_a, _real], active: 0);
        p.notifier.navigate(_real); // [real*] [real]
        p.notifier.setActive(1);
        p.reset();

        p.notifier.openToday(date: _today, noteId: _realId);

        _expectTabs(p, [_real, _real], 0, back: true);
      },
    );
  });

  group('closing tabs', () {
    /// `[b] [b*] [c]`.
    Future<_Probe> duplicates() async {
      final p = await _probe();
      p.open([_a, _x, _c], active: 0);
      p.notifier.navigate(_b);
      p.notifier.setActive(1);
      p.notifier.navigate(_b);
      p.reset();
      return p;
    }

    test(
      'closeAt closes only that tab when two tabs show the same value',
      () async {
        final p = await duplicates();

        p.notifier.closeAt(0);

        _expectTabs(p, [_b, _c], 0, back: true);
        p.notifier.back();
        _expectTabs(p, [_x, _c], 0, forward: true);
      },
    );

    test('closeAt of the active duplicate leaves the other one', () async {
      final p = await duplicates();

      p.notifier.closeAt(1);

      _expectTabs(p, [_b, _c], 0, back: true);
      p.notifier.back();
      _expectTabs(p, [_a, _c], 0, forward: true);
    });

    test(
      'closeAt of the active tab activates the tab before it and runs onBeforeLeave once',
      () async {
        final p = await _probe();
        p.open([_a, _b, _c], active: 2);
        p.walk([_d]);
        final before = p.state;

        p.notifier.closeAt(2);

        _expectTabs(p, [_a, _b], 1);
        _expectLeftOnceFrom(p, before);
        expect(p.selections, ['b']);
      },
    );

    test(
      'closeAt of the active first tab activates the tab that takes its place',
      () async {
        final p = await _probe();
        p.open([_a, _b, _c], active: 0);

        p.notifier.closeAt(0);

        _expectTabs(p, [_b, _c], 0);
        expect(p.selections, ['b']);
      },
    );

    test(
      'closeAt of a tab before the active one keeps the same tab active with no leave',
      () async {
        final p = await _probe();
        p.open([_a, _b, _c], active: 2);
        p.walk([_d]);

        p.notifier.closeAt(0);

        _expectTabs(p, [_b, _d], 1, back: true);
        expect(p.leaves, 0);
      },
    );

    test(
      'closeAt of a tab after the active one keeps the same tab active with no leave',
      () async {
        final p = await _probe();
        p.open([_a, _b, _c], active: 0);
        p.walk([_d]);

        p.notifier.closeAt(2);

        _expectTabs(p, [_d, _b], 0, back: true);
        expect(p.leaves, 0);
      },
    );

    test('closeAt out of range does nothing', () async {
      final p = await _probe();
      p.open([_a, _b]);
      p.walk([_c]);

      p.notifier.closeAt(-1);
      p.notifier.closeAt(2);
      p.notifier.closeAt(99);

      _expectTabs(p, [_a, _c], 1, back: true);
      expect(p.writes, 0);
      expect(p.leaves, 0);
    });

    test('closeAt of the last tab gives the empty state', () async {
      final p = await _probe();
      p.open([_a]);
      p.walk([_b]);

      p.notifier.closeAt(0);

      _expectTabs(p, [], 0);
      expect(p.state.activeTab, isNull);
      expect(p.selections, [null]);
      expect(p.leaves, 1);
      expect(p.store.read().tabs, isEmpty);
    });

    test(
      'close closes every tab showing the value in one state write',
      () async {
        final p = await duplicates();

        p.notifier.close(_b);

        _expectTabs(p, [_c], 0);
        expect(p.writes, 1, reason: 'one state write');
        expect(p.store.writes, 1, reason: 'one persist');
        expect(p.selections, ['c']);
        expect(p.leaves, 1, reason: 'the active tab was among them');
      },
    );

    test(
      'close with the active tab among them activates the nearest remaining tab before it',
      () async {
        final p = await _probe();
        p.open([_x, _y, _a, _c], active: 2);
        p.notifier.navigate(_b);
        p.notifier.setActive(1);
        p.notifier.navigate(_b); // [x] [b*] [b] [c]
        p.notifier.setActive(2); // [x] [b] [b*] [c]
        p.reset();

        p.notifier.close(_b);

        _expectTabs(p, [_x, _c], 0);
        expect(p.selections, ['x']);
        expect(p.leaves, 1);
      },
    );

    test(
      'close with the active tab among them and nothing before it activates the first remaining tab',
      () async {
        final p = await duplicates();
        p.notifier.setActive(0);
        p.reset();

        p.notifier.close(_b);

        _expectTabs(p, [_c], 0);
        expect(p.leaves, 1);
      },
    );

    test(
      'close with the active tab not among them keeps that tab active with no leave',
      () async {
        final p = await duplicates();
        p.notifier.setActive(2);
        p.reset();

        p.notifier.close(_b);

        _expectTabs(p, [_c], 0);
        expect(p.leaves, 0);
        expect(p.selections, ['c']);
      },
    );

    test(
      'close before and after the active tab keeps it active by instance',
      () async {
        final p = await _probe();
        p.open([_a, _c, _x, _d], active: 0);
        p.notifier.navigate(_b); // [b*] [c] [x] [d]
        p.notifier.setActive(3);
        p.notifier.navigate(_b); // [b] [c] [x] [b*]
        p.notifier.setActive(2); // [b] [c] [x*] [b]
        p.notifier.navigate(_y); // [b] [c] [y*] [b]
        p.reset();

        p.notifier.close(_b);

        _expectTabs(p, [_c, _y], 1, back: true);
        expect(p.leaves, 0);
      },
    );

    test('close of a value no tab shows does nothing', () async {
      final p = await duplicates();

      p.notifier.close(_d);

      expect(p.writes, 0);
      expect(p.leaves, 0);
      expect(p.state.tabs, [_b, _b, _c]);
    });

    test('close leaves a tab that only has the value in its history', () async {
      final p = await _probe();
      p.open([_x]);
      p.walk([_a, _b]);

      p.notifier.close(_a);

      _expectTabs(p, [_b], 0, back: true);
      expect(p.writes, 0);
    });

    test('close of the only value gives the empty state', () async {
      final p = await duplicates();
      p.notifier.closeAt(2);

      p.notifier.close(_b);

      _expectTabs(p, [], 0);
      expect(p.selections.last, isNull);
    });

    test(
      'closing a tab with closeAt discards its history and a new tab on the same target starts with canGoBack false',
      () async {
        final p = await _probe();
        p.open([_x, _a]);
        p.notifier.navigate(_b);
        expect(p.state.canGoBack, isTrue);

        p.notifier.closeAt(1);
        p.notifier.openOrFocus(_b);

        _expectTabs(p, [_x, _b], 1);
      },
    );

    test(
      'closing a tab with close discards its history and a new tab on the same target starts with canGoBack false',
      () async {
        final p = await _probe();
        p.open([_x, _a]);
        p.notifier.navigate(_b);
        expect(p.state.canGoBack, isTrue);

        p.notifier.close(_b);
        p.notifier.openOrFocus(_b);

        _expectTabs(p, [_x, _b], 1);
      },
    );

    test(
      'LRU eviction discards the history of the evicted tab and a new tab on the same target starts with canGoBack false',
      () async {
        final p = await _probe();
        // The oldest tab goes first: give it a history, then touch the rest.
        p.open(_notes(kMaxOpenTabs), active: 0);
        p.notifier.navigate(_b);
        expect(p.state.canGoBack, isTrue);
        for (var i = 1; i < kMaxOpenTabs; i++) {
          p.notifier.setActive(i);
        }
        p.notifier.setActive(kMaxOpenTabs - 1);

        p.notifier.openOrFocus(_target); // Evicts the tab showing b.
        expect(p.state.tabs, isNot(contains(_b)));

        p.notifier.openOrFocus(_b);

        expect(p.state.activeTab, _b);
        expect(p.state.canGoBack, isFalse);
      },
    );
  });

  group('LRU eviction by instance', () {
    test(
      'of two tabs showing one value only the least recently used goes when it is the left one',
      () async {
        final p = await _probe();
        final notes = _notes(kMaxOpenTabs);
        p.open(notes); // n0 is least recently used, n19 most.
        p.notifier.navigate(notes.first); // n19's tab now shows n0 too.

        p.notifier.openOrFocus(_target);

        expect(p.state.tabs, [
          ...notes.sublist(1, kMaxOpenTabs - 1),
          notes.first,
          _target,
        ]);
        expect(p.state.activeIndex, kMaxOpenTabs - 1);
      },
    );

    test(
      'of two tabs showing one value only the least recently used goes when it is the right one',
      () async {
        final p = await _probe();
        final notes = _notes(kMaxOpenTabs);
        p.open(notes);
        // Most recent to least: tab 0, tab 1, ... tab 19.
        for (var i = kMaxOpenTabs - 1; i >= 0; i--) {
          p.notifier.setActive(i);
        }
        p.notifier.navigate(notes.last); // Tab 0 shows n19 too.

        p.notifier.openOrFocus(_target);

        expect(p.state.tabs, [
          notes.last,
          ...notes.sublist(1, kMaxOpenTabs - 1),
          _target,
        ]);
        p.notifier.setActive(0);
        expect(p.state.canGoBack, isTrue, reason: 'tab 0 kept its history');
      },
    );

    test(
      'restored tabs showing one value are evicted one instance at a time',
      () async {
        final notes = _notes(kMaxOpenTabs - 1);
        final p = await _probe(restored: [notes[0], ...notes], active: 1);

        p.notifier.openOrFocus(_target);
        expect(p.state.tabs.where((t) => t == notes[0]), hasLength(2));
        expect(p.state.tabs, hasLength(kMaxOpenTabs));

        p.notifier.setActive(0);
        p.notifier.navigate(_y);
        expect(p.state.canGoBack, isTrue);
      },
    );

    test(
      'a Cmd focus makes that tab instance the most recently used',
      () async {
        final p = await _probe();
        final notes = _notes(kMaxOpenTabs);
        p.open(notes);
        p.notifier.navigate(notes[1]); // Tab 19 shows n1, as tab 1 does.

        p.notifier.openOrFocus(notes[0]); // Tab 0 is now the most recent.
        p.notifier.setActive(kMaxOpenTabs - 1);
        p.notifier.openOrFocus(_target); // Tab 1 is now the oldest: it goes.

        expect(p.state.tabs.first, notes[0]);
        expect(p.state.tabs.where((t) => t == notes[1]), hasLength(1));
        expect(p.state.tabs[kMaxOpenTabs - 2], notes[1]);
      },
    );

    test('a tab one short of the cap opens without evicting', () async {
      final p = await _probe();
      final notes = _notes(kMaxOpenTabs - 1);
      p.open(notes);
      p.notifier.navigate(notes.first);

      p.notifier.openOrFocus(_target);

      expect(p.state.tabs, hasLength(kMaxOpenTabs));
      expect(p.state.tabs.first, notes.first);
    });
  });

  group('ui_state.json', () {
    Future<UiStateStore> tempStore(String name) async {
      final dir = await Directory.systemTemp.createTemp(name);
      final store = UiStateStore(vaultPath: dir.path);
      addTearDown(() async {
        await store.flush();
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      return store;
    }

    Future<Map<String, dynamic>> onDisk(UiStateStore store) async {
      await store.flush();
      final f = File('${store.vaultPath}/.memex/ui_state.json');
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    }

    /// What main writes for [tabs]: the store's own `UiState` shape.
    Future<Map<String, dynamic>> asOnMain(
      List<WorkspaceTab> tabs,
      int active, {
      Map<String, CanvasViewport> viewports = const {},
      SidebarMode mode = SidebarMode.days,
    }) async {
      final twin = await tempStore('tabs_navigate_twin');
      await twin.write(
        UiState(
          tabs: [for (final t in tabs) t.toPersisted()],
          activeTabIndex: active,
          canvasViewports: viewports,
          sidebarMode: mode,
        ),
      );
      return onDisk(twin);
    }

    test(
      'ui_state.json after navigating holds what each tab shows and the active index with no history fields',
      () async {
        final store = await tempStore('tabs_navigate_store');
        final tabs = TabsNotifier(
          store: store,
          onPersistedSelection: (_) {},
          isNewTabModifierPressed: () => false,
        );
        addTearDown(tabs.dispose);
        tabs.openOrFocus(_a);
        tabs.openOrFocus(_b);
        tabs.setActive(0);

        tabs.navigate(_b);

        final json = await onDisk(store);
        expect(json['active_tab_index'], 0);
        expect(json['tabs'], [
          {'kind': 'note', 'id': 'b'},
          {'kind': 'note', 'id': 'b'},
        ]);
        expect(json.keys.toSet(), {
          'tabs',
          'active_tab_index',
          'canvas_viewports',
          'sidebar_mode',
        });
        expect(json, await asOnMain([_b, _b], 0));
      },
    );

    test('ui_state.json after back holds what the tab shows again', () async {
      final store = await tempStore('tabs_navigate_store');
      final tabs = TabsNotifier(
        store: store,
        onPersistedSelection: (_) {},
        isNewTabModifierPressed: () => false,
      );
      addTearDown(tabs.dispose);
      tabs.openOrFocus(_a);
      tabs.openOrFocus(_x);
      tabs.setActive(0);
      tabs.navigate(_b);

      tabs.back();

      expect(await onDisk(store), await asOnMain([_a, _x], 0));
      tabs.forward();
      expect(await onDisk(store), await asOnMain([_b, _x], 0));
    });

    test(
      'navigating keeps the canvas viewports and sidebar mode in ui_state.json',
      () async {
        final store = await tempStore('tabs_navigate_store');
        final viewport = CanvasViewport(dx: 1, dy: 2, zoom: 3);
        await store.write(
          UiState(
            tabs: [_a.toPersisted()],
            activeTabIndex: 0,
            canvasViewports: {'board': viewport},
            sidebarMode: SidebarMode.topics,
          ),
        );
        await store.flush();
        final tabs = TabsNotifier(
          store: store,
          onPersistedSelection: (_) {},
          isNewTabModifierPressed: () => false,
        );
        addTearDown(tabs.dispose);

        tabs.navigate(_b);

        expect(
          await onDisk(store),
          await asOnMain(
            [_b],
            0,
            viewports: {'board': viewport},
            mode: SidebarMode.topics,
          ),
        );
      },
    );
  });

  group('after a relaunch', () {
    test(
      'a relaunch restores what each tab shows with canGoBack and canGoForward false',
      () async {
        final store = _MemoryStore();
        final first = await _probe(store: store);
        first.open([_a, _x], active: 0);
        first.notifier.navigate(_b);
        first.notifier.navigate(_c);
        first.notifier.back();
        expect(first.state.canGoBack, isTrue);
        expect(first.state.canGoForward, isTrue);
        first.notifier.dispose();

        final second = await _probe(store: store);

        _expectTabs(second, [_b, _x], 0);
        second.notifier.back();
        second.notifier.forward();
        _expectTabs(second, [_b, _x], 0);
      },
    );

    test(
      'a relaunch restores two tabs showing one note as two tabs each with its own history',
      () async {
        final p = await _probe(restored: [_a, _a], active: 1);
        _expectTabs(p, [_a, _a], 1);

        p.notifier.navigate(_b);
        _expectTabs(p, [_a, _b], 1, back: true);

        p.notifier.setActive(0);
        _expectTabs(p, [_a, _b], 0);
        p.notifier.navigate(_c);
        _expectTabs(p, [_c, _b], 0, back: true);
      },
    );

    test('closing one restored duplicate leaves the other', () async {
      final p = await _probe(restored: [_a, _a, _b], active: 2);

      p.notifier.closeAt(0);

      _expectTabs(p, [_a, _b], 1);
    });

    test(
      'opening a vault with the today note in two restored tabs lands on the leftmost and each keeps its own history',
      () async {
        final p = await _probe(
          restored: [_x, _real, _real],
          todayDate: _today,
          todayNoteId: _realId,
        );
        _expectTabs(p, [_x, _real, _real], 1);

        p.notifier.navigate(_b);

        _expectTabs(p, [_x, _b, _real], 1, back: true);
      },
    );

    test(
      'opening a vault with the today note not restored inserts it first and navigate stays in it',
      () async {
        final p = await _probe(
          restored: [_x, _y],
          active: 1,
          todayDate: _today,
          todayNoteId: _realId,
        );
        _expectTabs(p, [_real, _x, _y], 0);

        p.notifier.navigate(_b);

        _expectTabs(p, [_b, _x, _y], 0, back: true);
      },
    );
  });

  group('resolveVirtualToday', () {
    test(
      'resolveVirtualToday rewrites every matching entry in every tab history to the real note',
      () async {
        final p = await _probe(restored: [_x], todayDate: _today);
        // [virtual*] [x]: walk the left tab away and back, the right one past
        // the virtual note too.
        p.walk([_a, _virtual, _b]);
        p.notifier.setActive(1);
        p.walk([_virtual, _y]);

        p.notifier.resolveVirtualToday(date: _today, noteId: _realId);
        _expectTabs(p, [_b, _y], 1, back: true);

        p.notifier.back();
        _expectTabs(p, [_b, _real], 1, back: true, forward: true);
        p.notifier.setActive(0);
        p.notifier.back();
        expect(p.state.activeTab, _real);
        p.notifier.back();
        expect(p.state.activeTab, _a);
        p.notifier.back();
        expect(p.state.activeTab, _real);
        expect(p.state.canGoBack, isFalse);
      },
    );

    test(
      'resolveVirtualToday rewrites history entries when no tab shows the virtual note',
      () async {
        final p = await _probe(todayDate: _today);
        p.walk([_a]);

        p.notifier.resolveVirtualToday(date: _today, noteId: _realId);

        _expectTabs(p, [_a], 0, back: true);
        p.notifier.back();
        _expectTabs(p, [_real], 0, forward: true);
      },
    );

    test(
      'resolveVirtualToday keeps the active tab active when values repeat',
      () async {
        // [virtual] [x] [real] with a real on the right as well as the left.
        final p = await _probe(restored: [_x, _y], todayDate: _today);
        p.notifier.setActive(1);
        p.notifier.navigate(_real); // [virtual] [real*] [y]
        p.notifier.setActive(2);
        p.notifier.navigate(_real); // [virtual] [real] [real*]
        p.reset();

        p.notifier.resolveVirtualToday(date: _today, noteId: _realId);

        _expectTabs(p, [_real, _real], 1, back: true);
        expect(p.selections, [_realId]);
      },
    );

    test(
      'resolveVirtualToday keeps the active tab active when the rewritten tab sits before a repeat of it',
      () async {
        // [real*] [virtual with history] [real]: the middle tab stays.
        final p = await _probe(restored: [_x, _y], todayDate: _today);
        p.notifier.navigate(_a);
        p.notifier.navigate(_virtual); // [virtual*] [x] [y], a behind it.
        p.notifier.setActive(1);
        p.notifier.navigate(_real); // [virtual] [real*] [y]
        p.notifier.setActive(2);
        p.reset();

        p.notifier.resolveVirtualToday(date: _today, noteId: _realId);

        _expectTabs(p, [_real, _real, _y], 2);
      },
    );

    test(
      'a virtual Today tab with nothing else in its history closes when the real note is open elsewhere',
      () async {
        final p = await _probe(restored: [_x], todayDate: _today);
        p.notifier.setActive(1);
        p.notifier.navigate(_real); // [virtual] [real*], x behind it.
        p.notifier.setActive(0);
        p.reset();

        p.notifier.resolveVirtualToday(date: _today, noteId: _realId);

        _expectTabs(p, [_real], 0, back: true);
        expect(p.selections, [_realId]);
        p.notifier.back();
        _expectTabs(p, [_x], 0, forward: true);
      },
    );

    test(
      'a virtual Today tab with other history entries stays and shows the real note when it is open elsewhere',
      () async {
        final p = await _probe(restored: [_x], todayDate: _today);
        p.walk([_a, _virtual]); // [virtual*] [x], with virtual and a behind.
        p.notifier.setActive(1);
        p.notifier.navigate(_real); // [virtual] [real*]
        p.notifier.setActive(0);
        p.reset();

        p.notifier.resolveVirtualToday(date: _today, noteId: _realId);

        _expectTabs(p, [_real, _real], 0, back: true);
        p.notifier.back();
        _expectTabs(p, [_a, _real], 0, back: true, forward: true);
        p.notifier.back();
        _expectTabs(p, [_real, _real], 0, forward: true);
      },
    );

    test(
      'a virtual Today tab with nothing else in its history becomes the real note in a tab that keeps its place',
      () async {
        final p = await _probe(restored: [_x], todayDate: _today);
        p.notifier.setActive(1);
        p.notifier.navigate(_y); // [virtual] [y*], x behind it.
        p.reset();

        p.notifier.resolveVirtualToday(date: _today, noteId: _realId);

        _expectTabs(p, [_real, _y], 1, back: true);
        p.notifier.setActive(0);
        _expectTabs(p, [_real, _y], 0);
      },
    );

    test(
      'resolveVirtualToday with no entry for that date does nothing',
      () async {
        final p = await _probe();
        p.open([_a]);
        p.walk([_b]);

        p.notifier.resolveVirtualToday(date: _today, noteId: _realId);

        expect(p.writes, 0);
        expect(p.selections, isEmpty);
        _expectTabs(p, [_b], 0, back: true);
      },
    );
  });

  group('Back and Forward skip a gone target', () {
    test(
      'back to a gone note removes that entry and continues to the next earlier one',
      () async {
        final exists = _Exists();
        final p = await _probe(exists: exists);
        p.open([_a]);
        p.walk([_b, _c]);
        exists.gone.add(_b);

        p.notifier.back();
        expect(p.state.activeTab, _b, reason: 'back switches at once');
        await pumpEventQueue();

        _expectTabs(p, [_a], 0, forward: true);
        expect(p.selections, ['b', 'a'], reason: 'one write per step');
        p.notifier.forward();
        await pumpEventQueue();
        _expectTabs(p, [_c], 0, back: true);
        p.notifier.back();
        await pumpEventQueue();
        _expectTabs(p, [_a], 0, forward: true);
      },
    );

    test(
      'forward to a gone note removes that entry and continues to the next later one',
      () async {
        final exists = _Exists();
        final p = await _probe(exists: exists);
        p.open([_a]);
        p.walk([_b, _c]);
        p.notifier.back();
        p.notifier.back();
        await pumpEventQueue();
        p.reset();
        exists.gone.add(_b);

        p.notifier.forward();
        expect(p.state.activeTab, _b, reason: 'forward switches at once');
        await pumpEventQueue();

        _expectTabs(p, [_c], 0, back: true);
        expect(p.selections, ['b', 'c'], reason: 'one write per step');
        p.notifier.back();
        await pumpEventQueue();
        _expectTabs(p, [_a], 0, forward: true);
      },
    );

    test('back skips several gone notes in a row', () async {
      final exists = _Exists();
      final p = await _probe(exists: exists);
      p.open([_a]);
      p.walk([_b, _c, _d]);
      exists.gone.addAll([_b, _c]);

      p.notifier.back();
      await pumpEventQueue();

      _expectTabs(p, [_a], 0, forward: true);
      expect(exists.calls, [_c, _b, _a]);
      expect(p.selections, ['c', 'b', 'a']);
    });

    test('forward skips several gone notes in a row', () async {
      final exists = _Exists();
      final p = await _probe(exists: exists);
      p.open([_a]);
      p.walk([_b, _c, _d]);
      p.notifier.back();
      p.notifier.back();
      p.notifier.back();
      await pumpEventQueue();
      exists.calls.clear();
      exists.gone.addAll([_b, _c]);

      p.notifier.forward();
      await pumpEventQueue();

      _expectTabs(p, [_d], 0, back: true);
      expect(exists.calls, [_b, _c, _d]);
    });

    test('skipping a gone note leaves the Forward entries in place', () async {
      final exists = _Exists();
      final p = await _probe(exists: exists);
      p.open([_a]);
      p.walk([_b, _c, _d]);
      p.notifier.back();
      await pumpEventQueue();
      exists.gone.add(_b);

      p.notifier.back();
      await pumpEventQueue();

      _expectTabs(p, [_a], 0, forward: true);
      p.notifier.forward();
      await pumpEventQueue();
      _expectTabs(p, [_c], 0, back: true, forward: true);
      p.notifier.forward();
      await pumpEventQueue();
      _expectTabs(p, [_d], 0, back: true);
    });

    test(
      'back with no earlier entry left returns to the entry it left and canGoBack is false',
      () async {
        final exists = _Exists();
        final p = await _probe(exists: exists);
        p.open([_a]);
        p.walk([_b]);
        exists.gone.add(_a);

        p.notifier.back();
        expect(p.state.activeTab, _a);
        await pumpEventQueue();

        _expectTabs(p, [_b], 0);
        expect(p.selections, ['a', 'b']);
      },
    );

    test(
      'forward with no later entry left returns to the entry it left and canGoForward is false',
      () async {
        final exists = _Exists();
        final p = await _probe(exists: exists);
        p.open([_a]);
        p.walk([_b]);
        p.notifier.back();
        await pumpEventQueue();
        p.reset();
        exists.gone.add(_b);

        p.notifier.forward();
        expect(p.state.activeTab, _b);
        await pumpEventQueue();

        _expectTabs(p, [_a], 0);
        expect(p.selections, ['b', 'a']);
      },
    );

    test(
      'back with every entry gone stops on the entry it left without checking it again',
      () async {
        final exists = _Exists();
        final p = await _probe(exists: exists);
        p.open([_a]);
        p.walk([_b]);
        exists.gone.addAll([_a, _b]);

        p.notifier.back();
        await pumpEventQueue();

        _expectTabs(p, [_b], 0);
        expect(exists.calls, [_a]);
      },
    );

    test(
      'forward with every later entry gone stops on the entry it left without checking it again',
      () async {
        final exists = _Exists();
        final p = await _probe(exists: exists);
        p.open([_a]);
        p.walk([_b, _c]);
        p.notifier.back();
        p.notifier.back();
        await pumpEventQueue();
        exists.calls.clear();
        exists.gone.addAll([_a, _b, _c]);

        p.notifier.forward();
        await pumpEventQueue();

        _expectTabs(p, [_a], 0);
        expect(exists.calls, [_b, _c]);
      },
    );

    test('an existing target stays and nothing else is checked', () async {
      final exists = _Exists();
      final p = await _probe(exists: exists);
      p.open([_a]);
      p.walk([_b, _c]);

      p.notifier.back();
      await pumpEventQueue();

      _expectTabs(p, [_b], 0, back: true, forward: true);
      expect(exists.calls, [_b]);
      expect(p.selections, ['b']);
    });

    test('navigate and a chip switch never check a target', () async {
      final exists = _Exists();
      final p = await _probe(exists: exists);
      p.open([_a, _x]);
      exists.gone.addAll([_a, _b, _x]);

      p.notifier.navigate(_b);
      p.notifier.setActive(0);
      p.notifier.navigate(_b);
      await pumpEventQueue();

      expect(exists.calls, isEmpty);
      _expectTabs(p, [_b, _b], 0, back: true);
    });

    test('back with no targetExists shows every entry', () async {
      final p = await _probe();
      p.open([_a]);
      p.walk([_b]);

      p.notifier.back();
      await pumpEventQueue();

      _expectTabs(p, [_a], 0, forward: true);
    });

    test(
      'a gone answer for a tab no longer active moves that tab and not the active one',
      () async {
        final exists = _Exists();
        final p = await _probe(exists: exists);
        p.open([_a, _x], active: 0);
        p.walk([_b, _c]);
        exists.hold();
        p.notifier.back(); // Left tab on b; the answer is pending.
        p.notifier.setActive(1);
        p.reset();

        exists.answerOnly(false);
        exists.holding = false;
        await pumpEventQueue();

        _expectTabs(p, [_a, _x], 1);
        expect(p.leaves, 0, reason: 'the active tab was not left');
        expect(p.selections.toSet(), isNot(contains('a')));
        p.notifier.setActive(0);
        _expectTabs(p, [_a, _x], 0, forward: true);
      },
    );
  });

  group('a targetExists failure counts as existing', () {
    Future<_Probe> onEntry(Future<bool> Function(WorkspaceTab) answer) async {
      final recorder = TabsRecorder();
      final store = _MemoryStore();
      final notifier = TabsNotifier(
        store: store,
        onPersistedSelection: (_) {},
        isNewTabModifierPressed: () => false,
        navigationObserver: recorder.observer,
        targetExists: answer,
      );
      addTearDown(() {
        if (notifier.mounted) notifier.dispose();
      });
      final p = _Probe(notifier, store, recorder);
      p.open([_a]);
      p.walk([_b, _c]);
      p.notifier.back();
      await pumpEventQueue();
      return p;
    }

    test(
      'a targetExists that throws VaultUnreachableException counts as existing',
      () async {
        final p = await onEntry((_) => Future<bool>.error(_unreachable));

        _expectTabs(p, [_b], 0, back: true, forward: true);
      },
    );

    test(
      'a targetExists that throws another error counts as existing',
      () async {
        final p = await onEntry((_) => Future<bool>.error(StateError('no db')));

        _expectTabs(p, [_b], 0, back: true, forward: true);
      },
    );

    test(
      'a targetExists that throws before returning a future counts as existing',
      () async {
        final p = await onEntry((_) => throw StateError('no db'));

        _expectTabs(p, [_b], 0, back: true, forward: true);
      },
    );
  });

  group('a late targetExists answer', () {
    /// `[a] [b] [c*]` with answers held.
    Future<(_Probe, _Exists)> held() async {
      final exists = _Exists();
      final p = await _probe(exists: exists);
      p.open([_a]);
      p.walk([_b, _c]);
      exists.hold();
      return (p, exists);
    }

    test('two quick back presses apply in order', () async {
      final (p, exists) = await held();

      p.notifier.back();
      p.notifier.back();

      _expectTabs(p, [_a], 0, forward: true);
      expect(exists.calls, [_b, _a]);
      expect(p.selections, ['b', 'a']);
    });

    test(
      'an answer that lands after a second back press changes nothing',
      () async {
        final (p, exists) = await held();
        p.notifier.back();
        p.notifier.back();
        p.reset();

        exists.answer(0, false); // b is gone, but the tab moved on.
        await pumpEventQueue();

        _expectTabs(p, [_a], 0, forward: true);
        expect(p.writes, 0);
        p.notifier.forward();
        expect(p.state.activeTab, _b, reason: 'the entry for b is still there');
      },
    );

    test('an answer that lands after navigate changes nothing', () async {
      final (p, exists) = await held();
      p.notifier.back();
      p.notifier.navigate(_d);
      p.reset();

      exists.answerOnly(false);
      await pumpEventQueue();

      _expectTabs(p, [_d], 0, back: true);
      expect(p.writes, 0);
      p.notifier.back();
      expect(p.state.activeTab, _b);
    });

    test(
      'an answer from an earlier visit to the same entry changes nothing and the newest answer decides',
      () async {
        final (p, exists) = await held();
        p.notifier.back(); // b, answer 0.
        p.notifier.forward(); // c, answer 1.
        p.notifier.back(); // b again, answer 2.
        p.reset();

        exists.answer(0, false);
        exists.answer(1, false);
        await pumpEventQueue();
        _expectTabs(p, [_b], 0, back: true, forward: true);
        expect(p.writes, 0);

        exists.answer(2, false);
        await pumpEventQueue();
        expect(p.state.activeTab, _a, reason: 'the current visit was gone');
      },
    );

    test(
      'an answer for a repeated value changes nothing on the other entry with that value',
      () async {
        final exists = _Exists();
        final p = await _probe(exists: exists);
        p.open([_a]);
        p.walk([_b, _a, _c]);
        exists.hold();
        p.notifier.back(); // a at index 2, answer 0.
        p.notifier.back(); // b, answer 1.
        p.notifier.back(); // a at index 0, answer 2.
        p.reset();

        exists.answer(0, false);
        await pumpEventQueue();

        expect(p.writes, 0);
        _expectTabs(p, [_a], 0, forward: true);
      },
    );

    test(
      'an answer that lands after a removal shifted the entries changes nothing',
      () async {
        final exists = _Exists();
        final p = await _probe(exists: exists);
        p.open([_a]);
        p.walk([_b, _c, _d]);
        exists.hold();
        p.notifier.back(); // c, answer 0.
        p.notifier.back(); // b, answer 1.
        exists.answer(1, false); // b goes, on to a, answer 2.
        await pumpEventQueue();
        expect(p.state.activeTab, _a);
        p.notifier.forward(); // c is index 1 now, answer 3.
        p.reset();

        exists.answer(0, false); // The first visit to c.
        exists.answer(2, false); // The visit to a.
        await pumpEventQueue();

        expect(p.writes, 0);
        _expectTabs(p, [_c], 0, back: true, forward: true);
      },
    );

    test(
      'an answer that lands after the tab closed changes nothing on the tab now at its index',
      () async {
        final exists = _Exists();
        final p = await _probe(exists: exists);
        p.open([_a, _x], active: 0);
        p.walk([_b]);
        exists.hold();
        p.notifier.back();
        p.notifier.closeAt(0);
        p.reset();

        exists.answerOnly(false);
        await pumpEventQueue();

        _expectTabs(p, [_x], 0);
        expect(p.writes, 0);
      },
    );

    test(
      'an answer that lands after the notifier is disposed changes nothing',
      () async {
        final (p, exists) = await held();
        p.notifier.back();
        expect(p.state.activeTab, _b);
        p.notifier.dispose();

        exists.answerOnly(false);
        await pumpEventQueue();

        expect(p.selections, ['b'], reason: 'nothing ran after the disposal');
      },
    );

    test('an answer that the entry exists changes nothing', () async {
      final (p, exists) = await held();
      p.notifier.back();
      p.reset();

      exists.answerOnly(true);
      await pumpEventQueue();

      expect(p.writes, 0);
      _expectTabs(p, [_b], 0, back: true, forward: true);
    });
  });

  group('followLater', () {
    /// `[a*] [x]`, with a result [later] taken on the left tab.
    Future<(_Probe, void Function(WorkspaceTab))> takenOnLeft({
      bool held = false,
      _Exists? exists,
    }) async {
      final p = await _probe(modifier: () => held, exists: exists);
      p.open([_a, _x], active: 0);
      final later = p.notifier.followLater();
      return (p, later);
    }

    test(
      'a followLater plain result is dropped when the tab it was taken on has closed',
      () async {
        final (p, later) = await takenOnLeft();
        p.notifier.closeAt(0);
        p.reset();

        later(_target);

        _expectTabs(p, [_x], 0);
        expect(p.writes, 0);
        expect(p.recorder.followed, [_target]);
        expect(p.recorder.navigated, isEmpty);
      },
    );

    test(
      'a followLater plain result is dropped when another tab with the same value survives the close',
      () async {
        final p = await _probe();
        p.open([_a, _x], active: 1);
        p.notifier.navigate(_a); // [a] [a*]
        final later = p.notifier.followLater();
        p.notifier.closeAt(1);
        p.reset();

        later(_target);

        _expectTabs(p, [_a], 0);
      },
    );

    test(
      'a followLater plain result is dropped when the tab it was taken on has navigated',
      () async {
        final (p, later) = await takenOnLeft();
        p.notifier.navigate(_b);
        p.reset();

        later(_target);

        _expectTabs(p, [_b, _x], 0, back: true);
        expect(p.writes, 0);
        expect(p.recorder.navigated, [_b]);
        expect(p.recorder.followed, [_target]);
      },
    );

    test(
      'a followLater plain result is dropped when the tab went back',
      () async {
        final p = await _probe();
        p.open([_a, _x], active: 0);
        p.walk([_b]);
        final later = p.notifier.followLater();
        p.notifier.back();
        p.reset();

        later(_target);

        _expectTabs(p, [_a, _x], 0, forward: true);
      },
    );

    test(
      'a followLater plain result is dropped when the tab went forward',
      () async {
        final p = await _probe();
        p.open([_a, _x], active: 0);
        p.walk([_b]);
        p.notifier.back();
        final later = p.notifier.followLater();
        p.notifier.forward();
        p.reset();

        later(_target);

        _expectTabs(p, [_b, _x], 0, back: true);
      },
    );

    test(
      'a followLater plain result is dropped when a gone target moved the tab',
      () async {
        final exists = _Exists();
        final p = await _probe(exists: exists);
        p.open([_a, _b]);
        p.walk([_c]);
        exists.gone.add(_b);
        p.notifier.back(); // Check pending; the tab shows b for now.
        final later = p.notifier.followLater();
        await pumpEventQueue(); // b is gone: the tab returns to c.
        expect(p.state.activeTab, _c);
        p.reset();

        later(_target);

        _expectTabs(p, [_a, _c], 1);
      },
    );

    test(
      'a followLater plain result navigates the tab it was taken on without changing the active tab',
      () async {
        final (p, later) = await takenOnLeft();
        p.notifier.setActive(1);
        p.reset();

        later(_target);

        _expectTabs(p, [_target, _x], 1);
        expect(p.leaves, 0, reason: 'the active tab was not left');
        expect(p.selections.where((s) => s != 'x'), isEmpty);
        expect(p.recorder.followed, [_target]);
        expect(p.recorder.navigated, [_target]);
        expect(p.store.read().tabs.first.id, 'target');
        p.notifier.setActive(0);
        _expectTabs(p, [_target, _x], 0, back: true);
        p.notifier.back();
        _expectTabs(p, [_a, _x], 0, forward: true);
      },
    );

    test(
      'a followLater plain result for a tab no longer active keeps that tab at the same target with no entry',
      () async {
        final (p, later) = await takenOnLeft();
        p.notifier.setActive(1);
        p.reset();

        later(_a);

        _expectTabs(p, [_a, _x], 1);
        p.notifier.setActive(0);
        expect(p.state.canGoBack, isFalse);
      },
    );

    test(
      'a followLater plain result still navigates after a chip switch away and back',
      () async {
        final (p, later) = await takenOnLeft();
        p.notifier.setActive(1);
        p.notifier.setActive(0);
        p.reset();

        later(_target);

        _expectTabs(p, [_target, _x], 0, back: true);
        expect(p.leaves, 1);
        expect(p.selections, ['target']);
      },
    );

    test(
      'a followLater plain result on the tab still active runs onBeforeLeave once and navigates it',
      () async {
        final (p, later) = await takenOnLeft();
        final before = p.state;

        later(_target);

        _expectLeftOnceFrom(p, before);
        _expectTabs(p, [_target, _x], 0, back: true);
        expect(p.recorder.navigated, [_target]);
      },
    );

    test(
      'a followLater plain result when the taken tab moved in the bar still navigates that tab',
      () async {
        final p = await _probe();
        p.open([_a, _x, _y], active: 1);
        final later = p.notifier.followLater();
        p.notifier.closeAt(0); // [x*] [y], the taken tab is now at index 0.
        p.notifier.setActive(1);

        later(_target);

        _expectTabs(p, [_target, _y], 1);
      },
    );

    test(
      'a followLater Cmd result still opens a tab when the tab it was taken on has closed',
      () async {
        final (p, later) = await takenOnLeft(held: true);
        p.notifier.closeAt(0);
        p.reset();

        later(_target);

        _expectTabs(p, [_x, _target], 1);
        expect(p.recorder.followed, [_target]);
      },
    );

    test(
      'a followLater Cmd result still focuses a tab when the tab it was taken on has navigated',
      () async {
        final (p, later) = await takenOnLeft(held: true);
        p.notifier.navigate(_b);
        p.reset();

        later(_x);

        _expectTabs(p, [_b, _x], 1);
        expect(p.leaves, 1);
      },
    );

    test(
      'a followLater Cmd result does nothing once the vault changed',
      () async {
        // tabsProvider builds a new notifier per vault and disposes the old
        // one, so a vault change is the disposal of the notifier the result
        // was taken on.
        final (p, later) = await takenOnLeft(held: true);
        p.notifier.navigate(_b);
        _expectTabs(p, [_b, _x], 0, back: true);
        p.reset();
        p.notifier.dispose();

        later(_target);

        expect(p.store.writes, 0, reason: 'nothing persisted');
        expect(p.recorder.followed, isEmpty);
        expect(p.selections, isEmpty);
      },
    );
  });

  group('onBeforeLeave', () {
    test(
      'navigate to another target runs onBeforeLeave once before the tab changes',
      () async {
        final p = await _probe();
        p.open([_a, _x], active: 0);
        final before = p.state;

        p.notifier.navigate(_b);

        _expectLeftOnceFrom(p, before);
        _expectTabs(p, [_b, _x], 0, back: true);
      },
    );

    test('back runs onBeforeLeave once before the tab changes', () async {
      final p = await _probe();
      p.open([_a]);
      p.walk([_b]);
      final before = p.state;

      p.notifier.back();

      _expectLeftOnceFrom(p, before);
      expect(p.state.activeTab, _a);
    });

    test('forward runs onBeforeLeave once before the tab changes', () async {
      final p = await _probe();
      p.open([_a]);
      p.walk([_b]);
      p.notifier.back();
      p.reset();
      final before = p.state;

      p.notifier.forward();

      _expectLeftOnceFrom(p, before);
      expect(p.state.activeTab, _b);
    });

    test(
      'back past a gone target runs onBeforeLeave only for the first step',
      () async {
        final exists = _Exists();
        final p = await _probe(exists: exists);
        p.open([_a]);
        p.walk([_b, _c, _d]);
        exists.gone.addAll([_b, _c]);

        p.notifier.back();
        await pumpEventQueue();

        expect(p.state.activeTab, _a);
        expect(p.leaves, 1);
      },
    );

    test(
      'forward past a gone target runs onBeforeLeave only for the first step',
      () async {
        final exists = _Exists();
        final p = await _probe(exists: exists);
        p.open([_a]);
        p.walk([_b, _c]);
        p.notifier.back();
        p.notifier.back();
        await pumpEventQueue();
        p.reset();
        exists.gone.add(_b);

        p.notifier.forward();
        await pumpEventQueue();

        expect(p.state.activeTab, _c);
        expect(p.leaves, 1);
      },
    );

    test(
      'navigate to the same target runs onBeforeLeave zero times and a real navigate after it runs it once',
      () async {
        final p = await _probe();
        p.open([_a, _x], active: 0);

        p.notifier.navigate(_a);
        expect(p.leaves, 0);

        p.notifier.navigate(_b);
        expect(p.leaves, 1);
        expect(p.state.tabs, [_b, _x]);
      },
    );

    test(
      'back and forward at the ends of history run onBeforeLeave zero times and a real step after them runs it once',
      () async {
        final p = await _probe();
        p.open([_a]);

        p.notifier.back();
        p.notifier.forward();
        expect(p.leaves, 0);

        p.notifier.navigate(_b);
        p.reset();
        p.notifier.forward();
        expect(p.leaves, 0);

        p.notifier.back();
        expect(p.leaves, 1);
        p.reset();
        p.notifier.back();
        expect(p.leaves, 0);
      },
    );

    test(
      'a Cmd click focusing the leftmost duplicate of the active tab runs onBeforeLeave once',
      () async {
        final p = await _probe(modifier: () => true);
        p.open([_a, _x], active: 0);
        p.notifier.navigate(_x); // [x*] [x]
        p.notifier.setActive(1);
        p.reset();
        final before = p.state;

        p.notifier.follow(_x);

        _expectLeftOnceFrom(p, before);
        expect(p.state.activeIndex, 0);
      },
    );

    test(
      'a Cmd click on the value of the active leftmost duplicate runs onBeforeLeave zero times',
      () async {
        final p = await _probe(modifier: () => true);
        p.open([_a, _x], active: 0);
        p.notifier.navigate(_x); // [x*] [x]
        p.reset();

        p.notifier.follow(_x);

        expect(p.leaves, 0);
        expect(p.state.activeIndex, 0);
        expect(p.state.canGoBack, isTrue);
      },
    );
  });

  group('a typed edit is saved before leaving', () {
    test(
      'an edit typed less than 500 ms before navigate is saved with the leaving note id',
      () async {
        final w = await _editorWired();
        w.open(_planId);
        w.ctrl.onContentChanged('new plan');

        w.tabs.navigate(const NoteTab(_otherId));
        await pumpEventQueue();

        w.expectOneSave(_planId, 'new plan', 3);
        expect(w.tabState.tabs, [_virtual, const NoteTab(_otherId)]);
      },
    );

    test(
      'an edit typed less than 500 ms before back is saved with the leaving note id',
      () async {
        final w = await _editorWired();
        w.open(_planId);
        w.tabs.navigate(const NoteTab(_otherId));
        w.ctrl.loadNote(w.db.getNote(_otherId)!);
        w.ctrl.onContentChanged('new other');

        w.tabs.back();
        await pumpEventQueue();

        w.expectOneSave(_otherId, 'new other', 7);
        expect(w.tabState.activeTab, const NoteTab(_planId));
      },
    );

    test(
      'an edit typed less than 500 ms before forward is saved with the leaving note id',
      () async {
        final w = await _editorWired();
        w.open(_planId);
        w.tabs.navigate(const NoteTab(_otherId));
        w.tabs.back();
        await pumpEventQueue();
        w.ctrl.loadNote(w.db.getNote(_planId)!);
        w.ctrl.onContentChanged('new plan');

        w.tabs.forward();
        await pumpEventQueue();

        w.expectOneSave(_planId, 'new plan', 3);
        expect(w.tabState.activeTab, const NoteTab(_otherId));
      },
    );
  });

  group('tabsProvider wires targetExists', () {
    test('a note whose getNote returns null is removed on back', () async {
      final v = await _vault();

      v.tabs
        ..navigate(const NoteTab(_seedA))
        ..navigate(const NoteTab(_goneId))
        ..navigate(const NoteTab(_seedB));
      v.tabs.back();
      expect(v.state.activeTab, const NoteTab(_goneId));
      await pumpEventQueue();

      expect(v.state.activeTab, const NoteTab(_seedA));
      expect(v.notes.reads, contains(_goneId));
    });

    test('a note whose getNote returns a note stays on back', () async {
      final v = await _vault();

      v.tabs
        ..navigate(const NoteTab(_seedA))
        ..navigate(const NoteTab(_seedB));
      v.tabs.back();
      await pumpEventQueue();

      expect(v.state.activeTab, const NoteTab(_seedA));
      expect(v.state.canGoForward, isTrue);
      expect(v.state.canGoBack, isTrue);
      expect(v.notes.reads, [_seedA]);
    });

    test(
      'a canvas whose getCanvasDetail returns a canvas stays on back',
      () async {
        final v = await _vault();

        v.tabs
          ..navigate(const CanvasTab(_seedCanvas))
          ..navigate(const NoteTab(_seedB));
        v.tabs.back();
        await pumpEventQueue();

        expect(v.state.activeTab, const CanvasTab(_seedCanvas));
        expect(v.state.canGoBack, isTrue);
        expect(v.canvas.reads, [_seedCanvas]);
        expect(v.notes.reads, isEmpty);
      },
    );

    test('a gone canvas is removed on back', () async {
      final v = await _vault();

      v.tabs
        ..navigate(const NoteTab(_seedA))
        ..navigate(const CanvasTab(_goneId))
        ..navigate(const NoteTab(_seedB));
      v.tabs.back();
      await pumpEventQueue();

      expect(v.state.activeTab, const NoteTab(_seedA));
      expect(v.canvas.reads, [_goneId]);
    });

    test(
      'a topic scoped Graph view whose note is gone is removed on back',
      () async {
        final v = await _vault();

        v.tabs
          ..navigate(const NoteTab(_seedA))
          ..navigate(GraphTab(const GraphScope.topic(_goneId)))
          ..navigate(const NoteTab(_seedB));
        v.tabs.back();
        await pumpEventQueue();

        expect(v.state.activeTab, const NoteTab(_seedA));
        expect(v.notes.reads, contains(_goneId));
      },
    );

    test(
      'a day scoped Graph view whose note is gone is removed on forward',
      () async {
        final v = await _vault();

        v.tabs
          ..navigate(const NoteTab(_seedA))
          ..navigate(GraphTab(const GraphScope.day(_goneId)))
          ..navigate(const NoteTab(_seedB));
        v.tabs
          ..back()
          ..back();
        await pumpEventQueue();
        expect(v.state.activeTab, const NoteTab(_seedA));

        v.tabs.forward();
        await pumpEventQueue();

        expect(v.state.activeTab, const NoteTab(_seedB));
      },
    );

    test('a topic scoped Graph view whose note exists stays on back', () async {
      final v = await _vault();
      final graph = GraphTab(const GraphScope.topic(_seedA));

      v.tabs
        ..navigate(graph)
        ..navigate(const NoteTab(_seedB));
      v.tabs.back();
      await pumpEventQueue();

      expect(v.state.activeTab, graph);
      expect(v.notes.reads, [_seedA]);
    });

    test('a day scoped Graph view whose note exists stays on back', () async {
      final v = await _vault();
      final graph = GraphTab(const GraphScope.day(_seedA));

      v.tabs
        ..navigate(graph)
        ..navigate(const NoteTab(_seedB));
      v.tabs.back();
      await pumpEventQueue();

      expect(v.state.activeTab, graph);
      expect(v.notes.reads, [_seedA]);
    });

    test('a virtual Today entry is never checked and never removed', () async {
      final v = await _vault();
      expect(v.state.activeTab, _virtual);

      v.tabs.navigate(const NoteTab(_seedA));
      v.tabs.back();
      await pumpEventQueue();

      expect(v.state.tabs, [_virtual]);
      expect(v.state.canGoForward, isTrue);
      expect(v.notes.reads, isEmpty);
      expect(v.canvas.reads, isEmpty);
    });

    test(
      'a folder scoped Graph view is never checked and never removed',
      () async {
        final v = await _vault();
        final graph = GraphTab(const GraphScope.folder(_goneId));

        v.tabs
          ..navigate(graph)
          ..navigate(const NoteTab(_seedB));
        v.tabs.back();
        await pumpEventQueue();

        expect(v.state.activeTab, graph);
        expect(v.state.canGoBack, isTrue);
        expect(v.notes.reads, isEmpty);
        expect(v.canvas.reads, isEmpty);
      },
    );

    test(
      'the whole vault Graph view is never checked and never removed',
      () async {
        final v = await _vault();
        final graph = GraphTab(const GraphScope.vault());

        v.tabs
          ..navigate(graph)
          ..navigate(const NoteTab(_seedB));
        v.tabs.back();
        await pumpEventQueue();

        expect(v.state.activeTab, graph);
        expect(v.notes.reads, isEmpty);
      },
    );

    test('with no vault access every entry counts as existing', () async {
      final v = await _vault(noAccess: true);

      v.tabs
        ..navigate(const NoteTab(_goneId))
        ..navigate(const NoteTab(_seedB));
      v.tabs.back();
      await pumpEventQueue();

      expect(v.state.activeTab, const NoteTab(_goneId));
    });

    test(
      'a getNote that throws VaultUnreachableException counts as existing',
      () async {
        final v = await _vault(error: _unreachable);

        v.tabs
          ..navigate(const NoteTab(_goneId))
          ..navigate(const NoteTab(_seedB));
        v.tabs.back();
        await pumpEventQueue();

        expect(v.state.activeTab, const NoteTab(_goneId));
        expect(v.state.canGoForward, isTrue);
      },
    );

    test(
      'a getCanvasDetail that throws another error counts as existing',
      () async {
        final v = await _vault(error: StateError('no db'));

        v.tabs
          ..navigate(const CanvasTab(_goneId))
          ..navigate(const NoteTab(_seedB));
        v.tabs.back();
        await pumpEventQueue();

        expect(v.state.activeTab, const CanvasTab(_goneId));
      },
    );
  });
}

// ------------------------------------------------- the real editor behind tabs

const _planId = '01J9PLAN000000000000000266';
const _otherId = '01J9OTHER00000000000000266';

/// The real `tabsProvider` and `editorControllerProvider` over a FakeVaultDb, a
/// FakeMemexCli and a FakeClock that never advances, so a save sent can only
/// be the leave's flush. No widget tree: a test calls `loadNote` itself.
class _EditorWired {
  _EditorWired(this.c, this.db, this.cli);

  final ProviderContainer c;
  final FakeVaultDb db;
  final FakeMemexCli cli;

  TabsNotifier get tabs => c.read(tabsProvider.notifier);
  TabsState get tabState => c.read(tabsProvider);
  EditorController get ctrl => c.read(editorControllerProvider.notifier);

  void open(String id) {
    tabs.openOrFocus(NoteTab(id));
    ctrl.loadNote(db.getNote(id)!);
  }

  void expectOneSave(String id, String text, int version) {
    final updates = cli.callsFor('update');
    expect(updates, hasLength(1), reason: 'exactly one save was sent');
    final call = updates.single;
    expect(call.flag('note-id'), id);
    expect(call.flag('expected-version'), '$version');
    expect(call.stdinBody, text);
  }
}

Future<_EditorWired> _editorWired() async {
  final dir = await Directory.systemTemp.createTemp('tabs_navigate_wired');
  final db = FakeVaultDb.v5()
    ..seedNote(id: _planId, title: 'Plan', content: 'old', version: 3)
    ..seedNote(id: _otherId, title: 'Other', content: 'other body', version: 7);
  final cli = FakeMemexCli()..onUpdateWrites(db);
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(cli),
      clockProvider.overrideWithValue(FakeClock()),
    ],
  );
  addTearDown(() async {
    final store = c.read(tabsProvider.notifier).store;
    c.dispose();
    await store.flush();
    db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  c.read(vaultAccessProvider);
  c.listen(tabsProvider, (_, _) {});
  c.listen(editorControllerProvider, (_, _) {});
  await pumpEventQueue();
  return _EditorWired(c, db, cli);
}

// ------------------------------------------------- tabsProvider over a vault

const _seedA = 'seed-a';
const _seedB = 'seed-b';
const _seedCanvas = 'seed-canvas';
const _goneId = 'gone';

/// A notes domain that records `getNote` and can make it throw.
class _ReadNotes extends LocalNotesAccess {
  _ReadNotes({required super.vaultPath, super.db, this.error});

  final Object? error;
  final reads = <String>[];

  @override
  Future<Note?> getNote(String id) async {
    reads.add(id);
    if (error case final e?) throw e;
    return super.getNote(id);
  }
}

/// A canvas domain that records `getCanvasDetail` and can make it throw.
class _ReadCanvas extends LocalCanvasAccess {
  _ReadCanvas({required super.vaultPath, super.db, this.error});

  final Object? error;
  final reads = <String>[];

  @override
  Future<CanvasDetailRow?> getCanvasDetail(String canvasId) async {
    reads.add(canvasId);
    if (error case final e?) throw e;
    return super.getCanvasDetail(canvasId);
  }
}

class _Vault {
  _Vault(this.c, this.notes, this.canvas);

  final ProviderContainer c;
  final _ReadNotes notes;
  final _ReadCanvas canvas;

  TabsNotifier get tabs => c.read(tabsProvider.notifier);
  TabsState get state => c.read(tabsProvider);
}

/// `tabsProvider` launched on a vault holding [_seedA], [_seedB] and
/// [_seedCanvas], on the virtual Today tab, with no modifier held.
Future<_Vault> _vault({bool noAccess = false, Object? error}) async {
  final dir = await Directory.systemTemp.createTemp('tabs_navigate_vault');
  final db = FakeVaultDb.v5()
    ..seedNote(id: _seedA, title: 'A', content: 'a')
    ..seedNote(id: _seedB, title: 'B', content: 'b')
    ..seedCanvas(_seedCanvas, 'Board', updatedAt: 1);
  final notes = _ReadNotes(vaultPath: dir.path, db: db, error: error);
  final canvas = _ReadCanvas(vaultPath: dir.path, db: db, error: error);
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(null),
      clockProvider.overrideWithValue(FakeClock()),
      vaultAccessProvider.overrideWith(
        (_) => noAccess
            ? null
            : LocalVaultAccess(
                vaultPath: dir.path,
                db: db,
                notes: notes,
                canvas: canvas,
              ),
      ),
    ],
  );
  addTearDown(() async {
    final store = c.read(tabsProvider.notifier).store;
    c.dispose();
    await store.flush();
    db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  c.listen(tabsProvider, (_, _) {});
  await pumpEventQueue();
  return _Vault(c, notes, canvas);
}
