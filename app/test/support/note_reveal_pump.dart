// #66 (54-R0, ruling D5): the shared pump for every note reveal test (#58's
// Outline, #61's Find in note, #59's Passages). It pumps the whole workspace
// (router -> Workspace -> NoteEditor) over the fakes in a sized viewport with
// long notes seeded, and reads geometry from the editor's own line boxes,
// never from constants: #53 changes heading geometry in parallel.
//
// Use it; don't fork it. Helper requests go to lead-54. Call
// `holdFontFetches()` at the top of `main()` in a file that uses it. Never
// pumpAndSettle the workspace (OmDot pulses forever): `pumpFrames` only.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/canvas_state.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/note_reveal.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/editor/echo_arrival_highlight.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import 'app_harness.dart';
import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';
import 'today_cli_fakes.dart';

export 'app_harness.dart' show WorkspaceHarness, pumpFrames;

// ------------------------------------------------------------------- notes

/// A long note: one prose row (segment 0, row 0) holding plain `line <i>`
/// lines, a heading in the middle of a paragraph ([revealMidHeading], with
/// no blank lines around it), a heading that wraps ([revealWrappedHeading]),
/// and a heading near the end ([revealEndHeading]).
const revealLongId = 'reveal-long';

/// Another long note of plain `other <i>` lines.
const revealOtherId = 'reveal-other';

/// `- item <i>` then `  passage <i>` for i in `0..300`: passage `k` is row
/// `2k + 1` of segment 0 (the echo tests' layout).
const revealItemsId = 'reveal-items';

/// A daily note whose person segment ends in stray text moved from below
/// the Topics marker, holding [revealStrayHeading].
const revealDailyId = 'reveal-daily';

const revealMidHeading = '## Mid heading';
const revealEndHeading = '## Near the end';
const revealStrayHeading = '## Stray heading';

/// A heading long enough to wrap at the editor's reading width.
final revealWrappedHeading =
    '## Wrapped ${List.filled(40, 'wrapword').join(' ')}';

/// Plain lines `<tag> <from>` .. `<tag> <to - 1>`, each ending in `\n`.
String revealLines(String tag, int from, int to) =>
    [for (var i = from; i < to; i++) '$tag $i\n'].join();

String get revealLongBody =>
    '${revealLines('line', 0, 120)}'
    'para before\n$revealMidHeading\npara after\n'
    '${revealLines('line', 120, 240)}'
    '\n$revealWrappedHeading\n\n'
    '${revealLines('line', 240, 360)}'
    '$revealEndHeading\nlast line a\nlast line b\n';

String get revealItemsBody =>
    [for (var i = 0; i < 300; i++) '- item $i\n  passage $i\n'].join();

String get revealDailyBody =>
    '${revealLines('morning', 0, 200)}'
    '$topicsMarker\n'
    '[[Long~about]]\n'
    '$revealStrayHeading\n'
    '${revealLines('stray', 0, 150)}';

/// Seeds [revealLongId], [revealOtherId], [revealItemsId] and
/// [revealDailyId] into [db].
FakeVaultDb seedRevealNotes(FakeVaultDb db) {
  db.seedNote(id: revealLongId, title: 'Long', content: revealLongBody);
  db.seedNote(
    id: revealOtherId,
    title: 'Other',
    content: revealLines('other', 0, 300),
  );
  db.seedNote(id: revealItemsId, title: 'Items', content: revealItemsBody);
  db.seedNote(
    id: revealDailyId,
    title: '2026-09-30',
    role: 'daily',
    content: revealDailyBody,
  );
  return db;
}

// -------------------------------------------------------------- tabs double

/// The real `TabsNotifier` with the app's wiring, recording every
/// `recordScrollOffset` call. The vault opens with no tab (no Today launch);
/// [pumpNoteReveal] navigates to the note it opens.
class RevealTabs extends TabsNotifier {
  RevealTabs({
    required super.store,
    required super.onPersistedSelection,
    super.onBeforeLeave,
    super.navigationObserver,
  });

