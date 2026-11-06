// WI #268 (N5): zooming into a note on a canvas is a Tab history entry. A
// CanvasTab carries `zoomedNoteId`; zoom is part of equality, not of `tabId` or
// of what `ui_state.json` holds. Every match on "the tab showing X" decides
// whether zoom counts: `openOrFocus` and `close(CanvasTab)` match the canvas
// (R2), `navigate` and its no-op match the whole value, a note never matches a
// canvas zoomed into it (R5), and `close(NoteTab)` zooms such a canvas out.
//
// Answers from `targetExists` come from Completers or fakes, never wall waits.
// The tab bar and the canvas widgets are in
// `app/test/widgets/canvas_zoom_history_test.dart`.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import '../support/canvas_seeds.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/today_cli_fakes.dart';
import '../support/recording_tabs.dart';

const _a = NoteTab('a');
const _b = NoteTab('b');
const _x = NoteTab('x');
const _y = NoteTab('y');
const _board = CanvasTab('board');
const _other = CanvasTab('other');
const _zoomedA = CanvasTab('board', zoomedNoteId: 'a');
const _zoomedB = CanvasTab('board', zoomedNoteId: 'b');

/// A UiStateStore that never touches disk and counts its writes.
class _MemoryStore extends UiStateStore {
  _MemoryStore() : super(vaultPath: '/nonexistent/tabs-canvas-zoom');

  UiState _last = UiState(
    tabs: const [],
    activeTabIndex: 0,
    canvasViewports: const {},
  );
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

/// A `targetExists` whose [gone] targets answer false at once.
class _Exists {
  final gone = <WorkspaceTab>{};
  Future<bool> call(WorkspaceTab target) =>
      Future<bool>.value(!gone.contains(target));
}

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

  void reset() {
    selections.clear();
    seen.clear();
    writes = 0;
    store.writes = 0;
  }

