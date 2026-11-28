// WI #77 (56-A3, Spec #59 reqs 2-3, 6, 40; design pack 77 board C3): the
// Command bar at the top of the sidebar opens the Command palette by click,
// Enter or Space, and draws the rest, hover, open and keyboard-focus states.
//
// The real Workspace pumped as #76's `pumpPaletteHost` body (fakes only, no
// vault on disk), at text scale 0.5 as the app harness pumps it. The bar is
// found by #76's `PaletteKeys.commandBar`; its look is read from the
// bordered box, the label's painted text style and the search icon.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/command_palette_state.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/command_palette/command_palette.dart'
    show paletteShellOverrides;
import 'package:open_memex_app/src/widgets/command_palette/palette_row.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/app_harness.dart'
    show pumpFrames, settingsGetMaxDepthStdout;
import '../../support/fake_memex_cli.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/palette_pump.dart';
import '../../support/token_store_fakes.dart';

const _label = 'search · ask · run';

Finder get _bar => find.byKey(PaletteKeys.commandBar);
Finder get _palette => find.byKey(PaletteKeys.palette);
Finder get _input => find.byKey(PaletteKeys.input);

Future<PaletteHarness> _workspace(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({
    'memex.binary_path': 'fake-memex',
    'memex.recent_vaults': <String>[paletteVaultPath],
    'memex.last_vault': paletteVaultPath,
  });
  final settings = await loadSettingsKeepingPickedBinary();
  final h = await pumpPaletteHost(
    tester,
    textScale: 0.5,
    cli: FakeMemexCli()
      ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout)),
    child: const Workspace(),
    overrides: [
      settingsProvider.overrideWith((_) => settings),
      ...paletteShellOverrides,
    ],
  );
  await pumpFrames(tester);
  expect(_bar, findsOneWidget, reason: 'the sidebar shows the command bar');
  return h;
}

EditableText _field(WidgetTester tester) => tester.widget<EditableText>(
  find.descendant(
    of: _input,
    matching: find.byType(EditableText),
    matchRoot: true,
  ),
);

List<PaletteItemId> _selected() => [
  for (final e in find.byType(PaletteRow, skipOffstage: false).evaluate())
    if ((e.widget as PaletteRow).selected) (e.widget as PaletteRow).item.id,
];

final _newNote = PaletteItemId(
  PaletteItemKind.command,
  PaletteCommand.newNote.name,
);

/// The bar's bordered box (fill and 1 px border).
BoxDecoration _box(WidgetTester tester) {
  expect(_bar, findsOneWidget, reason: 'the sidebar shows the command bar');
  for (final e
      in find
          .descendant(
            of: _bar,
            matching: find.byType(DecoratedBox),
            matchRoot: true,
          )
          .evaluate()) {
    final d = (e.widget as DecoratedBox).decoration;
    if (d is BoxDecoration && d.border != null) return d;
  }
  throw TestFailure('the command bar has no bordered box');
}

Color? _fill(WidgetTester tester) => _box(tester).color;

Color _border(WidgetTester tester) =>
    (_box(tester).border! as Border).top.color;

/// The label's painted colour.
Color? _labelColor(WidgetTester tester) => tester
    .renderObject<RenderParagraph>(
      find.descendant(of: _bar, matching: find.text(_label)),
    )
    .text
    .style
    ?.color;

Color? _iconColor(WidgetTester tester) => tester
    .widget<Icon>(
      find.descendant(of: _bar, matching: find.byIcon(LucideIcons.search)),
    )
    .color;

void _expectRest(WidgetTester tester, {bool border = true}) {
  expect(_fill(tester), OmColors.surface2, reason: 'rest fill');
  if (border) expect(_border(tester), OmColors.line2, reason: 'rest border');
  expect(_labelColor(tester), OmColors.fg2, reason: 'rest label');
  expect(_iconColor(tester), OmColors.fg3, reason: 'rest icon');
}

/// Whether the keyboard focus is on the bar (its own node, or one inside it).
bool _barFocused(WidgetTester tester) {
  final node = FocusManager.instance.primaryFocus;
  final focus = node?.context;
  if (node == null || focus == null) return false;
  final bar = tester.element(_bar);
  if (identical(focus, bar)) return true;
  var hit = false;
  focus.visitAncestorElements((e) {
    if (identical(e, bar)) hit = true;
    return !hit;
  });
  if (hit || node is FocusScopeNode) return hit;
  bar.visitAncestorElements((e) {
    if (identical(e, focus)) hit = true;
    return !hit;
  });
  return hit;
}

/// Tabs from no focus until the bar has it.
Future<void> _tabToBar(WidgetTester tester) async {
  expect(_bar, findsOneWidget, reason: 'the sidebar shows the command bar');
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  for (var i = 0; i < 60 && !_barFocused(tester); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab, platform: 'macos');
    await tester.pump();
  }
  expect(_barFocused(tester), isTrue, reason: 'Tab reaches the command bar');
}

void _expectOpenedEmpty(WidgetTester tester) {
  expect(_palette, findsOneWidget);
  expect(_field(tester).controller.text, isEmpty);
  expect(_field(tester).focusNode.hasFocus, isTrue);
  expect(_selected(), [_newNote]);
}