  /// Every `recordScrollOffset` call, in order.
  final recorded = <({String noteId, double offset})>[];

  @override
  void recordScrollOffset(String noteId, double offset) {
    recorded.add((noteId: noteId, offset: offset));
    super.recordScrollOffset(noteId, offset);
  }
}

// ----------------------------------------------------------------- jumps

/// Every pixel value the editor's scroll moves to from now on (a listener on
/// the editor's `ScrollController`, so a page rebuilt for another note is
/// still followed). A `jumpTo` that moves the page counts once.
class RevealJumps {
  RevealJumps._(this.controller) {
    controller.addListener(_moved);
  }

  final ScrollController controller;
  final values = <double>[];

  int get count => values.length;

  void _moved() {
    if (controller.hasClients) values.add(controller.positions.last.pixels);
  }

  void clear() => values.clear();

  /// Stops counting; a no-op once the editor (and its controller) is gone.
  void dispose() {
    try {
      controller.removeListener(_moved);
    } on FlutterError {
      // The controller was disposed with its editor.
    }
  }
}

// ----------------------------------------------------------------- harness

/// Everything a reveal test needs after [pumpNoteReveal].
class NoteRevealHarness {
  NoteRevealHarness(this.tester, this.workspace, this.tabs);

  final WidgetTester tester;
  final WorkspaceHarness workspace;
  final RevealTabs tabs;

  ProviderContainer get container => workspace.container;
  FakeVaultDb get db => workspace.db;
  T read<T>(ProviderListenable<T> provider) => container.read(provider);

  TabsState get tabState => read(tabsProvider);

  /// What `recordScrollOffset` was called with, in order.
  List<({String noteId, double offset})> get recorded => tabs.recorded;

  /// The pending reveal, if any.
  PendingReveal? get pending => read(noteRevealProvider);

  /// Asks for [r] (the caller navigates first when needed, D3b). Pumps
  /// nothing.
  void request(NoteRevealRequest r) =>
      container.read(noteRevealProvider.notifier).request(r);

  /// Navigates the active tab to [target] and pumps frames.
  Future<void> navigate(WorkspaceTab target) async {
    tabs.navigate(target);
    await pumpFrames(tester);
  }

  // ------------------------------------------------------------ the page

  Finder _in(Finder? under, Finder finder) =>
      under == null ? finder : find.descendant(of: under, matching: finder);

  /// The editor page's Scrollable (under [under] while two editors show).
  Finder scrollable({Finder? under}) => find
      .descendant(
        of: _in(under, find.byType(EditorPage)),
        matching: find.byType(Scrollable),
      )
      .first;

  ScrollPosition position({Finder? under}) =>
      tester.state<ScrollableState>(scrollable(under: under)).position;

  double pixels({Finder? under}) => position(under: under).pixels;

  /// The editor viewport's global rect.
  Rect viewport({Finder? under}) => tester.getRect(scrollable(under: under));

  /// Scrolls the page to [offset] as a person would and checks it got there.
  Future<void> scrollTo(double offset, {Finder? under}) async {
    final p = position(under: under);
    expect(
      p.maxScrollExtent,
      greaterThanOrEqualTo(offset),
      reason: 'the note must be long enough to scroll that far',
    );
    p.jumpTo(offset);
    await tester.pump();
    expect(p.pixels, offset);
  }

  /// Scrolls the page so the global y [y] of laid-out content moves to the
  /// global y [to].
  Future<void> scrollContent(double y, double to, {Finder? under}) =>
      scrollTo(pixels(under: under) + (y - to), under: under);

  /// The editor's scroll controller (through `EditorScrollScope`).
  ScrollController controller({Finder? under}) => tester
      .widget<EditorScrollScope>(_in(under, find.byType(EditorScrollScope)))
      .controller;

