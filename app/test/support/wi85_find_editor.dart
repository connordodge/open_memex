// WI #85 (Spec #61 F6): helpers for the Find in note editor integration
// tests and the robot journey. Owned by #85; every name carries the wi85
// prefix.
//
// Every test pumps the whole workspace through the shared reveal pump
// (`note_reveal_pump.dart`, ruling D5) over the notes [wi85SeedVault] adds,
// with a fake Window menu host. Find is triggered as the native menu does
// it: a `find` method call on `open_memex/window` played as a platform
// message (TD5), never a key event for Cmd+F, Cmd+G or Cmd+E.
//
// Note text is invented (public repo).
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/app_exit.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';
import 'package:open_memex_app/src/state/note_reveal.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_styles.dart';
import 'package:open_memex_app/src/widgets/find/find_highlights.dart';
import 'package:open_memex_app/src/widgets/find/find_keys.dart';

import '../robots/segmented_editor_robot.dart';
import 'daily_seed.dart';
import 'fake_vault_db.dart';
import 'note_reveal_pump.dart';
import 'window_menu_fakes.dart';

// ------------------------------------------------------------------ notes

/// The daily note the topic note's excerpt card quotes.
const wi85DailyId = 'daily-85-bake';
const wi85DailyDate = '2026-09-05';

/// The card's two blocks: 2 matches of `rye`.
const wi85BlockA = 'Mixed a rye dough before work.';
const wi85BlockB = 'Shaped two rye loaves at noon.';

/// The card's text as `RenderedExcerpt.text` gives it.
const wi85CardText = '$wi85BlockA\n$wi85BlockB';

/// The transclusion token of the card.
const wi85Token = '![[$wi85DailyDate#^k1a2b3..^k4c5d6]]';

/// The topic note: a title holding `Rye` (never searched), 10 body matches
/// of `rye` (segment 0 before the card, segment 2 after it, a table row
/// among them), the card (segment 1, 2 matches) and a Note footer chip
/// holding `Rye` (searched in Source mode only). Live preview counts 12,
/// Source 11 (Req 2).
const wi85TopicId = 'topic-85-rye';
const wi85TopicTitle = 'Rye notes';

const wi85Seg0 =
    'Rye bread wants a long, slow proof.\n'
    'Feed the starter for rye bread at night.\n'
    'A dark rye crumb stays moist for days.\n'
    'Plain line about wheat.\n';

const wi85Seg2 =
    '| Flour | Note |\n'
    '| --- | --- |\n'
    '| dark rye | too much water for rye |\n'
    'Plain line one.\n'
    'Plain line two.\n'
    'Toast the rye slices.\n'
    'Rye and caraway go together.\n'
    'Keep the rye starter cool.\n'
    'Rye rolls freeze well.\n'
    'Last rye line.\n';

const wi85Footer = '$topicsMarker\n[[Rye Starter~about]]\n';

const wi85TopicBody = '$wi85Seg0$wi85Token\n$wi85Seg2$wi85Footer';

/// The query most tests use.
const wi85Query = 'rye';

/// A note with a match in a link URL between two plain matches.
const wi85LinkId = 'topic-85-link';
const wi85LinkLine = 'See [the guide](https://example.com/rye-guide) here.';
const wi85LinkBody =
    'Plain rye line.\n'
    '$wi85LinkLine\n'
    'Another rye line.\n';

/// A long note for scrolling: `marker` on line 40, line 240 and line 260,
/// plain lines in between.
const wi85LongId = 'topic-85-long';
const wi85LongQuery = 'marker';

String get wi85LongBody {
  final out = StringBuffer();
  for (var i = 0; i < 300; i++) {
    out.write(switch (i) {
      40 => 'first marker line\n',
      240 => 'second marker line\n',
      260 => 'third marker line\n',
      _ => 'filler $i\n',
    });
  }
  return out.toString();
}