void main() {
  holdFontFetches();

  testWidgets(
    'clicking the command bar opens the palette with an empty input focused and the first row selected',
    (tester) async {
      await _workspace(tester);
      expect(_bar, findsOneWidget);
      expect(_palette, findsNothing);

      await tester.tap(_bar);
      await pumpFrames(tester);

      _expectOpenedEmpty(tester);
    },
  );

  testWidgets(
    'reopening the palette from the command bar starts again with an empty input',
    (tester) async {
      await _workspace(tester);
      await tester.tap(_bar);
      await pumpFrames(tester);
      await tester.enterText(_input, 'back');
      await pumpFrames(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumpFrames(tester);
      expect(_palette, findsNothing);

      await tester.tap(_bar);
      await pumpFrames(tester);

      _expectOpenedEmpty(tester);
    },
  );

  testWidgets('Tab reaches the command bar and Enter opens the palette', (
    tester,
  ) async {
    await _workspace(tester);
    await _tabToBar(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter, platform: 'macos');
    await pumpFrames(tester);

    _expectOpenedEmpty(tester);
  });

  testWidgets('with focus on the command bar Space opens the palette', (
    tester,
  ) async {
    await _workspace(tester);
    await _tabToBar(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.space, platform: 'macos');
    await pumpFrames(tester);

    _expectOpenedEmpty(tester);
  });

  testWidgets(
    'holding Enter on the command bar opens one palette and chooses nothing',
    (tester) async {
      final h = await _workspace(tester);
      final tabsBefore = h.read(tabsProvider);
      await _tabToBar(tester);

      const enter = LogicalKeyboardKey.enter;
      await tester.sendKeyDownEvent(enter, platform: 'macos');
      // Repeats before a frame reach the bar.
      await tester.sendKeyRepeatEvent(enter, platform: 'macos');
      await tester.sendKeyRepeatEvent(enter, platform: 'macos');
      await pumpFrames(tester);
      // Repeats after it reach the palette's input.
      await tester.sendKeyRepeatEvent(enter, platform: 'macos');
      await tester.pump();
      await tester.sendKeyRepeatEvent(enter, platform: 'macos');
      await tester.sendKeyUpEvent(enter, platform: 'macos');
      await pumpFrames(tester);

      _expectOpenedEmpty(tester);
      expect(h.tabs.navigated, isEmpty, reason: 'no row was chosen');
      expect(h.cli!.callsFor('add'), isEmpty, reason: 'New note did not run');
      expect(h.read(tabsProvider).tabs, tabsBefore.tabs);
    },
  );

  testWidgets(
    'two Enter presses on the command bar in one frame open one palette',
    (tester) async {
      await _workspace(tester);
      await _tabToBar(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter, platform: 'macos');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter, platform: 'macos');
      await pumpFrames(tester);

      expect(_palette, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumpFrames(tester);
      expect(_palette, findsNothing, reason: 'no second palette under it');
    },
  );

  testWidgets(
    'the command bar semantics label is Command bar: search, ask, run. Command K.',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await _workspace(tester);

      const label = 'Command bar: search, ask, run. Command K.';
      final node = find.bySemanticsLabel(label);
      expect(node, findsOneWidget);
      final data = tester.getSemantics(node);
      expect(data.label, label);
      expect(
        data,
        isSemantics(
          label: label,
          isButton: true,
          isFocusable: true,
          hasTapAction: true,
        ),
      );
      expect(
        data.childrenCount,
        0,
        reason: 'the label and chip are not read again',
      );
      semantics.dispose();
    },
  );

  testWidgets(
    'the sidebar command bar node is a button leaf found by its key',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await _workspace(tester);

      final data = tester.getSemantics(_bar);
      expect(
        data,
        matchesSemantics(
          label: 'Command bar: search, ask, run. Command K.',
          isButton: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      expect(data.childrenCount, 0, reason: 'a leaf node: no child nodes');
      semantics.dispose();
    },
  );

  testWidgets('the command bar label is drawn in fg2 at rest', (tester) async {
    await _workspace(tester);

    expect(
      find.descendant(of: _bar, matching: find.text(_label)),
      findsOneWidget,
    );
    _expectRest(tester);
  });

  testWidgets(
    'hovering the command bar draws the hover state and leaving it restores the rest state',
    (tester) async {
      await _workspace(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(900, 700));
      addTearDown(mouse.removePointer);
      await tester.pump();
      _expectRest(tester);

      await mouse.moveTo(tester.getCenter(_bar));
      await tester.pump();

      expect(_fill(tester), OmColors.surface3);
      expect(_border(tester), OmColors.line3);
      expect(_labelColor(tester), OmColors.fg1);
      expect(_iconColor(tester), OmColors.fg2);

      await mouse.moveTo(const Offset(900, 700));
      await tester.pump();

      _expectRest(tester);
    },
  );

  testWidgets(
    'the command bar draws the open state while the palette shows and the rest state after it closes',
    (tester) async {
      await _workspace(tester);
      await tester.tap(_bar);
      await pumpFrames(tester);
      expect(_palette, findsOneWidget);

      expect(_fill(tester), OmColors.surface4);
      expect(_border(tester), OmColors.line3);
      expect(_labelColor(tester), OmColors.fg1);
      expect(_iconColor(tester), OmColors.fg2);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumpFrames(tester);
      expect(_palette, findsNothing);

      // The border may show keyboard focus if the click focused the bar.
      _expectRest(tester, border: false);
    },
  );

  testWidgets('the keyboard focused command bar draws the accentSoft border', (
    tester,
  ) async {
    await _workspace(tester);
    _expectRest(tester);

    await _tabToBar(tester);
    await tester.pump();

    expect(_border(tester), OmColors.accentSoft);
    expect(_fill(tester), OmColors.surface2);
    expect(_labelColor(tester), OmColors.fg2);
    expect(_iconColor(tester), OmColors.fg3);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    _expectRest(tester);
  });
}
