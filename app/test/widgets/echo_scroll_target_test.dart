// WI #428 (391-A5, Spec #391 req 27): an opened echo lands at its passage.
// The editor takes A0's one-shot `echoScrollTargetProvider` on arrival (a
// fresh hydrate or a same-note tab focus), scrolls the row holding the
// passage to about a third of the way down the viewport and shows a 1.2 s
// `EchoArrivalHighlight` there (accent at 12%, fading out), then clears the
// target. Back/Forward and `NoteTab` equality are unchanged.
//
// Part 1 pins the pure offset -> row locator (`echoArrivalRowKey`). Part 2
// drives the workspace through `TabsNotifier.follow`, the call the echoes
// tab makes after setting the target.
//
// Highlight probes (architect ruling): every passage row's text starts with
// two spaces, so the row's left padding (its first 13.5 px at the harness
// text scale) holds no ink; the probe samples there, at the row's vertical
// middle, away from #392's squiggle band. A probe compares the pixel while
// the highlight shows with the same pixel once it is gone, so it pins colour
// and opacity whatever lies beneath. Time only moves through pump durations:
// `_wi428PumpUntilHighlight` pumps zero-length frames, so the first sample is
// the fade's start. Never pumpAndSettle the workspace (OmDot pulses forever).
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart' show MemexResult;
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/echo_scroll_target.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/echo_arrival_highlight.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../robots/segmented_editor_robot.dart'
    show fixtureRangeToken, fixtureTopicId, seedSegmentedVault;
import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/segment_editing_finder.dart';
import '../support/today_cli_fakes.dart';

const _wi428A = 'note-alpha';
const _wi428B = 'note-bravo';
const _wi428Daily = 'daily-bravo';
const _wi428Footer = 'note-footer';
const _wi428Accented = 'note-accented';

/// The frames the editor retries locating the passage for before it gives
/// up and opens at the top.
const _wi428FallbackFrames = 9;

/// How many item + passage line pairs a long body has.
const _wi428Pairs = 300;

/// An offset every long note can scroll to that is far from any target.
const _wi428Left = 300.0;

/// `- item<tag> i` then `  passage<tag> i`, for i in `0..pairs`: the item is
/// row `2i` of its segment and the passage row `2i + 1`.
List<String> _wi428Lines(int pairs, [String tag = '']) => [
  for (var i = 0; i < pairs; i++) ...['- item$tag $i\n', '  passage$tag $i\n'],
];

String _wi428Body(int pairs, [String tag = '']) =>
    _wi428Lines(pairs, tag).join();

/// The UTF-8 byte offset of line [line] of [lines] joined, plus [into].
int _wi428ByteOf(List<String> lines, int line, [int into = 0]) =>
    utf8.encode(lines.take(line).join()).length + into;

/// Segment 0's passage row `k`.
int _wi428PassageRow(int k) => 2 * k + 1;

Finder _wi428Row(int segment, int row) =>
    find.byKey(ValueKey('editor-row-$segment-$row'));

Finder get _wi428Highlight => find.byType(EchoArrivalHighlight);

// ------------------------------------------------------------------ launch

FakeVaultDb _wi428Seed() {
  final db = FakeVaultDb.v5();
  db.seedNote(
    id: _wi428A,
    title: 'Alpha',
    content: _wi428Body(_wi428Pairs, 'a'),
  );
  db.seedNote(id: _wi428B, title: 'Bravo', content: _wi428Body(_wi428Pairs));
  db.seedNote(
    id: _wi428Daily,
    title: '2026-09-30',
    role: 'daily',
    content: _wi428Body(_wi428Pairs),
  );
  db.seedNote(
    id: _wi428Footer,
    title: 'Footed',
    content: '${_wi428Body(_wi428Pairs)}$topicsMarker\n[[Alpha~about]]\n',
  );
  db.seedNote(
    id: _wi428Accented,
    title: 'Accented',
    content: '— intro 🙂\n${_wi428Body(_wi428Pairs)}',
  );
  return db;
}

Future<WorkspaceHarness> _wi428Launch(WidgetTester tester, {FakeVaultDb? db}) {
  final vault = db ?? _wi428Seed();
  final cli = FakeMemexCli()
    ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
    ..onUpdateWrites(vault);
  return pumpWorkspace(tester, db: vault, cli: cli);
}

extension on WorkspaceHarness {
  TabsNotifier get tabs => read(tabsProvider.notifier);
  TabsState get tabState => read(tabsProvider);
  EchoScrollTarget? get target => read(echoScrollTargetProvider);

  void setTarget(String noteId, int? startByte) => container
      .read(echoScrollTargetProvider.notifier)
      .set(EchoScrollTarget(noteId, startByte));
}

Future<void> _wi428Navigate(
  WidgetTester tester,
  WorkspaceHarness h,
  String noteId,
) async {
  h.tabs.navigate(NoteTab(noteId));
  await pumpFrames(tester);
}

/// The echoes tab's click: set the target, then follow [noteId] (with Cmd
/// held when [cmd]). Pumps nothing after the follow.
Future<void> _wi428OpenEcho(
  WidgetTester tester,
  WorkspaceHarness h,
  String noteId,
  int? startByte, {
  bool cmd = false,
}) async {
  h.setTarget(noteId, startByte);
  if (cmd) {
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.metaLeft,
      platform: 'macos',
    );
  }
  h.tabs.follow(NoteTab(noteId));
  if (cmd) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
  }
}

/// Pumps zero-length frames (the clock does not move) until the highlight
/// shows, at most [frames]; true when it showed.
Future<bool> _wi428PumpUntilHighlight(
  WidgetTester tester, {
  int frames = 30,
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump();
    if (_wi428Highlight.evaluate().isNotEmpty) return true;
  }
  return false;
}

/// The arrival shows no highlight at any frame, then settles.
Future<void> _wi428ExpectNoHighlight(WidgetTester tester) async {
  expect(
    await _wi428PumpUntilHighlight(tester),
    isFalse,
    reason: 'no highlight on this arrival',
  );
  await pumpFrames(tester);
  expect(_wi428Highlight, findsNothing);
  await tester.pump(const Duration(milliseconds: 1300));
  expect(_wi428Highlight, findsNothing);
}

// ---------------------------------------------------------------- geometry

ScrollableState _wi428Page(WidgetTester tester) =>
    tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(EditorPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );

double _wi428Pixels(WidgetTester tester) => _wi428Page(tester).position.pixels;

/// Scrolls the page to [offset] as a person would.
Future<void> _wi428ScrollTo(WidgetTester tester, double offset) async {
  final position = _wi428Page(tester).position;
  expect(position.maxScrollExtent, greaterThan(offset));
  position.jumpTo(offset);
  await tester.pump();
  expect(position.pixels, offset);
}

