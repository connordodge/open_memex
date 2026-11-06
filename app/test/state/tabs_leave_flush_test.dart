// WI #264 (N1, ruling D9): `TabsNotifier.onBeforeLeave` runs exactly once,
// before the state changes, on every call that changes which tab is active or
// removes the active tab, and never on any other call or at launch. Wired in
// `tabsProvider` to `EditorController.flushPendingSave`, so leaving a note
// never drops an edit typed inside the save debounce.
//
// A zero-call test proves nothing against a callback nobody calls, so every
// one of them ends with a real leave that must run it once: that control is
// what makes it red until the notifier calls the callback.
//
// Time is a FakeClock (the debounce fires only when a test advances it).
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/today_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/today_cli_fakes.dart';

const _today = '2026-10-03';
const _a = NoteTab('01J9AAAAAAAAAAAAAAAAAAAAAA');
const _b = NoteTab('01J9BBBBBBBBBBBBBBBBBBBBBB');
const _c = CanvasTab('01J9CCCCCCCCCCCCCCCCCCCCCC');
const _closedTab = NoteTab('01J9DDDDDDDDDDDDDDDDDDDDDD');
const _todayNote = NoteTab('01J9TTTTTTTTTTTTTTTTTTTTTT');
const _virtual = VirtualTodayTab(_today);

/// A notifier over a temp `ui_state.json`, with a probe on its callbacks.
class _Tabs {
  _Tabs(this.notifier, this.events, this.seen, this.launchEvents);

  final TabsNotifier notifier;

  /// `leave` and `select:<id>` in the order the notifier called them, since
  /// the launch finished.
  final List<String> events;

  /// The notifier's state as each `onBeforeLeave` saw it.
  final List<TabsState> seen;

  /// [events] as the launch left them, the launch's selection included.
  final List<String> launchEvents;

  TabsState get state => notifier.state;
  int get leaves => events.where((e) => e == 'leave').length;
}