/// A note whose matches each draw their own ink: strike runs (fg2, lifted
/// to fg1 inside a match that is not current) and plain runs, in a body text
/// segment (0), an excerpt card (1, text [wi85InkCardText]) and a table
/// (segment 2). Six matches of `rye`, in that order.
const wi85InkId = 'topic-85-ink';
const wi85InkSeg0 = 'Plain rye first.\n~~struck rye~~ then more.\n';
const wi85InkCardText = 'Card ~~rye~~ one.\nCard plain rye two.';
const wi85InkSeg2 =
    '| Item | Note |\n'
    '| --- | --- |\n'
    '| ~~rye~~ cell | plain rye cell |\n';
const wi85InkBody = '$wi85InkSeg0$wi85Token\n$wi85InkSeg2';

/// Another plain note.
const wi85OtherId = 'topic-85-other';
const wi85OtherBody = 'Nothing to see in this note.\n';

/// A daily note whose date header reads `Saturday, 12 September 2026` and
/// whose body holds `September` once.
const wi85DayId = 'daily-85-day';
const wi85DayBody = 'Baked a rye loaf in September.\n';

/// The reveal pump's notes plus every note above, and the card's daily note
/// with its two blocks.
FakeVaultDb wi85SeedVault([FakeVaultDb? into]) {
  final db = seedRevealNotes(into ?? FakeVaultDb.v5());
  db.seedDailyNote(wi85DailyDate, id: wi85DailyId);
  db.seedBlock(wi85DailyId, 'k1a2b3', ord: 0, text: wi85BlockA);
  db.seedBlock(wi85DailyId, 'k4c5d6', ord: 1, text: wi85BlockB);
  db.seedNote(
    id: wi85TopicId,
    title: wi85TopicTitle,
    role: 'topic',
    content: wi85TopicBody,
  );
  db.seedNote(id: wi85LinkId, title: 'Link note', content: wi85LinkBody);
  db.seedNote(id: wi85LongId, title: 'Long marker', content: wi85LongBody);
  db.seedNote(id: wi85InkId, title: 'Ink note', content: wi85InkBody);
  db.seedNote(id: wi85OtherId, title: 'Plain other', content: wi85OtherBody);
  db.seedNote(
    id: wi85DayId,
    title: '2026-09-12',
    role: 'daily',
    content: wi85DayBody,
  );
  return db;
}

// ------------------------------------------------------------------ pump

/// What a #85 test holds after [pumpWi85].
class Wi85 {
  Wi85(this.tester, this.h, this.menu);

  final WidgetTester tester;
  final NoteRevealHarness h;
  final FakeWindowMenuHost menu;

  ProviderContainer get container => h.container;

  /// The segmented editor robot over the same workspace.
  SegmentedEditorRobot get robot => SegmentedEditorRobot(tester, h.workspace);

  FindInNoteState get state => container.read(findInNoteProvider);

  // -------------------------------------------------------------- menu