/// [target]'s vertical middle sits about a third of the way down the
/// editor's viewport.
void _wi428ExpectAtThird(WidgetTester tester, Finder target) {
  expect(target, findsOneWidget);
  final viewport = tester.getRect(
    find
        .descendant(
          of: find.byType(EditorPage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  final rect = tester.getRect(target);
  final fraction = (rect.center.dy - viewport.top) / viewport.height;
  expect(
    fraction,
    closeTo(1 / 3, 0.06),
    reason: 'target $rect in viewport $viewport',
  );
}

// ------------------------------------------------------------------ pixels

/// The composited pixel at global [point] (the whole app's layer tree, so a
/// highlight in the root Overlay counts).
Future<Color> _wi428PixelAt(WidgetTester tester, Offset point) async {
  final layer = tester.binding.renderViews.first.debugLayer! as OffsetLayer;
  final region = Rect.fromLTWH(
    point.dx.floorToDouble(),
    point.dy.floorToDouble(),
    1,
    1,
  );
  final image = (await tester.runAsync(() => layer.toImage(region)))!;
  final bytes = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  image.dispose();
  return Color.fromARGB(
    bytes.getUint8(3),
    bytes.getUint8(0),
    bytes.getUint8(1),
    bytes.getUint8(2),
  );
}

List<int> _wi428Rgb(Color c) => [
  (c.r * 255).round(),
  (c.g * 255).round(),
  (c.b * 255).round(),
];

bool _wi428Near(Color a, Color b, [int tolerance = 3]) {
  final x = _wi428Rgb(a);
  final y = _wi428Rgb(b);
  for (var i = 0; i < 3; i++) {
    if ((x[i] - y[i]).abs() > tolerance) return false;
  }
  return true;
}

/// [under] with the highlight over it: accent at 12% opacity.
Color _wi428Highlighted(Color under) =>
    Color.alphaBlend(OmColors.accent.withValues(alpha: 0.12), under);

/// A point in [target]'s left padding, at its vertical middle.
Offset _wi428Probe(WidgetTester tester, Finder target) {
  final rect = tester.getRect(target);
  return Offset(rect.left + 4, rect.center.dy);
}

/// Waits for the highlight, then checks that it covers [target] at accent
/// 12% and none of [clear], that it is gone 1.3 s later, and that [target]
/// sits a third of the way down the viewport throughout.
Future<void> _wi428ExpectHighlightOn(
  WidgetTester tester,
  Finder target, {
  List<Finder> clear = const [],
}) async {
  expect(
    await _wi428PumpUntilHighlight(tester),
    isTrue,
    reason: 'the arrival shows the highlight',
  );
  await tester.pump();
  _wi428ExpectAtThird(tester, target);
  final probe = _wi428Probe(tester, target);
  final clearProbes = [
    for (final f in clear) Offset(probe.dx, tester.getRect(f).center.dy),
  ];
  final during = await _wi428PixelAt(tester, probe);
  final clearDuring = [
    for (final p in clearProbes) await _wi428PixelAt(tester, p),
  ];

  await tester.pump(const Duration(milliseconds: 1300));
  await tester.pump();
  expect(_wi428Highlight, findsNothing, reason: 'gone after 1.2 s');
  _wi428ExpectAtThird(tester, target);
  final after = await _wi428PixelAt(tester, probe);
  expect(
    _wi428Near(during, _wi428Highlighted(after)),
    isTrue,
    reason: 'probe $probe: $during while shown, $after after',
  );
  for (var i = 0; i < clearProbes.length; i++) {
    final now = await _wi428PixelAt(tester, clearProbes[i]);
    expect(
      _wi428Near(clearDuring[i], now, 1),
      isTrue,
      reason: '${clear[i]} is not highlighted: ${clearDuring[i]} vs $now',
    );
  }
}

bool _wi428BodyHasFocus(WidgetTester tester) =>
    editorBodySegment(tester).focusedRow != null;
// ------------------------------------------------- verify-mode additions

/// The editor viewport's rect.
Rect _wi428Viewport(WidgetTester tester) => tester.getRect(
  find
      .descendant(
        of: find.byType(EditorPage),
        matching: find.byType(Scrollable),
      )
      .first,
);

/// Each visual line of the prose [row]: its global rect.
List<Rect> _wi428LineRects(WidgetTester tester, Finder row) {
  final editable = findRenderEditable(tester.renderObject(row))!;
  return [
    for (final line in RenderEditableLineBoxes(editable).lines)
      Rect.fromPoints(
        editable.localToGlobal(Offset(0, line.top)),
        editable.localToGlobal(Offset(editable.size.width, line.bottom)),
      ),
  ];
}

/// The pixel at each of [points].
Future<List<Color>> _wi428Pixels4(
  WidgetTester tester,
  List<Offset> points,
) async => [for (final p in points) await _wi428PixelAt(tester, p)];

/// Pumps 1.3 s: the highlight is gone afterwards.
Future<void> _wi428FadeAway(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 1300));
  await tester.pump();
  expect(_wi428Highlight, findsNothing);
}

/// The pixels at [points] sampled now (the highlight showing, at its start)
/// and after it fades: [lit] points hold accent 12% over what they hold
/// afterwards, the others are unchanged.
Future<void> _wi428ExpectLitPoints(
  WidgetTester tester,
  List<Offset> points,
  List<bool> lit,
) async {
  final during = await _wi428Pixels4(tester, points);
  await _wi428FadeAway(tester);
  final after = await _wi428Pixels4(tester, points);
  for (var i = 0; i < points.length; i++) {
    expect(
      lit[i]
          ? _wi428Near(during[i], _wi428Highlighted(after[i]))
          : _wi428Near(during[i], after[i], 1),
      isTrue,
      reason:
          'point ${points[i]} (${lit[i] ? 'lit' : 'unlit'}): '
          '${during[i]} while shown, ${after[i]} after',
    );
  }
}

void main() {
  holdFontFetches();

  // ------------------------------------------------------- pure locator
  group('echoArrivalRowKey', () {
    test('a byte offset in a body maps to the editor row holding it', () {
      const body = '- a\n  passage\n- b\n';
      expect(echoArrivalRowKey(body, 0), const ValueKey('editor-row-0-0'));
      expect(echoArrivalRowKey(body, 4), const ValueKey('editor-row-0-1'));
      expect(echoArrivalRowKey(body, 9), const ValueKey('editor-row-0-1'));
      expect(echoArrivalRowKey(body, 14), const ValueKey('editor-row-0-2'));
    });

    test(
      'the row locator converts UTF-8 bytes to UTF-16 before matching rows',
      () {
        // '— 🙂 intro\n' is 11 UTF-16 code units but 15 UTF-8 bytes: byte 15 is
        // the bullet row; read as a code unit index it would be the passage.
        const body = '— 🙂 intro\n- x\n  passage\n';
        expect(utf8.encode('— 🙂 intro\n').length, 15);
        expect(echoArrivalRowKey(body, 15), const ValueKey('editor-row-0-1'));
        expect(echoArrivalRowKey(body, 19), const ValueKey('editor-row-0-2'));
      },
    );

    test('the row locator converts across segments of a body with a card', () {
      const lead = 'Intro — line\n$fixtureRangeToken\n🙂 Outro\n';
      const body = '$lead- y\n';
      final byte = utf8.encode(lead).length;
      expect(
        echoArrivalRowKey(body, byte, role: 'topic'),
        const ValueKey('editor-row-2-1'),
      );
    });

    test('a null or unconvertible start byte gives no row', () {
      const body = '— 🙂 intro\n- x\n  passage\n';
      final length = utf8.encode(body).length;
      expect(echoArrivalRowKey(body, null), isNull);
      expect(echoArrivalRowKey(body, 1), isNull, reason: 'inside the dash');
      expect(echoArrivalRowKey(body, 5), isNull, reason: 'inside the emoji');
      expect(echoArrivalRowKey(body, -1), isNull);
      expect(echoArrivalRowKey(body, length + 1), isNull);
      // The same body still locates a boundary offset.
      expect(echoArrivalRowKey(body, 15), const ValueKey('editor-row-0-1'));
    });

    test('an offset at the end of the last row gives no row', () {
      const body = '- a\n- b';
      expect(
        echoArrivalRowKey(body, 6),
        const ValueKey('editor-row-0-1'),
        reason: 'the last character is in the last row',
      );
      expect(echoArrivalRowKey(body, 7), isNull, reason: 'past the last row');
    });

    test('an offset in the Note footer is past the last row', () {
      const body = 'intro\n- x\n$topicsMarker\n[[Alpha~about]]\n';
      final chip = body.indexOf('[[Alpha');
      expect(echoArrivalRowKey(body, chip), isNull);
      expect(echoArrivalRowKey(body, body.indexOf(topicsMarker)), isNull);
      expect(echoArrivalRowKey(body, 6), const ValueKey('editor-row-0-1'));
    });

    test('a guide note has no footer so its marker line is a row', () {
      const body = 'intro\n- x\n$topicsMarker\n[[Alpha~about]]\n';
      expect(
        echoArrivalRowKey(body, body.indexOf('[[Alpha'), role: 'guide'),
        const ValueKey('editor-row-0-2'),
      );
    });

    test(
      'a daily note footer is past the last row and a daily body has no cards',
      () {
        final body = assembleDailyBody('first\n- x\n', const ['Alpha']);
        expect(
          echoArrivalRowKey(body, 6, role: 'daily'),
          const ValueKey('editor-row-0-1'),
        );
        expect(
          echoArrivalRowKey(body, body.indexOf('[[Alpha'), role: 'daily'),
          isNull,
        );
        const withToken = 'a\n$fixtureRangeToken\nb\n';
        expect(
          echoArrivalRowKey(withToken, 5, role: 'daily'),
          const ValueKey('editor-row-0-0'),
          reason: 'a daily note shows a token line as text',
        );
      },
    );

    test(
      'a daily note with stray text below the marker keeps footer offsets past the last row',
      () {
        // The stray line below the marker is shown at the end of the person
        // section, so the segment text is longer than the stored body up to the
        // marker: only its shared prefix is at body offsets.
        const person = 'first\n- x\n';
        const body = '$person$topicsMarker\n[[Alpha~about]]\nstray line\n';
        final marker = body.indexOf(topicsMarker);
        expect(marker, person.length);
        expect(
          echoArrivalRowKey(body, marker - 1, role: 'daily'),
          const ValueKey('editor-row-0-1'),
          reason: 'the last character before the marker is a row',
        );
        expect(
          echoArrivalRowKey(body, marker, role: 'daily'),
          isNull,
          reason: 'the marker line is the footer, not the moved stray row',
        );
        expect(
          echoArrivalRowKey(body, body.indexOf('[[Alpha'), role: 'daily'),
          isNull,
        );
        expect(
          echoArrivalRowKey(body, body.indexOf('stray'), role: 'daily'),
          isNull,
          reason: 'the stray text sits in the footer of the stored body',
        );
      },
    );

    test('an offset inside an excerpt card token maps to that card', () {
      const body = 'Intro line\n$fixtureRangeToken\nOutro line\n';
      const tokenAt = 11;
      expect(echoArrivalRowKey(body, tokenAt + 3), const Key('excerpt-card-1'));
      expect(echoArrivalRowKey(body, tokenAt), const Key('excerpt-card-1'));
      expect(
        echoArrivalRowKey(body, tokenAt + fixtureRangeToken.length),
        const Key('excerpt-card-1'),
        reason: 'the card line keeps its terminator',
      );
      expect(
        echoArrivalRowKey(body, body.indexOf('Outro')),
        const ValueKey('editor-row-2-0'),
      );
      expect(echoArrivalRowKey(body, 2), const ValueKey('editor-row-0-0'));
    });

    test('an offset inside a table maps to that table row', () {
      const body = 'intro\n| a | b |\n|---|---|\n| 1 | 2 |\nafter\n';
      expect(
        echoArrivalRowKey(body, body.indexOf('| 1')),
        const ValueKey('editor-table-0-1'),
      );
      expect(
        echoArrivalRowKey(body, body.indexOf('| a')),
        const ValueKey('editor-table-0-1'),
      );
      expect(
        echoArrivalRowKey(body, body.indexOf('after')),
        const ValueKey('editor-row-0-2'),
      );
    });
  });

  // ------------------------------------------------------- workspace
  group('fresh hydrate', () {
    testWidgets(
      'opening an echo note scrolls its passage row to a third of the viewport and highlights it',
      (tester) async {
        final h = await _wi428Launch(tester);
        await _wi428Navigate(tester, h, _wi428A);
        final lines = _wi428Lines(_wi428Pairs);
        const k = 150;

        await _wi428OpenEcho(
          tester,
          h,
          _wi428B,
          _wi428ByteOf(lines, 2 * k + 1),
        );
        await _wi428ExpectHighlightOn(
          tester,
          _wi428Row(0, _wi428PassageRow(k)),
          clear: [
            _wi428Row(0, _wi428PassageRow(k - 1)),
            _wi428Row(0, _wi428PassageRow(k + 1)),
          ],
        );
        expect(h.tabState.activeTab, const NoteTab(_wi428B));
        expect(h.target, isNull, reason: 'the target is used up');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a start byte after non ASCII text lands on the passage row', (
      tester,
    ) async {
      final db = FakeVaultDb.v5();
      db.seedNote(id: _wi428A, title: 'Alpha', content: _wi428Body(40, 'a'));
      final lines = [
        for (var i = 0; i < _wi428Pairs; i++) ...[
          '- item — 🙂 $i\n',
          '  passage — 🙂 $i\n',
        ],
      ];
      db.seedNote(id: _wi428B, title: 'Bravo', content: lines.join());
      final h = await _wi428Launch(tester, db: db);
      await _wi428Navigate(tester, h, _wi428A);
      const k = 120;
      final byte = _wi428ByteOf(lines, 2 * k + 1);
      expect(
        byte,
        isNot(lines.take(2 * k + 1).join().length),
        reason: 'bytes and code units differ here',
      );

      await _wi428OpenEcho(tester, h, _wi428B, byte);
      await _wi428ExpectHighlightOn(
        tester,
        _wi428Row(0, _wi428PassageRow(k)),
        clear: [
          _wi428Row(0, _wi428PassageRow(k - 1)),
          _wi428Row(0, _wi428PassageRow(k + 1)),
        ],
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('already hydrated tab', () {
    testWidgets(
      'focusing an open tab on the same note with the new tab modifier scrolls to and highlights the passage',
      (tester) async {
        final h = await _wi428Launch(tester);
        // [B] [B*]: the first tab left at an offset, the second on top.
        await _wi428Navigate(tester, h, _wi428B);
        await _wi428ScrollTo(tester, _wi428Left);
        h.tabs.openOrFocus(const NoteTab(_wi428A));
        await pumpFrames(tester);
        await _wi428Navigate(tester, h, _wi428B);
        expect(h.tabState.tabs, const [NoteTab(_wi428B), NoteTab(_wi428B)]);
        expect(h.tabState.activeIndex, 1);
        const k = 200;

        await _wi428OpenEcho(
          tester,
          h,
          _wi428B,
          _wi428ByteOf(_wi428Lines(_wi428Pairs), 2 * k + 1),
          cmd: true,
        );
        await _wi428ExpectHighlightOn(
          tester,
          _wi428Row(0, _wi428PassageRow(k)),
          clear: [_wi428Row(0, _wi428PassageRow(k + 1))],
        );
        expect(h.tabState.activeIndex, 0, reason: 'Cmd focused the first tab');
        expect(_wi428Pixels(tester), isNot(_wi428Left));
        expect(h.target, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('precedence and focus', () {
    testWidgets(
      'a target wins over the stored scroll restore of the focused tab',
      (tester) async {
        final h = await _wi428Launch(tester);
        // [B@300] [A*]: Cmd-following B focuses the first tab, whose entry
        // would restore 300.
        await _wi428Navigate(tester, h, _wi428B);
        await _wi428ScrollTo(tester, _wi428Left);
        h.tabs.openOrFocus(const NoteTab(_wi428A));
        await pumpFrames(tester);
        expect(h.tabState.activeIndex, 1);
        const k = 250;

        await _wi428OpenEcho(
          tester,
          h,
          _wi428B,
          _wi428ByteOf(_wi428Lines(_wi428Pairs), 2 * k + 1),
          cmd: true,
        );
        await _wi428ExpectHighlightOn(
          tester,
          _wi428Row(0, _wi428PassageRow(k)),
        );
        expect(h.tabState.activeIndex, 0);
        expect(_wi428Pixels(tester), isNot(_wi428Left));
        await pumpFrames(tester);
        _wi428ExpectAtThird(tester, _wi428Row(0, _wi428PassageRow(k)));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a target on a daily note does not take focus or move the caret to the end',
      (tester) async {
        final h = await _wi428Launch(tester);
        await _wi428Navigate(tester, h, _wi428A);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        const k = 140;

        await _wi428OpenEcho(
          tester,
          h,
          _wi428Daily,
          _wi428ByteOf(_wi428Lines(_wi428Pairs), 2 * k + 1),
        );
        await _wi428ExpectHighlightOn(
          tester,
          _wi428Row(0, _wi428PassageRow(k)),
        );
        expect(h.tabState.activeTab, const NoteTab(_wi428Daily));
        expect(
          _wi428BodyHasFocus(tester),
          isFalse,
          reason: 'the daily caret-at-end focus is suppressed',
        );
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('no usable offset', () {
    testWidgets(
      'a null start byte opens the note at the top with no highlight and clears the target',
      (tester) async {
        final h = await _wi428Launch(tester);
        await _wi428Navigate(tester, h, _wi428A);

        await _wi428OpenEcho(tester, h, _wi428B, null);
        await _wi428ExpectNoHighlight(tester);
        expect(h.tabState.activeTab, const NoteTab(_wi428B));
        expect(_wi428Pixels(tester), 0.0);
        expect(h.target, isNull, reason: 'the target is used up');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a null start byte beats a stored scroll restore and opens at the top',
      (tester) async {
        final h = await _wi428Launch(tester);
        await _wi428Navigate(tester, h, _wi428B);
        await _wi428ScrollTo(tester, _wi428Left);
        h.tabs.openOrFocus(const NoteTab(_wi428A));
        await pumpFrames(tester);

        await _wi428OpenEcho(tester, h, _wi428B, null, cmd: true);
        await _wi428ExpectNoHighlight(tester);
        expect(h.tabState.activeIndex, 0);
        expect(_wi428Pixels(tester), 0.0);
        expect(h.target, isNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a start byte inside a character or past the body end opens at the top with no highlight',
      (tester) async {
        final h = await _wi428Launch(tester);
        await _wi428Navigate(tester, h, _wi428A);

        // Byte 1 is inside the leading dash.
        await _wi428OpenEcho(tester, h, _wi428Accented, 1);
        await _wi428ExpectNoHighlight(tester);
        expect(h.tabState.activeTab, const NoteTab(_wi428Accented));
        expect(_wi428Pixels(tester), 0.0);
        expect(h.target, isNull);

        await _wi428Navigate(tester, h, _wi428A);
        final body =
            h.db.db.select('SELECT content_md FROM notes WHERE id = ?', [
                  _wi428Accented,
                ]).single['content_md']
                as String;
        await _wi428OpenEcho(
          tester,
          h,
          _wi428Accented,
          utf8.encode(body).length + 1,
        );
        await _wi428ExpectNoHighlight(tester);
        expect(h.tabState.activeTab, const NoteTab(_wi428Accented));
        expect(_wi428Pixels(tester), 0.0);
        expect(h.target, isNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a start byte in the Note footer is past the last row and opens at the top',
      (tester) async {
        final h = await _wi428Launch(tester);
        await _wi428Navigate(tester, h, _wi428A);
        final chip = utf8
            .encode('${_wi428Body(_wi428Pairs)}$topicsMarker\n')
            .length;

        await _wi428OpenEcho(tester, h, _wi428Footer, chip);
        await _wi428ExpectNoHighlight(tester);
        expect(h.tabState.activeTab, const NoteTab(_wi428Footer));
        expect(_wi428Pixels(tester), 0.0);
        expect(h.target, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('cards and tables', () {
    testWidgets(
      'an offset inside an excerpt card scrolls to and highlights that card',
      (tester) async {
        final before = _wi428Lines(150);
        final lead = '${before.join()}$fixtureRangeToken\n';
        final vault = seedSegmentedVault(
          topicBody: '$lead${_wi428Body(150, 'z')}',
        );
        final h = await _wi428Launch(tester, db: vault.db);
        await _wi428Navigate(tester, h, 'topic-other');
        final tokenByte = utf8.encode(before.join()).length;

        await _wi428OpenEcho(tester, h, fixtureTopicId, tokenByte + 4);
        await _wi428ExpectHighlightOn(
          tester,
          find.byKey(const Key('excerpt-card-1')),
          clear: [_wi428Row(0, _wi428PassageRow(149))],
        );
        expect(h.target, isNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'an offset inside a table scrolls to and highlights that table row',
      (tester) async {
        final before = _wi428Lines(150);
        const table = '| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n';
        final db = FakeVaultDb.v5();
        db.seedNote(id: _wi428A, title: 'Alpha', content: _wi428Body(40, 'a'));
        db.seedNote(
          id: _wi428B,
          title: 'Bravo',
          content: '${before.join()}$table${_wi428Body(150, 'z')}',
        );
        final h = await _wi428Launch(tester, db: db);
        await _wi428Navigate(tester, h, _wi428A);
        final byte =
            utf8.encode(before.join()).length + table.indexOf('| 3') + 2;

        await _wi428OpenEcho(tester, h, _wi428B, byte);
        await _wi428ExpectHighlightOn(
          tester,
          find.byKey(const ValueKey('editor-table-0-300')),
          clear: [_wi428Row(0, _wi428PassageRow(149))],
        );
        expect(h.target, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('highlight lifetime', () {
    testWidgets(
      'the highlight starts at accent 12 percent, fades over 1.2 s, then is gone and reopening lands normally',
      (tester) async {
        final h = await _wi428Launch(tester);
        await _wi428Navigate(tester, h, _wi428A);
        const k = 150;
        final row = _wi428Row(0, _wi428PassageRow(k));

        await _wi428OpenEcho(
          tester,
          h,
          _wi428B,
          _wi428ByteOf(_wi428Lines(_wi428Pairs), 2 * k + 1),
        );
        expect(await _wi428PumpUntilHighlight(tester), isTrue);
        await tester.pump();
        final probe = _wi428Probe(tester, row);
        final start = await _wi428PixelAt(tester, probe);

        await tester.pump(const Duration(milliseconds: 600));
        expect(
          _wi428Highlight,
          findsOneWidget,
          reason: 'still fading at 0.6 s',
        );
        final middle = await _wi428PixelAt(tester, probe);

        await tester.pump(const Duration(milliseconds: 500));
        expect(
          _wi428Highlight,
          findsOneWidget,
          reason: 'still fading at 1.1 s',
        );

        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump();
        expect(_wi428Highlight, findsNothing, reason: 'removed after 1.2 s');
        final end = await _wi428PixelAt(tester, probe);

        expect(
          _wi428Near(end, OmColors.surface2, 1),
          isTrue,
          reason: 'the probe is on the editor background: $end',
        );
        expect(
          _wi428Near(start, _wi428Highlighted(end)),
          isTrue,
          reason: 'starts at accent 12%: $start over $end',
        );
        int g(Color c) => (c.g * 255).round();
        expect(g(middle), greaterThan(g(end) + 1), reason: 'still showing');
        expect(g(middle), lessThan(g(start) - 1), reason: 'fading out');
        expect(h.target, isNull, reason: 'the target is cleared');

        // Reopening B later lands normally: at the top, no highlight.
        await _wi428Navigate(tester, h, _wi428A);
        h.tabs.navigate(const NoteTab(_wi428B));
        await _wi428ExpectNoHighlight(tester);
        expect(h.tabState.activeTab, const NoteTab(_wi428B));
        expect(_wi428Pixels(tester), 0.0);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('history', () {
    testWidgets('back and forward after an echo open behave as before', (
      tester,
    ) async {
      final h = await _wi428Launch(tester);
      await _wi428Navigate(tester, h, _wi428A);
      await _wi428ScrollTo(tester, _wi428Left);
      const k = 150;

      await _wi428OpenEcho(
        tester,
        h,
        _wi428B,
        _wi428ByteOf(_wi428Lines(_wi428Pairs), 2 * k + 1),
      );
      await _wi428ExpectHighlightOn(tester, _wi428Row(0, _wi428PassageRow(k)));
      expect(h.tabState.tabs, const [NoteTab(_wi428B)]);
      expect(h.tabState.canGoBack, isTrue);
      expect(h.tabState.canGoForward, isFalse);
      final leftAt = _wi428Pixels(tester) - 120;
      await _wi428ScrollTo(tester, leftAt);

      h.tabs.back();
      await _wi428ExpectNoHighlight(tester);
      expect(h.tabState.activeTab, const NoteTab(_wi428A));
      expect(_wi428Pixels(tester), _wi428Left);
      expect(h.tabState.canGoForward, isTrue);

      h.tabs.forward();
      await _wi428ExpectNoHighlight(tester);
      expect(h.tabState.activeTab, const NoteTab(_wi428B));
      expect(_wi428Pixels(tester), leftAt);
      expect(h.tabState.canGoForward, isFalse);
      expect(h.tabState.tabs, const [NoteTab(_wi428B)]);
      expect(tester.takeException(), isNull);
    });
  });

  // ----------------------------------------- verify-mode pinned contracts
  group('passage band and landing', () {
    FakeVaultDb seedBravo(List<String> lines) {
      final db = FakeVaultDb.v5();
      db.seedNote(id: _wi428A, title: 'Alpha', content: _wi428Body(40, 'a'));
      db.seedNote(id: _wi428B, title: 'Bravo', content: lines.join());
      return db;
    }

    testWidgets(
      'a prose passage highlights only its own paragraph and anchors its line at a third',
      (tester) async {
        // Row 300 is the item before the prose; row 301 the seven-line prose
        // row (blank lines inside it): the passage is the second paragraph.
        final lines = [
          ..._wi428Lines(150),
          '- sep\n',
          '  p1 a\n',
          '  p1 b\n',
          '\n',
          '  p2 a\n',
          '  p2 b\n',
          '\n',
          '  p3 a\n',
          ..._wi428Lines(100, 'z'),
        ];
        final h = await _wi428Launch(tester, db: seedBravo(lines));
        await _wi428Navigate(tester, h, _wi428A);
        final p2a = lines.indexOf('  p2 a\n');

        await _wi428OpenEcho(tester, h, _wi428B, _wi428ByteOf(lines, p2a, 4));
        expect(await _wi428PumpUntilHighlight(tester), isTrue);
        await tester.pump();
        final row = _wi428Row(0, 301);
        final rects = _wi428LineRects(tester, row);
        expect(rects, hasLength(7), reason: 'the paragraphs share one row');
        final viewport = _wi428Viewport(tester);
        expect(
          (rects[3].center.dy - viewport.top) / viewport.height,
          closeTo(1 / 3, 0.03),
          reason: 'the passage line, not the row, sits at a third',
        );
        final x = tester.getRect(row).left + 4;
        await _wi428ExpectLitPoints(
          tester,
          [for (final r in rects) Offset(x, r.center.dy)],
          [false, false, false, true, true, false, false],
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'an offset on the blank line before a paragraph highlights that paragraph',
      (tester) async {
        final lines = [
          ..._wi428Lines(150),
          '- sep\n',
          '  p1 a\n',
          '\n',
          '  p2 a\n',
          '  p2 b\n',
          '\n',
          '  p3 a\n',
          ..._wi428Lines(100, 'z'),
        ];
        final h = await _wi428Launch(tester, db: seedBravo(lines));
        await _wi428Navigate(tester, h, _wi428A);
        final blank = lines.indexOf('  p2 a\n') - 1;
        expect(lines[blank], '\n');

        await _wi428OpenEcho(tester, h, _wi428B, _wi428ByteOf(lines, blank));
        expect(await _wi428PumpUntilHighlight(tester), isTrue);
        await tester.pump();
        final row = _wi428Row(0, 301);
        final rects = _wi428LineRects(tester, row);
        expect(rects, hasLength(6));
        final x = tester.getRect(row).left + 4;
        await _wi428ExpectLitPoints(
          tester,
          [for (final r in rects) Offset(x, r.center.dy)],
          [false, false, true, true, false, false],
        );
      },
    );

    testWidgets(
      'a passage in the last paragraph of a prose row highlights to the row end',
      (tester) async {
        final lines = [
          ..._wi428Lines(150),
          '- sep\n',
          '  p1 a\n',
          '\n',
          '  p2 a\n',
          '  p2 b\n',
          ..._wi428Lines(100, 'z'),
        ];
        final h = await _wi428Launch(tester, db: seedBravo(lines));
        await _wi428Navigate(tester, h, _wi428A);

        await _wi428OpenEcho(
          tester,
          h,
          _wi428B,
          _wi428ByteOf(lines, lines.indexOf('  p2 a\n'), 4),
        );
        expect(await _wi428PumpUntilHighlight(tester), isTrue);
        await tester.pump();
        final row = _wi428Row(0, 301);
        final rects = _wi428LineRects(tester, row);
        expect(rects, hasLength(4));
        final x = tester.getRect(row).left + 4;
        await _wi428ExpectLitPoints(
          tester,
          [for (final r in rects) Offset(x, r.center.dy)],
          [false, false, true, true],
        );
      },
    );

    testWidgets(
      'a row taller than two thirds of the viewport aligns its top with the viewport top',
      (tester) async {
        final tall = '- ${List.filled(2500, 'wordy').join(' ')}\n';
        final lines = [..._wi428Lines(150), tall, ..._wi428Lines(100, 'z')];
        final h = await _wi428Launch(tester, db: seedBravo(lines));
        await _wi428Navigate(tester, h, _wi428A);

        await _wi428OpenEcho(tester, h, _wi428B, _wi428ByteOf(lines, 300, 400));
        expect(await _wi428PumpUntilHighlight(tester), isTrue);
        await tester.pump();
        final rect = tester.getRect(_wi428Row(0, 300));
        final viewport = _wi428Viewport(tester);
        expect(rect.height, greaterThan(viewport.height * 2 / 3));
        expect(rect.top, closeTo(viewport.top, 2));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('the highlight follows its row while the editor scrolls', (
      tester,
    ) async {
      final h = await _wi428Launch(tester);
      await _wi428Navigate(tester, h, _wi428A);
      const k = 150;
      final row = _wi428Row(0, _wi428PassageRow(k));

      await _wi428OpenEcho(
        tester,
        h,
        _wi428B,
        _wi428ByteOf(_wi428Lines(_wi428Pairs), 2 * k + 1),
      );
      expect(await _wi428PumpUntilHighlight(tester), isTrue);
      await tester.pump();
      final was = _wi428Probe(tester, row);
      _wi428Page(tester).position.jumpTo(_wi428Pixels(tester) + 100);
      await tester.pump();
      final now = _wi428Probe(tester, row);
      expect(now.dy, closeTo(was.dy - 100, 1));
      expect(_wi428Highlight, findsOneWidget);

      await _wi428ExpectLitPoints(tester, [now, was], [true, false]);
    });

    testWidgets('the highlight is clipped to the editor viewport', (
      tester,
    ) async {
      final h = await _wi428Launch(tester);
      await _wi428Navigate(tester, h, _wi428A);
      const k = 150;
      final row = _wi428Row(0, _wi428PassageRow(k));

      await _wi428OpenEcho(
        tester,
        h,
        _wi428B,
        _wi428ByteOf(_wi428Lines(_wi428Pairs), 2 * k + 1),
      );
      expect(await _wi428PumpUntilHighlight(tester), isTrue);
      await tester.pump();
      final viewport = _wi428Viewport(tester);
      final middle = tester.getRect(row).center.dy;
      // The row ends up 30 px above the viewport top.
      _wi428Page(
        tester,
      ).position.jumpTo(_wi428Pixels(tester) + (middle - viewport.top) + 30);
      await tester.pump();
      expect(row, findsOneWidget);
      final above = Offset(
        tester.getRect(row).left + 4,
        tester.getRect(row).center.dy,
      );
      expect(above.dy, lessThan(viewport.top));
      expect(_wi428Highlight, findsOneWidget);

      await _wi428ExpectLitPoints(tester, [above], [false]);
    });

    testWidgets('a new arrival removes the highlight of the previous one', (
      tester,
    ) async {
      final h = await _wi428Launch(tester);
      await _wi428Navigate(tester, h, _wi428A);
      const k = 150;

      await _wi428OpenEcho(
        tester,
        h,
        _wi428B,
        _wi428ByteOf(_wi428Lines(_wi428Pairs), 2 * k + 1),
      );
      expect(await _wi428PumpUntilHighlight(tester), isTrue);
      await tester.pump(const Duration(milliseconds: 200));
      expect(_wi428Highlight, findsOneWidget);

      await _wi428Navigate(tester, h, _wi428A);
      await tester.pump();
      expect(
        _wi428Highlight,
        findsNothing,
        reason: 'the highlight of B does not outlive the arrival at A',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'a second echo arrival while the first fades shows one highlight',
      (tester) async {
        final h = await _wi428Launch(tester);
        await _wi428Navigate(tester, h, _wi428A);
        final lines = _wi428Lines(_wi428Pairs);

        await _wi428OpenEcho(
          tester,
          h,
          _wi428B,
          _wi428ByteOf(lines, 2 * 150 + 1),
        );
        expect(await _wi428PumpUntilHighlight(tester), isTrue);
        await tester.pump(const Duration(milliseconds: 200));
        await _wi428OpenEcho(
          tester,
          h,
          _wi428Daily,
          _wi428ByteOf(lines, 2 * 100 + 1),
        );
        expect(await _wi428PumpUntilHighlight(tester), isTrue);
        await tester.pump();
        expect(_wi428Highlight, findsOneWidget);
        _wi428ExpectAtThird(tester, _wi428Row(0, _wi428PassageRow(100)));
        await _wi428FadeAway(tester);
      },
    );

    testWidgets(
      'the highlight fades linearly: accent 9 percent at 0.3 s and 3 percent at 0.9 s',
      (tester) async {
        final h = await _wi428Launch(tester);
        await _wi428Navigate(tester, h, _wi428A);
        const k = 150;
        final row = _wi428Row(0, _wi428PassageRow(k));

        await _wi428OpenEcho(
          tester,
          h,
          _wi428B,
          _wi428ByteOf(_wi428Lines(_wi428Pairs), 2 * k + 1),
        );
        expect(await _wi428PumpUntilHighlight(tester), isTrue);
        await tester.pump();
        final probe = _wi428Probe(tester, row);
        await tester.pump(const Duration(milliseconds: 300));
        final early = await _wi428PixelAt(tester, probe);
        await tester.pump(const Duration(milliseconds: 600));
        final late = await _wi428PixelAt(tester, probe);
        await _wi428FadeAway(tester);
        final end = await _wi428PixelAt(tester, probe);

        Color at(double alpha) =>
            Color.alphaBlend(OmColors.accent.withValues(alpha: alpha), end);
        expect(_wi428Near(early, at(0.09), 2), isTrue, reason: '$early');
        expect(_wi428Near(late, at(0.03), 2), isTrue, reason: '$late');
      },
    );

    testWidgets(
      'a passage inside a table the caret is in highlights the revealed row',
      (tester) async {
        final before = _wi428Lines(150);
        const table = '| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n';
        final db = FakeVaultDb.v5();
        db.seedNote(
          id: _wi428B,
          title: 'Bravo',
          content: '${before.join()}$table${_wi428Body(150, 'z')}',
        );
        db.seedNote(id: _wi428A, title: 'Alpha', content: _wi428Body(40, 'a'));
        final h = await _wi428Launch(tester, db: db);
        final byte =
            utf8.encode(before.join()).length + table.indexOf('| 3') + 2;
        // [B] [B*]: the caret goes into the table of the second.
        await _wi428Navigate(tester, h, _wi428B);
        h.tabs.openOrFocus(const NoteTab(_wi428A));
        await pumpFrames(tester);
        await _wi428Navigate(tester, h, _wi428B);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('editor-table-0-300')),
          400,
          scrollable: find
              .descendant(
                of: find.byType(EditorPage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        tester
            .state<SegmentViewState>(
              find.descendant(
                of: find.byKey(textSegmentKey(0)),
                matching: find.byType(SegmentView),
              ),
            )
            .widget
            .focusNode
            .requestFocus();
        segmentEditingAt(tester, 0).select(
          TextSelection.collapsed(
            offset: before.join().length + table.indexOf('| 3') + 2,
          ),
        );
        await pumpFrames(tester);
        expect(
          find.byKey(const ValueKey('editor-table-0-300')),
          findsNothing,
          reason: 'the table is revealed as its field',
        );
        expect(find.byKey(const ValueKey('editor-row-0-300')), findsOneWidget);

        await _wi428OpenEcho(tester, h, _wi428B, byte, cmd: true);
        await _wi428ExpectHighlightOn(
          tester,
          find.byKey(const ValueKey('editor-row-0-300')),
        );
        expect(h.tabState.activeIndex, 0);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'forward after back returns to the landing offset without a scroll',
      (tester) async {
        final h = await _wi428Launch(tester);
        await _wi428Navigate(tester, h, _wi428A);
        const k = 150;

        await _wi428OpenEcho(
          tester,
          h,
          _wi428B,
          _wi428ByteOf(_wi428Lines(_wi428Pairs), 2 * k + 1),
        );
        await _wi428ExpectHighlightOn(
          tester,
          _wi428Row(0, _wi428PassageRow(k)),
        );
        final landed = _wi428Pixels(tester);
        expect(landed, greaterThan(1000));

        h.tabs.back();
        await _wi428ExpectNoHighlight(tester);
        expect(_wi428Pixels(tester), 0.0);
        h.tabs.forward();
        await _wi428ExpectNoHighlight(tester);
        expect(_wi428Pixels(tester), landed);
      },
    );

    testWidgets(
      'a null start byte on a daily note opens at the top without the caret focus',
      (tester) async {
        final h = await _wi428Launch(tester);
        await _wi428Navigate(tester, h, _wi428A);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();

        await _wi428OpenEcho(tester, h, _wi428Daily, null);
        await _wi428ExpectNoHighlight(tester);
        expect(h.tabState.activeTab, const NoteTab(_wi428Daily));
        expect(_wi428Pixels(tester), 0.0);
        expect(_wi428BodyHasFocus(tester), isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  });
  // ------------------------------------- fix round 1: review-r1 findings
  group('fix round 1', () {
    /// [B] [B*] with the first tab left at [_wi428Left]; the second (the
    /// active one) is on top, its editor on B.
    Future<void> twoTabsOnB(WidgetTester tester, WorkspaceHarness h) async {
      await _wi428Navigate(tester, h, _wi428B);
      await _wi428ScrollTo(tester, _wi428Left);
      h.tabs.openOrFocus(const NoteTab(_wi428A));
      await pumpFrames(tester);
      await _wi428Navigate(tester, h, _wi428B);
      expect(h.tabState.tabs, const [NoteTab(_wi428B), NoteTab(_wi428B)]);
      expect(h.tabState.activeIndex, 1);
    }

    String stored(WorkspaceHarness h, String id) =>
        h.db.db.select('SELECT content_md FROM notes WHERE id = ?', [
              id,
            ]).single['content_md']
            as String;

    testWidgets(
      'unmounting the editor while the highlight fades removes it without an error',
      (tester) async {
        final h = await _wi428Launch(tester);
        // The workspace's editor in a tree of its own, so it can go away
        // without a tab arrival (which clears the highlight by itself).
        final shown = ValueNotifier(true);
        addTearDown(shown.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: h.container,
            child: MaterialApp(
              theme: buildOmTheme(),
              home: Scaffold(
                body: ValueListenableBuilder<bool>(
                  valueListenable: shown,
                  builder: (_, on, _) => on
                      ? NoteEditor(
                          rightPanelOpen: false,
                          onToggleRightPanel: () {},
                        )
                      : const SizedBox.shrink(key: Key('no-editor')),
                ),
              ),
            ),
          ),
        );
        await pumpFrames(tester);
        await _wi428Navigate(tester, h, _wi428A);
        const k = 150;
        await _wi428OpenEcho(
          tester,
          h,
          _wi428B,
          _wi428ByteOf(_wi428Lines(_wi428Pairs), 2 * k + 1),
        );
        expect(await _wi428PumpUntilHighlight(tester), isTrue);
        await tester.pump(const Duration(milliseconds: 300));
        expect(_wi428Highlight, findsOneWidget, reason: 'mid-fade');

        shown.value = false;
        await tester.pump();
        await tester.pump();
        expect(find.byType(NoteEditor), findsNothing);
        expect(
          _wi428Highlight,
          findsNothing,
          reason: 'the highlight does not outlive its editor',
        );
        await tester.pump(const Duration(milliseconds: 1500));
        expect(_wi428Highlight, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'the highlight of an item row also covers its marker left of the row',
      (tester) async {
        final h = await _wi428Launch(tester);
        await _wi428Navigate(tester, h, _wi428A);
        const k = 150;
        final row = _wi428Row(0, 2 * k);
        final next = _wi428Row(0, 2 * k + 1);

        await _wi428OpenEcho(
          tester,
          h,
          _wi428B,
          _wi428ByteOf(_wi428Lines(_wi428Pairs), 2 * k),
        );
        expect(await _wi428PumpUntilHighlight(tester), isTrue);
        await tester.pump();
        final rect = tester.getRect(row);
        final segment = tester.getRect(
          find.byKey(const ValueKey('text-segment-0')),
        );
        expect(
          segment.left + 8,
          lessThan(rect.left),
          reason: 'the marker sits left of the item row: $segment $rect',
        );
        final x = segment.left + 4;
        await _wi428ExpectLitPoints(
          tester,
          [
            Offset(x, rect.center.dy),
            Offset(rect.left + 4, rect.center.dy),
            Offset(x, tester.getRect(next).center.dy),
          ],
          [true, true, false],
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a same note arrival lands on the passage after an edit of the note was saved',
      (tester) async {
        final h = await _wi428Launch(tester);
        await twoTabsOnB(tester, h);
        const k = 200;
        final lines = _wi428Lines(_wi428Pairs);

        // Append a line far below the passage and let the save land.
        final edited = '${_wi428Body(_wi428Pairs)}tail\n';
        h.read(editorControllerProvider.notifier).onContentChanged(edited);
        h.clock.advance(saveDebounce);
        await pumpFrames(tester);
        expect(stored(h, _wi428B), edited, reason: 'the save landed');
        expect(h.read(editorControllerProvider).status, SaveStatus.clean);

        await _wi428OpenEcho(
          tester,
          h,
          _wi428B,
          _wi428ByteOf(lines, 2 * k + 1),
          cmd: true,
        );
        await _wi428ExpectHighlightOn(
          tester,
          _wi428Row(0, _wi428PassageRow(k)),
          clear: [_wi428Row(0, _wi428PassageRow(k + 1))],
        );
        expect(h.tabState.activeIndex, 0, reason: 'Cmd focused the first tab');
        expect(h.target, isNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'an arrival while the note shows text that is not stored opens at the top with no highlight',
      (tester) async {
        final db = _wi428Seed();
        final held = Completer<MemexResult>();
        final cli = FakeMemexCli()
          ..on(
            'settings get',
            (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout),
          )
          ..on('update', (_) => held.future);
        final h = await pumpWorkspace(tester, db: db, cli: cli);
        await twoTabsOnB(tester, h);
        // The active tab's editor is scrolled away from the top.
        await _wi428ScrollTo(tester, _wi428Left);
        const k = 200;
        final lines = _wi428Lines(_wi428Pairs);

        // An edit whose save is in flight: the editor shows text the stored
        // note does not have.
        final edited = '${_wi428Body(_wi428Pairs)}tail\n';
        h.read(editorControllerProvider.notifier).onContentChanged(edited);
        h.clock.advance(saveDebounce);
        await pumpFrames(tester);
        expect(stored(h, _wi428B), isNot(edited), reason: 'not stored yet');

        await _wi428OpenEcho(
          tester,
          h,
          _wi428B,
          _wi428ByteOf(lines, 2 * k + 1),
          cmd: true,
        );
        // The passage can't be located against the shown text: the editor
        // retries for eight frames, then opens the note at the top.
        var frames = 0;
        while (_wi428Pixels(tester) != 0.0 && frames < 30) {
          await tester.pump();
          frames++;
          expect(_wi428Highlight, findsNothing);
        }
        expect(_wi428Pixels(tester), 0.0, reason: 'opens at the top');
        expect(frames, _wi428FallbackFrames, reason: 'after 8 retried frames');
        await _wi428ExpectNoHighlight(tester);
        expect(h.tabState.activeIndex, 0);
        expect(h.target, isNull, reason: 'the target is used up');
        expect(tester.takeException(), isNull);
        held.complete(FakeMemexCli.error('unavailable', 'held save released'));
        await pumpFrames(tester);
      },
    );
  });

  group('superseded and unmounted landings', () {
    testWidgets(
      'an arrival that supersedes an echo before its landing frame cancels the landing',
      (tester) async {
        final h = await _wi428Launch(tester);
        await _wi428Navigate(tester, h, _wi428B);
        await _wi428ScrollTo(tester, _wi428Left);
        h.tabs.openOrFocus(const NoteTab(_wi428A));
        await pumpFrames(tester);
        await _wi428Navigate(tester, h, _wi428B);
        expect(h.tabState.activeIndex, 1);

        // The echo focuses the first B tab; before any frame runs, the second
        // tab is focused again with no target: that arrival owns the jump.
        await _wi428OpenEcho(
          tester,
          h,
          _wi428B,
          _wi428ByteOf(_wi428Lines(_wi428Pairs), 2 * 200 + 1),
          cmd: true,
        );
        expect(h.tabState.activeIndex, 0);
        h.tabs.openOrFocus(const NoteTab(_wi428A));
        h.tabs.follow(const NoteTab(_wi428B));

        await _wi428ExpectNoHighlight(tester);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('an echo landing due after the editor is gone does nothing', (
      tester,
    ) async {
      final h = await _wi428Launch(tester);
      await _wi428Navigate(tester, h, _wi428A);
      await _wi428OpenEcho(
        tester,
        h,
        _wi428B,
        _wi428ByteOf(_wi428Lines(_wi428Pairs), 2 * 150 + 1),
      );

      // The next frame unmounts the editor, then runs its landing callback.
      await tester.pumpWidget(const SizedBox());

      expect(tester.takeException(), isNull);
      expect(_wi428Highlight, findsNothing);
    });
  });
}