  /// `openOrFocus` of each of [tabs], then [reset].
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

Future<_Probe> _probe({bool Function()? modifier, _Exists? exists}) async {
  final memory = _MemoryStore();
  final recorder = TabsRecorder();
  late final _Probe probe;
  final notifier = TabsNotifier(
    store: memory,
    onPersistedSelection: (id) => probe.selections.add(id),
    onBeforeLeave: () => probe.seen.add(probe.notifier.state),
    isNewTabModifierPressed: modifier ?? () => false,
    navigationObserver: recorder.observer,
    targetExists: exists?.call,
  );
  probe = _Probe(notifier, memory, recorder);
  addTearDown(() {
    if (notifier.mounted) notifier.dispose();
  });
  notifier.addListener((_) => probe.writes++, fireImmediately: false);
  await pumpEventQueue();
  probe.reset();
  return probe;
}

/// The note each canvas tab in [tabs] is zoomed into, null for any other tab.
List<String?> _zooms(List<WorkspaceTab> tabs) => [
  for (final t in tabs) t is CanvasTab ? t.zoomedNoteId : null,
];

/// Equality ignores nothing here: the tabs and each tab's zoom are compared.
void _expectTabs(
  _Probe p,
  List<WorkspaceTab> tabs,
  int active, {
  bool back = false,
  bool forward = false,
}) {
  expect(p.state.tabs, tabs, reason: 'what each tab shows');
  expect(_zooms(p.state.tabs), _zooms(tabs), reason: 'what each tab zooms');
  expect(p.state.activeIndex, active, reason: 'the active index');
  expect(p.state.canGoBack, back, reason: 'canGoBack');
  expect(p.state.canGoForward, forward, reason: 'canGoForward');
}

/// One tab on [_board] with the history `board -> zoomedA`, active.
Future<_Probe> _zoomedProbe({
  bool Function()? modifier,
  _Exists? exists,
}) async {
  final p = await _probe(modifier: modifier, exists: exists);
  p.open([_board]);
  p.walk([_zoomedA]);
  return p;
}

void main() {
  group('CanvasTab value', () {
    test(
      'a zoomed canvas tab is not equal to the same canvas unzoomed but has its tabId and persists the same',
      () {
        // Built from run-time values so the constructor runs.
        final id = ['bo', 'ard'].join();
        final note = ['n', '1'].join();
        final plain = CanvasTab(id);
        final zoomed = CanvasTab(id, zoomedNoteId: note);

        expect(zoomed.zoomedNoteId, note);
        expect(plain.zoomedNoteId, isNull);
        expect(zoomed, isNot(plain));
        expect(plain, isNot(zoomed));
        expect(zoomed.tabId, plain.tabId);
        expect(zoomed.tabId, 'canvas-board');
        expect(zoomed.toPersisted(), plain.toPersisted());
        expect(zoomed.toPersisted().toJson(), {
          'kind': 'canvas',
          'id': 'board',
        });
      },
    );

    test(
      'canvas tabs zoomed into the same note are equal and zoomed into different notes are not',
      () {
        final one = CanvasTab(['bo', 'ard'].join(), zoomedNoteId: 'n1');
        final same = CanvasTab(['bo', 'ard'].join(), zoomedNoteId: 'n1');
        final otherNote = CanvasTab('board', zoomedNoteId: 'n2');
        final otherCanvas = CanvasTab('elsewhere', zoomedNoteId: 'n1');

        expect(one, same);
        expect(one.hashCode, same.hashCode);
        expect(
          one.hashCode,
          isNot(const CanvasTab('board').hashCode),
          reason: 'zoom is part of the hash',
        );
        expect(one, isNot(otherNote));
        expect(one, isNot(otherCanvas));
        expect(const NoteTab('n1'), isNot(one));
        expect(one, isNot(const NoteTab('n1')));
      },
    );
  });

  group('zooming is a history entry', () {
    test(
      'navigate to a zoomed canvas adds an entry that back zooms out of and forward zooms back into',
      () async {
        final p = await _probe();
        p.open([_board]);

        p.notifier.navigate(_zoomedA);
        _expectTabs(p, [_zoomedA], 0, back: true);

        p.notifier.back();
        _expectTabs(p, [_board], 0, forward: true);

        p.notifier.forward();
        _expectTabs(p, [_zoomedA], 0, back: true);
      },
    );

    test(
      'navigate from a zoomed canvas to another note on it adds an entry and back returns to the first note',
      () async {
        final p = await _zoomedProbe();

        p.notifier.navigate(_zoomedB);
        _expectTabs(p, [_zoomedB], 0, back: true);

        p.notifier.back();
        _expectTabs(p, [_zoomedA], 0, back: true, forward: true);
      },
    );

    test(
      'navigate to the zoom the active tab already shows adds no entry and changes nothing',
      () async {
        final p = await _zoomedProbe();

        p.notifier.navigate(CanvasTab('board', zoomedNoteId: ['a'].join()));

        _expectTabs(p, [_zoomedA], 0, back: true);
        expect(p.writes, 0, reason: 'no state write');
        expect(p.store.writes, 0, reason: 'no persist');
        expect(p.selections, isEmpty);
        expect(p.leaves, 0);
      },
    );

    test(
      'following a link from a zoomed note navigates and the first back returns to the zoomed note and the next to the canvas',
      () async {
        final p = await _zoomedProbe();

        p.notifier.follow(_b);
        _expectTabs(p, [_b], 0, back: true);
        expect(p.selections.last, 'b');

        p.notifier.back();
        _expectTabs(p, [_zoomedA], 0, back: true, forward: true);
        expect(p.selections.last, 'a');

        p.notifier.back();
        _expectTabs(p, [_board], 0, forward: true);
        expect(p.selections.last, isNull);
      },
    );

    test('two tabs on one canvas zoom independently', () async {
      final p = await _probe();
      p.open([_board, _x], active: 1);
      p.notifier.navigate(_board); // [board] [board*]
      p.notifier.setActive(0);
      p.reset();

      p.notifier.navigate(_zoomedA);
      _expectTabs(p, [_zoomedA, _board], 0, back: true);
      expect(p.state.tabs[0].tabId, p.state.tabs[1].tabId);

      p.notifier.setActive(1);
      p.notifier.navigate(_zoomedB);
      _expectTabs(p, [_zoomedA, _zoomedB], 1, back: true);

      p.notifier.back();
      _expectTabs(p, [_zoomedA, _board], 1, back: true, forward: true);
      expect(p.selections.last, isNull);

      p.notifier.setActive(0);
      p.notifier.back();
      _expectTabs(p, [_board, _board], 0, forward: true);
    });
  });

  group('openOrFocus and follow match a canvas by its id', () {
    test(
      'a Cmd click on a canvas focuses a tab zoomed into a note on it and leaves it zoomed with its history untouched',
      () async {
        final p = await _probe(modifier: () => true);
        p.open([_board, _x], active: 0);
        p.notifier.navigate(_zoomedA); // [zoomedA*] [x]
        p.notifier.setActive(1);
        p.reset();

        p.notifier.follow(_board);

        _expectTabs(p, [_zoomedA, _x], 0, back: true);
        expect(p.state.tabs, hasLength(2), reason: 'no new tab');
        expect(p.recorder.followed, [_board]);
        p.notifier.back();
        _expectTabs(p, [_board, _x], 0, forward: true);
      },
    );

    test(
      'openOrFocus of a canvas focuses the leftmost tab on it zoomed or not and returns its index',
      () async {
        final p = await _probe();
        p.open([_board, _x], active: 1);
        p.notifier.navigate(_board); // [board] [board*]
        p.notifier.setActive(0);
        p.notifier.navigate(_zoomedA); // [zoomedA*] [board]
        p.notifier.setActive(1);
        p.reset();

        final leftmost = p.notifier.openOrFocus(_board);

        expect(leftmost, 0);
        _expectTabs(p, [_zoomedA, _board], 0, back: true);

        p.notifier.setActive(1);
        p.notifier.navigate(_zoomedB); // [zoomedA] [zoomedB*]
        p.notifier.setActive(0);
        p.notifier.navigate(_board); // [board*] [zoomedB]
        p.reset();

        final onlyZoomed = p.notifier.openOrFocus(_board);
        expect(onlyZoomed, 0, reason: 'leftmost, the unzoomed one');
        expect(p.state.tabs, hasLength(2));

        p.notifier.setActive(1);
        expect(p.notifier.openOrFocus(_board), 0);
        expect(p.state.tabs, hasLength(2), reason: 'no tab was opened');
      },
    );

    test(
      'openOrFocus of a canvas finds a tab zoomed into a note when no tab shows it unzoomed',
      () async {
        final p = await _probe();
        p.open([_x, _board], active: 1);
        p.notifier.navigate(_zoomedA); // [x] [zoomedA*]
        p.notifier.setActive(0);
        p.reset();

        final index = p.notifier.openOrFocus(_board);

        expect(index, 1);
        _expectTabs(p, [_x, _zoomedA], 1, back: true);
        expect(p.selections, ['a']);
        expect(p.leaves, 1);
      },
    );

    test(
      'a plain click on a canvas from a tab zoomed into a note on it adds an entry showing the canvas unzoomed and back returns to the zoomed note',
      () async {
        final p = await _zoomedProbe();

        p.notifier.follow(_board);
        _expectTabs(p, [_board], 0, back: true);
        expect(p.selections, [null]);

        p.notifier.back();
        _expectTabs(p, [_zoomedA], 0, back: true, forward: true);
        expect(p.selections.last, 'a');

        p.notifier.back();
        _expectTabs(p, [_board], 0, forward: true);
      },
    );

    test(
      'openOrFocus of a zoomed canvas focuses only an equal zoomed tab and otherwise opens a new tab',
      () async {
        final p = await _probe();
        p.open([_board, _x], active: 0);
        p.notifier.openOrFocus(_zoomedB); // [board] [x] [zoomedB*]
        p.notifier.setActive(0);
        p.reset();

        expect(p.notifier.openOrFocus(_zoomedB), 2, reason: 'the equal tab');
        expect(p.state.tabs, hasLength(3));

        p.notifier.setActive(0);
        expect(
          p.notifier.openOrFocus(_zoomedA),
          3,
          reason: 'neither the plain canvas nor another zoom is a match',
        );
        _expectTabs(p, [_board, _x, _zoomedB, _zoomedA], 3);

        expect(
          p.notifier.openOrFocus(_other),
          4,
          reason: 'another canvas is never a match',
        );
        expect(p.state.tabs, hasLength(5));
      },
    );

    test(
      'a Cmd click on a note does not focus a canvas tab zoomed into that note',
      () async {
        final p = await _probe(modifier: () => true);
        p.open([_board, _x], active: 0);
        p.notifier.navigate(_zoomedA); // [zoomedA*] [x]
        p.reset();

        p.notifier.follow(_a);

        _expectTabs(p, [_zoomedA, _x, _a], 2, back: false);
        expect(p.selections, ['a']);
        expect(p.state.tabs[0], isA<CanvasTab>());
      },
    );

    test(
      'openOrFocus of a note focuses a note tab and skips a canvas tab zoomed into that note on either side of it',
      () async {
        final p = await _probe();
        p.open([_a, _board, _x], active: 1);
        p.notifier.navigate(_zoomedA); // [a] [zoomedA*] [x]
        p.notifier.setActive(2);
        p.reset();

        expect(p.notifier.openOrFocus(_a), 0);
        _expectTabs(p, [_a, _zoomedA, _x], 0, back: false);

        final q = await _probe();
        q.open([_board, _a], active: 0);
        q.notifier.navigate(_zoomedA); // [zoomedA*] [a]
        q.notifier.setActive(1);
        q.reset();

        expect(q.notifier.openOrFocus(_a), 1);
        expect(q.state.tabs, hasLength(2));
      },
    );
  });

  group('the selection follows the shown note', () {
    test(
      'zooming into a note emits that note id and zooming out emits null',
      () async {
        final p = await _probe();
        p.open([_board]);

        p.notifier.navigate(_zoomedA);
        expect(p.selections, ['a']);

        p.notifier.back();
        expect(p.selections, ['a', null]);

        p.notifier.forward();
        expect(p.selections, ['a', null, 'a']);
      },
    );

    test(
      'switching tabs emits the zoomed note of a zoomed canvas tab and null for a canvas tab',
      () async {
        final p = await _probe();
        p.open([_board, _x], active: 0);
        p.notifier.navigate(_zoomedA);
        p.notifier.setActive(1);
        p.reset();

        p.notifier.setActive(0);
        expect(p.selections, ['a']);

        p.notifier.setActive(1);
        expect(p.selections, ['a', 'x']);

        p.notifier.navigate(_other);
        expect(p.selections.last, isNull, reason: 'a canvas shows no note');
      },
    );

    test('back and forward into a zoomed entry emit its note id', () async {
      final p = await _probe();
      p.open([_board]);
      p.walk([_zoomedA, _b]);

      p.notifier.back();
      expect(p.selections, ['a']);

      p.notifier.forward();
      expect(p.selections, ['a', 'b']);
    });

    test(
      'a note id from a zoomed tab goes to selectedNoteIdProvider and zooming out clears it',
      () async {
        final v = await _vault();
        v.tabs.navigate(const CanvasTab(_canvasId));
        await pumpEventQueue();
        expect(v.c.read(selectedNoteIdProvider), isNull);

        v.tabs.navigate(const CanvasTab(_canvasId, zoomedNoteId: _noteA));
        expect(v.c.read(selectedNoteIdProvider), _noteA);

        v.tabs.back();
        await pumpEventQueue();
        expect(v.c.read(selectedNoteIdProvider), isNull);

        v.tabs.forward();
        await pumpEventQueue();
        expect(v.c.read(selectedNoteIdProvider), _noteA);
      },
    );
  });

  group('close', () {
    test(
      'close of a note zooms out a canvas tab zoomed into it instead of closing the tab in one write',
      () async {
        final p = await _probe();
        p.open([_board, _x], active: 0);
        p.walk([_zoomedA]); // [zoomedA*] [x]

        p.notifier.close(_a);

        _expectTabs(p, [_board, _x], 0, back: true);
        expect(p.writes, 1, reason: 'one state write');
        expect(p.store.writes, 1, reason: 'one persist');
        expect(p.selections, [null], reason: 'one selection, no note');
        expect(p.leaves, 1, reason: 'the active tab zoomed out');
      },
    );

    test(
      'close of a note replaces the zoomed entry so back reaches the entry before it in two steps and Forward is kept',
      () async {
        final p = await _probe();
        p.open([_a]);
        p.notifier.navigate(_board);
        p.notifier.navigate(_zoomedA); // [a, board, zoomedA*]
        p.notifier.navigate(_y); // [a, board, zoomedA, y*]
        p.notifier.back(); // [a, board, zoomedA*, y]
        p.reset();

        p.notifier.close(_a);

        _expectTabs(p, [_board], 0, back: true, forward: true);
        p.notifier.back();
        _expectTabs(p, [_board], 0, back: true, forward: true);
        p.notifier.back();
        _expectTabs(p, [_a], 0, forward: true);
        p.notifier.forward();
        p.notifier.forward();
        p.notifier.forward();
        _expectTabs(p, [_y], 0, back: true);
      },
    );

    test(
      'close of a note closes note tabs showing it and zooms out the zoomed canvas tab when the active tab is another tab',
      () async {
        final p = await _probe();
        p.open([_a, _board, _x], active: 1);
        p.notifier.navigate(_zoomedA);
        p.notifier.setActive(2);
        p.reset();
        expect(_zooms(p.state.tabs), [null, 'a', null], reason: 'setup');

        p.notifier.close(_a);

        _expectTabs(p, [_board, _x], 1, back: false);
        expect(p.state.tabs[0], _board);
        expect(p.writes, 1, reason: 'one state write');
        expect(p.store.writes, 1, reason: 'one persist');
        expect(p.selections, ['x'], reason: 'one selection');
        expect(p.leaves, 0, reason: 'the active tab was not affected');
      },
    );

    test(
      'close of a note with the active note tab among those closed runs onBeforeLeave once and activates the nearest remaining tab',
      () async {
        final p = await _probe();
        p.open([_x, _a, _board], active: 2);
        p.notifier.navigate(_zoomedA); // [x] [a] [zoomedA*]
        p.notifier.setActive(1);
        p.reset();
        expect(_zooms(p.state.tabs), [null, null, 'a'], reason: 'setup');

        p.notifier.close(_a);

        _expectTabs(p, [_x, _board], 0);
        expect(p.writes, 1);
        expect(p.store.writes, 1);
        expect(p.selections, ['x']);
        expect(p.leaves, 1);
      },
    );

    test(
      'close of a note with the zoomed canvas tab active and a note tab closing runs onBeforeLeave once',
      () async {
        final p = await _probe();
        p.open([_a, _board], active: 1);
        p.notifier.navigate(_zoomedA); // [a] [zoomedA*]
        p.reset();

        p.notifier.close(_a);

        _expectTabs(p, [_board], 0, back: true);
        expect(p.writes, 1);
        expect(p.store.writes, 1);
        expect(p.selections, [null]);
        expect(p.leaves, 1);
      },
    );

    test(
      'close of a note no tab shows or is zoomed into does nothing and leaves other zoomed tabs zoomed',
      () async {
        final p = await _zoomedProbe();

        p.notifier.close(const NoteTab('c'));

        _expectTabs(p, [_zoomedA], 0, back: true);
        expect(p.writes, 0);
        expect(p.store.writes, 0);
        expect(p.selections, isEmpty);
        expect(p.leaves, 0);
      },
    );

    test(
      'close of a note leaves a canvas tab zoomed into another note zoomed',
      () async {
        final p = await _probe();
        p.open([_board, _a], active: 0);
        p.notifier.navigate(_zoomedB); // [zoomedB*] [a]

        p.notifier.close(_a);

        _expectTabs(p, [_zoomedB], 0, back: true);
        expect(p.selections.last, 'b');
      },
    );

    test(
      'close of a note leaves older zoomed entries in every history and back falls to targetExists',
      () async {
        final exists = _Exists();
        final p = await _probe(exists: exists);
        p.open([_board]);
        p.walk([_zoomedA, _y]); // [board, zoomedA, y*]
        p.notifier.close(_a);
        _expectTabs(p, [_y], 0, back: true);
        expect(p.writes, 0, reason: 'the tab shows y, nothing closed');

        p.notifier.back();
        _expectTabs(p, [_zoomedA], 0, back: true, forward: true);

        exists.gone.add(_zoomedA);
        p.notifier.forward();
        p.notifier.back();
        await pumpEventQueue();

        _expectTabs(p, [_board], 0, forward: true);
      },
    );

    test('close of a canvas closes every tab on it zoomed or not', () async {
      final p = await _probe();
      p.open([_board, _x], active: 1);
      p.notifier.navigate(_board); // [board] [board*]
      p.notifier.setActive(0);
      p.notifier.navigate(_zoomedA); // [zoomedA*] [board]
      p.notifier.openOrFocus(_y); // [zoomedA] [board] [y*]
      p.notifier.openOrFocus(_other); // [zoomedA] [board] [y] [other*]
      p.reset();
      expect(_zooms(p.state.tabs), ['a', null, null, null], reason: 'setup');

      p.notifier.close(_board);

      _expectTabs(p, [_y, _other], 1, back: false);
      expect(p.writes, 1, reason: 'one state write');
      expect(p.store.writes, 1, reason: 'one persist');
      expect(p.selections, [null], reason: 'one selection');
      expect(p.leaves, 0, reason: 'the active tab stays');
    });

    test(
      'close of a canvas closes a tab that is only zoomed into a note on it',
      () async {
        final p = await _zoomedProbe();
        p.notifier.openOrFocus(_x);
        p.reset();
        expect(_zooms(p.state.tabs), ['a', null], reason: 'setup');

        p.notifier.close(_board);

        _expectTabs(p, [_x], 0);
        expect(p.leaves, 0);
        expect(p.writes, 1);
      },
    );
  });

  group('ui_state.json holds no zoom', () {
    Future<UiStateStore> tempStore() async {
      final dir = await Directory.systemTemp.createTemp('tabs_canvas_zoom');
      final store = UiStateStore(vaultPath: dir.path);
      addTearDown(() async {
        await store.flush();
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      return store;
    }

    String rawJson(UiStateStore store) =>
        File('${store.vaultPath}/.memex/ui_state.json').readAsStringSync();

    test(
      'a relaunch shows a canvas tab unzoomed and ui_state.json holds no zoom',
      () async {
        final store = await tempStore();
        final tabs = TabsNotifier(
          store: store,
          onPersistedSelection: (_) {},
          isNewTabModifierPressed: () => false,
        );
        addTearDown(tabs.dispose);
        tabs.openOrFocus(const CanvasTab('board'));

        tabs.navigate(const CanvasTab('board', zoomedNoteId: 'zoomed-note'));

        final active = tabs.state.activeTab! as CanvasTab;
        expect(active.zoomedNoteId, 'zoomed-note', reason: 'it is zoomed');
        await store.flush();
        final raw = rawJson(store);
        final json = jsonDecode(raw) as Map<String, dynamic>;
        expect(json['tabs'], [
          {'kind': 'canvas', 'id': 'board'},
        ]);
        expect(raw, isNot(contains('zoom')));
        expect(raw, isNot(contains('zoomed-note')));

        final reopened = TabsNotifier(
          store: UiStateStore(vaultPath: store.vaultPath),
          onPersistedSelection: (_) {},
          isNewTabModifierPressed: () => false,
        );
        addTearDown(reopened.dispose);
        final shown = reopened.state.activeTab! as CanvasTab;
        expect(shown.id, 'board');
        expect(shown.zoomedNoteId, isNull);
        expect(reopened.state.canGoBack, isFalse);
      },
    );

    test(
      'two tabs on one canvas persist as two identical entries and relaunch unzoomed',
      () async {
        final store = await tempStore();
        final tabs = TabsNotifier(
          store: store,
          onPersistedSelection: (_) {},
          isNewTabModifierPressed: () => false,
        );
        addTearDown(tabs.dispose);
        tabs.openOrFocus(const CanvasTab('board'));
        tabs.openOrFocus(_x);
        tabs.navigate(const CanvasTab('board')); // [board] [board*]
        tabs.setActive(0);

        tabs.navigate(const CanvasTab('board', zoomedNoteId: 'zoomed-note'));

        expect(_zooms(tabs.state.tabs), [
          'zoomed-note',
          null,
        ], reason: 'the first tab is zoomed');
        await store.flush();
        final json = jsonDecode(rawJson(store)) as Map<String, dynamic>;
        expect(json['tabs'], [
          {'kind': 'canvas', 'id': 'board'},
          {'kind': 'canvas', 'id': 'board'},
        ]);
        expect(json['active_tab_index'], 0);

        final reopened = TabsNotifier(
          store: UiStateStore(vaultPath: store.vaultPath),
          onPersistedSelection: (_) {},
          isNewTabModifierPressed: () => false,
        );
        addTearDown(reopened.dispose);
        expect(reopened.state.tabs, [_board, _board]);
        expect(_zooms(reopened.state.tabs), [null, null]);
      },
    );
  });

  group('tabsProvider wires targetExists for a zoomed entry', () {
    const zoomedHere = CanvasTab(_canvasId, zoomedNoteId: _noteA);
    const goneNote = CanvasTab(_canvasId, zoomedNoteId: _goneId);
    const goneCanvas = CanvasTab(_goneId, zoomedNoteId: _noteA);

    test(
      'back to a zoomed entry whose note is gone removes it and continues back with no error',
      () async {
        final v = await _vault();
        v.tabs
          ..navigate(const NoteTab(_noteB))
          ..navigate(goneNote)
          ..navigate(const NoteTab(_noteA));

        v.tabs.back();
        expect(v.state.activeTab, goneNote, reason: 'it lands there first');
        await pumpEventQueue();

        expect(v.state.activeTab, const NoteTab(_noteB));
        expect(v.state.canGoForward, isTrue);
        expect(v.canvas.reads, contains(_canvasId));
        expect(v.notes.reads, contains(_goneId));
        v.tabs.forward();
        await pumpEventQueue();
        expect(v.state.activeTab, const NoteTab(_noteA), reason: 'entry gone');
      },
    );

    test(
      'forward to a zoomed entry whose note is gone removes it and continues forward with no error',
      () async {
        final v = await _vault();
        v.tabs
          ..navigate(const NoteTab(_noteB))
          ..navigate(goneNote)
          ..navigate(const NoteTab(_noteA));
        v.tabs
          ..back()
          ..back();
        await pumpEventQueue();
        expect(v.state.activeTab, const NoteTab(_noteB));

        v.tabs.forward();
        expect(v.state.activeTab, goneNote);
        await pumpEventQueue();

        expect(v.state.activeTab, const NoteTab(_noteA));
        expect(v.state.canGoForward, isFalse);
      },
    );

    test(
      'back to a zoomed entry whose canvas is gone removes it and reads no note',
      () async {
        final v = await _vault();
        v.tabs
          ..navigate(const CanvasTab(_canvasId))
          ..navigate(goneCanvas)
          ..navigate(const NoteTab(_noteB));

        v.tabs.back();
        expect(v.state.activeTab, goneCanvas);
        await pumpEventQueue();

        expect(v.state.activeTab, const CanvasTab(_canvasId));
        expect(_zooms(v.state.tabs), [null]);
        expect(v.canvas.reads, [_goneId, _canvasId]);
        expect(v.notes.reads, isEmpty, reason: 'the canvas is checked first');
      },
    );

    test(
      'forward to a zoomed entry whose canvas is gone removes it and continues forward',
      () async {
        final v = await _vault();
        v.tabs
          ..navigate(const NoteTab(_noteB))
          ..navigate(goneCanvas)
          ..navigate(const NoteTab(_noteA));
        v.tabs
          ..back()
          ..back();
        await pumpEventQueue();
        expect(v.state.activeTab, const NoteTab(_noteB));

        v.tabs.forward();
        await pumpEventQueue();

        expect(v.state.activeTab, const NoteTab(_noteA));
      },
    );

    test(
      'a zoomed entry whose note and canvas exist stays on back and reads both',
      () async {
        final v = await _vault();
        v.tabs
          ..navigate(const NoteTab(_noteB))
          ..navigate(zoomedHere)
          ..navigate(const NoteTab(_noteA));

        v.tabs.back();
        await pumpEventQueue();

        expect(v.state.activeTab, zoomedHere);
        expect(_zooms(v.state.tabs), [_noteA]);
        expect(v.state.canGoBack, isTrue);
        expect(v.state.canGoForward, isTrue);
        expect(v.canvas.reads, [_canvasId]);
        expect(v.notes.reads, [_noteA]);
      },
    );

    test('a getNote that throws counts a zoomed entry as existing', () async {
      final v = await _vault(noteError: StateError('no notes'));
      v.tabs
        ..navigate(const NoteTab(_noteB))
        ..navigate(goneNote)
        ..navigate(const NoteTab(_noteA));

      v.tabs.back();
      await pumpEventQueue();

      expect(v.state.activeTab, goneNote);
      expect(v.state.canGoForward, isTrue);
    });

    test(
      'a getCanvasDetail that throws counts a zoomed entry as existing',
      () async {
        final v = await _vault(canvasError: StateError('no canvases'));
        v.tabs
          ..navigate(const NoteTab(_noteB))
          ..navigate(goneCanvas)
          ..navigate(const NoteTab(_noteA));

        v.tabs.back();
        await pumpEventQueue();

        expect(v.state.activeTab, goneCanvas);
        expect(v.state.canGoForward, isTrue);
      },
    );
  });

  group('a typed edit is saved before leaving a zoomed note', () {
    test(
      'an edit typed less than 500 ms before back from a zoomed note is saved with that note id and the clock not advanced',
      () async {
        final w = await _editorWired();
        w.tabs.openOrFocus(const CanvasTab(_canvasId));
        w.tabs.navigate(const CanvasTab(_canvasId, zoomedNoteId: _planId));
        expect(_activeZoom(w), _planId, reason: 'it is zoomed');
        w.ctrl.loadNote(w.db.getNote(_planId)!);
        w.ctrl.onContentChanged('new plan');

        w.tabs.back();
        await pumpEventQueue();

        w.expectOneSave(_planId, 'new plan', 3);
        expect(w.clock.now(), _launchedAt, reason: 'the clock did not move');
        expect(_activeZoom(w), isNull);
      },
    );

    test(
      'an edit typed less than 500 ms before a link followed from a zoomed note is saved with that note id',
      () async {
        final w = await _editorWired();
        w.tabs.openOrFocus(const CanvasTab(_canvasId));
        w.tabs.navigate(const CanvasTab(_canvasId, zoomedNoteId: _planId));
        expect(_activeZoom(w), _planId, reason: 'it is zoomed');
        w.ctrl.loadNote(w.db.getNote(_planId)!);
        w.ctrl.onContentChanged('new plan');

        w.tabs.navigate(const NoteTab(_otherId));
        await pumpEventQueue();

        w.expectOneSave(_planId, 'new plan', 3);
        expect(w.clock.now(), _launchedAt);
      },
    );
  });
}

// ------------------------------------------------- tabsProvider over a vault

const _canvasId = 'cv-268';
const _noteA = 'note-268-a';
const _noteB = 'note-268-b';
const _goneId = 'gone-268';

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

/// `tabsProvider` launched on a vault holding the notes [_noteA] and [_noteB]
/// and the canvas [_canvasId] with [_noteA] placed on it.
Future<_Vault> _vault({Object? noteError, Object? canvasError}) async {
  final dir = await Directory.systemTemp.createTemp('tabs_canvas_zoom_vault');
  final db = FakeVaultDb.v5()
    ..seedNote(id: _noteA, title: 'A', content: 'a')
    ..seedNote(id: _noteB, title: 'B', content: 'b')
    ..seedCanvas(_canvasId, 'Board', updatedAt: 1)
    ..seedCanvasNode(_canvasId, _noteA, x: 0, y: 0);
  final notes = _ReadNotes(vaultPath: dir.path, db: db, error: noteError);
  final canvas = _ReadCanvas(vaultPath: dir.path, db: db, error: canvasError);
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(null),
      clockProvider.overrideWithValue(FakeClock()),
      vaultAccessProvider.overrideWith(
        (_) => LocalVaultAccess(
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

// ------------------------------------------------- the real editor behind tabs

const _planId = '01J9PLAN000000000000000268';
const _otherId = '01J9OTHER00000000000000268';

/// The clock the wired editor starts on, which no test advances.
final _launchedAt = DateTime(2026, 10, 3, 9);

/// The real `tabsProvider` and `editorControllerProvider` over a FakeVaultDb
/// holding the canvas [_canvasId] with the note [_planId] on it, a FakeMemexCli
/// and a FakeClock that never advances, so a save sent can only be the leave's
/// flush. No widget tree: a test calls `loadNote` itself.
String? _activeZoom(_EditorWired w) =>
    (w.tabState.activeTab! as CanvasTab).zoomedNoteId;

class _EditorWired {
  _EditorWired(this.c, this.db, this.cli, this.clock);

  final ProviderContainer c;
  final FakeVaultDb db;
  final FakeMemexCli cli;
  final FakeClock clock;

  TabsNotifier get tabs => c.read(tabsProvider.notifier);
  TabsState get tabState => c.read(tabsProvider);
  EditorController get ctrl => c.read(editorControllerProvider.notifier);

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
  final dir = await Directory.systemTemp.createTemp('tabs_canvas_zoom_wired');
  final db = FakeVaultDb.v5()
    ..seedNote(id: _planId, title: 'Plan', content: 'old', version: 3)
    ..seedNote(id: _otherId, title: 'Other', content: 'other body', version: 7)
    ..seedCanvas(_canvasId, 'Board', updatedAt: 1)
    ..seedCanvasNode(_canvasId, _planId, x: 0, y: 0);
  final cli = FakeMemexCli()..onUpdateWrites(db);
  final clock = FakeClock();
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(cli),
      clockProvider.overrideWithValue(clock),
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
  return _EditorWired(c, db, cli, clock);
}
