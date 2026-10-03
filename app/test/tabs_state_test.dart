import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';

void main() {
  late Directory tmp;
  late UiStateStore store;
  late TabsNotifier notifier;
  late List<String?> selectionLog;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tabs_state_test');
    store = UiStateStore(vaultPath: tmp.path);
    selectionLog = [];
    notifier = TabsNotifier(
      store: store,
      onPersistedSelection: selectionLog.add,
    );
  });

  tearDown(() async {
    notifier.dispose();
    // The notifier persists with unawaited writes; drain them before the temp
    // dir is deleted (otherwise deleteSync races the tmp+rename).
    await store.flush();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('opening a NoteTab adds it and emits the note id selection', () {
    notifier.openOrFocus(const NoteTab('alpha'));
    expect(notifier.state.tabs, [const NoteTab('alpha')]);
    expect(notifier.state.activeIndex, 0);
    expect(selectionLog.last, 'alpha');
  });

  test('opening an already-open tab switches to it without duplicating', () {
    notifier.openOrFocus(const NoteTab('alpha'));
    notifier.openOrFocus(const NoteTab('beta'));
    expect(notifier.state.tabs.length, 2);
    notifier.openOrFocus(const NoteTab('alpha'));
    expect(notifier.state.tabs.length, 2);
    expect(notifier.state.activeIndex, 0);
    expect(selectionLog.last, 'alpha');
  });

  test('closing active tab activates the previous one', () {
    notifier.openOrFocus(const NoteTab('a'));
    notifier.openOrFocus(const NoteTab('b'));
    notifier.openOrFocus(const NoteTab('c'));
    expect(notifier.state.activeIndex, 2);
    notifier.close(const NoteTab('c'));
    expect(notifier.state.activeIndex, 1);
    expect(selectionLog.last, 'b');
  });

  test('closing the only tab returns to empty state', () {
    notifier.openOrFocus(const NoteTab('alone'));
    notifier.close(const NoteTab('alone'));
    expect(notifier.state.tabs, isEmpty);
    expect(selectionLog.last, isNull);
  });

  test('canvas tab emission clears the note selection', () {
    notifier.openOrFocus(const NoteTab('note'));
    notifier.openOrFocus(const CanvasTab('canvas'));
    expect(selectionLog.last, isNull);
  });

  test('LRU eviction kicks in past kMaxOpenTabs', () {
    for (var i = 0; i < kMaxOpenTabs; i++) {
      notifier.openOrFocus(NoteTab('n$i'));
    }
    expect(notifier.state.tabs.length, kMaxOpenTabs);
    notifier.openOrFocus(const NoteTab('overflow'));
    expect(notifier.state.tabs.length, kMaxOpenTabs);
    // The newest tab is active.
    expect(notifier.state.activeTab, const NoteTab('overflow'));
    // The very first opened tab (least recently used) was evicted.
    expect(notifier.state.tabs.contains(const NoteTab('n0')), isFalse);
  });

  test('persists across restart via the store', () async {
    notifier.openOrFocus(const NoteTab('n1'));
    notifier.openOrFocus(const CanvasTab('c1'));
    // Wait for the fire-and-forget writes to complete.
    await store.flush();

    // Build a fresh notifier with the same store.
    final secondLog = <String?>[];
    final reborn = TabsNotifier(
      store: store,
      onPersistedSelection: secondLog.add,
    );
    expect(reborn.state.tabs, [const NoteTab('n1'), const CanvasTab('c1')]);
    expect(reborn.state.activeIndex, 1);
    reborn.dispose();
  });
}
