// WI #270 (N7): Back, Forward and a chip switch return a note to the scroll
// offset it was left at; every other arrival lands at the top (Spec R26-R28,
// TD7). The tab model is in `app/test/state/tabs_scroll_test.dart`.
//
// The tests read the editor page's own scroll position and count jumps with a
// listener on it (`_Jumps`) where the page stays: a chip switch between two tabs
// on one note jumps once, a rebase or a foreign change not at all. Going to
// another note rebuilds the page while its read is in flight, so those tests
// check the offset over `_settled` frames instead: a second jump would show. `*`
// in a comment marks the active tab. The app launches on today's tab; each test
// seeds its long notes.
//
// Never pumpAndSettle the workspace (OmDot pulses forever): pumpFrames only.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/canvas_state.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/topic_actions.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';
import 'package:open_memex_app/src/widgets/graph/graph_view.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../robots/today_robot.dart';
import '../support/app_harness.dart';
import '../support/canvas_seeds.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/footer_cli_fakes.dart';
import '../support/graph_seeds.dart';
import '../support/segment_editing_finder.dart';
import '../support/today_cli_fakes.dart';
import '../support/topics_access_doubles.dart';
import '../support/topics_launch.dart';

const _l1 = 'long-one';
const _l2 = 'long-two';
const _l3 = 'long-three';
const _medium = 'medium';
const _short = 'short';
const _daily = 'daily-long';
const _dailyDate = '2026-09-30';
const _dailyShort = 'daily-short';
const _dailyShortDate = '2026-09-29';

const _longLines = 400;
const _mediumLines = 120;
const _shortLines = 3;

/// An offset every long note can scroll to at the harness surface size.
const _left = 700.0;
const _other = 300.0;

String _body(int lines, [String tag = 'line']) =>
    '${[for (var i = 0; i < lines; i++) '$tag $i'].join('\n')}\n';

extension on WorkspaceHarness {
  TabsNotifier get tabs => read(tabsProvider.notifier);
  TabsState get tabState => read(tabsProvider);
  EditorStateValue get editor => read(editorControllerProvider);
}

/// The vault every test starts from: three long notes of one length, a medium
/// note, a short note and a long daily note.
FakeVaultDb _seed(FakeVaultDb db) {
  db.seedNote(id: _l1, title: 'Long one', content: _body(_longLines));
  db.seedNote(id: _l2, title: 'Long two', content: _body(_longLines));
  db.seedNote(id: _l3, title: 'Long three', content: _body(_longLines));
  db.seedNote(id: _medium, title: 'Medium', content: _body(_mediumLines));
  db.seedNote(id: _short, title: 'Short', content: _body(_shortLines));
  db.seedNote(
    id: _daily,
    title: _dailyDate,
    role: 'daily',
    content: _body(_longLines),
  );
  db.seedNote(
    id: _dailyShort,
    title: _dailyShortDate,
    role: 'daily',
    content: _body(_shortLines),
  );
  return db;
}

Future<WorkspaceHarness> _launch(WidgetTester tester, {FakeVaultDb? db}) {
  final vault = db ?? _seed(FakeVaultDb.v5());
  final cli = FakeMemexCli()
    ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
    ..onUpdateWrites(vault);
  return pumpWorkspace(tester, db: vault, cli: cli);
}

/// The editor page's scroll position, of the page under [under] while two
/// editors are on screen.
ScrollPosition _position(WidgetTester tester, {Finder? under}) {
  final page = under == null
      ? find.byType(EditorPage)
      : find.descendant(of: under, matching: find.byType(EditorPage));
  return tester
      .state<ScrollableState>(
        find.descendant(of: page, matching: find.byType(Scrollable)).first,
      )
      .position;
}

double _pixels(WidgetTester tester, {Finder? under}) =>
    _position(tester, under: under).pixels;

/// Scrolls the page to [offset] as a person would and checks it got there.
Future<void> _scrollTo(
  WidgetTester tester,
  double offset, {
  Finder? under,
}) async {
  final position = _position(tester, under: under);
  expect(
    position.maxScrollExtent,
    greaterThanOrEqualTo(offset),
    reason: 'the note must be long enough to scroll that far',
  );
  position.jumpTo(offset);
  await tester.pump();
  expect(position.pixels, offset);
}

/// The page is at [offset] and stays there over more frames.
Future<void> _expectSettledAt(WidgetTester tester, double offset) async {
  expect(_pixels(tester), offset);
  await pumpFrames(tester);
  expect(_pixels(tester), offset, reason: 'no second jump');
}

/// Every pixel value the page's scroll position moves to from now on.
class _Jumps {
  _Jumps(WidgetTester tester, {Finder? under})
    : position = _position(tester, under: under) {
    position.addListener(_moved);
  }

  final ScrollPosition position;
  final values = <double>[];

  void _moved() => values.add(position.pixels);
}

Future<void> _navigate(
  WidgetTester tester,
  WorkspaceHarness h,
  WorkspaceTab target,
) async {
  h.tabs.navigate(target);
  await pumpFrames(tester);
}

Future<void> _back(WidgetTester tester, WorkspaceHarness h) async {
  h.tabs.back();
  await pumpFrames(tester);
}

Future<void> _forward(WidgetTester tester, WorkspaceHarness h) async {
  h.tabs.forward();
  await pumpFrames(tester);
}

Future<void> _chip(WidgetTester tester, WorkspaceHarness h, int index) async {
  h.tabs.setActive(index);
  await pumpFrames(tester);
}

/// Today's tab shows `first`; `second` opens in a new tab, active: `[first]
/// [second*]`.
Future<void> _twoTabs(
  WidgetTester tester,
  WorkspaceHarness h,
  String first,
  String second,
) async {
  await _navigate(tester, h, NoteTab(first));
  h.tabs.openOrFocus(NoteTab(second));
  await pumpFrames(tester);
  expect(h.tabState.tabs, [NoteTab(first), NoteTab(second)]);
  expect(h.tabState.activeIndex, 1);
}

/// `[l1] [l1*]`: two tabs on one note. The second reached it by navigating.
Future<void> _twoTabsOnOneNote(WidgetTester tester, WorkspaceHarness h) async {
  await _twoTabs(tester, h, _l1, _l2);
  await _navigate(tester, h, const NoteTab(_l1));
  expect(h.tabState.tabs, [const NoteTab(_l1), const NoteTab(_l1)]);
  expect(h.tabState.activeIndex, 1);
}

void _unfocus() => FocusManager.instance.primaryFocus?.unfocus();

bool _bodyHasFocus(WidgetTester tester) =>
    editorBodySegment(tester).focusedRow != null;

void _expectCaretAtEnd(WidgetTester tester) {
  final body = editorBodySegment(tester);
  expect(body.selection, TextSelection.collapsed(offset: body.text.length));
  expect(_bodyHasFocus(tester), isTrue, reason: 'the body takes focus');
}

