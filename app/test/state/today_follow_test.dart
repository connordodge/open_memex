// WI #271 (N8, Spec #232 R1, R2, R6, TD1): `openToday` is `follow` of today's
// target. A plain call navigates the active tab, a Cmd call focuses the
// leftmost tab showing today or opens one at the end, and `onBeforeLeave` runs
// once when today is not already showing and never when it is. The launch's
// own rule (focus today's tab or insert it first) stays.
//
// The notifier is built directly, with an injected Cmd state, over a temp
// `ui_state.json`. A zero-leave test ends with a real leave that must run
// `onBeforeLeave` once: that control keeps it red until the callback is wired.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';

import '../support/recording_tabs.dart';

const _date = '2026-10-03';
const _todayId = '01J9TODAY00000000000000271';
const _a = NoteTab('01J9NOTEA00000000000000271');
const _b = NoteTab('01J9NOTEB00000000000000271');
const _c = NoteTab('01J9NOTEC00000000000000271');
const _todayNote = NoteTab(_todayId);
const _virtual = VirtualTodayTab(_date);

/// A notifier with its Cmd state, the leaves it ran and the targets it saw.
class _Tabs {
  _Tabs(this.notifier, this.recorder, this.leaves, this.selections);

  final TabsNotifier notifier;
  final TabsRecorder recorder;

  /// The state as each `onBeforeLeave` saw it.
  final List<TabsState> leaves;

  /// Every selection the notifier emitted, since the launch.
  final List<String?> selections;

  bool cmd = false;

  TabsState get state => notifier.state;
  WorkspaceTab? get active => state.activeTab;

  /// `openOrFocus` of each of [tabs], then forgets the calls so far.
  void open(List<WorkspaceTab> tabs, {int? active}) {
    for (final t in tabs) {
      notifier.openOrFocus(t);
    }
    if (active != null) notifier.setActive(active);
    forget();
  }

  void forget() {
    leaves.clear();
    selections.clear();
    recorder.followed.clear();
    recorder.navigated.clear();
  }
}

