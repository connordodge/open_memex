// WI #70 (54-O4, Spec #58 R27, TD7; rulings D12, D13, D16): the Cmd+Shift+O
// chord. A HardwareKeyboard handler mounted in the workspace, so it fires
// whatever has focus. `sendKeyEvent` returns whether the key down was
// handled: true for exactly Cmd+Shift+O (and its repeats, which do nothing),
// false for any other chord and while a modal route is over the workspace.
// The #59 command palette does not exist yet: a root-navigator `showDialog`
// stands in for it (D13). Chord tests live here only, never in
// `tab_bar_history_buttons_test.dart` (D16).
//
// Each "not handled" test ends with a control press of the real chord, so
// it can only pass once the handler exists.
//
// Never pumpAndSettle the workspace (OmDot pulses forever): pumpFrames only.
// Test names use no apostrophes.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';
import 'package:open_memex_app/src/state/right_panel_tab.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/editor/segment_editing.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';

import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/segment_editing_finder.dart';
import '../support/wi70_outline.dart';

const _keyO = LogicalKeyboardKey.keyO;

extension on NoteRevealHarness {
  bool get panelOpen => read(rightPanelOpenProvider);
  RightPanelTab get panelTab => read(rightPanelTabProvider);
}

/// The Outline shows, with focus on row [i].
void _wi70ExpectOutlineOn(NoteRevealHarness h, int i, {String? reason}) {
  expect(h.panelOpen, isTrue, reason: '$reason: the right panel is open');
  expect(h.panelTab, RightPanelTab.outline, reason: '$reason: on outline');
  wi70ExpectOutlineFocus(h.tester, i, reason: reason);
}

/// The Outline did not open: the panel and its tab are as before.
void _wi70ExpectUntouched(
  NoteRevealHarness h, {
  required bool panelOpen,
  RightPanelTab tab = RightPanelTab.connections,
}) {
  expect(h.panelOpen, panelOpen, reason: 'the panel did not change');
  expect(h.panelTab, tab, reason: 'the tab did not change');
  expect(wi70FocusInOutline(), isFalse, reason: 'no focus in the Outline');
}

/// The handle of the editor body.
SegmentEditing _wi70Body(WidgetTester tester) => editorBodySegment(tester);