/// Loading any note leaves its unfocused selection at the end of its text, so
/// what a Back or a chip switch must not do is take focus.
void _expectNoFocusTaken(WidgetTester tester) {
  expect(_bodyHasFocus(tester), isFalse, reason: 'focus is not taken');
}

Finder get _sourceSurface => find.byKey(const Key('editor-source-surface'));
Finder get _sourceToggle => find.byKey(const Key('editor-source-toggle'));
Finder _zoomed(String noteId) => find.byKey(Key('zoomed-$noteId'));

Future<void> _toggleSource(WidgetTester tester) async {
  await tester.tap(_sourceToggle);
  await pumpFrames(tester);
}

void main() {
  group('back forward and chip switches restore the offset', () {
    testWidgets(
      'back and forward each return a long note to the scroll offset it was left at',
      (tester) async {
        final h = await _launch(tester);
        await _navigate(tester, h, const NoteTab(_l1));
        await _scrollTo(tester, _left);
        await _navigate(tester, h, const NoteTab(_l2));
        await _scrollTo(tester, _other);

        await _back(tester, h);
        expect(h.editor.title, 'Long one');
        await _expectSettledAt(tester, _left);

        await _forward(tester, h);
        expect(h.editor.title, 'Long two');
        await _expectSettledAt(tester, _other);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a chip switch returns to the scroll offset that tab was left at',
      (tester) async {
        final h = await _launch(tester);
        await _twoTabs(tester, h, _l1, _l2);
        await _scrollTo(tester, _other);
        await _chip(tester, h, 0);
        await _scrollTo(tester, _left);

        await tester.tap(find.byKey(const Key('tab-note-$_l2')));
        await pumpFrames(tester);
        expect(h.tabState.activeIndex, 1);
        expect(h.editor.title, 'Long two');
        await _expectSettledAt(tester, _other);

        await tester.tap(find.byKey(const Key('tab-note-$_l1')));
        await pumpFrames(tester);
        expect(h.tabState.activeIndex, 0);
        await _expectSettledAt(tester, _left);
      },
    );

    testWidgets('an entry that was never scrolled returns at the top', (
      tester,
    ) async {
      final h = await _launch(tester);
      await _navigate(tester, h, const NoteTab(_l1));
      await _navigate(tester, h, const NoteTab(_l2));
      await _scrollTo(tester, _left);

      await _back(tester, h);

      expect(h.editor.title, 'Long one');
      expect(_pixels(tester), 0.0, reason: 'the offset of Long two stays');

      await _forward(tester, h);
      expect(_pixels(tester), _left, reason: 'Long two kept its own offset');
    });

    testWidgets(
      'a daily note reached by back and never scrolled returns at the top with no caret jump and no focus',
      (tester) async {
        // Short: the caret jump of a long daily note scrolls the page to the
        // caret, and that scroll is the offset it was left at.
        final h = await _launch(tester);
        await _navigate(tester, h, const NoteTab(_dailyShort));
        await _navigate(tester, h, const NoteTab(_l1));
        await _scrollTo(tester, _left);
        _unfocus();
        await tester.pump();

        await _back(tester, h);

        expect(h.tabState.activeTab, const NoteTab(_dailyShort));
        _expectNoFocusTaken(tester);
        expect(_pixels(tester), 0.0);
      },
    );

    testWidgets(
      'when the note got shorter the restored offset is clamped to the new maximum',
      (tester) async {
        final h = await _launch(tester);
        await _navigate(tester, h, const NoteTab(_l1));
        final fullLength = _position(tester).maxScrollExtent;
        await _scrollTo(tester, fullLength);
        await _navigate(tester, h, const NoteTab(_l2));
        h.db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
          _body(_mediumLines),
          _l1,
        ]);

        await _back(tester, h);

        final position = _position(tester);
        expect(h.editor.contentMd, _body(_mediumLines));
        expect(position.maxScrollExtent, lessThan(fullLength));
        expect(position.maxScrollExtent, greaterThan(0.0));
        expect(position.pixels, position.maxScrollExtent);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a note that no longer scrolls restores to the top', (
      tester,
    ) async {
      final h = await _launch(tester);
      await _navigate(tester, h, const NoteTab(_l1));
      await _scrollTo(tester, _left);
      await _navigate(tester, h, const NoteTab(_l2));
      await _scrollTo(tester, _other);
      h.db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
        _body(_shortLines),
        _l1,
      ]);

      await _back(tester, h);

      final position = _position(tester);
      expect(position.maxScrollExtent, 0.0);
      expect(position.pixels, 0.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'a long note reached from a short one restores its whole offset after the first layout',
      (tester) async {
        final h = await _launch(tester);
        await _navigate(tester, h, const NoteTab(_l1));
        final fullLength = _position(tester).maxScrollExtent;
        expect(fullLength, greaterThan(_left));
        await _scrollTo(tester, fullLength);
        await _navigate(tester, h, const NoteTab(_short));
        expect(_position(tester).maxScrollExtent, 0.0);

        await _back(tester, h);

        expect(
          _pixels(tester),
          fullLength,
          reason: 'clamped against the long note, not the short one',
        );

        await _forward(tester, h);
        expect(_pixels(tester), 0.0);
        await _back(tester, h);
        expect(_pixels(tester), fullLength);
      },
    );

    testWidgets(
      'a shorter note clamping the page writes nothing into the entry just arrived at',
      (tester) async {
        final h = await _launch(tester);
        await _navigate(tester, h, const NoteTab(_medium));
        final mediumMax = _position(tester).maxScrollExtent;
        expect(mediumMax, greaterThan(100.0));
        await _scrollTo(tester, 100.0);
        await _navigate(tester, h, const NoteTab(_l1));
        final fullLength = _position(tester).maxScrollExtent;
        await _scrollTo(tester, fullLength);

        await _back(tester, h);
        expect(_pixels(tester), 100.0, reason: 'not the clamped maximum');

        await _forward(tester, h);
        expect(_pixels(tester), fullLength, reason: 'its entry was untouched');

        await _back(tester, h);
        expect(_pixels(tester), 100.0);
      },
    );

    testWidgets(
      'a taller viewport in the frame of a same note chip switch records no clamped offset into the entry arrived at',
      (tester) async {
        final h = await _launch(tester);
        await _twoTabsOnOneNote(tester, h);
        final fullLength = _position(tester).maxScrollExtent;
        await _scrollTo(tester, _other); // [l1] [l1*]
        await _chip(tester, h, 0);
        await _scrollTo(tester, fullLength); // [l1*] [l1]
        await _chip(tester, h, 1);
        expect(_pixels(tester), _other);

        // The first tab offset no longer fits once the page is taller.
        final size = tester.view.physicalSize;
        tester.view.physicalSize = Size(size.width, size.height + 400);
        h.tabs.setActive(0);
        await pumpFrames(tester);
        expect(_pixels(tester), lessThan(fullLength), reason: 'clamped');
        expect(_pixels(tester), greaterThan(_other));

        tester.view.physicalSize = size;
        await pumpFrames(tester);
        await _chip(tester, h, 1);
        expect(_pixels(tester), _other);
        await _chip(tester, h, 0);
        expect(_pixels(tester), fullLength, reason: 'its entry was untouched');
      },
    );

    testWidgets(
      'a chip switch to a shorter note writes nothing into either tab entry',
      (tester) async {
        final h = await _launch(tester);
        await _twoTabs(tester, h, _medium, _l1);
        final fullLength = _position(tester).maxScrollExtent;
        await _scrollTo(tester, fullLength);

        await _chip(tester, h, 0);
        expect(_pixels(tester), 0.0, reason: 'the medium tab never scrolled');

        await _chip(tester, h, 1);
        expect(_pixels(tester), fullLength);

        await _chip(tester, h, 0);
        expect(_pixels(tester), 0.0);
      },
    );
  });

  group('navigating lands at the top', () {
    testWidgets(
      'navigating lands at the top even to a note visited earlier and left scrolled and a different note does not inherit the previous offset',
      (tester) async {
        final h = await _launch(tester);
        await _navigate(tester, h, const NoteTab(_l1));
        await _scrollTo(tester, _left);

        await _navigate(tester, h, const NoteTab(_l2));
        expect(h.editor.title, 'Long two');
        expect(_pixels(tester), 0.0, reason: 'no inherited offset');
        await _scrollTo(tester, _other);

        await _navigate(tester, h, const NoteTab(_l1));
        expect(h.editor.title, 'Long one');
        expect(_pixels(tester), 0.0, reason: 'a new entry on a visited note');

        await _back(tester, h);
        expect(_pixels(tester), _other);
        await _back(tester, h);
        expect(_pixels(tester), _left, reason: 'the first entry kept its own');
      },
    );

    testWidgets(
      'a back followed at once by a navigate lands at the top of the new note',
      (tester) async {
        final h = await _launch(tester);
        await _navigate(tester, h, const NoteTab(_l1));
        await _scrollTo(tester, _left);
        await _navigate(tester, h, const NoteTab(_l2));
        await _scrollTo(tester, _other);

        h.tabs.back();
        h.tabs.navigate(const NoteTab(_l3));
        await pumpFrames(tester);

        expect(h.editor.title, 'Long three');
        expect(_pixels(tester), 0.0);
        await _back(tester, h);
        expect(h.editor.title, 'Long one');
        expect(_pixels(tester), _left);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a navigate one frame after a back does not apply the restore to the new note',
      (tester) async {
        final h = await _launch(tester);
        await _navigate(tester, h, const NoteTab(_l1));
        await _scrollTo(tester, _left);
        await _navigate(tester, h, const NoteTab(_l2));
        await _scrollTo(tester, _other);

        h.tabs.back();
        await tester.pump();
        h.tabs.navigate(const NoteTab(_l3));
        await pumpFrames(tester);

        expect(h.editor.title, 'Long three');
        expect(_pixels(tester), 0.0);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'leaving the editor in the frame of a back runs no jump and throws nothing',
      (tester) async {
        final h = await _launch(tester);
        await _navigate(tester, h, const NoteTab(_l1));
        await _scrollTo(tester, _left);
        await _navigate(tester, h, const NoteTab(_l2));

        h.tabs.back();
        h.tabs.navigate(GraphTab(const GraphScope.vault()));
        await pumpFrames(tester);

        expect(find.byType(NoteEditor), findsNothing);
        expect(tester.takeException(), isNull);

        await _back(tester, h);
        expect(h.editor.title, 'Long one');
        expect(_pixels(tester), _left, reason: 'the entry kept its offset');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'closing a tab on the same note left of the active one causes zero jumps',
      (tester) async {
        final h = await _launch(tester);
        await _twoTabsOnOneNote(tester, h);
        await _scrollTo(tester, _other);

        final jumps = _Jumps(tester);
        h.tabs.closeAt(0); // [l1*]: the index moves, the tab does not
        await pumpFrames(tester);

        expect(h.tabState.activeIndex, 0);
        expect(jumps.values, isEmpty);
        expect(_pixels(tester), _other);

        await _navigate(tester, h, const NoteTab(_l2));
        await _back(tester, h);
        expect(_pixels(tester), _other);
      },
    );

    testWidgets(
      'a chip tap on the active tab and openOrFocus on the note it shows cause zero jumps',
      (tester) async {
        final h = await _launch(tester);
        await _twoTabs(tester, h, _l1, _l2);
        await _scrollTo(tester, _other);

        final jumps = _Jumps(tester);
        await tester.tap(find.byKey(const Key('tab-note-$_l2')));
        await pumpFrames(tester);
        h.tabs.setActive(1);
        await pumpFrames(tester);
        h.tabs.openOrFocus(const NoteTab(_l2));
        await pumpFrames(tester);

        expect(jumps.values, isEmpty);
        expect(_pixels(tester), _other);

        await _chip(tester, h, 0);
        await _chip(tester, h, 1);
        expect(_pixels(tester), _other);
      },
    );
  });

  group('focusing an open tab and landing on a neighbour restore (D39)', () {
    testWidgets(
      'openOrFocus focusing an open tab and closing the active tab restore the offset of the tab reached and keep it',
      (tester) async {
        final h = await _launch(tester);
        await _twoTabs(tester, h, _l1, _l2);
        await _scrollTo(tester, _other);
        await _chip(tester, h, 0);
        await _scrollTo(tester, _left);

        h.tabs.openOrFocus(const NoteTab(_l2)); // [l1] [l2*]
        await pumpFrames(tester);
        expect(h.tabState.activeIndex, 1);
        expect(h.editor.title, 'Long two');
        await _expectSettledAt(tester, _other);
        // The restore did not write 0 into the entry: leave and come back.
        await _chip(tester, h, 0);
        expect(_pixels(tester), _left);
        await _chip(tester, h, 1);
        expect(_pixels(tester), _other, reason: 'the saved offset survives');

        h.tabs.openOrFocus(const NoteTab(_l1)); // [l1*] [l2]
        await pumpFrames(tester);
        await _expectSettledAt(tester, _left);

        h.tabs.close(const NoteTab(_l1)); // [l2*]
        await pumpFrames(tester);
        expect(h.tabState.tabs, [const NoteTab(_l2)]);
        expect(h.editor.title, 'Long two');
        await _expectSettledAt(tester, _other);
        h.tabs.openOrFocus(const NoteTab(_l3)); // [l2] [l3*]
        await pumpFrames(tester);
        await _chip(tester, h, 0);
        expect(_pixels(tester), _other, reason: 'closing wrote no 0 either');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'closing the active tab lands the neighbour at its offset and keeps the offset it had',
      (tester) async {
        final h = await _launch(tester);
        await _twoTabs(tester, h, _l1, _l2);
        await _scrollTo(tester, _other);
        await _chip(tester, h, 0);
        await _scrollTo(tester, _left);
        await _chip(tester, h, 1);

        h.tabs.closeAt(1); // [l1*]
        await pumpFrames(tester);

        expect(h.tabState.activeTab, const NoteTab(_l1));
        await _expectSettledAt(tester, _left);
        h.tabs.openOrFocus(const NoteTab(_l2)); // [l1] [l2*]
        await pumpFrames(tester);
        expect(_pixels(tester), 0.0, reason: 'a new tab lands at the top');
        await _chip(tester, h, 0);
        expect(_pixels(tester), _left, reason: 'the saved offset survives');
      },
    );

    testWidgets('openOrFocus opening a new tab lands at the top', (
      tester,
    ) async {
      final h = await _launch(tester);
      await _navigate(tester, h, const NoteTab(_l1));
      await _scrollTo(tester, _left);

      h.tabs.openOrFocus(const NoteTab(_l2));
      await pumpFrames(tester);

      expect(h.tabState.activeIndex, 1);
      expect(h.editor.title, 'Long two');
      await _expectSettledAt(tester, 0.0);
      h.tabs.openOrFocus(const NoteTab(_l1)); // focus the first tab
      await pumpFrames(tester);
      await _expectSettledAt(tester, _left);
    });

    testWidgets(
      'openOrFocus onto a tab on the same note restores that tab own offset with no re-hydrate and in one jump',
      (tester) async {
        final h = await _launch(tester);
        await _twoTabsOnOneNote(tester, h);
        await _scrollTo(tester, _other); // [l1] [l1*]
        await _chip(tester, h, 0);
        await _scrollTo(tester, _left); // [l1*] [l1]
        await _chip(tester, h, 1);
        expect(_pixels(tester), _other);
        h.db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
          _body(_longLines, 'stored'),
          _l1,
        ]);

        final jumps = _Jumps(tester);
        h.tabs.openOrFocus(const NoteTab(_l1)); // the leftmost: [l1*] [l1]
        await pumpFrames(tester);

        expect(h.tabState.activeIndex, 0);
        expect(_pixels(tester), _left);
        expect(jumps.values, [_left], reason: 'one jump');
        expect(h.editor.contentMd, _body(_longLines), reason: 'no re-hydrate');

        await _chip(tester, h, 1);
        expect(_pixels(tester), _other);
        await _chip(tester, h, 0);
        expect(_pixels(tester), _left, reason: 'the saved offset survives');
      },
    );

    testWidgets(
      'closing the active tab lands the neighbour on the same note at its own offset in one jump',
      (tester) async {
        final h = await _launch(tester);
        await _twoTabsOnOneNote(tester, h);
        await _scrollTo(tester, _other); // [l1] [l1*]
        await _chip(tester, h, 0);
        await _scrollTo(tester, _left); // [l1*] [l1]
        await _chip(tester, h, 1);
        expect(_pixels(tester), _other);

        final jumps = _Jumps(tester);
        h.tabs.closeAt(1); // [l1*]
        await pumpFrames(tester);

        expect(h.tabState.tabs, [const NoteTab(_l1)]);
        expect(_pixels(tester), _left);
        expect(jumps.values, [_left], reason: 'one jump, no re-hydrate');

        h.tabs.openOrFocus(const NoteTab(_l2));
        await pumpFrames(tester);
        await _chip(tester, h, 0);
        expect(_pixels(tester), _left, reason: 'the saved offset survives');
      },
    );

    testWidgets(
      'closing an inactive tab causes zero jumps and keeps a pending restore',
      (tester) async {
        final h = await _launch(tester);
        await _twoTabs(tester, h, _l1, _l2);
        await _scrollTo(tester, _other);
        h.tabs.openOrFocus(const NoteTab(_l3)); // [l1] [l2] [l3*]
        await pumpFrames(tester);
        await _chip(tester, h, 1);
        expect(_pixels(tester), _other);

        final jumps = _Jumps(tester);
        h.tabs.closeAt(2);
        h.tabs.closeAt(0); // [l2*]
        await pumpFrames(tester);

        expect(h.tabState.activeTab, const NoteTab(_l2));
        expect(jumps.values, isEmpty);
        expect(_pixels(tester), _other);
      },
    );

    testWidgets(
      'a daily note reached by openOrFocus on an open tab or by a close restores with no caret jump and no focus and a new daily tab takes focus',
      (tester) async {
        final h = await _launch(tester);
        await _navigate(tester, h, const NoteTab(_daily));
        await _scrollTo(tester, _left);
        h.tabs.openOrFocus(const NoteTab(_l1)); // [daily] [l1*]
        await pumpFrames(tester);
        _unfocus();
        await tester.pump();

        h.tabs.openOrFocus(const NoteTab(_daily)); // focus the open tab
        await pumpFrames(tester);
        expect(h.tabState.activeTab, const NoteTab(_daily));
        await _expectSettledAt(tester, _left);
        _expectNoFocusTaken(tester);

        await _chip(tester, h, 1);
        _unfocus();
        await tester.pump();
        h.tabs.close(const NoteTab(_l1)); // lands on the daily tab
        await pumpFrames(tester);
        expect(h.tabState.activeTab, const NoteTab(_daily));
        await _expectSettledAt(tester, _left);
        _expectNoFocusTaken(tester);

        // A new tab on a daily note keeps caret to end and focus.
        h.tabs.openOrFocus(const NoteTab(_dailyShort));
        await pumpFrames(tester);
        _expectCaretAtEnd(tester);
      },
    );

    testWidgets(
      'a new daily tab opened after the last tab was closed takes focus',
      (tester) async {
        final h = await _launch(tester);
        await _navigate(tester, h, const NoteTab(_l1));
        await _scrollTo(tester, _left);

        h.tabs.closeAt(0);
        await pumpFrames(tester);
        expect(h.tabState.tabs, isEmpty);
        h.tabs.openOrFocus(const NoteTab(_dailyShort));
        await pumpFrames(tester);

        expect(h.tabState.activeTab, const NoteTab(_dailyShort));
        _expectCaretAtEnd(tester);
      },
    );
  });

  group('the caret', () {
    testWidgets(
      'navigating to a daily note puts the caret at the end and takes focus',
      (tester) async {
        final h = await _launch(tester);
        await _navigate(tester, h, const NoteTab(_l1));
        _unfocus();
        await tester.pump();

        await _navigate(tester, h, const NoteTab(_daily));

        _expectCaretAtEnd(tester);
      },
    );

    testWidgets(
      'navigating to a daily note puts the caret at the end even after a back restored it',
      (tester) async {
        final h = await _launch(tester);
        await _navigate(tester, h, const NoteTab(_daily));
        await _scrollTo(tester, _left);
        await _navigate(tester, h, const NoteTab(_l1));
        _unfocus();
        await tester.pump();

        await _back(tester, h);
        expect(_pixels(tester), _left);
        _expectNoFocusTaken(tester);

        await _navigate(tester, h, const NoteTab(_l2));
        _unfocus();
        await tester.pump();
        await _navigate(tester, h, const NoteTab(_daily));

        _expectCaretAtEnd(tester);
      },
    );

    testWidgets(
      'back forward and chip switches do not restore the caret skip the daily caret jump and do not take focus',
      (tester) async {
        final h = await _launch(tester);
        await _navigate(tester, h, const NoteTab(_daily));
        await _scrollTo(tester, _left);
        await _navigate(tester, h, const NoteTab(_l1));
        _unfocus();
        await tester.pump();

        await _back(tester, h);
        expect(h.tabState.activeTab, const NoteTab(_daily));
        expect(_pixels(tester), _left, reason: 'Back');
        _expectNoFocusTaken(tester);

        await _forward(tester, h);
        expect(_bodyHasFocus(tester), isFalse, reason: 'Forward to a note');
        await _back(tester, h);
        expect(_pixels(tester), _left, reason: 'Back again');
        _expectNoFocusTaken(tester);

        h.tabs.openOrFocus(const NoteTab(_l2)); // [daily] [l2*]
        await pumpFrames(tester);
        _unfocus();
        await tester.pump();
        await _chip(tester, h, 0);
        expect(h.tabState.activeTab, const NoteTab(_daily));
        expect(_pixels(tester), _left, reason: 'a chip switch');
        _expectNoFocusTaken(tester);

        await _chip(tester, h, 1);
        await _navigate(tester, h, const NoteTab(_daily)); // [daily] [daily*]
        await _scrollTo(tester, _other);
        await _back(tester, h);
        _unfocus();
        await tester.pump();
        await _forward(tester, h);
        expect(h.tabState.activeTab, const NoteTab(_daily));
        expect(_pixels(tester), _other, reason: 'Forward to a daily note');
        _expectNoFocusTaken(tester);
      },
    );

    testWidgets(
      'a restore with focus on the body leaves the caret where it was on a same note chip switch',
      (tester) async {
        final h = await _launch(tester);
        await _twoTabsOnOneNote(tester, h);
        await focusSegmentAt(tester, find.byKey(editorBodyKey), offset: 5);
        expect(editorBodySegment(tester).selection.baseOffset, 5);
        final selection = editorBodySegment(tester).selection;

        await _chip(tester, h, 0);

        expect(editorBodySegment(tester).selection, selection);
      },
    );
  });

  group('two tabs on one note', () {
    testWidgets(
      'two tabs showing one note keep separate offsets and a chip switch between them jumps with no re-hydrate',
      (tester) async {
        final h = await _launch(tester);
        await _twoTabsOnOneNote(tester, h);
        await _scrollTo(tester, _other); // [l1] [l1*]
        await _chip(tester, h, 0);
        await _scrollTo(tester, _left); // [l1*] [l1]

        // A stored change nobody announced: only a re-hydrate would load it.
        h.db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
          _body(_longLines, 'stored'),
          _l1,
        ]);

        final jumps = _Jumps(tester);
        await _chip(tester, h, 1);
        expect(_pixels(tester), _other);
        expect(jumps.values, [_other], reason: 'one jump, on a tab listener');

        jumps.values.clear();
        await _chip(tester, h, 0);
        expect(_pixels(tester), _left);
        expect(jumps.values, [_left], reason: 'one jump, on a tab listener');

        expect(h.editor.contentMd, _body(_longLines), reason: 'no re-hydrate');
      },
    );

    testWidgets(
      'a same note chip switch followed at once by a navigate lands the new note at the top and keeps both offsets',
      (tester) async {
        final h = await _launch(tester);
        await _twoTabsOnOneNote(tester, h);
        await _scrollTo(tester, _other); // [l1] [l1*]
        await _chip(tester, h, 0);
        await _scrollTo(tester, _left); // [l1*] [l1]
        await _chip(tester, h, 1);
        expect(_pixels(tester), _other);

        // Two arrivals before any frame: the jump of the first is not run.
        h.tabs.setActive(0);
        h.tabs.navigate(const NoteTab(_l2));
        await pumpFrames(tester);

        expect(h.editor.title, 'Long two');
        await _expectSettledAt(tester, 0.0);

        await _back(tester, h);
        await _expectSettledAt(tester, _left);
        await _chip(tester, h, 1);
        await _expectSettledAt(tester, _other);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'three same note chip switches before a frame jump once to the tab reached last',
      (tester) async {
        final h = await _launch(tester);
        await _twoTabsOnOneNote(tester, h);
        await _scrollTo(tester, _other); // [l1] [l1*]
        await _chip(tester, h, 0);
        await _scrollTo(tester, _left); // [l1*] [l1]

        await _chip(tester, h, 1);
        expect(_pixels(tester), _other);

        final jumps = _Jumps(tester);
        h.tabs.setActive(0);
        h.tabs.setActive(1);
        h.tabs.setActive(0);
        await pumpFrames(tester);

        expect(jumps.values, [_left], reason: 'one jump, to the last tab');
        expect(_pixels(tester), _left);
      },
    );

    testWidgets(
      'the first tab last offset does not land on a second tab that never scrolled',
      (tester) async {
        final h = await _launch(tester);
        await _twoTabsOnOneNote(tester, h);
        await _chip(tester, h, 0);
        await _scrollTo(tester, _left);

        await _chip(tester, h, 1);
        expect(_pixels(tester), 0.0, reason: 'the second tab never scrolled');

        await _chip(tester, h, 0);
        expect(_pixels(tester), _left);

        await _chip(tester, h, 1);
        expect(_pixels(tester), 0.0);
      },
    );
  });

  group('a zoomed note on a canvas', () {
    const canvas = CanvasTab(C89.newer);
    const zoomedAlpha = CanvasTab(C89.newer, zoomedNoteId: C89.alpha);
    const zoomedBeta = CanvasTab(C89.newer, zoomedNoteId: C89.beta);

    /// The canvas fixture with Alpha and Gamma long and Beta twice as long, on
    /// the canvas, with zoom animations of [zoom].
    Future<WorkspaceHarness> onCanvas(
      WidgetTester tester, {
      Duration zoom = Duration.zero,
    }) async {
      final db = seedCanvasFixture(FakeVaultDb.v5());
      for (final (id, lines) in const [
        (C89.alpha, _longLines),
        (C89.beta, _longLines * 2),
        (C89.gamma, _longLines),
      ]) {
        db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
          _body(lines),
          id,
        ]);
      }
      final h = await pumpWorkspace(
        tester,
        db: db,
        cli: FakeMemexCli()
          ..on(
            'settings get',
            (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout),
          )
          ..onUpdateWrites(db),
        overrides: [
          canvasAnimationConfigProvider.overrideWithValue(
            CanvasAnimationConfig(zoomDuration: zoom),
          ),
        ],
      );
      h.tabs.navigate(canvas);
      await pumpFrames(tester);
      await pumpFrames(tester);
      expect(find.byKey(const Key('canvas-tab-${C89.newer}')), findsOneWidget);
      return h;
    }

    testWidgets(
      'a zoomed note on a canvas restores its offset on back and forward',
      (tester) async {
        final h = await onCanvas(tester);
        await _navigate(tester, h, zoomedAlpha);
        await _scrollTo(tester, _left);

        // Back zooms out, and Forward builds a new editor for the note.
        await _back(tester, h);
        expect(h.tabState.activeTab, canvas);
        expect(find.byType(NoteEditor), findsNothing);
        await _forward(tester, h);
        expect(h.editor.title, 'Alpha');
        expect(_pixels(tester), _left, reason: 'Forward into the zoomed note');

        // Back into the zoomed note, from a note of its own.
        await _navigate(tester, h, const NoteTab(C89.gamma));
        expect(_pixels(tester), 0.0);
        await _scrollTo(tester, _other);
        await _back(tester, h);
        expect(h.tabState.activeTab, zoomedAlpha);
        expect(h.editor.title, 'Alpha');
        expect(_pixels(tester), _left, reason: 'Back into the zoomed note');

        await _forward(tester, h);
        expect(h.editor.title, 'Gamma');
        expect(_pixels(tester), _other);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'navigating to a zoomed note lands at the top and each zoomed entry keeps its offset',
      (tester) async {
        final h = await onCanvas(tester);
        await _navigate(tester, h, zoomedAlpha);
        await _scrollTo(tester, _left);

        await _navigate(tester, h, zoomedBeta);
        expect(h.editor.title, 'Beta');
        expect(_pixels(tester), 0.0, reason: 'a navigate lands at the top');
        await _scrollTo(tester, _other);

        await _back(tester, h);
        expect(h.editor.title, 'Alpha');
        expect(_pixels(tester), _left);

        await _forward(tester, h);
        expect(h.editor.title, 'Beta');
        expect(_pixels(tester), _other);
      },
    );

    testWidgets(
      'the outgoing editor of a zoom change neither takes the restore nor reports an offset',
      (tester) async {
        const duration = Duration(milliseconds: 300);
        final h = await onCanvas(tester, zoom: duration);
        Future<void> finishSwitch() async {
          await tester.pump(duration);
          await tester.pump(duration);
          await pumpFrames(tester);
        }

        await _navigate(tester, h, zoomedAlpha);
        await finishSwitch();
        await _scrollTo(tester, _left, under: _zoomed(C89.alpha));

        await _navigate(tester, h, zoomedBeta);
        await finishSwitch();
        final betaLength = _position(
          tester,
          under: _zoomed(C89.beta),
        ).maxScrollExtent;
        await _scrollTo(tester, betaLength, under: _zoomed(C89.beta));

        // Back: inside the switcher's duration both editors are on screen. The
        // old one holds a longer note, so Alpha's shorter text clamps it.
        h.tabs.back();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 50));
        expect(_zoomed(C89.alpha), findsOneWidget);
        expect(_zoomed(C89.beta), findsOneWidget, reason: 'still switching');
        await tester.pump(const Duration(milliseconds: 50));
        expect(_zoomed(C89.beta), findsOneWidget, reason: 'still switching');
        await finishSwitch();

        expect(_zoomed(C89.beta), findsNothing);
        expect(
          _pixels(tester, under: _zoomed(C89.alpha)),
          _left,
          reason: 'the new editor took the restore',
        );

        h.tabs.forward();
        await finishSwitch();
        expect(_zoomed(C89.alpha), findsNothing);
        expect(
          _pixels(tester, under: _zoomed(C89.beta)),
          betaLength,
          reason: 'nothing was written into the entry on Beta',
        );

        h.tabs.back();
        await finishSwitch();
        expect(
          _pixels(tester, under: _zoomed(C89.alpha)),
          _left,
          reason: 'nothing was written into the entry on Alpha',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a zoom change reversed inside the switcher duration leaves the restore to the incoming editor',
      (tester) async {
        const duration = Duration(milliseconds: 300);
        final h = await onCanvas(tester, zoom: duration);
        Future<void> finishSwitch() async {
          await tester.pump(duration);
          await tester.pump(duration);
          await pumpFrames(tester);
        }

        await _navigate(tester, h, zoomedAlpha);
        await finishSwitch();
        await _scrollTo(tester, _left, under: _zoomed(C89.alpha));
        await _navigate(tester, h, zoomedBeta);
        await finishSwitch();
        final betaLength = _position(
          tester,
          under: _zoomed(C89.beta),
        ).maxScrollExtent;
        await _scrollTo(tester, betaLength, under: _zoomed(C89.beta));

        // Beta to Alpha to Beta, the second step before the first one is done:
        // the first Beta editor is still on screen when Beta is wanted again.
        h.tabs.back();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 50));
        expect(_zoomed(C89.beta), findsOneWidget, reason: 'still switching');
        h.tabs.forward();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 50));
        await finishSwitch();

        expect(h.tabState.activeTab, zoomedBeta);
        expect(_zoomed(C89.alpha), findsNothing);
        expect(
          _pixels(tester, under: _zoomed(C89.beta)),
          betaLength,
          reason: 'the new Beta editor took the restore',
        );

        h.tabs.back();
        await finishSwitch();
        expect(
          _pixels(tester, under: _zoomed(C89.alpha)),
          _left,
          reason: 'nothing was written into the entry on Alpha',
        );

        h.tabs.forward();
        await finishSwitch();
        expect(
          _pixels(tester, under: _zoomed(C89.beta)),
          betaLength,
          reason: 'the first Beta editor wrote nothing into the entry on Beta',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a zoomed neighbour reached by openOrFocus or by a close builds a new editor that takes the restore',
      (tester) async {
        final h = await onCanvas(tester);
        await _navigate(tester, h, zoomedAlpha);
        await _scrollTo(tester, _left);
        h.tabs.openOrFocus(const NoteTab(C89.gamma)); // [zoomedAlpha] [gamma*]
        await pumpFrames(tester);
        expect(find.byType(NoteEditor), findsOneWidget);
        expect(h.editor.title, 'Gamma');
        await _expectSettledAt(tester, 0.0);
        await _scrollTo(tester, _other);

        h.tabs.openOrFocus(zoomedAlpha); // focus the zoomed tab
        await pumpFrames(tester);
        expect(h.tabState.activeIndex, 0);
        expect(h.editor.title, 'Alpha');
        await _expectSettledAt(tester, _left);

        await _chip(tester, h, 1);
        expect(_pixels(tester), _other);
        h.tabs.close(const NoteTab(C89.gamma)); // lands on the zoomed tab
        await pumpFrames(tester);
        expect(h.tabState.activeTab, zoomedAlpha);
        expect(h.editor.title, 'Alpha');
        await _expectSettledAt(tester, _left);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a chip switch between a zoomed tab and a note tab on one note restores each own offset and a close landing does too',
      (tester) async {
        final h = await onCanvas(tester);
        await _navigate(tester, h, zoomedAlpha);
        await _scrollTo(tester, _left);
        h.tabs.openOrFocus(const NoteTab(C89.alpha)); // [zoomedAlpha] [alpha*]
        await pumpFrames(tester);
        await _expectSettledAt(tester, 0.0);
        await _scrollTo(tester, _other);

        await _chip(tester, h, 0);
        await _expectSettledAt(tester, _left);
        await _chip(tester, h, 1);
        await _expectSettledAt(tester, _other);
        await _chip(tester, h, 0);
        await _expectSettledAt(tester, _left);

        await _chip(tester, h, 1);
        h.tabs.closeAt(1); // lands on the zoomed tab
        await pumpFrames(tester);
        expect(h.tabState.activeTab, zoomedAlpha);
        await _expectSettledAt(tester, _left);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a chip switch to the zoomed tab and back before a frame leaves the note editor jumping and reporting',
      (tester) async {
        final h = await onCanvas(tester);
        await _navigate(tester, h, zoomedAlpha);
        await _scrollTo(tester, _left);
        h.tabs.openOrFocus(const NoteTab(C89.alpha)); // [zoomedAlpha] [alpha*]
        await pumpFrames(tester);
        await _scrollTo(tester, _other);

        h.tabs.setActive(0);
        h.tabs.setActive(1);
        await pumpFrames(tester);

        expect(h.tabState.activeTab, const NoteTab(C89.alpha));
        await _expectSettledAt(tester, _other);
        await _scrollTo(tester, 500);
        await _chip(tester, h, 0);
        await _chip(tester, h, 1);
        expect(_pixels(tester), 500, reason: 'the note editor reported 500');
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('what is not an arrival', () {
    testWidgets('rebaseEditorOnVersion causes zero scroll jumps', (
      tester,
    ) async {
      final h = await _launch(tester);
      await _navigate(tester, h, const NoteTab(_l1));
      await _scrollTo(tester, _left);
      final stored = h.db.getNote(_l1)!;
      h.db.db.execute('UPDATE notes SET version = ? WHERE id = ?', [
        stored.version + 1,
        _l1,
      ]);

      final jumps = _Jumps(tester);
      final ref = tester.element(find.byType(NoteEditor)) as WidgetRef;
      unawaited(
        rebaseEditorOnVersion(
          ref,
          fallback: stored,
          version: stored.version + 1,
          content: h.editor.contentMd,
        ),
      );
      await pumpFrames(tester);

      expect(h.editor.lastSavedVersion, stored.version + 1, reason: 'it ran');
      expect(jumps.values, isEmpty);
      expect(_pixels(tester), _left);

      // The offset still belongs to the entry.
      await _navigate(tester, h, const NoteTab(_l2));
      await _back(tester, h);
      expect(_pixels(tester), _left);
    });

    testWidgets('onTopicLinked causes zero scroll jumps', (tester) async {
      final db = _seed(FakeVaultDb.v5());
      final cli = FakeMemexCli()
        ..onUpdateWrites(db)
        ..onAddCreates(db)
        ..onFooterAdd(db);
      final r = await launchTopics(
        tester,
        AccessDoubles(),
        db: db,
        cli: cli,
        topicsMode: false,
      );
      final h = r.h;
      await _navigate(tester, h, const NoteTab(_daily));

      // The popover opens at the caret, at the end of the note, and stays there:
      // scroll first, so that it opens on screen with the page well down.
      await _scrollTo(tester, _position(tester).maxScrollExtent - 300);
      await typeSegmentText(
        tester,
        find.byKey(editorBodyKey),
        '${editorBodyText(tester)}Slept badly [[Sleep',
      );
      await pumpFrames(tester);
      final left = _pixels(tester);
      expect(left, greaterThan(0.0));
      final create = find.byKey(const Key('wikilink-popover-create'));
      expect(create, findsOneWidget);
      final version = h.editor.lastSavedVersion;

      final jumps = _Jumps(tester);
      await tester.tap(create);
      await pumpFrames(tester);

      expect(h.editor.lastSavedVersion, isNot(version), reason: 'it rebased');
      expect(jumps.values, isEmpty);
      expect(_pixels(tester), left);

      await _navigate(tester, h, const NoteTab(_l2));
      await _back(tester, h);
      expect(_pixels(tester), left);
    });

    testWidgets(
      'a foreign change applied by serverChanged causes zero scroll jumps',
      (tester) async {
        final h = await _launch(tester);
        await _navigate(tester, h, const NoteTab(_l1));
        await _scrollTo(tester, _left);
        final foreign = _body(_longLines, 'foreign');
        final version = h.db.getNote(_l1)!.version + 1;
        h.db.db.execute(
          'UPDATE notes SET content_md = ?, version = ? WHERE id = ?',
          [foreign, version, _l1],
        );

        final jumps = _Jumps(tester);
        unawaited(h.read(editorControllerProvider.notifier).serverChanged(_l1));
        await pumpFrames(tester);

        expect(h.editor.contentMd, foreign, reason: 'the change was applied');
        expect(jumps.values, isEmpty);
        expect(_pixels(tester), _left);

        await _navigate(tester, h, const NoteTab(_l2));
        await _back(tester, h);
        expect(_pixels(tester), _left);
      },
    );

    testWidgets(
      'a virtual Today note becoming real causes zero scroll jumps and keeps focus',
      (tester) async {
        final db = _seed(FakeVaultDb.v5());
        final r = TodayRobot(tester);
        final h = await r.launch(
          db: db,
          cli: FakeMemexCli()
            ..onAddDailyCreates(db)
            ..onUpdateWrites(db),
          clock: FakeClock(DateTime(2026, 10, 3, 9)),
        );
        r.expectVirtualToday('2026-10-03');

        await r.type(_body(_longLines));
        await pumpFrames(tester);
        await _scrollTo(tester, _left);
        expect(r.bodyHasFocus, isTrue);

        final jumps = _Jumps(tester);
        await r.waitForSave();

        r.expectRealNoteTab(createdDailyId);
        expect(jumps.values, isEmpty);
        expect(_pixels(tester), _left);
        expect(r.bodyHasFocus, isTrue, reason: 'typing goes on');

        // The offset followed the entry from the virtual note to the real one.
        await _navigate(tester, h, const NoteTab(_l1));
        await _back(tester, h);
        expect(h.tabState.activeTab, const NoteTab(createdDailyId));
        expect(_pixels(tester), _left);
      },
    );
  });

  group('source mode', () {
    testWidgets('source mode records no offset', (tester) async {
      final h = await _launch(tester);
      await _navigate(tester, h, const NoteTab(_l1));
      await _toggleSource(tester);
      expect(_sourceSurface, findsOneWidget);
      await _scrollTo(tester, _left);
      await _navigate(tester, h, const NoteTab(_l2));
      await _scrollTo(tester, _other);

      await _back(tester, h);

      expect(_sourceSurface, findsNothing);
      expect(_pixels(tester), 0.0, reason: 'nothing was recorded in Source');

      await _forward(tester, h);
      expect(_pixels(tester), _other, reason: 'the normal view still records');
    });

    testWidgets(
      'scrolling in source mode keeps the offset recorded before it',
      (tester) async {
        final h = await _launch(tester);
        await _navigate(tester, h, const NoteTab(_l1));
        await _scrollTo(tester, _left);
        await _toggleSource(tester);
        await _scrollTo(tester, _other);
        await _navigate(tester, h, const NoteTab(_l2));

        await _back(tester, h);

        expect(_sourceSurface, findsNothing);
        expect(_pixels(tester), _left);
      },
    );

    testWidgets(
      'back or forward to a note left in source mode shows the normal view',
      (tester) async {
        final h = await _launch(tester);
        await _navigate(tester, h, const NoteTab(_l1));
        await _scrollTo(tester, _left);
        await _navigate(tester, h, const NoteTab(_l2));
        await _scrollTo(tester, _other);
        await _toggleSource(tester);
        expect(_sourceSurface, findsOneWidget);

        await _back(tester, h);
        expect(_sourceSurface, findsNothing, reason: 'Back');
        expect(_pixels(tester), _left);
        await _toggleSource(tester);
        expect(_sourceSurface, findsOneWidget);

        await _forward(tester, h);
        expect(_sourceSurface, findsNothing, reason: 'Forward');
        expect(_pixels(tester), _other);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a chip switch between two tabs on one note left in source mode shows the normal view',
      (tester) async {
        final h = await _launch(tester);
        await _twoTabsOnOneNote(tester, h);
        await _scrollTo(tester, _other);
        await _chip(tester, h, 0);
        await _scrollTo(tester, _left);
        await _toggleSource(tester);
        expect(_sourceSurface, findsOneWidget);

        await _chip(tester, h, 1);

        expect(_sourceSurface, findsNothing);
        expect(_pixels(tester), _other);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'toggling source and back on one note causes no report that moves the offset',
      (tester) async {
        final h = await _launch(tester);
        await _navigate(tester, h, const NoteTab(_l1));
        await _scrollTo(tester, _left);
        await _toggleSource(tester);
        await _toggleSource(tester);
        expect(_sourceSurface, findsNothing);
        await _navigate(tester, h, const NoteTab(_l2));

        await _back(tester, h);

        expect(_pixels(tester), _left);
      },
    );
  });

  group('canvas and Graph views', () {
    testWidgets('a canvas pan and zoom come back on back', (tester) async {
      final db = seedCanvasFixture(FakeVaultDb.v5());
      final h = await _launch(tester, db: db);
      const canvas = CanvasTab(C89.newer);
      await _navigate(tester, h, canvas);
      await pumpFrames(tester);
      final viewer = find.byType(InteractiveViewer);
      Matrix4 shown() => tester
          .widget<InteractiveViewer>(viewer)
          .transformationController!
          .value;
      final before = shown().clone();

      await tester.drag(viewer, const Offset(-40, -25));
      await pumpFrames(tester);
      final panned = shown().clone();
      expect(panned, isNot(before), reason: 'the drag panned the canvas');

      await _navigate(tester, h, const NoteTab(C89.alpha));
      expect(viewer, findsNothing);
      await _back(tester, h);
      expect(h.tabState.activeTab, canvas);
      expect(shown(), panned, reason: 'the pan came back');

      const zoomed = CanvasViewport(offset: Offset(-10, -5), zoom: 1.5);
      h.read(canvasViewportProvider(C89.newer).notifier).state = zoomed;
      await _forward(tester, h);
      expect(viewer, findsNothing);
      await _back(tester, h);
      expect(shown().getMaxScaleOnAxis(), zoomed.zoom);
      expect(shown().getTranslation().x, zoomed.offset.dx);
      expect(shown().getTranslation().y, zoomed.offset.dy);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a graph view lays itself out afresh on back', (tester) async {
      final db = FakeVaultDb.v5();
      seedGraphFixture(db);
      final h = await _launch(tester, db: db);
      await _navigate(tester, h, GraphTab(const GraphScope.topic(G.alpha)));
      expect(find.byType(GraphView), findsOneWidget);
      final first = tester.state(find.byType(GraphView));

      await _navigate(tester, h, const NoteTab(G.beta));
      expect(find.byType(GraphView), findsNothing);
      await _back(tester, h);

      expect(find.byType(GraphView), findsOneWidget);
      expect(
        tester.state(find.byType(GraphView)),
        isNot(same(first)),
        reason: 'a new view, so a new layout',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('a bare EditorPage', () {
    testWidgets(
      'an EditorPage with no scroll scope above it builds and scrolls on its own',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: EditorPage(body: SizedBox(height: 5000))),
          ),
        );

        await _scrollTo(tester, _left);

        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'an EditorScrollScope hands a replaced controller to the page below it',
      (tester) async {
        final first = ScrollController();
        final second = ScrollController();
        addTearDown(first.dispose);
        addTearDown(second.dispose);
        const page = EditorPage(body: SizedBox(height: 5000));
        Widget app(ScrollController controller) => MaterialApp(
          home: Scaffold(
            body: EditorScrollScope(controller: controller, child: page),
          ),
        );

        await tester.pumpWidget(app(first));
        expect(first.hasClients, isTrue, reason: 'the page uses the scope');
        expect(second.hasClients, isFalse);

        await tester.pumpWidget(app(second));
        expect(second.hasClients, isTrue, reason: 'the page took the new one');
        expect(first.hasClients, isFalse);

        await tester.pumpWidget(app(second));
        expect(second.hasClients, isTrue, reason: 'the same one stays');
        second.jumpTo(_left);
        await tester.pump();
        expect(second.offset, _left);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
