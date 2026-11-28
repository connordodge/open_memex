// WI #129 verify round: the contracts Spec #122 R17a, R18, R19, R21, R22 and
// R11 document that the mapped tests in rebuild_isolation_test.dart leave to
// their bounds. Each test fails when its one documented rule is dropped.
//
// - The shared note-titles lookup (`NoteTitleResolver`): who is called back,
//   and when (pure Dart).
// - The decorations parse key (`DecorationsParse`, `layoutDecorations`).
// - `SegmentView.fieldsKey` and `LivePreviewController.propsChanged`.
// - The reveal gate repaints only rows with a selection to fill.
// - The link-region key handler is released with the last region.
// - The capture gutter measures a row again when its size changes.
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/note_title_lookup.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/link_region.dart' as link;
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_decorations.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';

import '../support/app_harness.dart';
import '../support/editor_rows_probe.dart';
import '../support/editor_scope.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/perf_counters.dart';
import '../support/poll_fakes.dart';
import '../support/spelling_editor_pump.dart';

/// One counter's current value, by its [PerfCounters] name.
int _n(String name) => PerfCounters.snapshot()[name]!;

NoteTitle _title(String id, String title) =>
    NoteTitle(id: id, title: title, updatedAt: 1);

/// A [LineBoxSource] over [text] with one 22.95 px line per source line and
/// 8 px per character.
class _Wi129Boxes implements LineBoxSource {
  _Wi129Boxes(this.text) {
    var top = 0.0;
    var start = 0;
    for (final line in text.split('\n')) {
      lines.add(
        LineBox(
          range: TextRange(start: start, end: start + line.length),
          top: top,
          bottom: top + 22.95,
        ),
      );
      top += 22.95;
      start += line.length + 1;
    }
  }

  final String text;

  @override
  final List<LineBox> lines = [];

  @override
  RenderBox get box => RenderConstrainedBox(
    additionalConstraints: const BoxConstraints.tightFor(
      width: 400,
      height: 100,
    ),
  );

  @override
  List<Rect> boxesFor(TextRange range) {
    if (range.isCollapsed) return const [];
    return [
      for (final l in lines)
        if (l.range.start < range.end && range.start <= l.range.end)
          Rect.fromLTRB(
            8.0 * (range.start.clamp(l.range.start, l.range.end)),
            l.top,
            8.0 * (range.end.clamp(l.range.start, l.range.end)),
            l.bottom,
          ),
    ];
  }

  @override
  Rect caretRect(int offset) => Rect.zero;

  @override
  int offsetAt(Offset point) => 0;

  @override
  LineBox lineAt(int offset) => lineHolding(lines, offset);
}

List<PaintedDecoration> _decorate(
  String text, {
  bool atSegmentStart = true,
  DecorationsParse? parse,
}) => layoutDecorations(
  text: text,
  boxes: _Wi129Boxes(text),
  columnLeft: 0,
  columnRight: 400,
  atSegmentStart: atSegmentStart,
  parse: parse,
);

/// A standalone [SegmentView] over [controller] whose parent rebuilds with
/// [fieldsKey] and a new `fieldBuilder` function on each `rebuild()`; the
/// count of field builds is `built`.
class _Wi129Segment {
  _Wi129Segment(this.controller);

  final TextEditingController controller;
  final focus = FocusNode();
  var gate = ValueNotifier<bool>(false);
  final _spare = <ValueNotifier<bool>>[];
  int fieldBuilds = 0;
  Object? fieldsKey;
  late StateSetter _set;

  Widget widget() => MaterialApp(
    home: Scaffold(
      body: StatefulBuilder(
        builder: (context, setState) {
          _set = setState;
          return SegmentView(
            index: 0,
            controller: controller,
            focusNode: focus,
            revealGate: gate,
            minLines: 1,
            hintText: null,
            fieldsKey: fieldsKey,
            onChanged: () {},
            onRowRemoved: (_) {},
            fieldBuilder: (context, row) {
              fieldBuilds++;
              return TextField(
                controller: row.controller,
                focusNode: row.focusNode,
                maxLines: null,
              );
            },
            builder: (context, rows, boxes) => rows,
          );
        },
      ),
    ),
  );

  Future<void> pump(WidgetTester tester) => pumpEditorScoped(tester, widget());

