// WI #267 (N4): the Back and Forward buttons pinned at the left of the tab bar,
// and the Cmd+[ and Cmd+] chords (TD8). The chords are a HardwareKeyboard
// handler, so they fire whatever has focus. `sendKeyEvent` returns whether the
// key was handled, which is the handler's return value when nothing else
// claims the key: true even at the ends of history (so macOS does not beep),
// false for any other chord and while a modal is over the workspace.
//
// Every step is read from `tabsProvider`, never from tab counts. Each test
// pumps the whole app with a FakeVaultDb that holds the notes the history
// visits, so the TD9 existence check never removes an entry.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';

import '../support/app_harness.dart';
import '../support/canvas_seeds.dart';
import '../support/fake_vault_db.dart';
import '../support/segment_editing_finder.dart';

const _aId = '01J9NOTEA00000000000000267';
const _bId = '01J9NOTEB00000000000000267';
const _cId = '01J9NOTEC00000000000000267';
const _dId = '01J9NOTED00000000000000267';
const _eId = '01J9NOTEE00000000000000267';
const _a = NoteTab(_aId);
const _b = NoteTab(_bId);
const _c = NoteTab(_cId);
const _d = NoteTab(_dId);
const _e = NoteTab(_eId);

const _backKey = Key('nav-back-button');
const _forwardKey = Key('nav-forward-button');
const _barKey = Key('workspace-tab-bar');

Finder get _back => find.byKey(_backKey);
Finder get _forward => find.byKey(_forwardKey);
Finder get _bar => find.byKey(_barKey);
Finder _chip(WorkspaceTab tab) => find.byKey(Key('tab-${tab.tabId}'));

const _meta = LogicalKeyboardKey.metaLeft;
const _metaRight = LogicalKeyboardKey.metaRight;
const _shift = LogicalKeyboardKey.shiftLeft;
const _ctrl = LogicalKeyboardKey.controlLeft;
const _alt = LogicalKeyboardKey.altLeft;
const _left = LogicalKeyboardKey.bracketLeft;
const _right = LogicalKeyboardKey.bracketRight;

FakeVaultDb _vault() {
  final db = FakeVaultDb.v5();
  for (final (id, title) in [
    (_aId, 'Alpha'),
    (_bId, 'Beta'),
    (_cId, 'Gamma'),
    (_dId, 'Delta'),
    (_eId, 'Epsilon'),
  ]) {
    db.seedNote(id: id, title: title, content: '$title body', version: 2);
  }
  return db;
}

extension on WorkspaceHarness {
  TabsNotifier get tabs => read(tabsProvider.notifier);
  TabsState get state => read(tabsProvider);
  EditorStateValue get editor => read(editorControllerProvider);
  WorkspaceTab? get active => state.activeTab;
}

/// The app with a note tab whose Tab history is `A, B, C`, showing [at]
/// entries from the start: 0 is A (the start), 1 is B (the middle), 2 is C.
/// The launch's Today tab sits to its left.
Future<WorkspaceHarness> _onHistory(
  WidgetTester tester, {
  int at = 2,
  FakeVaultDb? db,
}) async {
  final h = await pumpWorkspace(tester, db: db ?? _vault());
  h.tabs.openOrFocus(_a);
  h.tabs
    ..navigate(_b)
    ..navigate(_c);
  for (var i = 2; i > at; i--) {
    h.tabs.back();
  }
  await pumpFrames(tester);
  return h;
}

/// Press [key] with [mods] held and return whether the key down was handled.
Future<bool> _chord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  List<LogicalKeyboardKey> mods = const [_meta],
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

void _unfocus() => FocusManager.instance.primaryFocus?.unfocus();

OmButton _button(WidgetTester tester, Finder f) => tester.widget<OmButton>(f);

/// The widgets in the bar that paint a flat [OmColors.line1] fill.
Finder get _line1Fills => find.descendant(
  of: _bar,
  matching: find.byWidgetPredicate((w) {
    if (w is ColoredBox) return w.color == OmColors.line1;
    if (w is VerticalDivider) return w.color == OmColors.line1;
    if (w is DecoratedBox) {
      final d = w.decoration;
      return d is BoxDecoration && d.color == OmColors.line1;
    }
    return false;
  }, description: 'a flat OmColors.line1 fill'),
);