  /// Starts counting the editor's jumps; removed at teardown.
  RevealJumps jumps({Finder? under}) {
    final j = RevealJumps._(controller(under: under));
    addTearDown(j.dispose);
    return j;
  }

  /// The arrival highlight(s) showing.
  Finder get highlight => find.byType(EchoArrivalHighlight);

  // ------------------------------------------------------------ the text

  SegmentedBody body({Finder? under}) =>
      tester.widget<SegmentedBody>(_in(under, find.byType(SegmentedBody)));

  /// The live text the segmented body shows.
  String shownContent({Finder? under}) => body(under: under).content;

  /// The segments of [shownContent], split as the editor splits them.
  List<Segment> shownSegments({Finder? under}) {
    final role = body(under: under).note.role;
    return split(
      shownContent(under: under),
      isDaily: role == 'daily',
      noteFooter: role != 'guide',
    );
  }

  /// The text of text segment [segment] of [shownContent].
  String segmentText(int segment, {Finder? under}) =>
      (shownSegments(under: under)[segment] as TextSegment).text;

  /// The offset of [needle] in text segment [segment], checked present.
  int offsetOf(String needle, {int segment = 0, Finder? under}) {
    final at = segmentText(segment, under: under).indexOf(needle);
    expect(at, isNonNegative, reason: '"$needle" in segment $segment');
    return at;
  }

  /// A Text request for [start] (to [end]) of segment [segment] of the
  /// shown text.
  RevealAtText textAt(int start, {int segment = 0, int? end, Finder? under}) =>
      RevealAtText(
        segment: segment,
        start: start,
        end: end,
        content: shownContent(under: under),
      );

  /// The editor row of segment [segment] holding segment offset [local]:
  /// its index and spec (`splitRows(atSegmentStart: true)`, as the editor).
  ({int index, RowSpec spec}) rowOf(int segment, int local, {Finder? under}) {
    final text = segmentText(segment, under: under);
    final rows = splitRows(text, atSegmentStart: true);
    for (var r = 0; r < rows.length; r++) {
      if (rows[r].start <= local &&
          (local < rows[r].end || r == rows.length - 1)) {
        return (index: r, spec: rows[r]);
      }
    }
    throw TestFailure('no row holds $local in segment $segment');
  }

  /// The widget of row [row] of segment [segment] (`editor-row-<s>-<r>`).
  Finder rowFinder(int segment, int row, {Finder? under}) =>
      _in(under, find.byKey(ValueKey('editor-row-$segment-$row')));

  /// The global rect of the editor widget holding segment offset [local]:
  /// the row (a table row's grid while shown), or the excerpt card of a card
  /// segment.
  Rect rowRectOf(int segment, int local, {Finder? under}) {
    if (shownSegments(under: under)[segment] is TransclusionSegment) {
      return tester.getRect(
        _in(under, find.byKey(Key('excerpt-card-$segment'))),
      );
    }
    final row = rowOf(segment, local, under: under);
    final table = _in(
      under,
      find.byKey(ValueKey('editor-table-$segment-${row.index}')),
    );
    if (row.spec.kind == RowKind.table && table.evaluate().isNotEmpty) {
      return tester.getRect(table);
    }
    return tester.getRect(rowFinder(segment, row.index, under: under));
  }

  /// The global rect of the visual line holding segment offset [local] of
  /// segment [segment], from the row field's line boxes (its real top and
  /// bottom, the field's full width).
  Rect lineBoxOf(int segment, int local, {Finder? under}) {
    final row = rowOf(segment, local, under: under);
    final editable = findRenderEditable(
      tester.renderObject(rowFinder(segment, row.index, under: under)),
    );
    expect(editable, isNotNull, reason: 'row ${row.index} has a field');
    final lines = RenderEditableLineBoxes(editable!).lines;
    final line = lineHolding(lines, row.spec.toLocal(local));
    return Rect.fromPoints(
      editable.localToGlobal(Offset(0, line.top)),
      editable.localToGlobal(Offset(editable.size.width, line.bottom)),
    );
  }

