// WI #247 (A6, Spec #234 R8, R20, R21, R30; rulings D19a, D51, D52; design pack
// design/229-tags/packs/247.md, whose "no plain hover change" D52 overrides):
// a click on a rendered `#tag` opens Tags mode, in the editor and in an excerpt
// card.
//
// - Plain click: only on a line whose markup is hidden; with the caret on the
//   line it places the caret, so a person can edit the tag. Cmd+click always
//   opens. Neither navigates: click tests assert `TabsRecorder` stays empty.
// - Plain hover on a hidden-markup line: the click cursor and nothing else.
//   The underline and `accentSoft` come only with Cmd held (D52). Wikilinks and
//   links keep today's hover.
// - A hash the server reads as no tag gets no click, hover or cursor: a line in
//   a tilde fence (the ink is dropped, the token is not), `|#x|` in a table cell.
// - Cards: a tag-only pointer path in `card_rows.dart`; a press and a release on
//   the same tag open it, and wikilinks in a card stay inert.
//
// Everything runs in the workspace on FakeVaultDb + FakeMemexCli with the real
// sidebar, so "expanded and scrolled into view" is read off the Tags pane. Test
// names are single literals (the AC map matches them), with no hash or pipe.
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/markdown_inline.dart';
import 'package:open_memex_app/src/state/sidebar_mode_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/tags_browse_state.dart';
import 'package:open_memex_app/src/state/url_opener.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/link_region.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/table_grid.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/editor_scope.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/recording_tabs.dart';
import '../support/segment_editing_finder.dart' show textSegmentKey;
import '../support/table_harness.dart'
    show
        expectTableRendered,
        expectTableRevealed,
        tableCell,
        tableRowController;
import '../support/tags_seed.dart';
import '../support/wi159_line_geometry.dart' show wi159EditableIn;

/// The note titled `Known` that resolved wikilinks open.
const _knownId = 'topic-known';

/// Far past the Tags pane's fold, so `work` must scroll to be seen (rows sort
/// alphabetically and `work` sorts after them).
const _manyTags = 80;

const _dragPast = kPrecisePointerHitSlop + 1;

/// Everything a test needs after [_launch].
class _T {
  _T(this.r, this.tabs, this.opener);

  final SegmentedEditorRobot r;
  final TabsRecorder tabs;
  final RecordingUrlOpener opener;

  WidgetTester get tester => r.tester;
  WorkspaceHarness get h => r.h;

  SidebarMode get mode => h.read(sidebarModeProvider);
  String? get expanded => h.read(expandedTagProvider);
  bool get systemOpen => h.read(tagsSystemOpenProvider);

  /// Tags mode is open on [tag], and the click went through no navigation.
  void expectOpened(String tag, {bool system = false, String? why}) {
    expect(mode, SidebarMode.tags, reason: why ?? 'Tags mode');
    expect(expanded, tag, reason: why ?? 'the expanded tag');
    expect(systemOpen, system, reason: why ?? 'the System group');
    expectNoFollow(why: why);
  }

  /// Nothing has navigated and the active note is the one the test opened.
  void expectNoFollow({String? why}) {
    expect(tabs.followed, isEmpty, reason: why ?? 'no follow');
    expect(tabs.navigated, isEmpty, reason: why ?? 'no navigation');
    r.expectActiveNote(fixtureTopicId);
  }

  /// The sidebar is still in [expected] mode with nothing expanded.
  void expectModeAlone({SidebarMode expected = SidebarMode.days, String? why}) {
    expect(mode, expected, reason: why ?? 'the mode stays');
    expect(expanded, isNull, reason: why ?? 'no tag expanded');
    expect(
      h.read(tagsScrollRequestProvider),
      isNull,
      reason: why ?? 'no scroll request',
    );
  }

  /// Puts the sidebar back to Days with nothing expanded.
  Future<void> resetSidebar() async {
    h.read(sidebarModeProvider.notifier).select(SidebarMode.days).ignore();
    h.read(expandedTagProvider.notifier).state = null;
    h.read(tagsSystemOpenProvider.notifier).state = false;
    h.read(tagsScrollRequestProvider.notifier).state = null;
    await pumpFrames(tester);
  }
}

/// Pumps the workspace on [seedSegmentedVault] with the topic note body [body]
/// (plus `Known`, id [_knownId]), [_manyTags] tags ahead of `work`, `pricing`,
/// `inbox` and `agent-authored` on the Tags pane, and opens the note. The
/// sidebar starts in Days.
Future<_T> _launch(
  WidgetTester tester,
  String body, {
  List<String> blocks = const [],
}) async {
  final vault = seedSegmentedVault(topicBody: body);
  vault.db.seedTopicNote(_knownId, 'Known');
  for (final (i, text) in blocks.indexed) {
    vault.db.seedBlock(fixtureDailyId, _blockId(i), ord: 3 + i, text: text);
  }
  for (final tag in ['work', 'pricing', 'inbox', 'agent-authored']) {
    vault.db.seedTag(fixtureTopicId, tag);
  }
  for (var i = 0; i < _manyTags; i++) {
    vault.db.seedTag('topic-other', 'filler-${i.toString().padLeft(2, '0')}');
  }
  final tabs = TabsRecorder();
  final opener = RecordingUrlOpener();
  final h = await pumpWorkspace(
    tester,
    db: vault.db,
    cli: vault.cli,
    overrides: [tabs.override, urlOpenerProvider.overrideWithValue(opener)],
  );
  final r = SegmentedEditorRobot(tester, h);
  await r.open(fixtureTopicId);
  await pumpFrames(tester);
  tabs.followed.clear();
  tabs.navigated.clear();
  return _T(r, tabs, opener);
}

String _blockId(int i) => 'tc247${'abcdefgh'[i]}';

/// The topic body with one card of [blocks] (`Intro line`, card 1, `Outro
/// line`): text segment 0, card 1, text segment 2.
String _cardBody(List<String> blocks) {
  final token = blocks.length == 1
      ? '![[2026-09-05#^${_blockId(0)}]]'
      : '![[2026-09-05#^${_blockId(0)}..^${_blockId(blocks.length - 1)}]]';
  return 'Intro line\n$token\nOutro line\n';
}

/// [_launch] on a note holding one card of [blocks].
Future<_T> _launchCard(WidgetTester tester, List<String> blocks) async {
  final t = await _launch(tester, _cardBody(blocks), blocks: blocks);
  expect(t.r.card(1), findsOneWidget);
  return t;
}

// ----------------------------------------------------------- editor geometry

LineBoxSource _segmentBoxes(WidgetTester tester, [int seg = 0]) {
  final view = tester.state<SegmentViewState>(
    find.descendant(
      of: find.byKey(textSegmentKey(seg)),
      matching: find.byType(SegmentView),
    ),
  );
  return view.lineBoxes() ?? (throw TestFailure('segment $seg has no layout'));
}

/// The global rect of [local] in [boxes]' box coordinates.
Rect _global(LineBoxSource boxes, Rect local) => Rect.fromPoints(
  boxes.box.localToGlobal(local.topLeft),
  boxes.box.localToGlobal(local.bottomRight),
);

/// The global rect of the shown text [needle] in text segment [seg].
Rect _rectOf(_T t, String needle, {int seg = 0, int nth = 0}) {
  final text = t.r.segmentText(seg);
  var at = -1;
  for (var i = 0; i <= nth; i++) {
    at = text.indexOf(needle, at + 1);
    expect(at, isNonNegative, reason: 'segment $seg holds "$needle" #$i');
  }
  final boxes = _segmentBoxes(t.tester, seg);
  final rects = boxes.boxesFor(TextRange(start: at, end: at + needle.length));
  expect(rects, isNotEmpty, reason: '"$needle" has a glyph box');
  return _global(boxes, rects.first);
}

Offset _on(_T t, String needle, {int seg = 0, int nth = 0}) =>
    _rectOf(t, needle, seg: seg, nth: nth).center;

/// The middle of the glyph at segment [offset].
Offset _glyph(_T t, int offset, {int seg = 0}) {
  final boxes = _segmentBoxes(t.tester, seg);
  final rects = boxes.boxesFor(TextRange(start: offset, end: offset + 1));
  expect(rects, isNotEmpty, reason: 'a glyph at $offset');
  return _global(boxes, rects.first).center;
}

/// The segment offset of [needle], plus [plus].
int _offsetOf(_T t, String needle, {int seg = 0, int plus = 0}) {
  final at = t.r.segmentText(seg).indexOf(needle);
  expect(at, isNonNegative, reason: 'segment $seg holds "$needle"');
  return at + plus;
}

/// The caret offset the segment's boxes give for global [at].
int _boxOffsetAt(_T t, Offset at, {int seg = 0}) {
  final boxes = _segmentBoxes(t.tester, seg);
  return boxes.offsetAt(boxes.box.globalToLocal(at));
}

// --------------------------------------------------------------- span reading