  /// The parent hands the segment another reveal gate.
  Future<void> swapGate(WidgetTester tester) async {
    _spare.add(gate);
    _set(() => gate = ValueNotifier<bool>(false));
    await tester.pump();
  }

  Future<void> rebuild(WidgetTester tester, {Object? key}) async {
    _set(() => fieldsKey = key);
    await tester.pump();
  }

  void dispose() {
    controller.dispose();
    focus.dispose();
    gate.dispose();
    for (final g in _spare) {
      g.dispose();
    }
  }
}

/// A daily note whose person section is 20 short lines, then an agent
/// block (`a-bug`), then 20 more.
Future<LiveRobot> _wi129Daily(WidgetTester tester) async {
  final db = FakeVaultDb.v5()
    ..seedLiveDaily(
      blocks: [
        SeedBlock(
          'p-first',
          [for (var i = 0; i < 20; i++) 'first $i'].join('\n'),
        ),
        const SeedBlock(
          'a-bug',
          'Agent saw a bug in the parser while the test suite ran on a very old build.',
          source: 'agent',
          createdVersion: 2,
        ),
        SeedBlock(
          'p-second',
          [for (var i = 0; i < 20; i++) 'second $i'].join('\n'),
        ),
      ],
    );
  final clock = FakeClock(DateTime(2026, 10, 3, 15));
  final cli = FakeMemexCli()..onUpdateServer(db, clock: clock);
  final r = await pumpLiveWorkspace(tester, db: db, cli: cli, clock: clock);
  await r.settle();
  return r;
}

/// Lets queued tab persistence finish before the harness deletes the temp
/// vault.
Future<void> _wi129Flush(WidgetTester tester, WorkspaceHarness h) async {
  await pumpFrames(tester);
  final store = h.read(tabsProvider.notifier).store;
  var flushed = false;
  store.flush().then((_) => flushed = true);
  for (var i = 0; i < 5000 && !flushed; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump();
  }
  expect(flushed, isTrue, reason: 'tab persistence finished');
}

