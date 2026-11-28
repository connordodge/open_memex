// WI #70 (54-O4, Spec #58 R14, R24, R25, R27-R30, R38; TD7, TD8; TS5, TS6):
// shared helpers for the Outline keyboard tests (`outline_keys_test.dart`,
// `outline_keyboard_test.dart`) and the robot journey
// (`journeys/outline_journey_test.dart`). Built on the shared reveal pump
// (#66, D5): the whole workspace over the fakes, geometry from the editor's
// own line boxes (`lineTopOf`), never from constants.
//
// Never pumpAndSettle the workspace (OmDot pulses forever): pumpFrames only.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/outline.dart';
import 'package:open_memex_app/src/state/right_panel_tab.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/outline/outline_row.dart';
import 'package:open_memex_app/src/widgets/outline/outline_tab.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';

import 'fake_vault_db.dart';
import 'note_reveal_pump.dart';

export 'note_reveal_pump.dart';

// ------------------------------------------------------------------- notes

/// A note of [wi70KeysCount] `## Section <k>` headings, each followed by 12
/// plain lines and a blank line, after 40 intro lines (so no entry is
/// current at the top of the page) and before 120 tail lines (so the last
/// heading can reach the top of the page).
const wi70KeysId = 'wi70-keys';
const wi70KeysCount = 14;

/// A note of [wi70TallCount] headings, three plain lines apart: its Outline
/// is taller than the panel.
const wi70TallId = 'wi70-tall';
const wi70TallCount = 120;

/// A long note with no headings.
const wi70FlatId = 'wi70-flat';

String _lines(String tag, int n) =>
    [for (var i = 0; i < n; i++) '$tag line $i\n'].join();

String get wi70KeysBody =>
    '${_lines('intro', 40)}\n'
    '${[for (var k = 0; k < wi70KeysCount; k++) '## Section $k\n${_lines('s$k', 12)}\n'].join()}'
    '${_lines('tail', 120)}';

String get wi70TallBody =>
    '${_lines('top', 6)}\n'
    '${[for (var k = 0; k < wi70TallCount; k++) '## Tall $k\n${_lines('t$k', 3)}\n'].join()}'
    '${_lines('end', 120)}';

String get wi70FlatBody => _lines('flat', 300);

/// Seeds the reveal pump's notes plus [wi70KeysId], [wi70TallId] and
/// [wi70FlatId].
FakeVaultDb seedWi70Notes(FakeVaultDb db) {
  seedRevealNotes(db);
  db.seedNote(id: wi70KeysId, title: 'Keys', content: wi70KeysBody);
  db.seedNote(id: wi70TallId, title: 'Tall', content: wi70TallBody);
  db.seedNote(id: wi70FlatId, title: 'Flat', content: wi70FlatBody);
  return db;
}

/// The workspace on the WI #70 notes with [open] shown, the right panel
/// [panelOpen] on [tab].
Future<NoteRevealHarness> pumpWi70(
  WidgetTester tester, {
  String? open = wi70KeysId,
  bool panelOpen = true,
  RightPanelTab tab = RightPanelTab.connections,
}) async {
  final h = await pumpNoteReveal(
    tester,
    db: seedWi70Notes(FakeVaultDb.v5()),
    open: open,
  );
  h.container.read(rightPanelOpenProvider.notifier).state = panelOpen;
  h.container.read(rightPanelTabProvider.notifier).state = tab;
  await pumpFrames(tester);
  return h;
}

// ------------------------------------------------------------- the entries

/// The Outline entries of the live text the editor shows.
List<OutlineEntry> wi70Entries(NoteRevealHarness h) =>
    outlineEntries(h.shownContent(), role: h.body().note.role);

/// The heading line top of [entry], relative to the editor viewport top.
double wi70FromTop(NoteRevealHarness h, OutlineEntry entry) =>
    h.lineTopOf(entry.segment, entry.local) - h.viewport().top;

/// The index of the entry the line boxes say is current: the last whose
/// heading line top is at or above the viewport top + 16; null above the
/// first heading.
int? wi70ExpectedCurrent(NoteRevealHarness h) {
  int? current;
  final entries = wi70Entries(h);
  for (var i = 0; i < entries.length; i++) {
    if (wi70FromTop(h, entries[i]) <= 16 + 1e-6) current = i;
  }
  return current;
}

/// Scrolls the editor so entry [index]'s heading line sits 4 px below the
/// viewport top (it is then the current section), checks it, and pumps.
Future<void> wi70PutCurrent(NoteRevealHarness h, int index) async {
  final entry = wi70Entries(h)[index];
  await h.scrollContent(
    h.lineTopOf(entry.segment, entry.local),
    h.viewport().top + 4,
  );
  await pumpFrames(h.tester);
  expect(
    wi70ExpectedCurrent(h),
    index,
    reason: 'fixture: entry $index is the current section',
  );
}

// ------------------------------------------------------------- the Outline

/// Outline row [i] (Key `outline-entry-<i>`).
Finder wi70Row(int i) => find.byKey(Key('outline-entry-$i'));