void main() {
  group('the buttons in the bar (AC1, AC2)', () {
    testWidgets(
      'the back and forward buttons sit left of the chips at 24 by 24 inside the 32 px bar',
      (tester) async {
        final h = await _onHistory(tester, at: 1);

        expect(_bar, findsOneWidget);
        expect(_back, findsOneWidget);
        expect(_forward, findsOneWidget);
        final bar = tester.getRect(_bar);
        expect(bar.height, 32);
        for (final f in [_back, _forward]) {
          expect(tester.getSize(f), const Size(24, 24));
          final r = tester.getRect(f);
          expect(r.top, greaterThanOrEqualTo(bar.top));
          expect(r.bottom, lessThanOrEqualTo(bar.bottom));
          expect(r.left, greaterThanOrEqualTo(bar.left));
        }
        final firstChip = tester.getRect(_chip(h.state.tabs.first));
        expect(
          tester.getRect(_back).right,
          lessThanOrEqualTo(tester.getRect(_forward).left),
          reason: 'Back is left of Forward',
        );
        expect(
          tester.getRect(_forward).right,
          lessThanOrEqualTo(firstChip.left),
          reason: 'both buttons are left of the chips',
        );
      },
    );

    testWidgets('the back and forward buttons show their icons and tooltips', (
      tester,
    ) async {
      await _onHistory(tester, at: 1);

      expect(
        find.descendant(
          of: _back,
          matching: find.byIcon(LucideIcons.arrowLeft),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _forward,
          matching: find.byIcon(LucideIcons.arrowRight),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Tooltip>(
              find.descendant(of: _back, matching: find.byType(Tooltip)),
            )
            .message,
        'Back ⌘[',
      );
      expect(
        tester
            .widget<Tooltip>(
              find.descendant(of: _forward, matching: find.byType(Tooltip)),
            )
            .message,
        'Forward ⌘]',
      );
      for (final f in [_back, _forward]) {
        expect(_button(tester, f).kind, OmButtonKind.ghost);
        expect(_button(tester, f).size, 24);
      }
    });

    testWidgets(
      'scrolling the chips does not move the buttons or the 1 px line1 separator',
      (tester) async {
        final db = _vault();
        for (var i = 0; i < 30; i++) {
          db.seedNote(id: 'wide-$i', title: 'A fairly long note title $i');
        }
        final h = await _onHistory(tester, at: 1, db: db);
        for (var i = 0; i < 30; i++) {
          h.tabs.openOrFocus(NoteTab('wide-$i'));
        }
        await pumpFrames(tester);
        h.tabs.setActive(1);
        await pumpFrames(tester);

        final backBefore = tester.getRect(_back);
        final forwardBefore = tester.getRect(_forward);
        expect(_line1Fills, findsOneWidget, reason: 'one separator');
        final separatorBefore = tester.getRect(_line1Fills);
        expect(separatorBefore.width, 1);
        expect(separatorBefore.left, greaterThanOrEqualTo(forwardBefore.right));
        final chipsList = find.descendant(
          of: _bar,
          matching: find.byType(ListView),
        );
        expect(chipsList, findsOneWidget);
        final chipBefore = tester.getRect(_chip(h.state.tabs[1]));
        expect(
          chipBefore.left,
          greaterThanOrEqualTo(separatorBefore.right),
          reason: 'the chips start after the separator',
        );

        await tester.drag(chipsList, const Offset(-400, 0));
        await pumpFrames(tester);

        expect(
          tester.getRect(_chip(h.state.tabs[1])),
          isNot(chipBefore),
          reason: 'the chips scrolled',
        );
        expect(tester.getRect(_back), backBefore);
        expect(tester.getRect(_forward), forwardBefore);
        expect(tester.getRect(_line1Fills), separatorBefore);
      },
    );
  });

  group('the buttons step the history (AC3, AC4, AC5)', () {
    testWidgets(
      'pressing back and forward moves a note tab through its history',
      (tester) async {
        final h = await _onHistory(tester, at: 2);
        expect(h.active, _c);

        await tester.tap(_back);
        await pumpFrames(tester);
        expect(h.active, _b);
        expect(h.editor.title, 'Beta', reason: 'the editor follows the tab');

        await tester.tap(_back);
        await pumpFrames(tester);
        expect(h.active, _a);

        await tester.tap(_forward);
        await pumpFrames(tester);
        expect(h.active, _b);

        await tester.tap(_forward);
        await pumpFrames(tester);
        expect(h.active, _c);
      },
    );

    testWidgets(
      'pressing back and forward moves a canvas tab through its history',
      (tester) async {
        final db = seedCanvasFixture(FakeVaultDb.v5());
        final h = await pumpWorkspace(tester, db: db);
        final canvas = CanvasTab(C89.newer);
        h.tabs.openOrFocus(canvas);
        h.tabs.navigate(NoteTab(C89.alpha));
        await pumpFrames(tester);
        expect(h.active, NoteTab(C89.alpha));

        await tester.tap(_back);
        await pumpFrames(tester);
        expect(h.active, canvas);

        await tester.tap(_forward);
        await pumpFrames(tester);
        expect(h.active, NoteTab(C89.alpha));
      },
    );

    testWidgets(
      'pressing back and forward moves a graph tab through its history',
      (tester) async {
        final h = await pumpWorkspace(tester, db: _vault());
        final graph = GraphTab(const GraphScope.vault());
        h.tabs.openOrFocus(graph);
        h.tabs.navigate(_a);
        await pumpFrames(tester);
        expect(h.active, _a);

        await tester.tap(_back);
        await pumpFrames(tester);
        expect(h.active, graph);

        await tester.tap(_forward);
        await pumpFrames(tester);
        expect(h.active, _a);
      },
    );

    testWidgets(
      'at the start of the history back is dimmed with no click cursor and a tap does nothing',
      (tester) async {
        final h = await _onHistory(tester, at: 0);

        expect(_back, findsOneWidget, reason: 'shown, not hidden');
        expect(_button(tester, _back).onPressed, isNull);
        expect(_button(tester, _forward).onPressed, isNotNull);
        expect(
          tester
              .widget<Opacity>(
                find.descendant(of: _back, matching: find.byType(Opacity)),
              )
              .opacity,
          0.4,
        );
        await tester.tap(_back);
        await pumpFrames(tester);
        expect(h.active, _a);
        expect(h.state.canGoBack, isFalse);
        expect(h.state.canGoForward, isTrue);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: tester.getCenter(_back));
        await tester.pump();
        expect(
          tester.binding.mouseTracker.debugDeviceActiveCursor(1),
          isNot(SystemMouseCursors.click),
        );
        await mouse.moveTo(tester.getCenter(_forward));
        await tester.pump();
        expect(
          tester.binding.mouseTracker.debugDeviceActiveCursor(1),
          SystemMouseCursors.click,
          reason: 'the enabled neighbour keeps its click cursor',
        );
      },
    );

    testWidgets(
      'at the end of the history forward is dimmed with no click cursor and a tap does nothing',
      (tester) async {
        final h = await _onHistory(tester, at: 2);

        expect(_forward, findsOneWidget, reason: 'shown, not hidden');
        expect(_button(tester, _forward).onPressed, isNull);
        expect(_button(tester, _back).onPressed, isNotNull);
        expect(
          tester
              .widget<Opacity>(
                find.descendant(of: _forward, matching: find.byType(Opacity)),
              )
              .opacity,
          0.4,
        );
        await tester.tap(_forward);
        await pumpFrames(tester);
        expect(h.active, _c);
        expect(h.state.canGoForward, isFalse);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: tester.getCenter(_forward));
        await tester.pump();
        expect(
          tester.binding.mouseTracker.debugDeviceActiveCursor(1),
          isNot(SystemMouseCursors.click),
        );
        await mouse.moveTo(tester.getCenter(_back));
        await tester.pump();
        expect(
          tester.binding.mouseTracker.debugDeviceActiveCursor(1),
          SystemMouseCursors.click,
          reason: 'the enabled neighbour keeps its click cursor',
        );
      },
    );

    testWidgets('in the middle of the history both buttons are enabled', (
      tester,
    ) async {
      await _onHistory(tester, at: 1);

      expect(_button(tester, _back).onPressed, isNotNull);
      expect(_button(tester, _forward).onPressed, isNotNull);
    });

    testWidgets(
      'each button enables and disables as a chip switch moves to a tab with a different history',
      (tester) async {
        final h = await _onHistory(tester, at: 2); // B-tab: A, B, C at C.
        final todayTab = h.state.tabs.first;
        final historyTab = h.state.activeTab!;
        // A second tab in the middle of nothing: D, then back from E is not
        // possible, so give it D -> A and step back to D (forward only).
        h.tabs.openOrFocus(_d);
        h.tabs.navigate(_e);
        await pumpFrames(tester);
        h.tabs.back();
        await pumpFrames(tester);
        expect(h.active, _d);
        expect(
          _button(tester, _back).onPressed,
          isNull,
          reason: 'D tab: start',
        );
        expect(_button(tester, _forward).onPressed, isNotNull);

        await tester.tap(_chip(historyTab));
        await pumpFrames(tester);
        expect(
          _button(tester, _back).onPressed,
          isNotNull,
          reason: 'history tab',
        );
        expect(_button(tester, _forward).onPressed, isNull);

        await tester.tap(_chip(todayTab));
        await pumpFrames(tester);
        expect(_button(tester, _back).onPressed, isNull, reason: 'Today tab');
        expect(_button(tester, _forward).onPressed, isNull);

        await tester.tap(_chip(_d));
        await pumpFrames(tester);
        expect(_button(tester, _back).onPressed, isNull, reason: 'D tab again');
        expect(_button(tester, _forward).onPressed, isNotNull);
      },
    );
  });

  group('the Cmd+[ and Cmd+] chords (AC6 to AC13)', () {
    testWidgets(
      'Cmd+[ steps the active tab back while an editor row has focus and is handled',
      (tester) async {
        final h = await _onHistory(tester, at: 1);
        await focusSegmentAt(tester, find.byKey(editorBodyKey));
        expect(h.active, _b);

        final handled = await _chord(tester, _left);

        expect(handled, isTrue, reason: 'no bracket reaches the note');
        expect(h.active, _a);
        expect(h.editor.contentMd, 'Alpha body');
        expect(h.editor.contentMd, isNot(contains('[')));
      },
    );

    testWidgets(
      'Cmd+] steps the active tab forward while an editor row has focus and is handled',
      (tester) async {
        final h = await _onHistory(tester, at: 1);
        await focusSegmentAt(tester, find.byKey(editorBodyKey));
        expect(h.active, _b);

        final handled = await _chord(tester, _right);

        expect(handled, isTrue, reason: 'no bracket reaches the note');
        expect(h.active, _c);
        expect(h.editor.contentMd, 'Gamma body');
        expect(h.editor.contentMd, isNot(contains(']')));
      },
    );

    testWidgets('Cmd+[ steps the active tab back with nothing focused', (
      tester,
    ) async {
      final h = await _onHistory(tester, at: 1);
      _unfocus();
      await tester.pump();

      final handled = await _chord(tester, _left);

      expect(handled, isTrue);
      expect(h.active, _a);
      expect(h.state.canGoBack, isFalse);
      expect(h.state.canGoForward, isTrue);
    });

    testWidgets('Cmd+] steps the active tab forward with nothing focused', (
      tester,
    ) async {
      final h = await _onHistory(tester, at: 1);
      _unfocus();
      await tester.pump();

      final handled = await _chord(tester, _right, mods: [_metaRight]);

      expect(handled, isTrue);
      expect(h.active, _c);
      expect(h.state.canGoBack, isTrue);
      expect(h.state.canGoForward, isFalse);
    });

    testWidgets('the chord steps one entry per press', (tester) async {
      final h = await _onHistory(tester, at: 2);
      _unfocus();
      await tester.pump();

      await _chord(tester, _left);
      expect(h.active, _b);
      await _chord(tester, _left);
      expect(h.active, _a);
      await _chord(tester, _right);
      expect(h.active, _b);
    });

    testWidgets(
      'a held chord steps once because a key repeat does not step again',
      (tester) async {
        final h = await _onHistory(tester, at: 2);
        _unfocus();
        await tester.pump();

        await tester.sendKeyDownEvent(_meta, platform: 'macos');
        await tester.sendKeyDownEvent(_left, platform: 'macos');
        await pumpFrames(tester);
        expect(h.active, _b, reason: 'the key down stepped once');
        await tester.sendKeyRepeatEvent(_left, platform: 'macos');
        await tester.sendKeyRepeatEvent(_left, platform: 'macos');
        await pumpFrames(tester);
        await tester.sendKeyUpEvent(_left, platform: 'macos');
        await tester.sendKeyUpEvent(_meta, platform: 'macos');
        await pumpFrames(tester);

        expect(h.active, _b, reason: 'repeats did not step');
      },
    );

    testWidgets(
      'a held forward chord steps once because a key repeat does not step again',
      (tester) async {
        final h = await _onHistory(tester, at: 0);
        _unfocus();
        await tester.pump();

        await tester.sendKeyDownEvent(_meta, platform: 'macos');
        await tester.sendKeyDownEvent(_right, platform: 'macos');
        await pumpFrames(tester);
        expect(h.active, _b, reason: 'the key down stepped once');
        await tester.sendKeyRepeatEvent(_right, platform: 'macos');
        await pumpFrames(tester);
        await tester.sendKeyUpEvent(_right, platform: 'macos');
        await tester.sendKeyUpEvent(_meta, platform: 'macos');
        await pumpFrames(tester);

        expect(h.active, _b, reason: 'the repeat did not step');
      },
    );

    testWidgets(
      'with a modal dialog open the chord does not step and is not handled',
      (tester) async {
        final h = await _onHistory(tester, at: 1);
        _unfocus();
        final context = tester.element(find.byType(Workspace));
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(content: Text('a modal')),
        );
        await pumpFrames(tester);
        expect(find.text('a modal'), findsOneWidget);

        expect(await _chord(tester, _left), isFalse);
        expect(await _chord(tester, _right), isFalse);
        expect(h.active, _b, reason: 'neither direction stepped');

        Navigator.of(tester.element(find.text('a modal'))).pop();
        await pumpFrames(tester);
        expect(find.text('a modal'), findsNothing);
        _unfocus();
        expect(await _chord(tester, _left), isTrue, reason: 'modal closed');
        expect(h.active, _a);
      },
    );

    testWidgets(
      'at the start of the history Cmd+[ does nothing and is still handled',
      (tester) async {
        final h = await _onHistory(tester, at: 0);
        _unfocus();
        await tester.pump();

        final handled = await _chord(tester, _left);

        expect(handled, isTrue, reason: 'handled so macOS does not beep');
        expect(h.active, _a);
        expect(h.state.canGoForward, isTrue);
      },
    );

    testWidgets(
      'at the end of the history Cmd+] does nothing and is still handled',
      (tester) async {
        final h = await _onHistory(tester, at: 2);
        _unfocus();
        await tester.pump();

        final handled = await _chord(tester, _right);

        expect(handled, isTrue, reason: 'handled so macOS does not beep');
        expect(h.active, _c);
        expect(h.state.canGoBack, isTrue);
      },
    );

    for (final (name, mods, key)
        in <(String, List<LogicalKeyboardKey>, LogicalKeyboardKey)>[
          ('a plain left bracket does not step and is not handled', [], _left),
          (
            'a plain right bracket does not step and is not handled',
            [],
            _right,
          ),
          ('Ctrl+[ does not step and is not handled', [_ctrl], _left),
          ('Ctrl+] does not step and is not handled', [_ctrl], _right),
          (
            'Cmd+Shift+[ does not step and is not handled',
            [_meta, _shift],
            _left,
          ),
          (
            'Cmd+Shift+] does not step and is not handled',
            [_meta, _shift],
            _right,
          ),
          (
            'Cmd+Option+[ does not step and is not handled',
            [_meta, _alt],
            _left,
          ),
          (
            'Cmd+Option+] does not step and is not handled',
            [_meta, _alt],
            _right,
          ),
          (
            'Cmd+Ctrl+[ does not step and is not handled',
            [_meta, _ctrl],
            _left,
          ),
          (
            'Cmd+Ctrl+] does not step and is not handled',
            [_meta, _ctrl],
            _right,
          ),
          (
            'Cmd plus another key does not step and is not handled',
            [_meta],
            LogicalKeyboardKey.keyK,
          ),
        ]) {
      testWidgets(name, (tester) async {
        final h = await _onHistory(tester, at: 1);
        _unfocus();
        await tester.pump();

        final handled = await _chord(tester, key, mods: mods);

        expect(handled, isFalse);
        expect(h.active, _b);
      });
    }

    testWidgets('releasing the chord keys is not handled and does not step', (
      tester,
    ) async {
      final h = await _onHistory(tester, at: 1);
      _unfocus();
      await tester.pump();

      await tester.sendKeyDownEvent(_meta, platform: 'macos');
      expect(await tester.sendKeyDownEvent(_left, platform: 'macos'), isTrue);
      expect(h.active, _a, reason: 'the key down stepped once');
      expect(
        await tester.sendKeyUpEvent(_left, platform: 'macos'),
        isFalse,
        reason: 'only the key down is claimed',
      );
      expect(await tester.sendKeyUpEvent(_meta, platform: 'macos'), isFalse);
      await pumpFrames(tester);

      expect(h.active, _a, reason: 'the releases did not step');
      // A repeat of a key that is not a bracket is not claimed either.
      await tester.sendKeyDownEvent(_meta, platform: 'macos');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK, platform: 'macos');
      expect(
        await tester.sendKeyRepeatEvent(
          LogicalKeyboardKey.keyK,
          platform: 'macos',
        ),
        isFalse,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK, platform: 'macos');
      await tester.sendKeyUpEvent(_meta, platform: 'macos');
      await pumpFrames(tester);
      expect(h.active, _a);
    });

    testWidgets(
      'a plain left bracket with an editor row focused is left to the note',
      (tester) async {
        final h = await _onHistory(tester, at: 1);
        await focusSegmentAt(tester, find.byKey(editorBodyKey));

        final handled = await _chord(tester, _left, mods: const []);

        expect(handled, isFalse, reason: 'the platform delivers the bracket');
        expect(h.active, _b);
        expect(h.editor.contentMd, 'Beta body');
      },
    );

    testWidgets(
      'with no tabs open the bar is blank with no buttons and the chord is handled but steps nothing',
      (tester) async {
        final h = await _onHistory(tester, at: 1);
        while (h.state.tabs.isNotEmpty) {
          h.tabs.closeAt(0);
        }
        await pumpFrames(tester);
        _unfocus();

        expect(_back, findsNothing);
        expect(_forward, findsNothing);
        expect(
          find.byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('tab-'),
          ),
          findsNothing,
          reason: 'no chips',
        );
        expect(await _chord(tester, _left), isTrue);
        expect(await _chord(tester, _right), isTrue);
        expect(h.state.tabs, isEmpty);
      },
    );

    testWidgets(
      'after the workspace is disposed the handler is gone and the chord does not step',
      (tester) async {
        final h = await _onHistory(tester, at: 2);
        _unfocus();
        await tester.pump();
        expect(await _chord(tester, _left), isTrue);
        expect(h.active, _b, reason: 'the handler works while mounted');

        await tester.pumpWidget(const SizedBox());
        await tester.pump();

        expect(await _chord(tester, _left), isFalse);
        expect(await _chord(tester, _right), isFalse);
        expect(h.active, _b, reason: 'no step once the workspace is gone');
      },
    );
  });
}