Future<_Tabs> _launch(
  List<WorkspaceTab> open, {
  int active = 0,
  String? todayDate,
  String? todayNoteId,
}) async {
  final dir = await Directory.systemTemp.createTemp('tabs_leave_flush');
  final store = UiStateStore(vaultPath: dir.path);
  if (open.isNotEmpty) {
    await store.write(
      UiState(
        tabs: [for (final t in open) t.toPersisted()],
        activeTabIndex: active,
        canvasViewports: const {},
      ),
    );
    await store.flush();
  }
  final events = <String>[];
  final seen = <TabsState>[];
  TabsNotifier? built;
  final notifier = TabsNotifier(
    store: store,
    onPersistedSelection: (id) => events.add('select:$id'),
    onBeforeLeave: () {
      events.add('leave');
      final s = built?.state;
      if (s != null) seen.add(s);
    },
    todayDate: todayDate,
    todayNoteId: todayNoteId,
  );
  built = notifier;
  addTearDown(() async {
    notifier.dispose();
    await store.flush();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  // The launch's selection is emitted in a microtask.
  await Future<void>.delayed(Duration.zero);
  final launchEvents = [...events];
  events.clear();
  return _Tabs(notifier, events, seen, launchEvents);
}

/// `onBeforeLeave` ran once, on [before], ahead of the selection, and the tab
/// is now [active].
void _expectLeftOnce(_Tabs t, TabsState before, WorkspaceTab? active) {
  expect(t.leaves, 1, reason: 'onBeforeLeave runs exactly once');
  expect(t.events.first, 'leave', reason: 'it runs before the selection moves');
  final seen = t.seen.single;
  expect(seen.tabs, before.tabs, reason: 'it runs before the tabs change');
  expect(
    seen.activeIndex,
    before.activeIndex,
    reason: 'it runs before the active tab changes',
  );
  expect(t.state.activeTab, active);
}

/// No `onBeforeLeave` so far, then a real leave runs it once. [switchTo] is an
/// open tab other than the active one.
void _expectNoLeaveThenControl(_Tabs t, WorkspaceTab switchTo) {
  expect(t.leaves, 0, reason: 'this call leaves nothing');
  final index = t.state.tabs.indexOf(switchTo);
  expect(index, isNonNegative);
  expect(index, isNot(t.state.activeIndex));
  t.notifier.setActive(index);
  expect(t.leaves, 1, reason: 'control: a real switch runs onBeforeLeave');
}

// ------------------------------------------------- real editor behind the tabs

const _planId = '01J9PLAN000000000000000264';
const _otherId = '01J9OTHER00000000000000264';

/// The real `tabsProvider` and `editorControllerProvider` over a FakeVaultDb, a
/// FakeMemexCli and a FakeClock. No widget tree: nothing hydrates the editor
/// unless a test calls `loadNote`.
class _Wired {
  _Wired(this.c, this.db, this.cli, this.clock);

  final ProviderContainer c;
  final FakeVaultDb db;
  final FakeMemexCli cli;
  final FakeClock clock;

  TabsNotifier get tabs => c.read(tabsProvider.notifier);
  TabsState get tabState => c.read(tabsProvider);
  EditorController get ctrl => c.read(editorControllerProvider.notifier);
  List<FakeCliCall> get updates => cli.callsFor('update');
  List<FakeCliCall> get adds => cli.callsFor('add');

  /// Shows note [id] the way the app does: its tab, then the editor loads it.
  void open(String id) {
    tabs.openOrFocus(NoteTab(id));
    ctrl.loadNote(db.getNote(id)!);
  }

  /// Lets the debounce fire, then every write and read finish.
  Future<void> fireDebounce() async {
    clock.advance(saveDebounce);
    await pumpEventQueue();
  }
}

Future<_Wired> _wired({Completer<void>? addGate}) async {
  final dir = await Directory.systemTemp.createTemp('tabs_leave_wired');
  final db = FakeVaultDb.v5()
    ..seedNote(id: _planId, title: 'Plan', content: 'old', version: 3)
    ..seedNote(id: _otherId, title: 'Other', content: 'other body', version: 7);
  final cli = FakeMemexCli()
    ..onUpdateWrites(db)
    ..onAddDailyCreates(db, gate: addGate);
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
  return _Wired(c, db, cli, clock);
}

/// The one save sent so far is note [id]'s [text] on [version].
void _expectOneSave(_Wired w, String id, String text, int version) {
  expect(w.updates, hasLength(1), reason: 'exactly one save was sent');
  final call = w.updates.single;
  expect(call.flag('note-id'), id);
  expect(call.flag('expected-version'), '$version');
  expect(call.stdinBody, text);
}

void main() {
  group('onBeforeLeave runs once before the state changes (AC1)', () {
    test(
      'openOrFocus of another open tab runs onBeforeLeave once before the state changes',
      () async {
        final t = await _launch([_a, _b, _c]);
        final before = t.state;

        t.notifier.openOrFocus(_b);

        _expectLeftOnce(t, before, _b);
        expect(t.events, ['leave', 'select:${_b.id}']);
      },
    );

    test(
      'openOrFocus of a tab not open runs onBeforeLeave once before the state changes',
      () async {
        final t = await _launch([_a, _b]);
        final before = t.state;

        t.notifier.openOrFocus(_closedTab);

        _expectLeftOnce(t, before, _closedTab);
        expect(t.events, ['leave', 'select:${_closedTab.id}']);
      },
    );

    test(
      'setActive of another tab runs onBeforeLeave once before the state changes',
      () async {
        final t = await _launch([_a, _b, _c]);
        final before = t.state;

        t.notifier.setActive(1);

        _expectLeftOnce(t, before, _b);
        expect(t.events, ['leave', 'select:${_b.id}']);
      },
    );

    test(
      'close of the active tab runs onBeforeLeave once before the state changes',
      () async {
        final t = await _launch([_a, _b, _c], active: 1);
        final before = t.state;

        t.notifier.close(_b);

        _expectLeftOnce(t, before, _a);
        expect(t.events, ['leave', 'select:${_a.id}']);
      },
    );

    test(
      'close of the only open tab runs onBeforeLeave once before the tabs empty',
      () async {
        final t = await _launch([_a]);
        final before = t.state;

        t.notifier.close(_a);

        _expectLeftOnce(t, before, null);
        expect(t.events, ['leave', 'select:null']);
      },
    );

    test(
      'openToday with the today note open but not active runs onBeforeLeave once before the state changes',
      () async {
        final t = await _launch([_a, _todayNote]);
        final before = t.state;

        t.notifier.openToday(date: _today, noteId: _todayNote.id);

        _expectLeftOnce(t, before, _todayNote);
        expect(t.events, ['leave', 'select:${_todayNote.id}']);
      },
    );

    test(
      'openToday with the today note not open runs onBeforeLeave once before the state changes',
      () async {
        final t = await _launch([_a, _b]);
        final before = t.state;

        t.notifier.openToday(date: _today, noteId: _todayNote.id);

        _expectLeftOnce(t, before, _todayNote);
        expect(t.events, ['leave', 'select:${_todayNote.id}']);
      },
    );

    test(
      'openToday with the virtual Today tab open but not active runs onBeforeLeave once before the state changes',
      () async {
        final t = await _launch([_a], todayDate: _today);
        t.notifier.setActive(1);
        t.events.clear();
        t.seen.clear();
        final before = t.state;

        t.notifier.openToday(date: _today);

        _expectLeftOnce(t, before, _virtual);
        expect(t.events, ['leave', 'select:${_virtual.id}']);
      },
    );

    test(
      'openToday with no daily note and no Today tab runs onBeforeLeave once before the state changes',
      () async {
        final t = await _launch([_a, _b]);
        final before = t.state;

        t.notifier.openToday(date: _today);

        _expectLeftOnce(t, before, _virtual);
        expect(t.events, ['leave', 'select:${_virtual.id}']);
      },
    );
  });

  group('onBeforeLeave does not run when nothing is left (AC2)', () {
    test(
      'setActive of the current index runs onBeforeLeave zero times and a real switch after it runs it once',
      () async {
        final t = await _launch([_a, _b], active: 1);

        t.notifier.setActive(1);

        _expectNoLeaveThenControl(t, _a);
      },
    );

    test(
      'openOrFocus of the active tab runs onBeforeLeave zero times and a real switch after it runs it once',
      () async {
        final t = await _launch([_a, _b]);

        t.notifier.openOrFocus(_a);

        _expectNoLeaveThenControl(t, _b);
      },
    );

    test(
      'openToday when the today note is the active tab runs onBeforeLeave zero times and a real switch after it runs it once',
      () async {
        final t = await _launch([_todayNote, _a]);

        t.notifier.openToday(date: _today, noteId: _todayNote.id);

        _expectNoLeaveThenControl(t, _a);
      },
    );

    test(
      'openToday when the virtual Today tab is the active tab runs onBeforeLeave zero times and a real switch after it runs it once',
      () async {
        final t = await _launch([_a], todayDate: _today);
        expect(t.state.activeTab, _virtual);

        t.notifier.openToday(date: _today);

        _expectNoLeaveThenControl(t, _a);
      },
    );

    test(
      'close of a tab before the active tab runs onBeforeLeave zero times and a real switch after it runs it once',
      () async {
        final t = await _launch([_a, _b, _c], active: 1);

        t.notifier.close(_a);

        expect(t.state.activeTab, _b);
        _expectNoLeaveThenControl(t, _c);
      },
    );

    test(
      'close of a tab after the active tab runs onBeforeLeave zero times and a real switch after it runs it once',
      () async {
        final t = await _launch([_a, _b, _c], active: 1);

        t.notifier.close(_c);

        expect(t.state.activeTab, _b);
        _expectNoLeaveThenControl(t, _a);
      },
    );

    test(
      'close of a tab that is not open runs onBeforeLeave zero times and a real switch after it runs it once',
      () async {
        final t = await _launch([_a, _b]);

        t.notifier.close(_closedTab);

        _expectNoLeaveThenControl(t, _b);
      },
    );

    test(
      'setActive with an out of range index runs onBeforeLeave zero times and a real switch after it runs it once',
      () async {
        final t = await _launch([_a, _b]);

        t.notifier.setActive(-1);
        t.notifier.setActive(2);
        t.notifier.setActive(99);

        expect(t.state.activeTab, _a);
        _expectNoLeaveThenControl(t, _b);
      },
    );

    test(
      'resolveVirtualToday of the active virtual tab runs onBeforeLeave zero times and a real switch after it runs it once',
      () async {
        final t = await _launch([_a], todayDate: _today);

        t.notifier.resolveVirtualToday(date: _today, noteId: _todayNote.id);

        expect(t.state.activeTab, _todayNote);
        _expectNoLeaveThenControl(t, _a);
      },
    );

    test(
      'resolveVirtualToday of an active virtual tab whose note is already open runs onBeforeLeave zero times and a real switch after it runs it once',
      () async {
        final t = await _launch([_a, _todayNote], todayDate: _today);

        t.notifier.resolveVirtualToday(date: _today, noteId: _todayNote.id);

        expect(t.state.tabs, [_a, _todayNote]);
        expect(t.state.activeTab, _todayNote);
        _expectNoLeaveThenControl(t, _a);
      },
    );

    test(
      'resolveVirtualToday while another tab is active runs onBeforeLeave zero times and a real switch after it runs it once',
      () async {
        final t = await _launch([_a, _b], todayDate: _today);
        t.notifier.setActive(1);
        t.events.clear();
        t.seen.clear();

        t.notifier.resolveVirtualToday(date: _today, noteId: _todayNote.id);

        expect(t.state.activeTab, _a);
        _expectNoLeaveThenControl(t, _b);
      },
    );
  });

  group('the launch leaves nothing (AC3)', () {
    test(
      'constructing the notifier over restored tabs runs onBeforeLeave zero times and a real switch after it runs it once',
      () async {
        final t = await _launch([_a, _b], active: 1);

        expect(t.launchEvents, ['select:${_b.id}']);
        _expectNoLeaveThenControl(t, _a);
      },
    );

    test(
      'the launch inserting the today note first runs onBeforeLeave zero times and a real switch after it runs it once',
      () async {
        final t = await _launch(
          [_a, _b],
          active: 1,
          todayDate: _today,
          todayNoteId: _todayNote.id,
        );

        expect(t.state.tabs, [_todayNote, _a, _b]);
        expect(t.launchEvents, ['select:${_todayNote.id}']);
        _expectNoLeaveThenControl(t, _a);
      },
    );

    test(
      'the launch focusing the restored today note runs onBeforeLeave zero times and a real switch after it runs it once',
      () async {
        final t = await _launch(
          [_a, _todayNote],
          todayDate: _today,
          todayNoteId: _todayNote.id,
        );

        expect(t.state.activeTab, _todayNote);
        expect(t.launchEvents, ['select:${_todayNote.id}']);
        _expectNoLeaveThenControl(t, _a);
      },
    );

    test(
      'the launch inserting a virtual Today tab runs onBeforeLeave zero times and a real switch after it runs it once',
      () async {
        final t = await _launch([_a], todayDate: _today);

        expect(t.state.activeTab, _virtual);
        expect(t.launchEvents, ['select:${_virtual.id}']);
        _expectNoLeaveThenControl(t, _a);
      },
    );
  });

  group('what the wired flush saves', () {
    test(
      'a title edit typed before leaving is saved with the clock not advanced',
      () async {
        final w = await _wired();
        w.open(_otherId);
        w.open(_planId);

        w.ctrl.onTitleChanged('Plan B');
        w.tabs.openOrFocus(const NoteTab(_otherId));
        await pumpEventQueue();

        _expectOneSave(w, _planId, 'old', 3);
        expect(w.updates.single.flag('title'), 'Plan B');
      },
    );
  });

  group('leaving the virtual Today note (AC6)', () {
    void typeInVirtualToday(_Wired w, String text) {
      w.ctrl.loadNote(virtualTodayNote(_today));
      w.ctrl.onContentChanged(text);
    }

    test(
      'leaving the virtual Today note with an edit pending sends exactly one create',
      () async {
        final w = await _wired();
        expect(w.tabState.activeTab, _virtual);
        typeInVirtualToday(w, 'Morning pages');

        w.tabs.openOrFocus(const NoteTab(_otherId));
        await pumpEventQueue();

        expect(
          w.adds,
          hasLength(1),
          reason: 'the leave itself sent the create',
        );
        expect(w.adds.single.flag('title'), _today);
        expect(w.adds.single.flag('role'), 'daily');
        expect(w.adds.single.stdinBody, 'Morning pages');

        // The editor then hydrates the other note, and the debounce never
        // comes back.
        w.ctrl.loadNote(w.db.getNote(_otherId)!);
        await pumpEventQueue();
        await w.fireDebounce();

        expect(w.adds, hasLength(1));
        expect(w.updates, isEmpty);
        expect(
          splitDailyBody(
            w.db.getNote(createdDailyId)!.contentMd,
          ).person.trimRight(),
          'Morning pages',
        );
      },
    );

    test(
      'the editor loading the next note while the leave create is in flight sends no second create',
      () async {
        final gate = Completer<void>();
        final w = await _wired(addGate: gate);
        typeInVirtualToday(w, 'Morning pages');

        w.tabs.openOrFocus(const NoteTab(_otherId));
        await pumpEventQueue();
        expect(
          w.adds,
          hasLength(1),
          reason: 'the leave itself sent the create',
        );

        w.ctrl.loadNote(w.db.getNote(_otherId)!);
        await pumpEventQueue();
        gate.complete();
        await pumpEventQueue();
        await w.fireDebounce();

        expect(w.adds, hasLength(1));
        expect(w.updates, isEmpty);
        expect(w.tabState.activeTab, const NoteTab(_otherId));
        expect(w.tabState.tabs, contains(const NoteTab(createdDailyId)));
        expect(
          w.c.read(editorControllerProvider).contentMd,
          'other body',
          reason: 'the note on screen is untouched',
        );
      },
    );

    test(
      'a virtual Today note with no pending edit sends no create when left and an edit left after it sends one',
      () async {
        final w = await _wired();
        w.ctrl.loadNote(virtualTodayNote(_today));

        w.tabs.openOrFocus(const NoteTab(_otherId));
        w.ctrl.loadNote(w.db.getNote(_otherId)!);
        await pumpEventQueue();
        await w.fireDebounce();
        expect(w.adds, isEmpty);

        w.tabs.openToday(date: _today);
        typeInVirtualToday(w, 'Morning pages');
        w.tabs.setActive(w.tabState.tabs.indexOf(const NoteTab(_otherId)));
        await pumpEventQueue();
        expect(w.adds, hasLength(1), reason: 'control');
      },
    );
  });

  group('no pending edit, no save (AC7)', () {
    for (final (name, leave) in <(String, void Function(_Wired))>[
      (
        'a note with no pending edit sends no save when openOrFocus leaves it and an edit left the same way sends one',
        (w) => w.tabs.openOrFocus(const NoteTab(_otherId)),
      ),
      (
        'a note with no pending edit sends no save when setActive leaves it and an edit left the same way sends one',
        (w) =>
            w.tabs.setActive(w.tabState.tabs.indexOf(const NoteTab(_otherId))),
      ),
      (
        'a note with no pending edit sends no save when close leaves it and an edit left the same way sends one',
        (w) => w.tabs.close(const NoteTab(_planId)),
      ),
      (
        'a note with no pending edit sends no save when openToday leaves it and an edit left the same way sends one',
        (w) => w.tabs.openToday(date: _today),
      ),
    ]) {
      test(name, () async {
        final w = await _wired();
        w.open(_otherId);
        w.open(_planId);

        leave(w);
        await pumpEventQueue();
        await w.fireDebounce();

        expect(w.updates, isEmpty);
        expect(w.adds, isEmpty);

        w.open(_planId);
        w.ctrl.onContentChanged('new text');
        leave(w);
        await pumpEventQueue();

        _expectOneSave(w, _planId, 'new text', 3);
      });
    }

    test(
      'a note whose edit already saved sends no second save when left and a later edit left the same way sends one',
      () async {
        final w = await _wired();
        w.open(_otherId);
        w.open(_planId);
        w.ctrl.onContentChanged('new text');
        await w.fireDebounce();
        _expectOneSave(w, _planId, 'new text', 3);

        w.tabs.openOrFocus(const NoteTab(_otherId));
        await pumpEventQueue();
        await w.fireDebounce();
        expect(w.updates, hasLength(1));

        w.open(_planId);
        w.ctrl.onContentChanged('newer text');
        w.tabs.openOrFocus(const NoteTab(_otherId));
        await pumpEventQueue();

        expect(w.updates, hasLength(2), reason: 'control');
        expect(w.updates.last.flag('expected-version'), '4');
        expect(w.updates.last.stdinBody, 'newer text');
      },
    );

    test(
      'a flush right before leaving sends one save and the leave adds none and a later edit left the same way sends one',
      () async {
        final w = await _wired();
        w.open(_otherId);
        w.open(_planId);
        w.ctrl.onContentChanged('new text');

        // What LinkRegion does until #269: flush, then open the target.
        w.ctrl.flushPendingSave();
        w.tabs.openOrFocus(const NoteTab(_otherId));
        await pumpEventQueue();
        await w.fireDebounce();
        _expectOneSave(w, _planId, 'new text', 3);

        w.open(_planId);
        w.ctrl.onContentChanged('newer text');
        w.tabs.openOrFocus(const NoteTab(_otherId));
        await pumpEventQueue();

        expect(w.updates, hasLength(2), reason: 'control');
      },
    );
  });
}