  /// The global top of the visual line holding segment offset [local] of
  /// segment [segment] (D5).
  double lineTopOf(int segment, int local, {Finder? under}) =>
      lineBoxOf(segment, local, under: under).top;

  /// The global rect spanning the line boxes holding `[start, end)` of
  /// segment [segment] (one row).
  Rect linesOf(int segment, int start, int end, {Finder? under}) => lineBoxOf(
    segment,
    start,
    under: under,
  ).expandToInclude(lineBoxOf(segment, end - 1, under: under));

  /// How many visual lines hold `[start, end)` of segment [segment].
  int lineCount(int segment, int start, int end, {Finder? under}) {
    final row = rowOf(segment, start, under: under);
    final editable = findRenderEditable(
      tester.renderObject(rowFinder(segment, row.index, under: under)),
    )!;
    final lines = RenderEditableLineBoxes(editable).lines;
    final from = row.spec.toLocal(start);
    final to = row.spec.toLocal(end);
    return lines.where((l) => l.range.end > from && l.range.start < to).length;
  }

  // ------------------------------------------------------------ modes

  Finder get sourceSurface => find.byKey(const Key('editor-source-surface'));

  /// Taps the toolbar's Source toggle and pumps frames.
  Future<void> toggleSource() async {
    await tester.tap(find.byKey(const Key('editor-source-toggle')));
    await pumpFrames(tester);
  }

  EditorStateValue get editor => read(editorControllerProvider);
}

/// Pumps the workspace over [db] (by default a fresh V5 vault with
/// [seedRevealNotes]) and [cli] (by default answering `settings get` and
/// writing `update`s), at [surfaceSize] with text at the harness scale, and
/// navigates to [open] (nothing when null). Zoom animations take [zoom].
/// `tabsProvider` is a [RevealTabs]; [overrides] must not repeat it.
Future<NoteRevealHarness> pumpNoteReveal(
  WidgetTester tester, {
  FakeVaultDb? db,
  FakeMemexCli? cli,
  String? open = revealLongId,
  Duration zoom = Duration.zero,
  Size surfaceSize = const Size(1600, 1000),
  List<Override> overrides = const [],
}) async {
  final vault = db ?? seedRevealNotes(FakeVaultDb.v5());
  final fakeCli =
      cli ??
      (FakeMemexCli()
        ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
        ..onUpdateWrites(vault));
  RevealTabs? tabs;
  UiStateStore? store;
  final workspace = await pumpWorkspace(
    tester,
    db: vault,
    cli: fakeCli,
    surfaceSize: surfaceSize,
    overrides: [
      tabsProvider.overrideWith((ref) {
        final vaultPath = ref.watch(currentVaultProvider).localPath;
        store =
            ref.watch(uiStateStoreProvider) ??
            UiStateStore(vaultPath: vaultPath ?? '/dev/null');
        return tabs = RevealTabs(
          store: store!,
          onPersistedSelection: (id) =>
              ref.read(selectedNoteIdProvider.notifier).state = id,
          onBeforeLeave: () =>
              ref.read(editorControllerProvider.notifier).flushPendingSave(),
          navigationObserver: ref.watch(tabsNavigationObserverProvider),
        );
      }),
      canvasAnimationConfigProvider.overrideWithValue(
        CanvasAnimationConfig(zoomDuration: zoom),
      ),
      ...overrides,
    ],
  );
  // Tab writes are fire-and-forget file IO that never completes inside the
  // test's fake async zone (awaiting `store.flush()` in a teardown hangs);
  // pumpWorkspace's teardown removes the temp vault quietly instead.
  workspace.container.read(tabsProvider);
  final h = NoteRevealHarness(tester, workspace, tabs!);
  if (open != null) {
    await h.navigate(NoteTab(open));
    await pumpFrames(tester);
    expect(find.byType(NoteEditor), findsOneWidget);
    expect(h.body().note.id, open);
  }
  return h;
}
