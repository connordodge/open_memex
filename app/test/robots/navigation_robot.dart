// WI #271 (N8): the robot for the navigation history journey (Spec #232).
// It drives the real workspace the way a person does, by Key: the Back and
// Forward buttons (`nav-back-button`, `nav-forward-button`), a mouse press on a
// rendered wikilink, the footer topic chips (`footer-chip-<id>`), graph nodes
// (`graph-node-<id>`), canvas node cards (`canvas-node-<id>`), the right panel
// links (`outgoing-link-<id>`, `backlink-item-<from>-<id>`) and the note menu
// (`note-menu-button`, `note-menu-open-graph`, `note-menu-delete`,
// `delete-note-confirm`).
//
// Real mouse presses only: the editor ignores a press whose kind is not
// `PointerDeviceKind.mouse`, so `tester.tap` would not follow a wikilink. Run
// the editor clicks under `macOnly` (`mac_editing.dart`), where Cmd is the
// real `LogicalKeyboardKey.metaLeft`.
//
// Never pumpAndSettle the workspace (OmDot pulses forever): pumpFrames only.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';

import '../support/app_harness.dart';
import '../support/mac_editing.dart';
import '../support/segment_editing_finder.dart';

/// A pause longer than `kDoubleTapTimeout`, so two clicks at one spot are two
/// single clicks.
const navDoubleTapGap = Duration(milliseconds: 400);

class NavigationRobot {
  NavigationRobot(this.tester, this.h);

  final WidgetTester tester;
  final WorkspaceHarness h;

  // ---------------------------------------------------------------- finders

  Finder get todayRow => find.byKey(const Key('days-row-today'));
  Finder get backButton => find.byKey(const Key('nav-back-button'));
  Finder get forwardButton => find.byKey(const Key('nav-forward-button'));
  Finder chip(WorkspaceTab tab) => find.byKey(Key('tab-${tab.tabId}'));
  Finder footerChip(String topicNoteId) =>
      find.byKey(Key('footer-chip-$topicNoteId'));
  Finder graphNode(String noteId) => find.byKey(Key('graph-node-$noteId'));
  Finder get graphView => find.byKey(const Key('graph-view'));
  Finder canvasNode(String noteId) => find.byKey(Key('canvas-node-$noteId'));
  Finder canvasView(String canvasId) => find.byKey(Key('canvas-tab-$canvasId'));
  Finder zoomedView(String noteId) => find.byKey(Key('zoomed-$noteId'));
  Finder outgoingLink(String linkId) =>
      find.byKey(Key('outgoing-link-$linkId'));
  Finder backlink(String fromNoteId, String linkId) =>
      find.byKey(Key('backlink-item-$fromNoteId-$linkId'));

  // ------------------------------------------------------------------ state

  TabsNotifier get notifier => h.read(tabsProvider.notifier);
  TabsState get tabs => h.read(tabsProvider);
  WorkspaceTab? get active => tabs.activeTab;
  EditorStateValue get editor => h.read(editorControllerProvider);

  /// The editor page's scroll position (the page of the one note on screen).
  ScrollPosition get page => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byType(EditorPage),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;

  double get scrolled => page.pixels;

  // ---------------------------------------------------------------- actions

  Future<void> pump() => pumpFrames(tester);

  Future<void> tapBack() async {
    expect(backButton, findsOneWidget);
    await tester.tap(backButton);
    await pump();
  }

  Future<void> tapForward() async {
    expect(forwardButton, findsOneWidget);
    await tester.tap(forwardButton);
    await pump();
  }

  /// Scrolls the editor page to [offset] as a person would and checks it got
  /// there.
  Future<void> scrollTo(double offset) async {
    expect(
      page.maxScrollExtent,
      greaterThanOrEqualTo(offset),
      reason: 'the note must be long enough to scroll that far',
    );
    page.jumpTo(offset);
    await tester.pump();
    expect(page.pixels, offset);
  }