void main() {
  holdFontFetches();

  group('opening the Outline', () {
    testWidgets(
      'Cmd+Shift+O with the right panel closed opens it on outline and focuses the current entry',
      (tester) async {
        final h = await pumpWi70(tester, panelOpen: false);
        expect(find.byType(Sidebar), findsOneWidget);
        await wi70PutCurrent(h, 10);
        wi70Unfocus();
        await tester.pump();

        expect(await wi70OutlineChord(tester), isTrue, reason: 'handled');
        await pumpFrames(tester);

        expect(wi70ExpectedCurrent(h), 10, reason: 'the page did not move');
        _wi70ExpectOutlineOn(h, 10, reason: 'the current entry');
        expect(wi70CurrentRows(tester), [10]);
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+Shift+O with the connections tab showing switches to outline and focuses the current entry',
      (tester) async {
        final h = await pumpWi70(tester);
        expect(h.panelOpen, isTrue);
        expect(h.panelTab, RightPanelTab.connections);
        await wi70PutCurrent(h, 4);
        wi70Unfocus();
        await tester.pump();

        expect(await wi70OutlineChord(tester), isTrue);
        await pumpFrames(tester);

        _wi70ExpectOutlineOn(h, 4, reason: 'the current entry');
        expect(wi70CurrentRows(tester), [4]);
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+Shift+O with the outline tab already showing focuses the current entry',
      (tester) async {
        final h = await pumpWi70(tester, tab: RightPanelTab.outline);
        await wi70PutCurrent(h, 7);
        wi70Unfocus();
        await tester.pump();
        expect(wi70FocusedRows(tester), isEmpty, reason: 'no ring yet');

        expect(await wi70OutlineChord(tester), isTrue);
        await pumpFrames(tester);

        _wi70ExpectOutlineOn(h, 7, reason: 'the current entry');
      },
      variant: macOnly,
    );

    testWidgets('Cmd+Shift+O with no current entry focuses the first entry', (
      tester,
    ) async {
      final h = await pumpWi70(tester, panelOpen: false);
      expect(h.pixels(), 0);
      expect(wi70ExpectedCurrent(h), isNull, reason: 'above the first');

      expect(await wi70OutlineChord(tester), isTrue);
      await pumpFrames(tester);

      _wi70ExpectOutlineOn(h, 0, reason: 'the first entry');
      expect(wi70CurrentRows(tester), isEmpty, reason: 'none is current');
    }, variant: macOnly);

    testWidgets(
      'Cmd+Shift+O on a note with no headings opens the outline tab and leaves focus where it was',
      (tester) async {
        final h = await pumpWi70(tester, open: wi70FlatId, panelOpen: false);
        await focusSegmentAt(tester, find.byKey(editorBodyKey), offset: 12);
        final focused = FocusManager.instance.primaryFocus;
        final selection = _wi70Body(tester).selection;
        expect(selection, const TextSelection.collapsed(offset: 12));

        expect(await wi70OutlineChord(tester), isTrue, reason: 'handled');
        await pumpFrames(tester);

        expect(h.panelOpen, isTrue, reason: 'the panel opened');
        expect(h.panelTab, RightPanelTab.outline, reason: 'on outline');
        expect(find.byKey(const Key('outline-empty')), findsOneWidget);
        expect(
          FocusManager.instance.primaryFocus,
          same(focused),
          reason: 'focus did not move',
        );
        expect(_wi70Body(tester).selection, selection);
        expect(wi70FocusInOutline(), isFalse);
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+Shift+O when the Outline already has focus on another row moves focus back to the current entry',
      (tester) async {
        final h = await pumpWi70(tester);
        await wi70PutCurrent(h, 6);
        expect(await wi70OutlineChord(tester), isTrue);
        _wi70ExpectOutlineOn(h, 6, reason: 'first press');
        await wi70Press(tester, LogicalKeyboardKey.arrowUp, times: 3);
        wi70ExpectOutlineFocus(tester, 3, reason: 'moved up');

        expect(await wi70OutlineChord(tester), isTrue);
        await pumpFrames(tester);

        _wi70ExpectOutlineOn(h, 6, reason: 'second press');
      },
      variant: macOnly,
    );

    testWidgets(
      'with the find bar open Cmd+Shift+O focuses the Outline and the find bar stays open',
      (tester) async {
        final h = await pumpWi70(tester);
        h.read(findInNoteProvider.notifier).show();
        await pumpFrames(tester);
        expect(h.read(findInNoteProvider).open, isTrue, reason: 'fixture');

        expect(await wi70OutlineChord(tester), isTrue);
        await pumpFrames(tester);

        _wi70ExpectOutlineOn(h, 0, reason: 'the first entry');
        expect(
          h.read(findInNoteProvider).open,
          isTrue,
          reason: 'focusing the Outline leaves the find bar open (D13)',
        );
      },
      variant: macOnly,
    );
  });

  group('wherever focus is', () {
    for (final (name, setUpFocus)
        in <(String, Future<void> Function(WidgetTester))>[
          (
            'Cmd+Shift+O works with focus in the editor body',
            (tester) async {
              await focusSegmentAt(
                tester,
                find.byKey(editorBodyKey),
                offset: 3,
              );
              expect(
                wi70FocusWithin(tester, find.byKey(editorBodyKey)),
                isTrue,
                reason: 'fixture: focus in the body',
              );
            },
          ),
          (
            'Cmd+Shift+O works with focus in the note title field',
            (tester) async {
              await tester.showKeyboard(find.byKey(const Key('editor-title')));
              await tester.pump();
              expect(
                wi70FocusWithin(tester, find.byKey(const Key('editor-title'))),
                isTrue,
                reason: 'fixture: focus in the title',
              );
            },
          ),
          ('Cmd+Shift+O works with focus in the sidebar', wi70FocusSidebar),
          (
            'Cmd+Shift+O works with nothing focused',
            (tester) async {
              wi70Unfocus();
              await tester.pump();
            },
          ),
        ]) {
      testWidgets(name, (tester) async {
        final h = await pumpWi70(tester, panelOpen: false);
        await setUpFocus(tester);
        expect(wi70ExpectedCurrent(h), isNull, reason: 'at the note top');

        expect(await wi70OutlineChord(tester), isTrue, reason: 'handled');
        await pumpFrames(tester);

        _wi70ExpectOutlineOn(h, 0, reason: name);
      }, variant: macOnly);
    }
  });

  group('other chords', () {
    for (final (name, key, mods)
        in <(String, LogicalKeyboardKey, List<LogicalKeyboardKey>)>[
          (
            'Cmd+Shift+Ctrl+O is not handled and the Outline does not open',
            _keyO,
            [wi70Meta, wi70Shift, wi70Ctrl],
          ),
          (
            'Cmd+Shift+Alt+O is not handled and the Outline does not open',
            _keyO,
            [wi70Meta, wi70Shift, wi70Alt],
          ),
          (
            'Cmd+O without Shift is not handled and the Outline does not open',
            _keyO,
            [wi70Meta],
          ),
          (
            'Ctrl+Shift+O is not handled and the Outline does not open',
            _keyO,
            [wi70Ctrl, wi70Shift],
          ),
          (
            'Cmd+Shift+P is not handled and the Outline does not open',
            LogicalKeyboardKey.keyP,
            [wi70Meta, wi70Shift],
          ),
          (
            'Cmd+F is not handled by the Outline handler',
            LogicalKeyboardKey.keyF,
            [wi70Meta],
          ),
          (
            'Cmd+G is not handled by the Outline handler',
            LogicalKeyboardKey.keyG,
            [wi70Meta],
          ),
          (
            'Cmd+E is not handled by the Outline handler',
            LogicalKeyboardKey.keyE,
            [wi70Meta],
          ),
        ]) {
      testWidgets(name, (tester) async {
        final h = await pumpWi70(tester, panelOpen: false);
        wi70Unfocus();
        await tester.pump();

        expect(
          await wi70Chord(tester, key, mods: mods),
          isFalse,
          reason: 'left to the native menu and the focused widget',
        );
        _wi70ExpectUntouched(h, panelOpen: false);

        // Control: the real chord is handled.
        expect(await wi70OutlineChord(tester), isTrue, reason: 'control');
        await pumpFrames(tester);
        _wi70ExpectOutlineOn(h, 0, reason: 'control');
      }, variant: macOnly);
    }

    testWidgets('Cmd+Shift+O with the right Command key is handled', (
      tester,
    ) async {
      final h = await pumpWi70(tester, panelOpen: false);
      wi70Unfocus();
      await tester.pump();

      expect(
        await wi70Chord(
          tester,
          _keyO,
          mods: const [LogicalKeyboardKey.metaRight, wi70Shift],
        ),
        isTrue,
      );
      await pumpFrames(tester);
      _wi70ExpectOutlineOn(h, 0, reason: 'right Command');
    }, variant: macOnly);
  });

  group('modal routes', () {
    testWidgets(
      'Cmd+Shift+O is not handled while a modal dialog shows and the Outline does not open',
      (tester) async {
        final h = await pumpWi70(tester, panelOpen: false);
        wi70Unfocus();
        showDialog<void>(
          context: tester.element(find.byType(Workspace)),
          builder: (_) => const AlertDialog(content: Text('a modal')),
        );
        await pumpFrames(tester);
        expect(find.text('a modal'), findsOneWidget);

        expect(await wi70OutlineChord(tester), isFalse);
        await pumpFrames(tester);
        _wi70ExpectUntouched(h, panelOpen: false);

        Navigator.of(tester.element(find.text('a modal'))).pop();
        await pumpFrames(tester);
        expect(find.text('a modal'), findsNothing);
        wi70Unfocus();
        expect(
          await wi70OutlineChord(tester),
          isTrue,
          reason: 'handled once the modal closed',
        );
        await pumpFrames(tester);
        _wi70ExpectOutlineOn(h, 0, reason: 'modal closed');
      },
      variant: macOnly,
    );

    testWidgets(
      'a key repeat of Cmd+Shift+O is not handled while a modal dialog shows',
      (tester) async {
        final h = await pumpWi70(tester);
        wi70Unfocus();
        showDialog<void>(
          context: tester.element(find.byType(Workspace)),
          builder: (_) => const AlertDialog(content: Text('a modal')),
        );
        await pumpFrames(tester);

        await tester.sendKeyDownEvent(wi70Meta, platform: 'macos');
        await tester.sendKeyDownEvent(wi70Shift, platform: 'macos');
        expect(
          await tester.sendKeyDownEvent(_keyO, platform: 'macos'),
          isFalse,
        );
        expect(
          await tester.sendKeyRepeatEvent(_keyO, platform: 'macos'),
          isFalse,
        );
        await tester.sendKeyUpEvent(_keyO, platform: 'macos');
        await tester.sendKeyUpEvent(wi70Shift, platform: 'macos');
        await tester.sendKeyUpEvent(wi70Meta, platform: 'macos');
        await pumpFrames(tester);
        _wi70ExpectUntouched(h, panelOpen: true);

        Navigator.of(tester.element(find.text('a modal'))).pop();
        await pumpFrames(tester);
        wi70Unfocus();
        expect(await wi70OutlineChord(tester), isTrue, reason: 'control');
      },
      variant: macOnly,
    );
  });

  group('held and released', () {
    testWidgets(
      'holding Cmd+Shift+O acts once and its key repeats are claimed without acting',
      (tester) async {
        final h = await pumpWi70(tester, panelOpen: false);
        wi70Unfocus();
        await tester.pump();

        await tester.sendKeyDownEvent(wi70Meta, platform: 'macos');
        await tester.sendKeyDownEvent(wi70Shift, platform: 'macos');
        expect(await tester.sendKeyDownEvent(_keyO, platform: 'macos'), isTrue);
        await pumpFrames(tester);
        _wi70ExpectOutlineOn(h, 0, reason: 'the key down acted');

        // Undo what the key down did, so a repeat that acts would show.
        h.container.read(rightPanelTabProvider.notifier).state =
            RightPanelTab.connections;
        h.container.read(rightPanelOpenProvider.notifier).state = false;
        wi70Unfocus();
        await pumpFrames(tester);

        expect(
          await tester.sendKeyRepeatEvent(_keyO, platform: 'macos'),
          isTrue,
          reason: 'a repeat is claimed so macOS does not beep',
        );
        expect(
          await tester.sendKeyRepeatEvent(_keyO, platform: 'macos'),
          isTrue,
        );
        await pumpFrames(tester);
        _wi70ExpectUntouched(h, panelOpen: false);

        expect(
          await tester.sendKeyUpEvent(_keyO, platform: 'macos'),
          isFalse,
          reason: 'only the key down and its repeats are claimed',
        );
        await tester.sendKeyUpEvent(wi70Shift, platform: 'macos');
        await tester.sendKeyUpEvent(wi70Meta, platform: 'macos');
        await pumpFrames(tester);
        _wi70ExpectUntouched(h, panelOpen: false);
      },
      variant: macOnly,
    );

    testWidgets('a key repeat of O with Cmd alone held is not claimed', (
      tester,
    ) async {
      final h = await pumpWi70(tester, panelOpen: false);
      wi70Unfocus();
      await tester.pump();

      await tester.sendKeyDownEvent(wi70Meta, platform: 'macos');
      expect(await tester.sendKeyDownEvent(_keyO, platform: 'macos'), isFalse);
      expect(
        await tester.sendKeyRepeatEvent(_keyO, platform: 'macos'),
        isFalse,
      );
      await tester.sendKeyUpEvent(_keyO, platform: 'macos');
      await tester.sendKeyUpEvent(wi70Meta, platform: 'macos');
      await pumpFrames(tester);
      _wi70ExpectUntouched(h, panelOpen: false);

      expect(await wi70OutlineChord(tester), isTrue, reason: 'control');
    }, variant: macOnly);
  });

  group('lifetime', () {
    testWidgets('once the workspace is gone Cmd+Shift+O is no longer handled', (
      tester,
    ) async {
      final h = await pumpWi70(tester, panelOpen: false);
      wi70Unfocus();
      expect(await wi70OutlineChord(tester), isTrue, reason: 'mounted');
      expect(h.read(tabsProvider).activeTab, const NoteTab(wi70KeysId));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      expect(
        await wi70OutlineChord(tester),
        isFalse,
        reason: 'the handler left with the workspace',
      );
      expect(tester.takeException(), isNull);
    }, variant: macOnly);
  });
}