/// A notifier over a temp `ui_state.json` holding [restored]; with [todayDate]
/// it launches on today as the app does.
Future<_Tabs> _launch({
  List<WorkspaceTab> restored = const [],
  int active = 0,
  String? todayDate,
  String? todayNoteId,
}) async {
  final dir = await Directory.systemTemp.createTemp('today_follow');
  final store = UiStateStore(vaultPath: dir.path);
  if (restored.isNotEmpty) {
    await store.write(
      UiState(
        tabs: [for (final t in restored) t.toPersisted()],
        activeTabIndex: active,
        canvasViewports: const {},
      ),
    );
    await store.flush();
  }
  final leaves = <TabsState>[];
  final selections = <String?>[];
  final recorder = TabsRecorder();
  late final _Tabs tabs;
  final notifier = TabsNotifier(
    store: store,
    onPersistedSelection: selections.add,
    onBeforeLeave: () => leaves.add(tabs.notifier.state),
    todayDate: todayDate,
    todayNoteId: todayNoteId,
    isNewTabModifierPressed: () => tabs.cmd,
    navigationObserver: recorder.observer,
  );
  tabs = _Tabs(notifier, recorder, leaves, selections);
  addTearDown(() async {
    notifier.dispose();
    await store.flush();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  // The launch's selection is emitted in a microtask.
  await Future<void>.delayed(Duration.zero);
  tabs.forget();
  return tabs;
}

/// No leave so far, then a real switch to [to] runs `onBeforeLeave` once: what
/// makes a zero count meaningful.
void _expectNoLeaveThenControl(_Tabs t, WorkspaceTab to) {
  expect(t.leaves, isEmpty, reason: 'this call leaves nothing');
  final index = t.state.tabs.indexOf(to);
  expect(index, isNonNegative);
  expect(index, isNot(t.state.activeIndex));
  t.notifier.setActive(index);
  expect(t.leaves, hasLength(1), reason: 'control: a real switch leaves once');
}

void main() {
  group('a plain openToday navigates the active tab', () {
    test(
      'a plain openToday with a daily note navigates the active tab to it through follow and Back returns',
      () async {
        final t = await _launch();
        t.open([_a, _b], active: 0);

        t.notifier.openToday(date: _date, noteId: _todayId);

        expect(t.recorder.followed, [_todayNote]);
        expect(t.recorder.navigated, [_todayNote]);
        expect(t.state.tabs, [_todayNote, _b], reason: 'no tab was added');
        expect(t.state.activeIndex, 0);
        expect(t.state.canGoBack, isTrue);
        expect(t.selections, [_todayId]);

        t.notifier.back();
        expect(t.state.tabs, [_a, _b]);
        expect(t.state.canGoForward, isTrue);
      },
    );

    test(
      'a plain openToday with no daily note navigates the active tab to a virtual Today note through follow',
      () async {
        final t = await _launch();
        t.open([_a, _b], active: 1);

        t.notifier.openToday(date: _date);

        expect(t.recorder.followed, [_virtual]);
        expect(t.recorder.navigated, [_virtual]);
        expect(t.state.tabs, [_a, _virtual]);
        expect(t.state.activeIndex, 1);
        expect(t.state.canGoBack, isTrue);
        expect(t.selections, [_virtual.id]);

        t.notifier.back();
        expect(t.state.tabs, [_a, _b]);
      },
    );

    test(
      'a plain openToday stays in the active tab when another tab already shows today',
      () async {
        final t = await _launch();
        t.open([_todayNote, _a], active: 1);

        t.notifier.openToday(date: _date, noteId: _todayId);

        expect(t.state.tabs, [_todayNote, _todayNote]);
        expect(t.state.activeIndex, 1, reason: 'two tabs now show today');
        expect(t.state.canGoBack, isTrue);
        t.notifier.setActive(0);
        expect(
          t.state.canGoBack,
          isFalse,
          reason: 'the first tab is untouched',
        );
      },
    );

    test(
      'a plain openToday with no tab open opens the first tab on today',
      () async {
        final t = await _launch();
        expect(t.state.tabs, isEmpty);

        t.notifier.openToday(date: _date, noteId: _todayId);

        expect(t.state.tabs, [_todayNote]);
        expect(t.state.activeIndex, 0);
        expect(t.recorder.followed, [_todayNote]);
      },
    );
  });

  group('a Cmd openToday focuses or opens a tab', () {
    test(
      'a Cmd openToday with today not open opens a tab at the end with a history of only today and leaves every other history alone',
      () async {
        final t = await _launch();
        t.open([_a, _b], active: 1);
        t.notifier.navigate(_c); // [a] [c*] with b behind it.
        t.forget();
        t.cmd = true;

        t.notifier.openToday(date: _date, noteId: _todayId);

        expect(t.recorder.followed, [_todayNote]);
        expect(t.recorder.navigated, isEmpty, reason: 'Cmd does not navigate');
        expect(t.state.tabs, [_a, _c, _todayNote], reason: 'appended last');
        expect(t.state.activeIndex, 2);
        expect(t.state.canGoBack, isFalse, reason: 'only today in its history');
        expect(t.state.canGoForward, isFalse);

        t.notifier.setActive(1);
        expect(t.state.canGoBack, isTrue, reason: 'the left tab kept Back');
        t.notifier.back();
        expect(t.state.tabs, [_a, _b, _todayNote]);
      },
    );

    test(
      'a Cmd openToday with no daily note opens a virtual Today tab at the end',
      () async {
        final t = await _launch();
        t.open([_a, _b], active: 0);
        t.cmd = true;

        t.notifier.openToday(date: _date);

        expect(t.recorder.followed, [_virtual]);
        expect(t.state.tabs, [_a, _b, _virtual]);
        expect(t.state.activeIndex, 2);
        expect(t.state.canGoBack, isFalse);
      },
    );

    test(
      'a Cmd openToday focuses the leftmost tab showing today and leaves its history and every other tab alone',
      () async {
        final t = await _launch();
        t.open([_a, _todayNote, _b], active: 2);
        t.notifier.navigate(_todayNote); // [a] [today] [today*]
        t.notifier.setActive(1);
        t.notifier.navigate(_c);
        t.notifier.back(); // The middle tab: today, with c ahead of it.
        t.notifier.setActive(2);
        t.forget();
        t.cmd = true;

        t.notifier.openToday(date: _date, noteId: _todayId);

        expect(t.recorder.followed, [_todayNote]);
        expect(t.recorder.navigated, isEmpty);
        expect(t.state.tabs, [_a, _todayNote, _todayNote]);
        expect(t.state.activeIndex, 1, reason: 'the leftmost one');
        expect(t.state.canGoBack, isFalse, reason: 'its history is untouched');
        expect(t.state.canGoForward, isTrue);
      },
    );

    test(
      'a Cmd openToday on a tab already showing today does nothing',
      () async {
        final t = await _launch();
        t.open([_a, _todayNote], active: 1);
        t.cmd = true;

        t.notifier.openToday(date: _date, noteId: _todayId);

        expect(t.state.tabs, [_a, _todayNote]);
        expect(t.state.activeIndex, 1);
        _expectNoLeaveThenControl(t, _a);
      },
    );
  });

  group('onBeforeLeave runs once for the Today row', () {
    for (final (name, cmd, open, active, today)
        in <(String, bool, List<WorkspaceTab>, int, String?)>[
          (
            'a plain openToday with today not showing runs onBeforeLeave once before the state changes',
            false,
            [_a, _b],
            0,
            _todayId,
          ),
          (
            'a plain openToday with today showing in another tab runs onBeforeLeave once before the state changes',
            false,
            [_todayNote, _a],
            1,
            _todayId,
          ),
          (
            'a plain openToday of a virtual Today note runs onBeforeLeave once before the state changes',
            false,
            [_a, _b],
            1,
            null,
          ),
          (
            'a Cmd openToday that opens a tab runs onBeforeLeave once before the state changes',
            true,
            [_a, _b],
            0,
            _todayId,
          ),
          (
            'a Cmd openToday that focuses another tab runs onBeforeLeave once before the state changes',
            true,
            [_todayNote, _a],
            1,
            _todayId,
          ),
        ]) {
      test(name, () async {
        final t = await _launch();
        t.open(open, active: active);
        final before = t.state;
        t.cmd = cmd;

        t.notifier.openToday(date: _date, noteId: today);

        expect(t.leaves, hasLength(1), reason: 'exactly one leave');
        expect(t.leaves.single.tabs, before.tabs, reason: 'before the change');
        expect(t.leaves.single.activeIndex, before.activeIndex);
        expect(t.recorder.followed, [today == null ? _virtual : _todayNote]);
      });
    }

    test(
      'a plain openToday with today already showing in the active tab runs onBeforeLeave zero times and adds no history entry',
      () async {
        final t = await _launch();
        t.open([_a, _todayNote], active: 1);
        final before = t.state;

        t.notifier.openToday(date: _date, noteId: _todayId);

        expect(t.state.tabs, before.tabs);
        expect(t.state.activeIndex, before.activeIndex);
        expect(t.state.canGoBack, isFalse, reason: 'no entry was added');
        expect(t.state.canGoForward, isFalse);
        expect(t.recorder.followed, [
          _todayNote,
        ], reason: 'a click, not a leave');
        _expectNoLeaveThenControl(t, _a);
      },
    );

    test(
      'a plain openToday with the virtual Today note already showing in the active tab runs onBeforeLeave zero times and adds no history entry',
      () async {
        final t = await _launch();
        t.open([_a, _virtual], active: 1);

        t.notifier.openToday(date: _date);

        expect(t.state.tabs, [_a, _virtual]);
        expect(t.state.canGoBack, isFalse, reason: 'no entry was added');
        expect(t.recorder.followed, [_virtual], reason: 'a click, not a leave');
        _expectNoLeaveThenControl(t, _a);
      },
    );
  });

  group('the launch keeps its own rule', () {
    test(
      'the launch inserts a real today note first as the active tab ahead of the restored tabs',
      () async {
        final t = await _launch(
          restored: [_a, _b],
          active: 1,
          todayDate: _date,
          todayNoteId: _todayId,
        );
        expect(t.state.tabs, [_todayNote, _a, _b]);
        expect(t.state.activeIndex, 0);
        expect(t.leaves, isEmpty, reason: 'the launch leaves nothing');
        expect(t.recorder.followed, isEmpty, reason: 'it is not a click');
      },
    );

    test(
      'the launch inserts the virtual Today note first when there is no daily note',
      () async {
        final t = await _launch(restored: [_a], todayDate: _date);
        expect(t.state.tabs, [_virtual, _a]);
        expect(t.state.activeIndex, 0);
        expect(t.recorder.followed, isEmpty);
      },
    );

    test(
      'the launch focuses the leftmost restored tab showing today instead of inserting one',
      () async {
        final t = await _launch(
          restored: [_a, _todayNote, _b, _todayNote],
          active: 3,
          todayDate: _date,
          todayNoteId: _todayId,
        );
        expect(t.state.tabs, [_a, _todayNote, _b, _todayNote]);
        expect(t.state.activeIndex, 1);
        expect(t.recorder.followed, isEmpty);
      },
    );

    test('a Cmd openToday appends where the launch inserts first', () async {
      final t = await _launch(
        restored: [_a, _b],
        todayDate: _date,
        todayNoteId: _todayId,
      );
      expect(t.state.tabs, [_todayNote, _a, _b], reason: 'the launch');
      t.notifier.closeAt(0);
      expect(t.state.tabs, [_a, _b]);
      t.cmd = true;

      t.notifier.openToday(date: _date, noteId: _todayId);

      expect(t.state.tabs, [_a, _b, _todayNote], reason: 'the click');
      expect(t.state.activeIndex, 2);
    });
  });

  group('the virtual Today note in several tabs', () {
    test(
      'a virtual Today note followed from a note tab resolves in every tab and every history entry onto the real note',
      () async {
        final t = await _launch();
        t.open([_a, _b], active: 0);
        t.notifier.openToday(date: _date); // [virtual*] [b], a behind it
        t.notifier.setActive(1);
        t.notifier.openToday(date: _date); // [virtual] [virtual*], b behind it
        expect(t.state.tabs, [_virtual, _virtual]);

        t.notifier.resolveVirtualToday(date: _date, noteId: _todayId);

        expect(t.state.tabs, [_todayNote, _todayNote]);
        expect(t.state.activeIndex, 1, reason: 'the active tab stays active');
        expect(t.state.canGoBack, isTrue);
        t.notifier.back();
        expect(t.state.tabs, [_todayNote, _b], reason: 'Back is the note left');
        t.notifier.setActive(0);
        t.notifier.back();
        expect(t.state.tabs, [_a, _b]);
        t.notifier.forward();
        expect(t.state.tabs, [
          _todayNote,
          _b,
        ], reason: 'Forward is the real note, not the virtual one');
      },
    );

    test(
      'a virtual Today note followed from a note tab does not close a tab that has other history when the real note is open elsewhere',
      () async {
        final t = await _launch();
        t.open([_todayNote, _a], active: 1);
        t.notifier.openToday(date: _date); // [today] [virtual*], a behind it

        t.notifier.resolveVirtualToday(date: _date, noteId: _todayId);

        expect(t.state.tabs, [_todayNote, _todayNote]);
        expect(t.state.activeIndex, 1);
        t.notifier.back();
        expect(t.state.tabs, [_todayNote, _a]);
      },
    );
  });
}