/// The Outline list (Key `outline-list`).
Finder get wi70List => find.byKey(const Key('outline-list'));

int _rowIndex(Element e) {
  final key = e.widget.key;
  if (key is ValueKey<String> && key.value.startsWith('outline-entry-')) {
    return int.parse(key.value.substring('outline-entry-'.length));
  }
  throw TestFailure('an OutlineRow without an outline-entry key: $key');
}

/// The built Outline rows drawn with the focus ring, by index.
List<int> wi70FocusedRows(WidgetTester tester) => [
  for (final e in find.byType(OutlineRow).evaluate())
    if ((e.widget as OutlineRow).focused) _rowIndex(e),
]..sort();

/// The built Outline rows drawn as the current section, by index.
List<int> wi70CurrentRows(WidgetTester tester) => [
  for (final e in find.byType(OutlineRow).evaluate())
    if ((e.widget as OutlineRow).current) _rowIndex(e),
]..sort();

/// Whether [context] is [ancestor]'s element or below it.
bool _within(BuildContext? context, bool Function(Widget) ancestor) {
  if (context == null) return false;
  if (ancestor(context.widget)) return true;
  var found = false;
  context.visitAncestorElements((e) {
    found = ancestor(e.widget);
    return !found;
  });
  return found;
}

/// Whether keyboard focus is in the Outline tab.
bool wi70FocusInOutline() => _within(
  FocusManager.instance.primaryFocus?.context,
  (w) => w is OutlineTab,
);

/// Whether keyboard focus is at or below the widget [finder] finds.
bool wi70FocusWithin(WidgetTester tester, Finder finder) {
  final targets = finder.evaluate().map((e) => e.widget).toSet();
  if (targets.isEmpty) return false;
  return _within(FocusManager.instance.primaryFocus?.context, targets.contains);
}

/// Keyboard focus is in the Outline and the focus ring is on row [i] only.
void wi70ExpectOutlineFocus(WidgetTester tester, int i, {String? reason}) {
  expect(
    wi70FocusInOutline(),
    isTrue,
    reason:
        '${reason ?? ''}: keyboard focus is in the Outline '
        '(primary focus: ${FocusManager.instance.primaryFocus})',
  );
  expect(wi70FocusedRows(tester), [
    i,
  ], reason: '${reason ?? ''}: the focus ring is on row $i only');
}

/// The Outline list's scroll position.
ScrollPosition wi70ListPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(of: wi70List, matching: find.byType(Scrollable)).first,
    )
    .position;

/// The Outline list's visible rect (global).
Rect wi70ListRect(WidgetTester tester) => tester.getRect(wi70List);

/// Taps the outline chip and pumps.
Future<void> wi70ShowOutline(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('outline-tab-chip')));
  await pumpFrames(tester);
}

// ---------------------------------------------------------------- the keys

const wi70Meta = LogicalKeyboardKey.metaLeft;
const wi70Shift = LogicalKeyboardKey.shiftLeft;
const wi70Ctrl = LogicalKeyboardKey.controlLeft;
const wi70Alt = LogicalKeyboardKey.altLeft;

/// Presses [key] with [mods] held, releases them, pumps frames and returns
/// whether the key down was handled.
Future<bool> wi70Chord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  List<LogicalKeyboardKey> mods = const [wi70Meta, wi70Shift],
}) async {
  for (final m in mods) {
    await tester.sendKeyDownEvent(m, platform: 'macos');
  }
  final handled = await tester.sendKeyEvent(key, platform: 'macos');
  for (final m in mods.reversed) {
    await tester.sendKeyUpEvent(m, platform: 'macos');
  }
  await pumpFrames(tester);
  return handled;
}

/// Cmd+Shift+O.
Future<bool> wi70OutlineChord(WidgetTester tester) =>
    wi70Chord(tester, LogicalKeyboardKey.keyO);

/// Presses and releases [key] with no modifier [times] times, then pumps
/// frames.
Future<void> wi70Press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  int times = 1,
}) async {
  for (var i = 0; i < times; i++) {
    await tester.sendKeyEvent(key, platform: 'macos');
    await tester.pump();
  }
  await pumpFrames(tester);
}

/// Drops keyboard focus.
void wi70Unfocus() => FocusManager.instance.primaryFocus?.unfocus();

/// Gives keyboard focus to the sidebar's manage vaults button (Key
/// `sidebar-vaults-manage`) and checks it.
Future<void> wi70FocusSidebar(WidgetTester tester) async {
  final button = find.byKey(const Key('sidebar-vaults-manage'));
  FocusNode? node;
  for (final e
      in find.descendant(of: button, matching: find.byType(Focus)).evaluate()) {
    e.visitChildElements((c) {
      final n = Focus.maybeOf(c, createDependency: false);
      if (node == null && n != null && n.canRequestFocus) node = n;
    });
  }
  node?.requestFocus();
  await tester.pump();
  expect(
    wi70FocusWithin(tester, find.byType(Sidebar)),
    isTrue,
    reason:
        'fixture: keyboard focus is in the sidebar ($node, primary '
        '${FocusManager.instance.primaryFocus})',
  );
}