  /// Plays the native `find` call with [action] (`show`, `next`,
  /// `previous`, `useSelection`) as MainFlutterWindow.swift sends it, then
  /// pumps frames.
  Future<void> send(String action) async {
    var replied = false;
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      appWindowChannel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('find', action)),
      (_) => replied = true,
    );
    await pumpFrames(tester);
    expect(replied, isTrue, reason: 'find $action got a reply');
  }

  // -------------------------------------------------------------- bar

  Finder get bar => find.byKey(findBarKey);

  /// The query field's EditableText.
  Finder get field => find.descendant(
    of: find.byKey(findBarFieldKey),
    matching: find.byType(EditableText),
  );

  EditableText get fieldEditable => tester.widget<EditableText>(field);

  /// Whether the query field shows and has focus.
  bool get fieldFocused =>
      field.evaluate().isNotEmpty && fieldEditable.focusNode.hasFocus;

  /// The counter text, or null when no counter shows.
  String? get counter {
    final text = find.descendant(
      of: find.byKey(findBarCounterKey),
      matching: find.byType(Text),
    );
    if (text.evaluate().isEmpty) return null;
    return tester.widget<Text>(text).data;
  }

  /// Types [query] into the query field (replacing it) and pumps frames.
  Future<void> typeQuery(String query) async {
    await tester.enterText(field, query);
    await pumpFrames(tester);
  }

  /// `find show`, then types [query]: the bar is open on [query].
  Future<void> openOn(String query) async {
    await send('show');
    expect(bar, findsOneWidget, reason: 'find show opens the Find bar');
    await typeQuery(query);
    expect(state.query, query);
  }

  Future<void> tapNext() async {
    await tester.tap(find.byKey(findBarNextKey));
    await pumpFrames(tester);
  }

  Future<void> tapPrevious() async {
    await tester.tap(find.byKey(findBarPreviousKey));
    await pumpFrames(tester);
  }

  Future<void> tapClose() async {
    await tester.tap(find.byKey(findBarCloseKey));
    await pumpFrames(tester);
  }

  /// Presses Esc with the query field focused (checked).
  Future<void> escInField() async {
    expect(fieldFocused, isTrue, reason: 'Esc goes to the query field');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape, platform: 'macos');
    await pumpFrames(tester);
  }

  /// Steps with the down button until the current match satisfies [test],
  /// at most once per match.
  Future<FindMatch> stepUntil(bool Function(FindMatch m) test) async {
    for (var i = 0; i <= state.matches.length; i++) {
      final m = state.currentMatch;
      if (m != null && test(m)) return m;
      await tapNext();
    }
    throw TestFailure('no match satisfied the test: ${state.matches}');
  }

  // -------------------------------------------------------------- paint

  /// Every find paint range of every highlight layer under [under] (the
  /// whole app when null).
  List<FindPaintRange> ranges({Finder? under}) {
    final layers = under == null
        ? find.byType(FindHighlights)
        : find.descendant(of: under, matching: find.byType(FindHighlights));
    return [
      for (final w in tester.widgetList<FindHighlights>(layers)) ...w.ranges,
    ];
  }

  // -------------------------------------------------------------- reveal

  /// Records every reveal request made from now on (each one once, by its
  /// sequence number); cancelled at teardown.
  Wi85Reveals reveals() {
    final out = Wi85Reveals();
    final sub = container.listen<PendingReveal?>(noteRevealProvider, (_, next) {
      if (next != null && out._seqs.add(next.seq)) {
        out.requests.add(next.request);
      }
    });
    addTearDown(sub.close);
    return out;
  }

  // -------------------------------------------------------------- body

  /// The live preview segments of the shown note.
  List<Segment> get segments => h.shownSegments();

  // -------------------------------------------------------------- ink

  /// The live preview span of the body row field holding offset [local] of
  /// text segment [segment], and [local] in that row's own text.
  (InlineSpan, int) bodyRowSpan(int segment, int local, {Finder? under}) {
    final row = h.rowOf(segment, local, under: under);
    final field = find.descendant(
      of: h.rowFinder(segment, row.index, under: under),
      matching: find.byType(EditableText),
    );
    final controller =
        tester.widget<EditableText>(field).controller as LivePreviewController;
    return (
      controller.buildTextSpan(
        context: tester.element(field),
        withComposing: false,
      ),
      row.spec.toLocal(local),
    );
  }

  /// The span of the excerpt card [segment]'s row holding offset [at] of its
  /// text [cardText], and [at] in that row's own text.
  (InlineSpan, int) cardRowSpan(
    int segment,
    String cardText,
    int at, {
    Finder? under,
  }) {
    final specs = splitRows(cardText, atSegmentStart: true);
    final r = specs.lastIndexWhere((spec) => spec.start <= at);
    final text = find.descendant(
      of: find.descendant(
        of: _scope(under, find.byKey(Key('excerpt-card-$segment'))),
        matching: find.byKey(ValueKey('card-row-text-$r')),
      ),
      matching: find.byType(RichText),
    );
    return (tester.widget<RichText>(text).text, at - specs[r].textStart);
  }

  /// The span of the table cell of text segment [segment] whose text is
  /// [cell] (one per table).
  InlineSpan tableCellSpan(int segment, String cell, {Finder? under}) {
    final cells = find.descendant(
      of: _scope(
        under,
        find.byWidgetPredicate((widget) {
          final k = widget.key;
          return k is ValueKey<String> &&
              k.value.startsWith('editor-table-$segment-');
        }),
      ),
      matching: find.byWidgetPredicate(
        (widget) => widget is RichText && widget.text.toPlainText() == cell,
      ),
    );
    expect(cells, findsOneWidget, reason: 'the cell "$cell" shows');
    return tester.widget<RichText>(cells).text;
  }

  Finder _scope(Finder? under, Finder finder) =>
      under == null ? finder : find.descendant(of: under, matching: finder);

  /// The global rect of the visual line holding offset [local] of the Source
  /// field, from its own line boxes.
  Rect sourceLineBox(int local) {
    final editable = findRenderEditable(
      tester.renderObject(
        find.descendant(
          of: find.byKey(const Key('editor-source-surface')),
          matching: find.byKey(const Key('editor-body')),
        ),
      ),
    );
    expect(editable, isNotNull, reason: 'the Source field is laid out');
    final line = lineHolding(RenderEditableLineBoxes(editable!).lines, local);
    return Rect.fromPoints(
      editable.localToGlobal(Offset(0, line.top)),
      editable.localToGlobal(Offset(editable.size.width, line.bottom)),
    );
  }

  /// The Source field's EditableText.
  EditableText get sourceEditable => tester.widget<EditableText>(
    find.descendant(
      of: find.byKey(const Key('editor-source-surface')),
      matching: find.descendant(
        of: find.byKey(const Key('editor-body')),
        matching: find.byType(EditableText),
      ),
    ),
  );
}