/// The effective style of the code unit at [offset] of [root].
TextStyle _styleAt(InlineSpan root, int offset) {
  TextStyle? found;
  var pos = 0;
  bool visit(InlineSpan span, TextStyle inherited) {
    final style = span.style == null ? inherited : inherited.merge(span.style);
    if (span is TextSpan) {
      final text = span.text ?? '';
      if (offset >= pos && offset < pos + text.length) {
        found = style;
        return false;
      }
      pos += text.length;
      for (final child in span.children ?? const <InlineSpan>[]) {
        if (!visit(child, style)) return false;
      }
    }
    return true;
  }

  visit(root, const TextStyle());
  expect(found, isNotNull, reason: 'offset $offset is in the span');
  return found!;
}

/// The style of the first unit of [needle] in [root]'s text.
TextStyle _styleOfNeedle(InlineSpan root, String needle) {
  final plain = root.toPlainText();
  final at = plain.indexOf(needle);
  expect(at, isNonNegative, reason: '"$needle" in "$plain"');
  return _styleAt(root, at);
}

/// Expects [style] to be a tag at rest: `fg2`, no underline.
void _expectAtRest(TextStyle style, {String? why}) {
  expect(style.color, OmColors.fg2, reason: why ?? 'fg2 at rest');
  expect(
    style.decoration?.contains(TextDecoration.underline) ?? false,
    isFalse,
    reason: why ?? 'no underline at rest',
  );
}

/// Expects [style] to be a Cmd-hovered tag: `accentSoft`, a solid underline in
/// the text colour.
void _expectCmdHovered(TextStyle style, {String? why}) {
  expect(style.color, OmColors.accentSoft, reason: why ?? 'accentSoft');
  expect(
    style.decoration?.contains(TextDecoration.underline) ?? false,
    isTrue,
    reason: why ?? 'underlined',
  );
  expect(
    style.decorationStyle ?? TextDecorationStyle.solid,
    TextDecorationStyle.solid,
    reason: why ?? 'a solid underline',
  );
}

/// The rendered span of editor row [row] of segment [seg].
InlineSpan _rowSpan(WidgetTester tester, int row, {int seg = 0}) =>
    wi159EditableIn(tester, find.byKey(Key('editor-row-$seg-$row'))).text!;

/// The live preview controller of editor row [row] of segment [seg].
LivePreviewController _rowController(
  WidgetTester tester,
  int row, {
  int seg = 0,
}) => tableRowController(tester, seg, row);

// ---------------------------------------------------------------- mouse input

/// The mouse cursor the app shows for the test mouse (device 1).
MouseCursor? _cursor() =>
    RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);

Future<void> _cmdDown(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
  await tester.pump();
}

Future<void> _cmdUp(WidgetTester tester) async {
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
  await tester.pump();
}

/// Adds a hovering mouse at [at] (no button down) and pumps.
Future<TestGesture> _mouseAt(WidgetTester tester, Offset at) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: at);
  await tester.pump();
  await mouse.moveTo(at);
  await tester.pump();
  return mouse;
}

Future<void> _removeMouse(WidgetTester tester, TestGesture mouse) async {
  await mouse.removePointer();
  await tester.pump();
}

/// Removes the mouse a click (a mouse `tapAt`) leaves added, so a later
/// [_mouseAt] can add it again without a MouseTracker assertion.
Future<void> _dropClickMouse(WidgetTester tester) async {
  final stale = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await _removeMouse(tester, stale);
}

/// Lets the double-click window pass, so the next click is a single click.
Future<void> _pastDoubleClick(WidgetTester tester) =>
    tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 200));

/// A plain click at [at], then frames and past the double-click window.
Future<void> _click(WidgetTester tester, Offset at) async {
  await tester.macClick(at);
  await pumpFrames(tester);
  await _pastDoubleClick(tester);
}

/// A Cmd+click at [at], then frames and past the double-click window.
Future<void> _cmdClick(WidgetTester tester, Offset at) async {
  await tester.macCmdClick(at);
  await pumpFrames(tester);
  await _pastDoubleClick(tester);
}

/// A mouse press at [from], moved to [to], released, then pumps.
Future<void> _pressMoveRelease(
  WidgetTester tester,
  Offset from,
  Offset to, {
  int buttons = kPrimaryButton,
}) async {
  final mouse = await tester.startGesture(
    from,
    kind: PointerDeviceKind.mouse,
    buttons: buttons,
  );
  await tester.pump();
  await mouse.moveTo(to);
  await tester.pump();
  await mouse.up();
  await pumpFrames(tester);
  await _pastDoubleClick(tester);
  await _dropClickMouse(tester);
}

// ------------------------------------------------------------- card geometry

/// Every row text paragraph of card [card], in row order.
List<Element> _cardRowTexts(_T t, {int card = 1}) => find
    .descendant(
      of: find.descendant(
        of: t.r.card(card),
        matching: find.byWidgetPredicate((w) {
          final k = w.key;
          return k is ValueKey<String> && k.value.startsWith('card-row-text-');
        }),
      ),
      matching: find.byType(RichText),
    )
    .evaluate()
    .toList();

/// The paragraph of card [card] holding the [nth] [needle], and where.
(RenderParagraph, int) _cardHit(
  _T t,
  String needle, {
  int nth = 0,
  int card = 1,
}) {
  var left = nth;
  for (final element in _cardRowTexts(t, card: card)) {
    final paragraph = element.renderObject! as RenderParagraph;
    final plain = paragraph.text.toPlainText();
    var at = plain.indexOf(needle);
    while (at >= 0) {
      if (left == 0) return (paragraph, at);
      left--;
      at = plain.indexOf(needle, at + 1);
    }
  }
  throw TestFailure('card $card holds no "$needle" #$nth');
}

/// The global rect of the [nth] [needle]'s glyphs in card [card].
Rect _cardRect(_T t, String needle, {int nth = 0, int card = 1}) {
  final (paragraph, at) = _cardHit(t, needle, nth: nth, card: card);
  final box = paragraph
      .getBoxesForSelection(
        TextSelection(baseOffset: at, extentOffset: at + needle.length),
        boxHeightStyle: ui.BoxHeightStyle.max,
      )
      .first
      .toRect();
  return box.shift(paragraph.localToGlobal(Offset.zero));
}

Offset _onCard(_T t, String needle, {int nth = 0, int card = 1}) =>
    _cardRect(t, needle, nth: nth, card: card).center;

/// The style of the first unit of the [nth] [needle] in card [card], as the
/// row's current span renders it.
TextStyle _cardStyle(_T t, String needle, {int nth = 0, int card = 1}) {
  final (paragraph, at) = _cardHit(t, needle, nth: nth, card: card);
  return _styleAt(paragraph.text, at);
}

/// The grid of card row [row].
Finder _cardGrid(_T t, int row, {int card = 1}) => find.descendant(
  of: t.r.card(card),
  matching: find.byKey(Key('card-table-$row')),
);

/// The global rect of [token]'s glyphs in [table], the text of card row [row]'s
/// grid, through the grid's line-box seam.
Rect _cardGridRect(_T t, int row, String table, String token, {int card = 1}) {
  final state = t.tester.state<TableGridState>(_cardGrid(t, row, card: card));
  final boxes =
      state.lineBoxes() ?? (throw TestFailure('card-table-$row has no layout'));
  final at = table.indexOf(token);
  expect(at, isNonNegative, reason: '"$token" in the table');
  final rects = boxes.boxesFor(TextRange(start: at, end: at + token.length));
  expect(rects, isNotEmpty, reason: '"$token" has glyph boxes');
  return _global(boxes, rects.first);
}

/// The rendered span of the [row]-[col] cell of card row [cardRow]'s grid: the
/// RichText whose text is [cellText].
InlineSpan _cardCellSpan(_T t, int cardRow, String cellText) {
  final riches = t.tester.widgetList<RichText>(
    find.descendant(of: _cardGrid(t, cardRow), matching: find.byType(RichText)),
  );
  return riches.firstWhere((rich) => rich.text.toPlainText() == cellText).text;
}

// ------------------------------------------------ a bare LinkRegion on a field

/// A [LinkRegion] over one unfocused field whose controller gets no fence state
/// from a host, so the fallback to the text is what decides.
class _Field {
  _Field(this.tester, this.controller, this.fieldKey);

  final WidgetTester tester;
  final LivePreviewController controller;
  final GlobalKey fieldKey;

  ProviderContainer get container =>
      ProviderScope.containerOf(tester.element(find.byType(LinkRegion)));

  RenderEditable get _editable => wi159EditableIn(tester, find.byKey(fieldKey));

  /// The middle of the shown text [needle].
  Offset on(String needle) {
    final source = RenderEditableLineBoxes(_editable);
    final at = controller.text.indexOf(needle);
    expect(at, isNonNegative);
    final rects = source.boxesFor(
      TextRange(start: at, end: at + needle.length),
    );
    expect(rects, isNotEmpty);
    return source.box.localToGlobal(rects.first.center);
  }

  String? get expanded => container.read(expandedTagProvider);
  void reset() => container.read(expandedTagProvider.notifier).state = null;
}