  /// Scrolls the page until the [needle] of text segment [segment] is on
  /// screen, and returns where it is (its centre) in global coordinates.
  Future<Offset> scrollToText(int segment, String needle) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final at = _pointOn(segment, needle);
      final viewport = tester.getRect(find.byType(EditorPage));
      final inside = at.dy > viewport.top + 60 && at.dy < viewport.bottom - 60;
      if (inside) return at;
      page.jumpTo(
        (page.pixels + at.dy - viewport.center.dy).clamp(
          page.minScrollExtent,
          page.maxScrollExtent,
        ),
      );
      await tester.pump();
    }
    return _pointOn(segment, needle);
  }

  Offset _pointOn(int segment, String needle) {
    final handle = segmentEditingAt(tester, segment);
    final text = handle.text;
    final start = text.indexOf(needle);
    expect(start, isNonNegative, reason: 'segment $segment holds "$needle"');
    final a = handle.rectForOffset(start);
    final b = handle.rectForOffset(start + needle.length);
    expect(a.center.dy, closeTo(b.center.dy, 0.5), reason: 'one line');
    return Offset((a.left + b.left) / 2, a.center.dy);
  }

  /// A real mouse click on the rendered [needle] of text segment [segment]
  /// (scrolled into view first), with Cmd held when [cmd].
  Future<void> clickLink(int segment, String needle, {bool cmd = false}) async {
    final at = await scrollToText(segment, needle);
    await tester.macClick(at, cmd: cmd);
    await pump();
  }

  /// A mouse click on the footer chip of [topicNoteId] (scrolled into view).
  Future<void> clickFooterChip(String topicNoteId, {bool cmd = false}) async {
    final f = footerChip(topicNoteId);
    expect(f, findsOneWidget);
    await tester.ensureVisible(f);
    await tester.pump();
    await tester.macClick(tester.getCenter(f), cmd: cmd);
    await pump();
  }

  /// Opens the Graph view of the shown note from its note menu.
  Future<void> openGraphFromNoteMenu() async {
    await _tapKey('note-menu-button');
    await _tapKey('note-menu-open-graph');
    // The layout settles over some frames.
    await pumpFrames(tester, frames: 20);
  }

  /// A click on graph node [noteId]'s Key, with Cmd held when [cmd].
  Future<void> clickGraphNode(String noteId, {bool cmd = false}) async {
    final f = graphNode(noteId);
    expect(f, findsOneWidget, reason: 'graph node $noteId');
    await tester.macClick(tester.getCenter(f), cmd: cmd);
    await pump();
  }

  /// A mouse click on the keyed [target] (a right panel link, a sidebar row),
  /// scrolled into view, with Cmd held when [cmd].
  Future<void> click(Finder target, {bool cmd = false}) async {
    expect(target, findsOneWidget);
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.macClick(tester.getCenter(target), cmd: cmd);
    await pump();
  }

  /// Double clicks the canvas node card of [noteId] (a zoom).
  Future<void> doubleClick(String noteId) async {
    final at = tester.getCenter(canvasNode(noteId));
    await tester.tapAt(at, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at, kind: PointerDeviceKind.mouse);
    await pump();
    await pump();
  }

  /// Deletes the shown note through its menu and confirms.
  Future<void> deleteShownNote() async {
    await _tapKey('note-menu-button');
    await _tapKey('note-menu-delete');
    await _tapKey('delete-note-confirm');
    await pump();
  }

  Future<void> _tapKey(String key) async {
    final f = find.byKey(Key(key));
    expect(f, findsOneWidget, reason: key);
    await tester.tap(f);
    await pump();
  }

  /// Lets queued tab persistence finish: `UiStateStore.flush()` chains real
  /// file IO (which only runs outside the fake zone) with fake-zone callbacks
  /// (which only run on a pump), so alternate the two until it completes.
  Future<void> flushStore() async {
    await pump();
    final store = notifier.store;
    var flushed = false;
    unawaited(store.flush().then((_) => flushed = true));
    for (var i = 0; i < 5000 && !flushed; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
      await tester.pump();
    }
    expect(flushed, isTrue, reason: 'tab persistence finished');
  }

  /// The tabs `ui_state.json` holds, as `kind:id` strings.
  List<String> persistedTabs() {
    final file = File('${h.vaultPath}/.memex/ui_state.json');
    if (!file.existsSync()) return const [];
    final text = file.readAsStringSync();
    return [
      for (final m in RegExp(
        r'"kind"\s*:\s*"(\w+)"\s*,\s*"id"\s*:\s*"([^"]+)"',
      ).allMatches(text))
        '${m.group(1)}:${m.group(2)}',
    ];
  }

  // ------------------------------------------------------------- assertions

  void expectOnNote(String noteId, {String? title}) {
    expect(active, NoteTab(noteId));
    expect(h.read(tabsProvider).activeNoteId, noteId);
    if (title != null) expect(editor.title, title);
  }

  /// The page is at [offset] and stays there over more frames (no second
  /// jump).
  Future<void> expectScrolledTo(double offset) async {
    expect(scrolled, offset);
    await pump();
    expect(scrolled, offset, reason: 'no second jump');
  }

  /// The page is at the top (an arrival through a click).
  Future<void> expectAtTop() => expectScrolledTo(0);
}