void main() {
  holdFontFetches();

  setUp(() {
    PerfCounters.reset();
    link.debugLinkRegionTitleUpdates = 0;
    debugNoteTitleLookupBuilds = 0;
  });

  // ------------------------------------------------- note titles (R22)

  group('note titles resolver contracts (AC6, AC7)', () {
    test('the first titles load calls back every subscription', () {
      final resolver = NoteTitleResolver();
      var a = 0;
      var b = 0;
      resolver.subscribe(() => const ['One'], () => a++);
      resolver.subscribe(() => const <String>[], () => b++);
      resolver.update([_title('1', 'Other')]);
      expect(a, 1, reason: 'a link target that stays unresolved is called');
      expect(b, 1, reason: 'a region with no link is called too');
    });

    test(
      'a reload calls back only subscriptions whose targets resolve differently',
      () {
        final resolver = NoteTitleResolver();
        var linksOne = 0;
        var linksTwo = 0;
        var none = 0;
        resolver.update([_title('1', 'Two')]);
        resolver.subscribe(() => const ['One'], () => linksOne++);
        resolver.subscribe(() => const ['Two'], () => linksTwo++);
        resolver.subscribe(() => const <String>[], () => none++);
        resolver.update([_title('1', 'Two'), _title('2', 'One')]);
        expect(linksOne, 1, reason: 'One now resolves');
        expect(linksTwo, 0, reason: 'Two resolved before and after');
        expect(none, 0, reason: 'no targets, nothing to resolve');
        resolver.update([_title('2', 'One')]);
        expect(linksOne, 1, reason: 'One still resolves');
        expect(linksTwo, 1, reason: 'Two stopped resolving');
      },
    );

    test('the same list again calls nobody and builds no lookup', () {
      final resolver = NoteTitleResolver();
      final titles = [_title('1', 'Two')];
      resolver.update(titles);
      var calls = 0;
      resolver.subscribe(() => const ['One'], () => calls++);
      debugNoteTitleLookupBuilds = 0;
      resolver.update(titles);
      expect(calls, 0);
      expect(debugNoteTitleLookupBuilds, 0);
    });

    test(
      'a vault switch to unloaded and back calls every subscription again',
      () {
        final resolver = NoteTitleResolver();
        resolver.update([_title('1', 'Two')]);
        var calls = 0;
        resolver.subscribe(() => const <String>[], () => calls++);
        resolver.update(null);
        expect(calls, 0, reason: 'unloaded: every target resolves');
        expect(resolver.lookup.titles, isNull);
        expect(resolver.lookup.resolves('Anything'), isTrue);
        resolver.update([_title('9', 'Three')]);
        expect(calls, 1, reason: 'the first load of the next vault');
        expect(resolver.lookup.resolves('Anything'), isFalse);
        expect(resolver.lookup.resolves('Three'), isTrue);
      },
    );

    test('a cancelled subscription is not called back', () {
      final resolver = NoteTitleResolver();
      var calls = 0;
      final s = resolver.subscribe(() => const ['One'], () => calls++);
      s.cancel();
      resolver.update([_title('1', 'Two')]);
      expect(calls, 0);
    });

    test('a subscription cancelled by an earlier callback is skipped', () {
      final resolver = NoteTitleResolver();
      late NoteTitleSubscription second;
      var secondCalls = 0;
      resolver.subscribe(() => const <String>[], () => second.cancel());
      second = resolver.subscribe(() => const <String>[], () => secondCalls++);
      resolver.update([_title('1', 'Two')]);
      expect(secondCalls, 0);
    });

    test(
      'a list at the cap resolves every target and the first equal title wins',
      () {
        final capped = NoteTitleLookup.of([
          for (var i = 0; i < noteTitlesCap; i++) _title('$i', 'T$i'),
        ]);
        expect(capped.ids, isNull);
        expect(capped.resolves('No such note'), isTrue);
        final lookup = NoteTitleLookup.of([
          _title('first', 'Same'),
          _title('second', 'Same'),
        ]);
        expect(lookup.ids, {'Same': 'first'});
        expect(lookup.resolves('Same'), isTrue);
        expect(lookup.resolves('Other'), isFalse);
      },
    );
  });

  // ----------------------------------------- decorations parse key (R18)

  group('decorations parse key (AC5)', () {
    const text = '***\nplain `code` line';

    test('a parse of the same text and segment start is used again', () {
      final parse = DecorationsParse(text, atSegmentStart: true);
      final first = _decorate(text, parse: parse);
      PerfCounters.reset();
      final second = _decorate(text, parse: parse);
      expect(_n('classifyLines'), 0);
      expect(_n('tokenizeInline'), 0);
      expect(second.map((d) => d.rect), first.map((d) => d.rect));
      expect(second, isNotEmpty);
    });

    test('a parse of other text is not used for this text', () {
      final parse = DecorationsParse('plain line', atSegmentStart: true);
      PerfCounters.reset();
      final got = _decorate(text, parse: parse);
      expect(_n('classifyLines'), 1, reason: 'this text was parsed');
      expect(
        got.map((d) => d.rect),
        _decorate(text).map((d) => d.rect),
        reason: 'the decorations are the text own, not the stale parse',
      );
      expect(parse.holds('plain line', atSegmentStart: true), isTrue);
      expect(parse.holds(text, atSegmentStart: true), isFalse);
    });

    test('a parse made at the segment start is not used away from it', () {
      const fm = '---\nkey: v\n---\nbody';
      final parse = DecorationsParse(fm, atSegmentStart: true);
      expect(
        _decorate(fm, parse: parse),
        isEmpty,
        reason: 'frontmatter at the segment start paints no rule',
      );
      final away = _decorate(fm, atSegmentStart: false, parse: parse);
      expect(away, hasLength(2), reason: 'two rules away from the start');
      expect(
        away.map((d) => d.rect),
        _decorate(fm, atSegmentStart: false).map((d) => d.rect),
      );
      expect(parse.holds(fm, atSegmentStart: false), isFalse);
    });
  });

  // ------------------------------------------- fieldsKey and props (R19)

  group('segment view field reuse (AC2, AC11)', () {
    testWidgets(
      'a rebuild with a new field builder and no fieldsKey builds the fields again',
      (tester) async {
        final s = _Wi129Segment(TextEditingController(text: 'one\ntwo'));
        addTearDown(s.dispose);
        await s.pump(tester);
        final built = s.fieldBuilds;
        expect(built, greaterThan(0));
        await s.rebuild(tester);
        expect(s.fieldBuilds, greaterThan(built));
      },
    );

    testWidgets('a rebuild that keeps its fieldsKey builds no field again', (
      tester,
    ) async {
      final s = _Wi129Segment(TextEditingController(text: 'one\ntwo'));
      addTearDown(s.dispose);
      s.fieldsKey = 'note-1';
      await s.pump(tester);
      final built = s.fieldBuilds;
      await s.rebuild(tester, key: 'note-1');
      expect(s.fieldBuilds, built, reason: 'an equal key keeps the fields');
      await s.rebuild(tester, key: 'note-2');
      expect(s.fieldBuilds, greaterThan(built), reason: 'a new key rebuilds');
    });

    testWidgets('a change of line props alone notifies the row controller', (
      tester,
    ) async {
      final s = _Wi129Segment(TextEditingController(text: '- [ ] a'));
      addTearDown(s.dispose);
      await s.pump(tester);
      final host = tester.state<SegmentViewState>(find.byType(SegmentView));
      final row = host.rowController(0)!;
      expect(row.text, 'a');
      expect(row.taskDone, isFalse);
      var notified = 0;
      row.addListener(() => notified++);
      s.controller.text = '- [x] a';
      expect(notified, 1, reason: 'told once, as the host re-derives the rows');
      await tester.pump();
      await tester.pump();
      expect(host.rowController(0), same(row), reason: 'the row was kept');
      expect(row.text, 'a', reason: 'the row text did not change');
      expect(row.taskDone, isTrue, reason: 'only its line prop did');
    });

    testWidgets(
      'a swapped reveal gate is handed to the kept row and notifies it',
      (tester) async {
        final s = _Wi129Segment(TextEditingController(text: '- [ ] a'));
        addTearDown(s.dispose);
        await s.pump(tester);
        final host = tester.state<SegmentViewState>(find.byType(SegmentView));
        final row = host.rowController(0)!;
        final first = s.gate;
        expect(row.revealGate, same(first));
        var notified = 0;
        row.addListener(() => notified++);
        await s.swapGate(tester);
        expect(host.rowController(0), same(row), reason: 'the row was kept');
        expect(row.revealGate, same(s.gate));
        expect(row.revealGate, isNot(same(first)));
        expect(
          notified,
          greaterThan(0),
          reason: 'the field shows the new gate',
        );
      },
    );

    testWidgets(
      'each row reports where the segment selection meets its edges',
      (tester) async {
        final s = _Wi129Segment(
          TextEditingController(text: '- aa\n- bb\n- cc\n- dd\n- ee\n'),
        );
        addTearDown(s.dispose);
        await s.pump(tester);
        final host = tester.state<SegmentViewState>(find.byType(SegmentView));
        RowSelectionEdges edges(int row) =>
            host.rowEdgesOf(host.rowController(row)!)!.value;
        const none = (fromAbove: false, rowBreak: false, spans: false);
        // From inside row 1 to inside row 3.
        host.select(const TextSelection(baseOffset: 8, extentOffset: 18));
        await tester.pump();
        expect(edges(0), none);
        expect(edges(1), (fromAbove: false, rowBreak: true, spans: false));
        expect(edges(2), (fromAbove: true, rowBreak: true, spans: true));
        expect(edges(3), (fromAbove: true, rowBreak: false, spans: false));
        expect(edges(4), none);
        // Ends exactly on a row's edges: row 1 starts at 5, ends at 9.
        host.select(const TextSelection(baseOffset: 5, extentOffset: 14));
        await tester.pump();
        expect(edges(1), (fromAbove: false, rowBreak: true, spans: true));
        expect(edges(2), (fromAbove: true, rowBreak: false, spans: true));
        expect(edges(3), none);
        host.select(const TextSelection(baseOffset: 8, extentOffset: 15));
        await tester.pump();
        expect(edges(2), (fromAbove: true, rowBreak: true, spans: true));
        expect(edges(3), (fromAbove: true, rowBreak: false, spans: false));
        host.select(const TextSelection(baseOffset: 9, extentOffset: 12));
        await tester.pump();
        expect(edges(1), (fromAbove: false, rowBreak: true, spans: false));
        expect(edges(2), (fromAbove: true, rowBreak: false, spans: false));
        // The same range backwards, then a caret.
        host.select(const TextSelection(baseOffset: 18, extentOffset: 8));
        await tester.pump();
        expect(edges(2), (fromAbove: true, rowBreak: true, spans: true));
        host.select(const TextSelection.collapsed(offset: 12));
        await tester.pump();
        for (var r = 0; r < 5; r++) {
          expect(edges(r), none, reason: 'row $r under a caret');
        }
      },
    );

    testWidgets(
      'a row line parse is kept for its text and made again for new text',
      (tester) async {
        final s = _Wi129Segment(TextEditingController(text: 'abc'));
        addTearDown(s.dispose);
        await s.pump(tester);
        final host = tester.state<SegmentViewState>(find.byType(SegmentView));
        final row = host.rowController(0)!;
        final first = host.rowLinesOf(row)!;
        expect(first.single.contentEnd, 3);
        PerfCounters.reset();
        expect(host.rowLinesOf(row), same(first), reason: 'kept for its text');
        expect(_n('classifyLines'), 0);
        s.controller.text = 'abcdef';
        await tester.pump();
        expect(host.rowController(0), same(row), reason: 'the row was kept');
        expect(host.rowLinesOf(row)!.single.contentEnd, 6);
        expect(host.rowLinesOf(TextEditingController()), isNull);
      },
    );

    test('propsChanged notifies the controller listeners', () {
      final c = LivePreviewController(text: 'a');
      addTearDown(c.dispose);
      var notified = 0;
      c.addListener(() => notified++);
      c.propsChanged();
      expect(notified, 1);
    });
  });

  // ------------------------------------------------- reveal gate (R17a)

  group('reveal gate repaints (AC4)', () {
    const body = '- aa\n- bb\n- cc\n- dd\n- ee\n- ff\n';

    Future<SegmentViewState> prepare(
      WidgetTester tester, {
      required bool selecting,
    }) async {
      await pumpSpellingEditor(tester, body: body);
      await pumpFrames(tester);
      await activateRow(tester, 0, 2, offset: 1);
      final host = rowsHostOf(tester);
      if (selecting) {
        host.select(
          TextSelection(
            baseOffset: host.rowSpec(1)!.textStart + 1,
            extentOffset: host.rowSpec(3)!.textStart + 1,
          ),
        );
        await tester.pump();
        await tester.pump();
      }
      await pumpFrames(tester);
      return host;
    }

    testWidgets(
      'a gate change repaints the selection fill of the selected rows only',
      (tester) async {
        final host = await prepare(tester, selecting: true);
        expect(host.rowCount, greaterThan(6));
        PerfCounters.reset();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        await tester.pump();
        expect(
          _n('rowSelectionPaints'),
          inInclusiveRange(3, 4),
          reason: 'the three rows holding the selection, not all seven',
        );
      },
    );

    testWidgets(
      'a gate change with no selection repaints no selection fill beyond the caret row',
      (tester) async {
        await prepare(tester, selecting: false);
        PerfCounters.reset();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        await tester.pump();
        expect(_n('rowSelectionPaints'), lessThanOrEqualTo(2));
        expect(_n('layoutDecorations'), lessThanOrEqualTo(2));
      },
    );

    testWidgets(
      'a gate change repaints the row whose only selected part is its line break',
      (tester) async {
        await pumpSpellingEditor(tester, body: body);
        await pumpFrames(tester);
        await activateRow(tester, 0, 2, offset: 1);
        final host = rowsHostOf(tester);
        // From exactly the end of row 1's text into row 2: row 1 holds no
        // selected character of its own, only the line break after it.
        host.select(
          TextSelection(
            baseOffset: host.rowSpec(1)!.textEnd,
            extentOffset: host.rowSpec(2)!.textStart + 1,
          ),
        );
        await tester.pump();
        await tester.pump();
        await pumpFrames(tester);
        final own = host.rowController(1)!.selection;
        expect(
          own.isValid && !own.isCollapsed,
          isFalse,
          reason: 'row 1 selects no character of its own text',
        );
        // The row's selection render object, marked dirty by the gate change
        // alone: another row's repaint, or its own boundary's, must not hide
        // that it was told to repaint.
        RenderObject? fill;
        void visit(RenderObject o) {
          if (o.runtimeType.toString() == '_RenderRowSelection') fill ??= o;
          o.visitChildren(visit);
        }

        final rowObject = tester
            .element(find.byKey(const ValueKey<String>('editor-row-0-1')))
            .renderObject!;
        visit(rowObject);
        expect(fill, isNotNull, reason: 'row 1 has a selection render object');
        await tester.pump();
        expect(fill!.debugNeedsPaint, isFalse, reason: 'settled first');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.idle();
        expect(
          fill!.debugNeedsPaint,
          isTrue,
          reason: 'the gate change marked the line break row for paint',
        );
      },
    );

    testWidgets(
      'a gate change repaints decorations of rows holding a selection only',
      (tester) async {
        final host = await prepare(tester, selecting: true);
        expect(host.rowCount, greaterThan(6));
        PerfCounters.reset();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        await tester.pump();
        expect(
          _n('layoutDecorations'),
          inInclusiveRange(3, 4),
          reason: 'rows with a valid selection, not all seven',
        );
      },
    );
  });

  // -------------------------------------------------- key handler (R21)

  group('link key handler release (AC8)', () {
    testWidgets('the handler is released when the last link region goes', (
      tester,
    ) async {
      final s = _Wi129Segment(TextEditingController(text: 'one\ntwo\nthree'));
      addTearDown(s.dispose);
      await s.pump(tester);
      expect(link.debugLinkKeyHandlers, 1);
      // Two rows go away; one region is left, the handler stays.
      s.controller.text = 'one';
      await tester.pump();
      await tester.pump();
      expect(link.debugLinkKeyHandlers, 1, reason: 'a region is still there');
      await tester.pumpWidget(const SizedBox());
      expect(link.debugLinkKeyHandlers, 0, reason: 'no region, no handler');
      // A key event with no handler left does nothing and does not throw.
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.metaLeft,
        platform: 'macos',
      );
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.metaLeft,
        platform: 'macos',
      );
    }, variant: macOnly);

    testWidgets(
      'a pointer that left the link no longer follows the modifier key',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: '- see [[Other note]] here\n- second item\n',
        );
        await pumpFrames(tester);
        await activateRow(tester, 0, 0);
        final controller = rowsHostOf(tester).rowController(0)!;
        final text = controller.text;
        final start = text.indexOf('Other note');
        final boxes = rowBoxesOf(tester, 0, 0);
        final shown = boxes
            .boxesFor(TextRange(start: start, end: start + 'Other note'.length))
            .first;
        final at = boxes.box.localToGlobal(shown.center);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: at);
        await tester.pump();
        await mouse.moveTo(at);
        await tester.pump();
        await tester.sendKeyDownEvent(
          LogicalKeyboardKey.metaLeft,
          platform: 'macos',
        );
        await tester.pump();
        expect(controller.cmdHover, isNotNull, reason: 'hovered with Cmd');
        // The mouse leaves the field: the styling goes, and stays gone.
        await mouse.moveTo(const Offset(5, 5));
        await tester.pump();
        expect(controller.cmdHover, isNull, reason: 'the pointer left');
        await tester.sendKeyUpEvent(
          LogicalKeyboardKey.metaLeft,
          platform: 'macos',
        );
        await tester.sendKeyDownEvent(
          LogicalKeyboardKey.metaLeft,
          platform: 'macos',
        );
        await tester.pump();
        expect(controller.cmdHover, isNull, reason: 'not hovered, Cmd pressed');
        await tester.sendKeyUpEvent(
          LogicalKeyboardKey.metaLeft,
          platform: 'macos',
        );
        await mouse.removePointer();
        await _wi129Flush(tester, e.workspace);
      },
      variant: macOnly,
    );
  });

  // ---------------------------------------------- capture gutter (R11)

  group('capture gutter measures (AC10)', () {
    testWidgets(
      'the capture gutter rule grows when its block row wraps to a second line',
      (tester) async {
        final r = await _wi129Daily(tester);
        final before = tester.getRect(r.gutterRule('a-bug'));
        // The window narrows: the same row text wraps, so the row's size
        // changes while its text does not.
        tester.view.physicalSize = const Size(1100, 1000);
        await r.settle();
        await tester.pump();
        await tester.pump();
        final after = tester.getRect(r.gutterRule('a-bug'));
        expect(
          after.height,
          greaterThan(before.height + 8),
          reason: 'a wrapped line makes the block taller: $before -> $after',
        );
        await _wi129Flush(tester, r.h);
      },
      variant: macOnly,
    );
  });
}