Future<_Field> _pumpField(WidgetTester tester, String text) async {
  final controller = LivePreviewController(text: text);
  addTearDown(controller.dispose);
  final key = GlobalKey();
  await pumpEditorScoped(
    tester,
    MaterialApp(
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 700,
            child: LinkRegion(
              controller: controller,
              boxes: () {
                final context = key.currentContext;
                if (context == null) return null;
                return RenderEditableLineBoxes(
                  wi159EditableIn(tester, find.byKey(key)),
                );
              },
              child: TextField(
                key: key,
                controller: controller,
                maxLines: null,
              ),
            ),
          ),
        ),
      ),
    ),
    titles: [NoteTitle(id: _knownId, title: 'Known', updatedAt: 1)],
  );
  await tester.pump();
  await tester.pump();
  return _Field(tester, controller, key);
}

void main() {
  holdFontFetches();

  // ---------------------------------------------------------------- predicate
  group('isPlainClickFollowable', () {
    test('isPlainClickFollowable is true for a tag token', () {
      final token = tokenizeInline(
        '#work',
      ).firstWhere((t) => t.kind == InlineTokenKind.tag);
      expect(isPlainClickFollowable(token), isTrue);
    });
  });

  // ------------------------------------------------------- the editor, a click
  group('a click on a tag in the editor', () {
    testWidgets(
      'a plain click on a rendered work tag switches to Tags mode with work expanded and scrolled into view',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext line\n');
        expect(find.byKey(const Key('days-pane')), findsOneWidget);
        expect(find.byKey(const Key('tag-row-work')), findsNothing);

        await _click(tester, _on(t, '#work'));
        await pumpFrames(tester, frames: 8);

        t.expectOpened('work');
        expect(find.byKey(const Key('tags-pane')), findsOneWidget);
        expect(find.byKey(const Key('days-pane')), findsNothing);
        final row = find.byKey(const Key('tag-row-work'));
        expect(row, findsOneWidget);
        final view = tester.getRect(
          find.ancestor(of: row, matching: find.byType(Scrollable)).first,
        );
        final rect = tester.getRect(row);
        expect(rect.top, greaterThanOrEqualTo(view.top - 0.5));
        expect(rect.bottom, lessThanOrEqualTo(view.bottom + 0.5));
        expect(
          find.byKey(Key('tag-note-row-work-$fixtureTopicId')),
          findsOneWidget,
          reason: 'its notes are listed under it',
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'a Cmd click on a rendered work tag switches to Tags mode with work expanded and scrolled into view',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext line\n');

        await _cmdClick(tester, _on(t, '#work'));
        await pumpFrames(tester, frames: 8);

        t.expectOpened('work');
        final row = find.byKey(const Key('tag-row-work'));
        expect(row, findsOneWidget);
        final view = tester.getRect(
          find.ancestor(of: row, matching: find.byType(Scrollable)).first,
        );
        final rect = tester.getRect(row);
        expect(rect.top, greaterThanOrEqualTo(view.top - 0.5));
        expect(rect.bottom, lessThanOrEqualTo(view.bottom + 0.5));
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain click elsewhere in the line places the caret and leaves the mode alone and a tag on another line still opens',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext #pricing\n');
        final at = _on(t, 'here');
        final expected = _boxOffsetAt(t, at);

        await _click(tester, at);

        expect(t.r.segmentHasFocus(0), isTrue);
        expect(
          t.r.segmentSelection(0),
          TextSelection.collapsed(offset: expected),
        );
        t.expectModeAlone();

        await _click(tester, _on(t, '#pricing'));
        t.expectOpened('pricing');
      },
      variant: macOnly,
    );

    testWidgets(
      'a press just left of the tag places the caret and a press on its first glyph opens it',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext line\n');
        final rect = _rectOf(t, '#work');

        await _click(tester, Offset(rect.left - 1, rect.center.dy));

        expect(t.r.segmentHasFocus(0), isTrue);
        t.expectModeAlone(why: 'a pixel left of the hash');

        await t.r.pressKey(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        final first = _rectOf(t, '#');
        await _click(tester, Offset(first.left + 1, first.center.dy));
        t.expectOpened('work', why: 'a pixel into the hash');
      },
      variant: macOnly,
    );

    testWidgets(
      'a press just past the tag end places the caret and a press on its last glyph opens it',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext line\n');
        final rect = _rectOf(t, '#work');

        await _click(tester, Offset(rect.right + 1, rect.center.dy));

        expect(t.r.segmentHasFocus(0), isTrue);
        t.expectModeAlone(why: 'a pixel past the k');

        await t.r.pressKey(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        final last = _rectOf(t, 'k here');
        await _click(tester, Offset(last.left + 1, last.center.dy));
        t.expectOpened('work', why: 'a pixel into the k');
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain click on a rendered inbox tag opens Tags mode with System expanded',
      (tester) async {
        final t = await _launch(tester, 'Intro #inbox here\nNext line\n');

        await _click(tester, _on(t, '#inbox'));
        await pumpFrames(tester, frames: 8);

        t.expectOpened('inbox', system: true);
        expect(find.byKey(const Key('tag-row-inbox')), findsOneWidget);
        expect(find.byKey(const Key('tag-row-agent-authored')), findsOneWidget);
        expect(
          find.byKey(Key('tag-note-row-inbox-$fixtureTopicId')),
          findsOneWidget,
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'a Cmd click on a rendered agent authored tag opens Tags mode with System expanded',
      (tester) async {
        final t = await _launch(tester, 'See #agent-authored now\nNext\n');

        await _cmdClick(tester, _on(t, '#agent-authored'));

        t.expectOpened('agent-authored', system: true);
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain click on a mixed case Work tag opens the lowercase work',
      (tester) async {
        final t = await _launch(tester, 'Intro #Work here\nNext line\n');

        await _click(tester, _on(t, '#Work'));

        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a Cmd click on an upper case INBOX tag opens System with inbox expanded',
      (tester) async {
        final t = await _launch(tester, 'Intro #INBOX here\nNext line\n');

        await _cmdClick(tester, _on(t, '#INBOX'));

        t.expectOpened('inbox', system: true);
      },
      variant: macOnly,
    );

    testWidgets(
      'a click on a tag with a trailing dash opens the name without the dash',
      (tester) async {
        final t = await _launch(tester, 'Intro #work- here\nNext line\n');

        await _click(tester, _on(t, '#work'));

        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain click and a Cmd click on a tag record no follow and change no tab',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext #pricing\n');
        final open = List<WorkspaceTab>.of(t.h.read(tabsProvider).tabs);
        final canGoBack = t.h.read(tabsProvider).canGoBack;

        await _click(tester, _on(t, '#work'));
        t.expectOpened('work', why: 'the plain click');
        expect(t.h.read(tabsProvider).tabs, open);
        expect(t.h.read(tabsProvider).canGoBack, canGoBack);

        await t.resetSidebar();
        await _cmdClick(tester, _on(t, '#pricing'));
        t.expectOpened('pricing', why: 'the Cmd click');
        expect(t.h.read(tabsProvider).tabs, open);
        expect(t.h.read(tabsProvider).canGoBack, canGoBack);
        expect(t.r.updates, isEmpty, reason: 'nothing is written');
      },
      variant: macOnly,
    );

    testWidgets('a plain click on a tag moves no caret and focuses no row', (
      tester,
    ) async {
      final t = await _launch(tester, 'Intro #work here\n- second words\n');
      final caret = _offsetOf(t, 'words', plus: 2);
      await t.r.focusSegment(0, offset: caret);
      expect(t.r.segment(0).focusedRow, 1);

      await _click(tester, _on(t, '#work'));

      t.expectOpened('work');
      expect(t.r.segmentSelection(0), TextSelection.collapsed(offset: caret));
      expect(t.r.segment(0).focusedRow, 1);
    }, variant: macOnly);

    for (final (name, body) in [
      (
        'a plain click on a tag in a heading row opens it',
        '# Title #work\nEnd\n',
      ),
      (
        'a plain click on a tag in a bullet row opens it',
        '- item #work\nEnd\n',
      ),
      (
        'a plain click on a tag in a numbered row opens it',
        '1. item #work\nEnd\n',
      ),
      (
        'a plain click on a tag in a task row opens it',
        '- [ ] item #work\nEnd\n',
      ),
      (
        'a plain click on a tag in a quote row opens it',
        '> quoted #work\nEnd\n',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final t = await _launch(tester, body);

        await _click(tester, _on(t, '#work'));

        t.expectOpened('work');
      }, variant: macOnly);
    }

    testWidgets(
      'source mode opens no tag on a plain click or a Cmd click and the normal view does',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext line\n');
        final point = _on(t, '#work');

        await t.r.toggleSource();
        expect(t.r.sourceBody, findsOneWidget);
        final field = wi159EditableIn(tester, t.r.sourceBody);
        final at = 'Intro #work here\nNext line\n'.indexOf('#work');
        final box = RenderEditableLineBoxes(field);
        final inSource = field.localToGlobal(
          box.boxesFor(TextRange(start: at, end: at + 5)).first.center,
        );
        await _click(tester, inSource);
        await _cmdClick(tester, inSource);
        t.expectModeAlone(why: 'source mode');

        await t.r.toggleSource();
        await _dropClickMouse(tester);
        await _click(tester, point);
        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a secondary click on a tag opens nothing and a primary click opens it',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext line\n');
        final at = _on(t, '#work');

        await _pressMoveRelease(tester, at, at, buttons: kSecondaryMouseButton);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await pumpFrames(tester);
        t.expectModeAlone(why: 'the secondary click');

        // The context menu's click placed the caret: leave the line.
        await t.r.focusSegment(0, offset: t.r.segmentText(0).length - 1);
        await tester.pump();
        await _click(tester, _on(t, '#work'));
        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a Shift click on a tag extends the selection and opens nothing and a Cmd click opens it',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext words\n');
        final caret = _offsetOf(t, 'words', plus: 2);
        await t.r.focusSegment(0, offset: caret);

        await tester.macClick(_on(t, '#work'), shift: true);
        await pumpFrames(tester);
        await _pastDoubleClick(tester);

        final selection = t.r.segmentSelection(0);
        expect(selection.isCollapsed, isFalse, reason: 'the selection grew');
        expect(selection.baseOffset, caret);
        t.expectModeAlone(why: 'Shift+click');

        await _cmdClick(tester, _on(t, '#work'));
        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets('a press on a tag released inside the slop opens it', (
      tester,
    ) async {
      final t = await _launch(tester, 'Intro #work here\nNext line\n');
      final at = _on(t, '#work');

      await _pressMoveRelease(
        tester,
        at,
        at + const Offset(kPrecisePointerHitSlop, 0),
      );

      t.expectOpened('work');
    }, variant: macOnly);

    testWidgets(
      'a press on a tag dragged past the slop selects from the press and opens nothing and another tag then opens',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext #pricing\n');
        final at = _on(t, '#work');
        final expected = _boxOffsetAt(t, at);

        await _pressMoveRelease(tester, at, at + const Offset(_dragPast, 0));

        t.expectModeAlone(why: 'past the slop');
        expect(t.r.segmentSelection(0).baseOffset, expected);

        await _click(tester, _on(t, '#pricing'));
        t.expectOpened('pricing');
      },
      variant: macOnly,
    );

    testWidgets(
      'a Cmd press on one tag released on another opens neither and a Cmd click opens it',
      (tester) async {
        final t = await _launch(tester, 'Intro #work and #pricing\nNext\n');

        await tester.macHolding([LogicalKeyboardKey.metaLeft], () async {
          final mouse = await tester.startGesture(
            _on(t, '#work'),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump();
          await mouse.moveTo(_on(t, '#pricing'));
          await tester.pump();
          await mouse.up();
          await tester.pump();
        });
        await pumpFrames(tester);
        await _pastDoubleClick(tester);
        t.expectModeAlone(why: 'released on the other tag');

        await _dropClickMouse(tester);
        await _cmdClick(tester, _on(t, '#pricing'));
        t.expectOpened('pricing');
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------- the caret on the line (D51 a)
  group('a tag on a line with its markup showing', () {
    testWidgets(
      'with the caret on the line a plain click on the tag places the caret and stays in the current mode and a Cmd click opens it',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext line\n');
        t.h
            .read(sidebarModeProvider.notifier)
            .select(SidebarMode.topics)
            .ignore();
        await pumpFrames(tester);
        await t.r.focusSegment(0, offset: 2);
        await tester.pump();

        final at = _on(t, '#work');
        final expected = _boxOffsetAt(t, at);
        await _click(tester, at);

        expect(
          t.r.segmentSelection(0),
          TextSelection.collapsed(offset: expected),
          reason: 'a person can edit the tag',
        );
        t.expectModeAlone(expected: SidebarMode.topics);

        await _cmdClick(tester, _on(t, '#work'));
        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'with the caret on another line a plain click on the tag opens it',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext #pricing\n');
        await t.r.focusSegment(0, offset: _offsetOf(t, 'Next', plus: 1));
        await tester.pump();

        await _click(tester, _on(t, '#work'));
        t.expectOpened('work', why: 'caret on the other line');
      },
      variant: macOnly,
    );

    testWidgets(
      'on a line with its markup showing a plain hover keeps the text cursor and Cmd held brings the click cursor and underline',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext line\n');
        await t.r.focusSegment(0, offset: 2);
        await tester.pump();
        final mouse = await _mouseAt(tester, _on(t, '#work'));

        expect(_cursor(), isNot(SystemMouseCursors.click));
        expect(_rowController(tester, 0).cmdHover, isNull);

        await _cmdDown(tester);
        expect(_cursor(), SystemMouseCursors.click);
        _expectCmdHovered(_styleOfNeedle(_rowSpan(tester, 0), '#work'));

        await _cmdUp(tester);
        expect(_cursor(), isNot(SystemMouseCursors.click));
        expect(_rowController(tester, 0).cmdHover, isNull);
        await _removeMouse(tester, mouse);
      },
      variant: macOnly,
    );

    testWidgets(
      'a caret arriving on the hovered line takes the click cursor away and a caret leaving brings it back',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext line\n');
        final mouse = await _mouseAt(tester, _on(t, '#work'));
        expect(_cursor(), SystemMouseCursors.click, reason: 'hidden markup');

        await t.r.focusSegment(0, offset: 2);
        await pumpFrames(tester);
        expect(_cursor(), isNot(SystemMouseCursors.click), reason: 'revealed');

        await t.r.focusSegment(0, offset: _offsetOf(t, 'Next', plus: 1));
        await pumpFrames(tester);
        expect(_cursor(), SystemMouseCursors.click, reason: 'hidden again');
        await _removeMouse(tester, mouse);
      },
      variant: macOnly,
    );
  });

  // ------------------------------------------------------------- hover (D52)
  group('hovering a tag in the editor', () {
    testWidgets(
      'a plain hover over a tag on a hidden markup line shows the click cursor with no underline and no colour change',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext line\n');
        final mouse = await _mouseAt(tester, _on(t, '#work'));

        expect(_cursor(), SystemMouseCursors.click);
        expect(_rowController(tester, 0).cmdHover, isNull);
        _expectAtRest(_styleOfNeedle(_rowSpan(tester, 0), '#work'));

        await _removeMouse(tester, mouse);
      },
      variant: macOnly,
    );

    testWidgets(
      'with Cmd held a hover shows the underline on the tag and it goes when Cmd is released',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext line\n');
        final mouse = await _mouseAt(tester, _on(t, '#work'));
        final span = _offsetOf(t, '#work');

        await _cmdDown(tester);
        expect(_cursor(), SystemMouseCursors.click);
        expect(
          _rowController(tester, 0).cmdHover,
          TextRange(start: span, end: span + '#work'.length),
          reason: 'the whole tag, not the line',
        );
        _expectCmdHovered(_styleOfNeedle(_rowSpan(tester, 0), '#work'));
        expect(
          _styleOfNeedle(
                _rowSpan(tester, 0),
                'here',
              ).decoration?.contains(TextDecoration.underline) ??
              false,
          isFalse,
          reason: 'the text beside it has no underline',
        );

        await _cmdUp(tester);
        expect(_rowController(tester, 0).cmdHover, isNull);
        _expectAtRest(_styleOfNeedle(_rowSpan(tester, 0), '#work'));
        expect(
          _cursor(),
          SystemMouseCursors.click,
          reason: 'the plain hover cursor stays',
        );
        await _removeMouse(tester, mouse);
      },
      variant: macOnly,
    );

    testWidgets(
      'moving onto the tag with Cmd already held shows the underline and moving off takes it and the cursor away',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext line\n');
        final mouse = await _mouseAt(tester, _on(t, 'Intro'));
        await _cmdDown(tester);
        expect(_cursor(), isNot(SystemMouseCursors.click));

        await mouse.moveTo(_on(t, '#work'));
        await tester.pump();
        expect(_cursor(), SystemMouseCursors.click);
        _expectCmdHovered(_styleOfNeedle(_rowSpan(tester, 0), '#work'));

        await mouse.moveTo(_on(t, 'here'));
        await tester.pump();
        expect(_cursor(), isNot(SystemMouseCursors.click));
        _expectAtRest(_styleOfNeedle(_rowSpan(tester, 0), '#work'));

        await _cmdUp(tester);
        await _removeMouse(tester, mouse);
      },
      variant: macOnly,
    );

    testWidgets(
      'a hover beside the tag shows no click cursor and a hover on it does',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext line\n');
        final rect = _rectOf(t, '#work');

        final mouse = await _mouseAt(
          tester,
          Offset(rect.left - 1, rect.center.dy),
        );
        expect(
          _cursor(),
          isNot(SystemMouseCursors.click),
          reason: 'left of it',
        );

        await mouse.moveTo(Offset(rect.right + 1, rect.center.dy));
        await tester.pump();
        expect(
          _cursor(),
          isNot(SystemMouseCursors.click),
          reason: 'right of it',
        );

        await mouse.moveTo(Offset(rect.left + 1, rect.center.dy));
        await tester.pump();
        expect(_cursor(), SystemMouseCursors.click, reason: 'its first glyph');

        await mouse.moveTo(Offset(rect.right - 1, rect.center.dy));
        await tester.pump();
        expect(_cursor(), SystemMouseCursors.click, reason: 'its last glyph');
        await _removeMouse(tester, mouse);
      },
      variant: macOnly,
    );
  });

  // ------------------------------------------- a hash that is no tag (D51 b, c)
  group('a hash the server reads as no tag', () {
    /// A hover on the hash at [point]: no click cursor and no Cmd hover, with
    /// and without Cmd.
    Future<void> expectNoHover(
      _T t,
      Offset point, {
      required int row,
      String why = '',
    }) async {
      final tester = t.tester;
      final mouse = await _mouseAt(tester, point);
      expect(_cursor(), isNot(SystemMouseCursors.click), reason: 'plain $why');
      expect(
        _rowController(tester, row).cmdHover,
        isNull,
        reason: 'no plain hover $why',
      );
      await _cmdDown(tester);
      expect(_cursor(), isNot(SystemMouseCursors.click), reason: 'Cmd $why');
      expect(
        _rowController(tester, row).cmdHover,
        isNull,
        reason: 'no Cmd hover $why',
      );
      await _cmdUp(tester);
      await _removeMouse(tester, mouse);
    }

    /// A hover and a Cmd click on the hash at [point] do nothing.
    Future<void> expectInert(
      _T t,
      Offset point, {
      required int row,
      String why = '',
    }) async {
      await expectNoHover(t, point, row: row, why: why);
      await _cmdClick(t.tester, point);
      t.expectModeAlone(why: 'Cmd click $why');
      await _dropClickMouse(t.tester);
    }

    testWidgets(
      'a tag inside a tilde fence has no click no hover and no cursor and a tag below the fence opens',
      (tester) async {
        final t = await _launch(tester, '~~~\n#inside\n~~~\n#work\n');

        // Before any caret: a plain click on the fenced line stays a caret.
        final inside = _on(t, '#inside');
        await expectInert(t, inside, row: 0, why: 'in the fence');
        await _click(tester, inside);
        t.expectModeAlone(why: 'plain click in the fence');
        expect(t.r.segmentHasFocus(0), isTrue, reason: 'it placed a caret');
        await _dropClickMouse(tester);

        await _click(tester, _on(t, '#work'));
        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a tag on an item row inside a tilde fence has no click no hover and no cursor and a tag below the fence opens',
      (tester) async {
        // The row alone can't tell: `- #inside` opens no fence of its own, so
        // only the host's per-line answer says it is fenced.
        final t = await _launch(tester, '~~~\n- #inside\n~~~\n#work\n');

        await expectInert(t, _on(t, '#inside'), row: 1, why: 'item row');

        await _click(tester, _on(t, '#work'));
        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a tag inside a backtick fence has no click and a tag below the fence opens',
      (tester) async {
        final t = await _launch(tester, '```\n#inside\n```\n#work\n');
        final segment = t.r.segmentText(0);
        expect(segment, contains('#inside'));

        await _cmdClick(tester, _on(t, '#inside'));
        t.expectModeAlone(why: 'code row');
        await _dropClickMouse(tester);

        await _click(tester, _on(t, '#work'));
        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a fence opened on the line above takes the click off a tag whose text did not change and closing it gives the click back',
      (tester) async {
        final t = await _launch(tester, 'Plain\n- #work here\n');
        // Hover and hit once, so anything cached for this row is cached.
        final first = await _mouseAt(tester, _on(t, '#work'));
        expect(_cursor(), SystemMouseCursors.click);
        await _removeMouse(tester, first);

        t.r.segment(0).replaceText('~~~\n- #work here\n');
        await pumpFrames(tester);
        await _cmdClick(tester, _on(t, '#work'));
        t.expectModeAlone(why: 'fenced now');
        await _dropClickMouse(tester);

        t.r.segment(0).replaceText('Plain\n- #work here\n');
        await pumpFrames(tester);
        await _cmdClick(tester, _on(t, '#work'));
        t.expectOpened('work', why: 'the fence is gone');
      },
      variant: macOnly,
    );

    testWidgets(
      'a hash glued to a table pipe has no click no hover and no cursor and a spaced tag in the same row opens',
      (tester) async {
        final t = await _launch(
          tester,
          'Above\n|#glued| #work |\n|---|---|\n|a|b|\nBelow\n',
        );
        expectTableRendered(0, 1);

        await expectNoHover(t, _on(t, '#glued'), row: 1, why: 'on the grid');

        await _click(tester, _on(t, '#work'));
        t.expectOpened('work');
        expectTableRendered(0, 1, reason: 'opening reveals nothing');

        // A press on the glued hash is the grid's own: it reveals the table.
        await t.resetSidebar();
        await _click(tester, _on(t, '#glued'));
        t.expectModeAlone(why: 'plain click on the glued hash');
        expectTableRevealed(0, 1, reason: 'as any cell press does');

        await _cmdClick(tester, _on(t, '#glued'));
        t.expectModeAlone(why: 'Cmd click on the glued hash');
      },
      variant: macOnly,
    );

    testWidgets(
      'a hash glued to a quote marker has no click and a spaced tag on the next line opens',
      (tester) async {
        final t = await _launch(tester, '>#glued\nNext #work\n');

        await _cmdClick(tester, _on(t, '#glued'));
        t.expectModeAlone(why: 'after a quote marker');
        await _dropClickMouse(tester);

        await _click(tester, _on(t, '#work'));
        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a hash in a code span or a url has no click and a tag on the next line opens',
      (tester) async {
        final t = await _launch(
          tester,
          'Run `#code` or https://a.example/#frag now\nNext #work\n',
        );

        await _cmdClick(tester, _on(t, '#code'));
        t.expectModeAlone(why: 'a code span');
        await _dropClickMouse(tester);
        await _cmdClick(tester, _on(t, '#frag'));
        t.expectModeAlone(why: 'a url');
        await _dropClickMouse(tester);

        await _click(tester, _on(t, '#work'));
        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a bare field with no fence state judges the fence from its text so a fenced tag has no click and a tag below it opens',
      (tester) async {
        final f = await _pumpField(tester, '~~~\n#inside\n~~~\n#work\n');
        expect(f.controller.fenced, isNull);

        await _cmdClick(tester, f.on('#inside'));
        expect(f.expanded, isNull, reason: 'fenced by the text');
        await _dropClickMouse(tester);

        await _cmdClick(tester, f.on('#work'));
        expect(f.expanded, 'work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a fence state change on the same text takes the click off a tag and gives it back',
      (tester) async {
        final f = await _pumpField(tester, '#work here\n');

        await _cmdClick(tester, f.on('#work'));
        expect(f.expanded, 'work', reason: 'nothing fenced');
        f.reset();
        await _dropClickMouse(tester);

        f.controller.fenced = const [true];
        await tester.pump();
        await _cmdClick(tester, f.on('#work'));
        expect(f.expanded, isNull, reason: 'the host says fenced');
        await _dropClickMouse(tester);

        f.controller.fenced = const [false];
        await tester.pump();
        await _cmdClick(tester, f.on('#work'));
        expect(f.expanded, 'work', reason: 'the host says not fenced');
      },
      variant: macOnly,
    );

    testWidgets(
      'a segment start change on the same text takes the click off a tag in leading frontmatter and gives it back',
      (tester) async {
        // At a segment start the leading `---` lines are frontmatter and the
        // tag between them is no link; mid-segment they are rules.
        final f = await _pumpField(tester, '---\n#work\n---\n');
        expect(f.controller.atSegmentStart, isTrue);

        await _cmdClick(tester, f.on('#work'));
        expect(f.expanded, isNull, reason: 'frontmatter at a segment start');
        await _dropClickMouse(tester);

        f.controller.atSegmentStart = false;
        await tester.pump();
        await _cmdClick(tester, f.on('#work'));
        expect(f.expanded, 'work', reason: 'rules, not frontmatter');
        f.reset();
        await _dropClickMouse(tester);

        f.controller.atSegmentStart = true;
        await tester.pump();
        await _cmdClick(tester, f.on('#work'));
        expect(f.expanded, isNull, reason: 'frontmatter again');
      },
      variant: macOnly,
    );
  });

  // ------------------------------------------------- a rendered table (D51 c)
  group('a tag in a rendered table', () {
    const table = 'Above\n| #work | a |\n|---|---|\n| b | #pricing |\nBelow\n';

    testWidgets(
      'a plain click on a spaced tag in a rendered table row opens it and keeps the table rendered and the caret where it was',
      (tester) async {
        final t = await _launch(tester, table);
        await _click(tester, _on(t, 'Above'));
        final caret = t.r.segmentSelection(0);
        expect(t.r.segmentHasFocus(0), isTrue);
        expectTableRendered(0, 1);

        await _click(tester, _on(t, '#work'));

        t.expectOpened('work');
        expectTableRendered(0, 1, reason: 'opening reveals nothing');
        expect(t.r.segmentSelection(0), caret);
      },
      variant: macOnly,
    );

    testWidgets(
      'a Cmd click on a tag in a body row of a rendered table opens it',
      (tester) async {
        final t = await _launch(tester, table);

        await _cmdClick(tester, _on(t, '#pricing'));

        t.expectOpened('pricing');
        expectTableRendered(0, 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'with the caret in the table a plain click on its tag places the caret and a Cmd click opens it',
      (tester) async {
        final t = await _launch(tester, table);
        await _click(tester, _glyph(t, _offsetOf(t, '| a', plus: 2)));
        await pumpFrames(tester);
        expectTableRevealed(0, 1);

        await _click(tester, _on(t, '#pricing'));
        t.expectModeAlone(why: 'a revealed table');
        expectTableRevealed(0, 1);

        await _cmdClick(tester, _on(t, '#pricing'));
        t.expectOpened('pricing');
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain hover over a tag in a rendered table shows the click cursor with no underline and Cmd held underlines it',
      (tester) async {
        final t = await _launch(tester, table);
        final mouse = await _mouseAt(tester, _on(t, '#work'));

        InlineSpan cell() => tester
            .widget<RichText>(
              find.descendant(
                of: tableCell(0, 1, 0, 0),
                matching: find.byType(RichText),
              ),
            )
            .text;

        expect(_cursor(), SystemMouseCursors.click);
        _expectAtRest(_styleOfNeedle(cell(), '#work'));

        await _cmdDown(tester);
        _expectCmdHovered(_styleOfNeedle(cell(), '#work'));

        await _cmdUp(tester);
        _expectAtRest(_styleOfNeedle(cell(), '#work'));
        expect(_cursor(), SystemMouseCursors.click);
        await _removeMouse(tester, mouse);
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain click beside a tag in a rendered table reveals the table as any cell press does and leaves the mode alone',
      (tester) async {
        final t = await _launch(tester, table);

        await _click(tester, _glyph(t, _offsetOf(t, '| a', plus: 2)));

        expectTableRevealed(0, 1, reason: 'a press beside the tag is a reveal');
        t.expectModeAlone();

        await _cmdClick(tester, _on(t, '#work'));
        t.expectOpened('work');
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------- wikilinks and links, as before
  group('wikilinks and links beside a tag behave as before', () {
    testWidgets(
      'a plain click and a Cmd click on a wikilink beside a tag follow it and leave the sidebar mode alone',
      (tester) async {
        final t = await _launch(tester, 'See [[Known]] and #work here\nNext\n');
        final link = _on(t, 'Known');

        await _click(tester, link);
        expect(t.tabs.followed, [const NoteTab(_knownId)]);
        expect(t.tabs.navigated, [const NoteTab(_knownId)]);
        t.expectModeAlone();

        await t.r.open(fixtureTopicId);
        await pumpFrames(tester);
        t.tabs.followed.clear();
        t.tabs.navigated.clear();
        await _dropClickMouse(tester);

        await _cmdClick(tester, _on(t, 'Known'));
        expect(t.tabs.followed, [const NoteTab(_knownId)]);
        expect(t.tabs.navigated, isEmpty, reason: 'Cmd opens a tab');
        t.expectModeAlone();
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain click and a Cmd click on a url link beside a tag open it and leave the sidebar mode alone',
      (tester) async {
        final t = await _launch(
          tester,
          'See [site](https://a.example) and #work here\nNext\n',
        );

        await _click(tester, _on(t, 'site'));
        expect(t.opener.opened, ['https://a.example']);
        t.expectModeAlone();
        await _dropClickMouse(tester);

        await _cmdClick(tester, _on(t, 'site'));
        expect(t.opener.opened, ['https://a.example', 'https://a.example']);
        t.expectModeAlone();
        expect(t.tabs.followed, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain hover over a wikilink beside a tag keeps the click cursor and the underline',
      (tester) async {
        final t = await _launch(tester, 'See [[Known]] and #work here\nNext\n');
        final mouse = await _mouseAt(tester, _on(t, 'Known'));

        expect(_cursor(), SystemMouseCursors.click);
        expect(_rowController(tester, 0).cmdHover, isNotNull);
        expect(
          _styleOfNeedle(
            _rowSpan(tester, 0),
            'Known',
          ).decoration?.contains(TextDecoration.underline),
          isTrue,
        );
        _expectAtRest(_styleOfNeedle(_rowSpan(tester, 0), '#work'));
        await _removeMouse(tester, mouse);
      },
      variant: macOnly,
    );

    testWidgets(
      'a Cmd hover over a wikilink lights the wikilink and not the tag beside it and a Cmd hover over the tag does the reverse',
      (tester) async {
        final t = await _launch(tester, 'See [[Known]] and #work here\nNext\n');
        final mouse = await _mouseAt(tester, _on(t, 'Known'));
        await _cmdDown(tester);
        expect(
          _styleOfNeedle(
            _rowSpan(tester, 0),
            'Known',
          ).decoration?.contains(TextDecoration.underline),
          isTrue,
        );
        _expectAtRest(_styleOfNeedle(_rowSpan(tester, 0), '#work'));

        await mouse.moveTo(_on(t, '#work'));
        await tester.pump();
        _expectCmdHovered(_styleOfNeedle(_rowSpan(tester, 0), '#work'));
        expect(
          _styleOfNeedle(
                _rowSpan(tester, 0),
                'Known',
              ).decoration?.contains(TextDecoration.underline) ??
              false,
          isFalse,
        );
        await _cmdUp(tester);
        await _removeMouse(tester, mouse);
      },
      variant: macOnly,
    );
  });

  // ------------------------------------------------------------ excerpt cards
  group('a tag in an excerpt card', () {
    testWidgets(
      'a plain click on a tag in an excerpt card opens Tags mode with that tag expanded and scrolled into view',
      (tester) async {
        final t = await _launchCard(tester, ['Card text #work here']);

        await _click(tester, _onCard(t, '#work'));
        await pumpFrames(tester, frames: 8);

        t.expectOpened('work');
        final row = find.byKey(const Key('tag-row-work'));
        expect(row, findsOneWidget);
        final view = tester.getRect(
          find.ancestor(of: row, matching: find.byType(Scrollable)).first,
        );
        final rect = tester.getRect(row);
        expect(rect.top, greaterThanOrEqualTo(view.top - 0.5));
        expect(rect.bottom, lessThanOrEqualTo(view.bottom + 0.5));
      },
      variant: macOnly,
    );

    testWidgets(
      'a Cmd click on a tag in an excerpt card opens Tags mode with that tag expanded',
      (tester) async {
        final t = await _launchCard(tester, ['Card text #work here']);

        await _cmdClick(tester, _onCard(t, '#work'));

        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain click on an inbox tag in an excerpt card opens Tags mode with System expanded',
      (tester) async {
        final t = await _launchCard(tester, ['Card text #inbox here']);

        await _click(tester, _onCard(t, '#inbox'));

        t.expectOpened('inbox', system: true);
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain click on a mixed case Work tag in an excerpt card opens the lowercase work',
      (tester) async {
        final t = await _launchCard(tester, ['Card text #Work here']);

        await _click(tester, _onCard(t, '#Work'));

        t.expectOpened('work');
      },
      variant: macOnly,
    );

    for (final (name, block) in [
      ('a click on a card tag in a heading row opens it', '# Title #work'),
      ('a click on a card tag in a bullet row opens it', '- item #work'),
      ('a click on a card tag in a numbered row opens it', '1. item #work'),
      ('a click on a card tag in a task row opens it', '- [ ] item #work'),
      ('a click on a card tag in a quote row opens it', '> quoted #work'),
    ]) {
      testWidgets(name, (tester) async {
        final t = await _launchCard(tester, [block]);

        await _click(tester, _onCard(t, '#work'));

        t.expectOpened('work');
      }, variant: macOnly);
    }

    testWidgets(
      'a click on a card tag on the second visual line of a wrapped row opens it',
      (tester) async {
        final long = List.filled(30, 'wrapping words here').join(' ');
        final t = await _launchCard(tester, ['$long #work end']);
        final rect = _cardRect(t, '#work');
        expect(
          rect.top,
          greaterThan(_cardRect(t, 'wrapping').top + 1),
          reason: 'the tag is below the first visual line',
        );

        await _click(tester, rect.center);

        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a click just beside a card tag opens nothing and a click on its first and last glyph opens it',
      (tester) async {
        final t = await _launchCard(tester, ['Card text #work here']);
        final rect = _cardRect(t, '#work');

        await _click(tester, Offset(rect.left - 1, rect.center.dy));
        t.expectModeAlone(why: 'left of the hash');
        await _click(tester, Offset(rect.right + 1, rect.center.dy));
        t.expectModeAlone(why: 'right of the k');

        await _click(tester, Offset(rect.left + 1, rect.center.dy));
        t.expectOpened('work', why: 'its first glyph');

        await t.resetSidebar();
        await _click(tester, Offset(rect.right - 1, rect.center.dy));
        t.expectOpened('work', why: 'its last glyph');
      },
      variant: macOnly,
    );

    testWidgets(
      'a card press and release on the same tag opens it and a press on one tag released on another opens neither',
      (tester) async {
        final t = await _launchCard(tester, ['Card #work and #pricing here']);
        final work = _onCard(t, '#work');
        final pricing = _onCard(t, '#pricing');

        await _pressMoveRelease(tester, work, pricing);
        t.expectModeAlone(why: 'released on the other tag');

        await _pressMoveRelease(tester, work, _onCard(t, 'here'));
        t.expectModeAlone(why: 'released off the tag');

        await _pressMoveRelease(tester, _onCard(t, 'here'), work);
        t.expectModeAlone(why: 'pressed off the tag');

        final rect = _cardRect(t, '#work');
        await _pressMoveRelease(
          tester,
          Offset(rect.left + 1, rect.center.dy),
          Offset(rect.right - 1, rect.center.dy),
        );
        t.expectOpened('work', why: 'pressed and released on the tag');
      },
      variant: macOnly,
    );

    testWidgets(
      'a card press on a tag in one row released on the same tag text in another row opens nothing',
      (tester) async {
        final t = await _launchCard(tester, ['- #work', '- #work']);

        await _pressMoveRelease(
          tester,
          _onCard(t, '#work'),
          _onCard(t, '#work', nth: 1),
        );
        t.expectModeAlone(why: 'another row');

        await _click(tester, _onCard(t, '#work', nth: 1));
        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a secondary press on a card tag opens nothing and a primary click opens it',
      (tester) async {
        final t = await _launchCard(tester, ['Card text #work here']);
        final at = _onCard(t, '#work');

        await _pressMoveRelease(tester, at, at, buttons: kSecondaryMouseButton);
        t.expectModeAlone();

        await _click(tester, at);
        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a click on a card tag does not move the editor caret or write anything',
      (tester) async {
        final t = await _launchCard(tester, ['Card text #work here']);
        await t.r.focusSegment(0, offset: 3);
        await tester.pump();

        await _click(tester, _onCard(t, '#work'));

        t.expectOpened('work');
        expect(
          t.r.segmentSelection(0),
          const TextSelection.collapsed(offset: 3),
        );
        await t.r.waitForSave();
        expect(t.r.updates, isEmpty);
        expect(t.r.excerptRms, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'the caption of a card holding a tag still follows and a click on the tag opens Tags mode first',
      (tester) async {
        final t = await _launchCard(tester, ['Card text #work here']);

        await _click(tester, _onCard(t, '#work'));
        t.expectOpened('work');

        await _click(tester, tester.getCenter(t.r.cardCaption(1)));
        expect(t.tabs.followed, [const NoteTab(fixtureDailyId)]);
        expect(t.expanded, 'work', reason: 'the caption leaves the mode alone');
      },
      variant: macOnly,
    );

    testWidgets(
      'the Remove button of a card holding a tag still removes it and a click on the tag opens Tags mode first',
      (tester) async {
        final t = await _launchCard(tester, ['Card text #work here']);

        await _click(tester, _onCard(t, '#work'));
        t.expectOpened('work');
        await _dropClickMouse(tester);

        await t.r.tapRemove(1);
        expect(t.r.excerptRms, hasLength(1));
      },
      variant: macOnly,
    );

    testWidgets(
      'pressing Cmd after a card holding a tag has gone throws nothing',
      (tester) async {
        final t = await _launchCard(tester, ['Card text #work here']);
        final mouse = await _mouseAt(tester, _onCard(t, '#work'));
        expect(_cursor(), SystemMouseCursors.click);
        await _removeMouse(tester, mouse);

        await t.r.tapRemove(1);
        expect(t.r.card(1), findsNothing);

        await _cmdDown(tester);
        await _cmdUp(tester);
        expect(tester.takeException(), isNull);
      },
      variant: macOnly,
    );

    testWidgets(
      'a wikilink and a url link in a card stay inert beside a tag that opens',
      (tester) async {
        final t = await _launchCard(tester, [
          'See [[Known]] and [site](https://a.example) and #work here',
        ]);
        final known = _onCard(t, 'Known');
        final site = _onCard(t, 'site');

        for (final at in [known, site]) {
          await _click(tester, at);
          await _cmdClick(tester, at);
          await _dropClickMouse(tester);

          final mouse = await _mouseAt(tester, at);
          expect(_cursor(), isNot(SystemMouseCursors.click));
          await _cmdDown(tester);
          expect(_cursor(), isNot(SystemMouseCursors.click));
          await _cmdUp(tester);
          await _removeMouse(tester, mouse);
        }
        expect(t.tabs.followed, isEmpty);
        expect(t.opener.opened, isEmpty);
        t.expectModeAlone();

        await _click(tester, _onCard(t, '#work'));
        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain hover over a card tag shows the click cursor with no underline and beside it shows none',
      (tester) async {
        final t = await _launchCard(tester, ['Card text #work here']);
        final rect = _cardRect(t, '#work');
        final mouse = await _mouseAt(tester, rect.center);

        expect(_cursor(), SystemMouseCursors.click);
        _expectAtRest(_cardStyle(t, '#work'));

        await mouse.moveTo(Offset(rect.left - 1, rect.center.dy));
        await tester.pump();
        expect(
          _cursor(),
          isNot(SystemMouseCursors.click),
          reason: 'left of it',
        );

        await mouse.moveTo(Offset(rect.right + 1, rect.center.dy));
        await tester.pump();
        expect(
          _cursor(),
          isNot(SystemMouseCursors.click),
          reason: 'right of it',
        );

        await mouse.moveTo(Offset(rect.left + 1, rect.center.dy));
        await tester.pump();
        expect(_cursor(), SystemMouseCursors.click, reason: 'its first glyph');

        await mouse.moveTo(Offset(rect.right - 1, rect.center.dy));
        await tester.pump();
        expect(_cursor(), SystemMouseCursors.click, reason: 'its last glyph');
        await _removeMouse(tester, mouse);
      },
      variant: macOnly,
    );

    testWidgets(
      'with Cmd held a hover over a card tag shows accentSoft and a solid underline and releasing Cmd takes them away',
      (tester) async {
        final t = await _launchCard(tester, ['Card text #work here']);
        final mouse = await _mouseAt(tester, _onCard(t, '#work'));
        _expectAtRest(_cardStyle(t, '#work'));

        await _cmdDown(tester);
        expect(_cursor(), SystemMouseCursors.click);
        _expectCmdHovered(_cardStyle(t, '#work'));

        await _cmdUp(tester);
        _expectAtRest(_cardStyle(t, '#work'));
        expect(_cursor(), SystemMouseCursors.click);
        await _removeMouse(tester, mouse);
      },
      variant: macOnly,
    );

    testWidgets(
      'moving onto a card tag with Cmd already held lights it and moving off takes it away',
      (tester) async {
        final t = await _launchCard(tester, ['Card text #work here']);
        final mouse = await _mouseAt(tester, _onCard(t, 'Card'));
        await _cmdDown(tester);
        expect(_cursor(), isNot(SystemMouseCursors.click));

        await mouse.moveTo(_onCard(t, '#work'));
        await tester.pump();
        expect(_cursor(), SystemMouseCursors.click);
        _expectCmdHovered(_cardStyle(t, '#work'));

        await mouse.moveTo(_onCard(t, 'here'));
        await tester.pump();
        expect(_cursor(), isNot(SystemMouseCursors.click));
        _expectAtRest(_cardStyle(t, '#work'));

        await mouse.moveTo(_onCard(t, '#work'));
        await tester.pump();
        _expectCmdHovered(_cardStyle(t, '#work'));

        // Off the card altogether.
        await mouse.moveTo(tester.getCenter(t.r.textSegment(2)));
        await tester.pump();
        _expectAtRest(_cardStyle(t, '#work'));

        await _cmdUp(tester);
        await _removeMouse(tester, mouse);
      },
      variant: macOnly,
    );

    testWidgets(
      'with Cmd held a hover over a tag in one card row leaves the same tag in another row at rest',
      (tester) async {
        final t = await _launchCard(tester, ['- #work', '- #work']);
        final mouse = await _mouseAt(tester, _onCard(t, '#work'));
        await _cmdDown(tester);

        _expectCmdHovered(_cardStyle(t, '#work'));
        _expectAtRest(_cardStyle(t, '#work', nth: 1));

        await _cmdUp(tester);
        await _removeMouse(tester, mouse);
      },
      variant: macOnly,
    );

    testWidgets(
      'a tag on a fenced line of a card has no click no hover and no cursor and a tag below the fence opens',
      (tester) async {
        final t = await _launchCard(tester, ['~~~', '#inside', '~~~', '#work']);
        final inside = _onCard(t, '#inside');

        await _click(tester, inside);
        await _cmdClick(tester, inside);
        t.expectModeAlone(why: 'in the fence');
        await _dropClickMouse(tester);

        final mouse = await _mouseAt(tester, inside);
        expect(_cursor(), isNot(SystemMouseCursors.click));
        await _cmdDown(tester);
        expect(_cursor(), isNot(SystemMouseCursors.click));
        expect(
          _cardStyle(
                t,
                '#inside',
              ).decoration?.contains(TextDecoration.underline) ??
              false,
          isFalse,
        );
        await _cmdUp(tester);
        await _removeMouse(tester, mouse);

        await _click(tester, _onCard(t, '#work'));
        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a tag on an item row inside a tilde fence of a card has no click and a tag below the fence opens',
      (tester) async {
        final t = await _launchCard(tester, [
          '~~~',
          '- #inside',
          '~~~',
          '#work',
        ]);

        await _cmdClick(tester, _onCard(t, '#inside'));
        t.expectModeAlone(why: 'fenced, by the whole excerpt');
        await _dropClickMouse(tester);

        await _click(tester, _onCard(t, '#work'));
        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a hash glued to a quote marker in a card has no click and a spaced tag on the next row opens',
      (tester) async {
        final t = await _launchCard(tester, ['>#glued', 'Next #work']);

        await _cmdClick(tester, _onCard(t, '#glued'));
        t.expectModeAlone();
        await _dropClickMouse(tester);

        await _click(tester, _onCard(t, '#work'));
        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a press on the last sliver of a card tag whose nearest text offset is past the tag opens nothing and a press a pixel inside opens it',
      (tester) async {
        // The italic closer after the tag renders zero-width, so the paragraph
        // maps the last sliver of the k to the offset after the closer.
        final t = await _launchCard(tester, ['*x #work* y']);
        final rect = _cardRect(t, '#work');
        final (paragraph, at) = _cardHit(t, '#work');
        final sliver = Offset(rect.right - 0.001, rect.center.dy);
        expect(rect.contains(sliver), isTrue, reason: 'inside the glyph box');
        expect(
          paragraph
              .getPositionForOffset(paragraph.globalToLocal(sliver))
              .offset,
          greaterThan(at + '#work'.length),
          reason: 'the SDK maps the sliver past the tag end',
        );

        await _click(tester, sliver);
        t.expectModeAlone(why: 'the offset is past the tag');
        await _dropClickMouse(tester);

        await _click(tester, Offset(rect.right - 1, rect.center.dy));
        t.expectOpened('work', why: 'a pixel inside the last glyph');
      },
      variant: macOnly,
    );

    group('in a table', () {
      const table = '| #work | a |\n|---|---|\n|#glued| #pricing |';

      testWidgets(
        'a plain click on a tag in a table in an excerpt card opens it and a Cmd click on a body row tag does too',
        (tester) async {
          final t = await _launchCard(tester, ['Lead in', table]);

          await _click(tester, _cardGridRect(t, 1, table, '#work').center);
          t.expectOpened('work');

          await t.resetSidebar();
          await _cmdClick(
            tester,
            _cardGridRect(t, 1, table, '#pricing').center,
          );
          t.expectOpened('pricing');
        },
        variant: macOnly,
      );

      testWidgets(
        'a hash glued to a pipe in a card table has no click no hover and no cursor and a plain cell opens nothing',
        (tester) async {
          final t = await _launchCard(tester, ['Lead in', table]);
          final glued = _cardGridRect(t, 1, table, '#glued').center;
          final plain = _cardGridRect(t, 1, table, 'a').center;

          for (final at in [glued, plain]) {
            await _click(tester, at);
            await _cmdClick(tester, at);
            await _dropClickMouse(tester);
            final mouse = await _mouseAt(tester, at);
            expect(_cursor(), isNot(SystemMouseCursors.click));
            await _removeMouse(tester, mouse);
          }
          t.expectModeAlone();

          await _click(tester, _cardGridRect(t, 1, table, '#work').center);
          t.expectOpened('work');
        },
        variant: macOnly,
      );

      testWidgets(
        'a hover over a tag in a card table shows the click cursor and Cmd held underlines only that tag',
        (tester) async {
          final t = await _launchCard(tester, ['Lead in', table]);
          final mouse = await _mouseAt(
            tester,
            _cardGridRect(t, 1, table, '#work').center,
          );

          expect(_cursor(), SystemMouseCursors.click);
          _expectAtRest(_styleOfNeedle(_cardCellSpan(t, 1, '#work'), '#work'));

          await _cmdDown(tester);
          _expectCmdHovered(
            _styleOfNeedle(_cardCellSpan(t, 1, '#work'), '#work'),
          );
          _expectAtRest(
            _styleOfNeedle(_cardCellSpan(t, 1, '#pricing'), '#pricing'),
          );

          await _cmdUp(tester);
          _expectAtRest(_styleOfNeedle(_cardCellSpan(t, 1, '#work'), '#work'));
          await _removeMouse(tester, mouse);
        },
        variant: macOnly,
      );

      testWidgets(
        'a tag on a fenced table row of a card opens nothing and a tag outside the fence opens',
        (tester) async {
          const fencedTable = '| #inside | a |\n|---|---|\n| b | c |';
          final t = await _launchCard(tester, [
            '~~~',
            fencedTable,
            '~~~',
            '#work',
          ]);
          final grid = _cardGrid(t, 1);
          expect(grid, findsOneWidget);

          await _cmdClick(
            tester,
            _cardGridRect(t, 1, fencedTable, '#inside').center,
          );
          t.expectModeAlone(why: 'fenced');
          await _dropClickMouse(tester);

          await _click(tester, _onCard(t, '#work'));
          t.expectOpened('work');
        },
        variant: macOnly,
      );
    });
  });

  // ------------------------------------------- verify: contracts pinned late
  group('verify pins for a click on a tag', () {
    testWidgets(
      'a touch tap on a tag on a hidden markup line opens nothing and a mouse click then opens it',
      (tester) async {
        final t = await _launch(tester, 'Intro #work here\nNext line\n');

        await tester.tapAt(_on(t, '#work'));
        await pumpFrames(tester);
        await _pastDoubleClick(tester);
        t.expectModeAlone(why: 'a touch tap');

        await t.r.focusSegment(0, offset: t.r.segmentText(0).length - 1);
        await tester.pump();
        await _click(tester, _on(t, '#work'));
        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a touch tap on a tag in a rendered table opens nothing and a Cmd click on it then opens it',
      (tester) async {
        final t = await _launch(
          tester,
          'Above\n| #work | a |\n|---|---|\n| b | #pricing |\nBelow\n',
        );

        await tester.tapAt(_on(t, '#work'));
        await pumpFrames(tester);
        await _pastDoubleClick(tester);
        t.expectModeAlone(why: 'a touch tap');

        await _cmdClick(tester, _on(t, '#work'));
        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a cancelled press on a card tag opens nothing and a click then opens it',
      (tester) async {
        final t = await _launchCard(tester, ['Card text #work here']);
        final at = _onCard(t, '#work');

        final mouse = await tester.startGesture(
          at,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await mouse.cancel();
        await pumpFrames(tester);
        t.expectModeAlone(why: 'cancelled');
        await _dropClickMouse(tester);

        await _click(tester, at);
        t.expectOpened('work');
      },
      variant: macOnly,
    );

    testWidgets(
      'a card row with no live tag adds no listener and a row holding one adds exactly one',
      (tester) async {
        final t = await _launchCard(tester, [
          'Plain row',
          '- #work item',
          '~~~',
          '#inside',
          '~~~',
          '- bullet row',
        ]);
        // Listeners between each row text and the card's top.
        final counts = <String, int>{};
        for (final element in _cardRowTexts(t)) {
          final plain = (element.renderObject! as RenderParagraph).text
              .toPlainText();
          var n = 0;
          element.visitAncestorElements((a) {
            if (a.widget is Listener) n++;
            return true;
          });
          counts[plain] = n;
        }
        expect(counts.keys, containsAll(['Plain row', 'bullet row']));
        final base = counts['Plain row']!;
        expect(counts['bullet row'], base, reason: 'an item row, no tag');
        expect(
          counts.entries.firstWhere((e) => e.key.contains('#work')).value,
          base + 1,
          reason: 'the row holding a live tag',
        );
        expect(
          counts.entries.firstWhere((e) => e.key.contains('#inside')).value,
          base,
          reason: 'a tag inside a fence is no live tag',
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'a bare field of item text opens no fence so a tag after a tilde run opens and as a plain line it does not',
      (tester) async {
        final f = await _pumpField(tester, '~~~ #work\n');
        expect(f.controller.fenced, isNull);

        await _cmdClick(tester, f.on('#work'));
        expect(f.expanded, isNull, reason: 'a fence opener line');
        await _dropClickMouse(tester);

        f.controller.itemText = true;
        await tester.pump();
        await _cmdClick(tester, f.on('#work'));
        expect(f.expanded, 'work', reason: 'item text opens no fence');
      },
      variant: macOnly,
    );
  });
}