/// The reveal requests recorded by [Wi85.reveals], in order.
class Wi85Reveals {
  final requests = <NoteRevealRequest>[];
  final _seqs = <int>{};

  int get count => requests.length;
  NoteRevealRequest get last => requests.last;
  void clear() => requests.clear();
}

/// Pumps the workspace over [wi85SeedVault] (or [db]) with a fake Window
/// menu host and opens [open] (nothing when null).
Future<Wi85> pumpWi85(
  WidgetTester tester, {
  String? open = wi85TopicId,
  FakeVaultDb? db,
  Duration zoom = Duration.zero,
  List<Override> overrides = const [],
}) async {
  final menu = FakeWindowMenuHost();
  final h = await pumpNoteReveal(
    tester,
    db: db ?? wi85SeedVault(),
    open: open,
    zoom: zoom,
    overrides: [windowMenuHostProvider.overrideWithValue(menu), ...overrides],
  );
  return Wi85(tester, h, menu);
}

// ------------------------------------------------------------------ text

/// Whether code unit [offset] of the text [root] spans renders hidden
/// (`livePreviewHiddenStyle`; a span with no style inherits its parent's).
bool wi85HiddenAt(InlineSpan root, int offset) {
  var at = 0;
  bool? found;
  void walk(InlineSpan span, bool parentHidden) {
    if (found != null) return;
    if (span is! TextSpan) {
      if (offset == at) found = parentHidden;
      at += 1;
      return;
    }
    final style = span.style;
    final hidden = style == null
        ? parentHidden
        : style == livePreviewHiddenStyle;
    final length = span.text?.length ?? 0;
    if (offset >= at && offset < at + length) {
      found = hidden;
      return;
    }
    at += length;
    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child, hidden);
    }
  }

  walk(root, false);
  if (found == null) throw TestFailure('offset $offset is past the spans');
  return found!;
}

/// The colour code unit [offset] of the spans [root] draws in (the nearest
/// style colour, inherited from parents).
Color? wi85ColorAt(InlineSpan root, int offset) {
  var at = 0;
  Color? found;
  var done = false;
  void walk(InlineSpan span, Color? parent) {
    if (done) return;
    if (span is! TextSpan) {
      at += 1;
      return;
    }
    final color = span.style?.color ?? parent;
    final length = span.text?.length ?? 0;
    if (offset >= at && offset < at + length) {
      found = color;
      done = true;
      return;
    }
    at += length;
    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child, color);
    }
  }

  walk(root, null);
  if (!done) throw TestFailure('offset $offset is past the spans');
  return found;
}

/// How many times [needle] occurs in [text], case folded, non-overlapping.
int wi85Count(String text, String needle) {
  final hay = text.toLowerCase();
  final n = needle.toLowerCase();
  var count = 0;
  var at = hay.indexOf(n);
  while (at >= 0) {
    count++;
    at = hay.indexOf(n, at + n.length);
  }
  return count;
}
