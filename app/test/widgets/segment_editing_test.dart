// WI #159 (D5, D7, D13, TD12, TS6): the interface-first seams over today's
// single field per text segment.
// - The `SegmentEditing` handle found from Key `text-segment-<i>`: text,
//   selection in segment offsets, rowCount 1, focusedRow, select(),
//   replaceText() (one onContentChanged with the joined body) and
//   rectForOffset() (global, non-zero height).
// - Every text segment field is wrapped in a `LivePreviewFrame` whose
//   controller is the segment's `LivePreviewController`; with the
//   pass-throughs the field renders exactly the controller text and no
//   saved byte changes.
// - `revealGate` follows the segment's focus.
// - The selection paints with `OmColors.selection`.
// - No robot, journey or widget test reads a segment through EditableText.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/link_region.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_decorations.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_frame.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/editor_scope.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/segment_editing_finder.dart';
import '../support/wi159_line_geometry.dart';

const _token = '![[2026-09-05#^b7k2m9..^c3d4e5]]';

/// Text segment 0, the card (segment 1) and text segment 2.
const _body = 'Intro line\n$_token\nOutro line\n';

Note _note(String content, {bool daily = false}) => Note(
  id: daily ? 'daily-2026-10-03' : 'topic-159',
  title: daily ? '2026-10-03' : 'Seams',
  contentMd: content,
  frontmatter: daily ? '{"role":"daily"}' : '{"role":"topic"}',
  version: 3,
  createdAt: 0,
  updatedAt: 0,
  tags: const [],
);

/// Every `onContentChanged` report of the pumped [SegmentedBody].
typedef _Wi159Changes = List<String>;

/// Pumps a [SegmentedBody] showing [content] (no vault: cards render empty)
/// and returns the list its `onContentChanged` reports land in.
Future<_Wi159Changes> _wi159PumpBody(
  WidgetTester tester, {
  String content = _body,
  bool daily = false,
}) async {
  final changes = <String>[];
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: SegmentedBody(
            note: _note(content, daily: daily),
            content: content,
            savedVersion: 3,
            onContentChanged: changes.add,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return changes;
}

Finder _wi159Segment(int i) => find.byKey(textSegmentKey(i));

/// The single [LivePreviewFrame] under text segment [i].
Finder _wi159FrameOf(int i) => find.descendant(
  of: _wi159Segment(i),
  matching: find.byType(LivePreviewFrame),
);

LivePreviewFrame _wi159Frame(WidgetTester tester, int i) =>
    tester.widget<LivePreviewFrame>(_wi159FrameOf(i));

/// The rendered field of text segment [i].
RenderEditable _wi159Field(WidgetTester tester, int i) =>
    wi159EditableIn(tester, _wi159Segment(i));

/// The files TS6 migrates onto the handle (WI #159 item 6).
const _wi159MigratedFiles = [
  'test/robots/segmented_editor_robot.dart',
  'test/support/poll_fakes.dart',
  'test/robots/today_robot.dart',
  'test/robots/hosted_workspace_robot.dart',
  'test/journeys/create_topic_editor_test.dart',
  'test/journeys/create_topic_partial_failure_test.dart',
  'test/journeys/create_topic_test.dart',
  'test/journeys/topics_editor_rebase_test.dart',
  'test/journeys/topics_editor_rebase_race_test.dart',
  'test/journeys/live_append_test.dart',
  'test/journeys/hosted_pending_save_test.dart',
  'test/journeys/virtual_today_edges_journey_test.dart',
  'test/widgets/segmented_body_test.dart',
  'test/widgets/segmented_editor_test.dart',
  'test/widgets/editor_async_contracts_test.dart',
  'test/widgets/editor_vault_access_test.dart',
  'test/widgets/editor_vault_writes_test.dart',
  'test/widgets/capture_gutter_test.dart',
];

void main() {
  holdFontFetches();

  group('SegmentEditing handle (AC1)', () {
    testWidgets(
      'each text segment handle found from its Key reports the segment text and one row',
      (tester) async {
        await _wi159PumpBody(tester);

        final first = segmentEditingAt(tester, 0);
        final last = segmentEditingAt(tester, 2);
        expect(first.text, 'Intro line\n');
        expect(last.text, 'Outro line\n');
        expect(first.rowCount, 1);
        expect(last.rowCount, 1);
        expect(first.focusedRow, isNull);
        expect(last.focusedRow, isNull);
        // A loaded note puts each segment caret at its end.
        expect(
          first.selection,
          const TextSelection.collapsed(offset: 'Intro line\n'.length),
        );
        expect(
          last.selection,
          const TextSelection.collapsed(offset: 'Outro line\n'.length),
        );
        final all = allSegmentEditings(tester);
        expect(all, hasLength(2));
        expect(all.first, same(first));
        expect(all.last, same(last));
        // The card between them has no handle.
        expect(
          find.descendant(
            of: find.byKey(const Key('excerpt-card-1')),
            matching: segmentEditingElements,
          ),
          findsNothing,
        );
        // The editor body is the first text segment.
        expect(editorBodySegment(tester), same(first));
      },
    );

    testWidgets(
      'focusedRow is 0 while the segment field has focus and null otherwise',
      (tester) async {
        await _wi159PumpBody(tester);

        await tester.showKeyboard(_wi159Segment(2));
        await tester.pump();
        expect(segmentEditingAt(tester, 2).focusedRow, 0);
        expect(segmentEditingAt(tester, 0).focusedRow, isNull);

        await tester.showKeyboard(_wi159Segment(0));
        await tester.pump();
        expect(segmentEditingAt(tester, 0).focusedRow, 0);
        expect(segmentEditingAt(tester, 2).focusedRow, isNull);

        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        expect(segmentEditingAt(tester, 0).focusedRow, isNull);
        expect(segmentEditingAt(tester, 2).focusedRow, isNull);
      },
    );

    testWidgets(
      'select moves the field selection in segment offsets without moving focus',
      (tester) async {
        await _wi159PumpBody(tester);
        await tester.showKeyboard(_wi159Segment(0));
        await tester.pump();

        const range = TextSelection(baseOffset: 1, extentOffset: 4);
        segmentEditingAt(tester, 2).select(range);
        await tester.pump();

        expect(segmentEditingAt(tester, 2).selection, range);
        expect(_wi159Field(tester, 2).selection, range);
        expect(segmentEditingAt(tester, 0).focusedRow, 0);
        expect(segmentEditingAt(tester, 2).focusedRow, isNull);

        // A backwards range keeps its direction.
        const back = TextSelection(baseOffset: 9, extentOffset: 2);
        segmentEditingAt(tester, 0).select(back);
        await tester.pump();
        expect(segmentEditingAt(tester, 0).selection, back);
        expect(_wi159Field(tester, 0).selection, back);
        expect(segmentEditingAt(tester, 0).focusedRow, 0);

        segmentEditingAt(
          tester,
          0,
        ).select(const TextSelection.collapsed(offset: 0));
        await tester.pump();
        expect(
          _wi159Field(tester, 0).selection,
          const TextSelection.collapsed(offset: 0),
        );
      },
    );

    testWidgets(
      'replaceText changes the text and reports one onContentChanged with the joined body',
      (tester) async {
        final changes = await _wi159PumpBody(tester);

        segmentEditingAt(tester, 2).replaceText('Outro edited\n');
        await tester.pump();

        expect(changes, ['Intro line\n$_token\nOutro edited\n']);
        expect(segmentEditingAt(tester, 2).text, 'Outro edited\n');
        expect(
          _wi159Field(tester, 2).text?.toPlainText(),
          'Outro edited\n',
          reason: 'the field renders the new text',
        );
        expect(
          segmentEditingAt(tester, 2).selection,
          const TextSelection.collapsed(offset: 'Outro edited\n'.length),
        );
        expect(segmentEditingAt(tester, 2).focusedRow, isNull);

        // Text before a card keeps the card on its own line when joined.
        segmentEditingAt(tester, 0).replaceText('Intro');
        await tester.pump();
        expect(changes, hasLength(2));
        expect(changes.last, 'Intro\n$_token\nOutro edited\n');

        // The same text again is no change.
        segmentEditingAt(tester, 0).replaceText('Intro');
        await tester.pump();
        expect(changes, hasLength(2));
      },
    );

    testWidgets(
      'replaceText on the focused segment keeps its focus and puts the caret at the end',
      (tester) async {
        final changes = await _wi159PumpBody(tester);
        await tester.showKeyboard(_wi159Segment(0));
        await tester.pump();

        segmentEditingAt(tester, 0).replaceText('Typed\nlines\n');
        await tester.pump();

        expect(changes, ['Typed\nlines\n$_token\nOutro line\n']);
        expect(segmentEditingAt(tester, 0).focusedRow, 0);
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(offset: 12),
        );
      },
    );
  });

  group('rectForOffset (AC2)', () {
    testWidgets(
      'rectForOffset returns the field caret rect for an offset in global coordinates with non-zero height',
      (tester) async {
        await _wi159PumpBody(
          tester,
          content: 'Intro line\nsecond line\n$_token\n',
        );
        final handle = segmentEditingAt(tester, 0);
        final field = _wi159Field(tester, 0);
        expect(field.localToGlobal(Offset.zero).dx, greaterThan(20));

        for (final offset in [0, 5, 10, 11, 17, 23]) {
          final rect = handle.rectForOffset(offset);
          final caret = wi159Global(
            field,
            field.getLocalRectForCaret(TextPosition(offset: offset)),
          );
          expect(rect.height, greaterThan(0), reason: 'offset $offset');
          expect(
            rect.left,
            moreOrLessEquals(caret.left, epsilon: 1),
            reason: 'offset $offset x',
          );
          expect(
            rect.center.dy,
            inInclusiveRange(caret.top, caret.bottom),
            reason: 'offset $offset is on the caret line',
          );
        }
        // The second line is below the first.
        expect(
          handle.rectForOffset(11).top,
          greaterThan(handle.rectForOffset(0).top + 10),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'rectForOffset of an empty text segment has non-zero height at the field',
      (tester) async {
        await _wi159PumpBody(tester, content: '$_token\nAfter the card\n');
        final empty = segmentEditingAt(tester, 0);
        expect(empty.text, '');
        final field = _wi159Field(tester, 0);
        final origin = field.localToGlobal(Offset.zero);

        final rect = empty.rectForOffset(0);
        expect(rect.height, greaterThan(0));
        expect(rect.left, moreOrLessEquals(origin.dx, epsilon: 1));
        expect(
          rect.center.dy,
          inInclusiveRange(origin.dy, origin.dy + field.size.height),
        );
        // The segment after the card starts below the empty one.
        expect(
          segmentEditingAt(tester, 2).rectForOffset(0).top,
          greaterThan(rect.bottom),
        );
      },
      variant: macOnly,
    );
  });

  group('live preview frame (AC6)', () {
    testWidgets(
      'every text segment field is wrapped in a LivePreviewFrame whose controller is the segment LivePreviewController',
      (tester) async {
        await _wi159PumpBody(tester);

        expect(find.byType(LivePreviewFrame), findsNWidgets(2));
        for (final i in [0, 2]) {
          final frameFinder = _wi159FrameOf(i);
          expect(frameFinder, findsOneWidget, reason: 'segment $i');
          final frame = _wi159Frame(tester, i);
          final controller = frame.controller;
          expect(controller, isA<LivePreviewController>());
          // The wrapped field edits that controller.
          final field = tester.widget<TextField>(
            find.descendant(of: frameFinder, matching: find.byType(TextField)),
          );
          expect(field.controller, same(controller), reason: 'segment $i');
          // The frame composes the decorations and the link region around
          // the field, handing them the same controller.
          final decorations = find.descendant(
            of: frameFinder,
            matching: find.byType(LivePreviewDecorations),
          );
          final links = find.descendant(
            of: frameFinder,
            matching: find.byType(LinkRegion),
          );
          expect(decorations, findsOneWidget);
          expect(links, findsOneWidget);
          expect(
            tester.widget<LivePreviewDecorations>(decorations).controller,
            same(controller),
          );
          expect(tester.widget<LinkRegion>(links).controller, same(controller));
          for (final wrapper in [decorations, links]) {
            expect(
              find.descendant(of: wrapper, matching: find.byType(TextField)),
              findsOneWidget,
            );
          }
          // Pass-through: the field renders exactly the controller text,
          // which is the segment text.
          expect(_wi159Field(tester, i).text?.toPlainText(), controller.text);
          expect(controller.text, segmentEditingAt(tester, i).text);
        }

        // An edit through the handle lands in the frame controller.
        segmentEditingAt(tester, 2).replaceText('Edited');
        await tester.pump();
        expect(_wi159Frame(tester, 2).controller.text, 'Edited');
      },
    );

    testWidgets(
      'a re-split segment field is a LivePreviewController in a LivePreviewFrame too',
      (tester) async {
        await _wi159PumpBody(tester);
        // A note of another shape (two cards) builds new segments.
        const twoCards = 'A\n$_token\nB\n![[2026-09-05#^f6g7h8]]\nC\n';
        await _wi159PumpBody(tester, content: twoCards);
        await tester.pump();

        expect(find.byType(LivePreviewFrame), findsNWidgets(3));
        for (final (i, text) in [(0, 'A\n'), (2, 'B\n'), (4, 'C\n')]) {
          final frame = _wi159Frame(tester, i);
          expect(frame.controller, isA<LivePreviewController>());
          expect(frame.controller.text, text);
          expect(_wi159Field(tester, i).text?.toPlainText(), text);
        }
      },
    );

    testWidgets(
      'the frame boxes and textLeft locate the field text for decorations and links',
      (tester) async {
        for (final daily in [false, true]) {
          await _wi159PumpBody(
            tester,
            daily: daily,
            content: daily
                ? 'Morning pages\nsecond line\n'
                : 'Intro line\nsecond line\n',
          );
          await tester.pump();
          final frameFinder = _wi159FrameOf(0);
          final frame = _wi159Frame(tester, 0);
          final handle = segmentEditingAt(tester, 0);
          final textStart = handle.rectForOffset(0);

          final boxes = frame.boxes?.call();
          expect(boxes, isNotNull, reason: 'daily $daily: laid out boxes');
          final caret = boxes!.caretRect(0);
          final global = boxes.box.localToGlobal(caret.topLeft);
          expect(global.dx, moreOrLessEquals(textStart.left, epsilon: 0.5));
          expect(global.dy, moreOrLessEquals(textStart.top, epsilon: 0.5));
          expect(boxes.lines, hasLength(greaterThanOrEqualTo(2)));

          // textLeft is where the text column starts in the frame.
          final frameLeft = tester.getTopLeft(frameFinder).dx;
          expect(
            frameLeft + frame.textLeft,
            moreOrLessEquals(textStart.left, epsilon: 1),
            reason: 'daily $daily',
          );
          final decorationsFinder = find.descendant(
            of: frameFinder,
            matching: find.byType(LivePreviewDecorations),
          );
          final decorations = tester.widget<LivePreviewDecorations>(
            decorationsFinder,
          );
          expect(
            tester.getTopLeft(decorationsFinder).dx + decorations.textLeft,
            moreOrLessEquals(textStart.left, epsilon: 1),
          );
          final links = tester.widget<LinkRegion>(
            find.descendant(of: frameFinder, matching: find.byType(LinkRegion)),
          );
          for (final LineBoxSource? Function()? get in [
            decorations.boxes,
            links.boxes,
          ]) {
            final other = get?.call();
            expect(other, isNotNull);
            expect(other!.box, same(boxes.box));
          }
          if (daily) {
            // The capture gutter column stays left of the text column.
            final gutter = tester.getRect(
              find.byKey(const Key('capture-gutter')),
            );
            expect(textStart.left, greaterThanOrEqualTo(gutter.right - 0.5));
          }
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'opening notes with live preview frames and moving focus between segments saves nothing',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);
        expect(find.byType(LivePreviewFrame), findsNWidgets(2));
        await r.focusSegment(0);
        await r.focusSegment(2);
        await r.waitForSave();

        await r.open(fixtureDailyId);
        // TEST-CHANGE (#167): one LivePreviewFrame per editor row; the
        // person text's `- tried coyote time` line is its own item row.
        expect(r.segment(0).rowCount, 3);
        expect(find.byType(LivePreviewFrame), findsNWidgets(3));
        await r.focusSegment(0, offset: 0);
        await r.waitForSave();

        expect(r.updates, isEmpty);
        expect(r.segmentText(0), fixturePerson);
      },
    );
  });

  group('segment view and reveal gate contracts (verify)', () {
    testWidgets(
      'the SegmentView builder gets null line boxes before the field is laid out',
      (tester) async {
        final controller = TextEditingController(text: 'abc\ndef');
        final focus = FocusNode();
        final gate = ValueNotifier(false);
        addTearDown(controller.dispose);
        addTearDown(focus.dispose);
        addTearDown(gate.dispose);
        final duringBuild = <LineBoxSource?>[];
        LineBoxSource? Function()? boxes;
        var withField = true;
        late StateSetter setOuter;
        await pumpEditorScoped(
          tester,
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  setOuter = setState;
                  return SegmentView(
                    index: 0,
                    controller: controller,
                    focusNode: focus,
                    revealGate: gate,
                    minLines: 1,
                    hintText: null,
                    onChanged: () {},
                    onRowRemoved: (_) {},
                    fieldBuilder: (context, row) => withField
                        ? TextField(
                            key: const Key('view-field'),
                            controller: row.controller,
                            focusNode: row.focusNode,
                            maxLines: null,
                          )
                        : const SizedBox(width: 10, height: 10),
                    builder: (context, rows, b) {
                      boxes = b;
                      duringBuild.add(b());
                      return rows;
                    },
                  );
                },
              ),
            ),
          ),
        );

        expect(duringBuild, hasLength(1));
        expect(duringBuild.single, isNull, reason: 'first build: no layout');
        final laidOut = boxes!();
        expect(laidOut, isNotNull);
        // Over C1's rows the source measures the one prose row's field:
        // two lines, the second holding `def` (segment offsets 4..7).
        expect(laidOut!.lines, hasLength(2));
        expect(laidOut.lines.last.range, const TextRange(start: 4, end: 7));
        expect(
          laidOut.caretRect(4).top,
          moreOrLessEquals(laidOut.lines.last.top, epsilon: 0.5),
        );
        expect(
          tester.state<SegmentViewState>(find.byType(SegmentView)).lineBoxes(),
          isNotNull,
        );

        // A builder that renders no field reports no line boxes.
        setOuter(() => withField = false);
        await tester.pump();
        expect(boxes!(), isNull);
        expect(
          tester.state<SegmentViewState>(find.byType(SegmentView)).lineBoxes(),
          isNull,
        );
      },
    );

    testWidgets(
      'a re-split disposes the replaced reveal gates and the new gates follow segment focus',
      (tester) async {
        await _wi159PumpBody(tester);
        await tester.showKeyboard(_wi159Segment(0));
        await tester.pump();
        final old0 = _wi159Frame(tester, 0).controller.revealGate;
        final old2 = _wi159Frame(tester, 2).controller.revealGate;
        expect(old0.value, isTrue);

        // Another shape re-splits the body; segment 0 reuses the primary
        // focus node, and the caret moves to the segment at its offset.
        const twoCards = 'A\n$_token\nB\n![[2026-09-05#^f6g7h8]]\nC\n';
        await _wi159PumpBody(tester, content: twoCards);
        await tester.pump();
        final new0 = _wi159Frame(tester, 0).controller.revealGate;
        expect(new0, isNot(same(old0)));
        var focused = 0;
        for (final i in [0, 2, 4]) {
          final hasFocus = segmentEditingAt(tester, i).focusedRow != null;
          if (hasFocus) focused++;
          expect(
            _wi159Frame(tester, i).controller.revealGate.value,
            hasFocus,
            reason: 'segment $i gate follows its focus',
          );
        }
        expect(focused, 1, reason: 'the caret is restored into one segment');

        for (final gate in [old0, old2]) {
          expect(
            () => (gate as ChangeNotifier).addListener(() {}),
            throwsFlutterError,
            reason: 'the replaced gate is disposed',
          );
        }

        // The disposed gate no longer listens to the reused primary node:
        // moving focus away and back reports no error.
        await tester.showKeyboard(_wi159Segment(2));
        await tester.pump();
        await tester.showKeyboard(_wi159Segment(0));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(new0.value, isTrue);
      },
    );
  });

  group('LivePreviewController (AC6, AC7)', () {
    testWidgets(
      'a new LivePreviewController has safe defaults and renders its text unchanged',
      (tester) async {
        const text = '# Head **b** [[c]]\n- [ ] d\n> q\n';
        final controllers = [
          LivePreviewController(text: text),
          LivePreviewController.fromValue(
            const TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: 3),
            ),
          ),
        ];
        for (final c in controllers) {
          addTearDown(c.dispose);
          expect(c.text, text);
          expect(c.itemText, isFalse);
          expect(c.taskDone, isFalse);
          expect(c.quote, isFalse);
          expect(c.atSegmentStart, isTrue);
          expect(c.revealGate.value, isFalse);
        }
        expect(controllers[1].selection.baseOffset, 3);
        // Host-set props are settable.
        final gate = ValueNotifier<bool>(true);
        addTearDown(gate.dispose);
        controllers[0]
          ..itemText = true
          ..taskDone = true
          ..quote = true
          ..atSegmentStart = false
          ..revealGate = gate;
        expect(controllers[0].itemText, isTrue);
        expect(controllers[0].taskDone, isTrue);
        expect(controllers[0].quote, isTrue);
        expect(controllers[0].atSegmentStart, isFalse);
        expect(controllers[0].revealGate.value, isTrue);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TextField(
                key: const Key('plain-field'),
                controller: controllers[1],
                maxLines: null,
              ),
            ),
          ),
        );
        final span = controllers[1].buildTextSpan(
          context: tester.element(find.byKey(const Key('plain-field'))),
          withComposing: false,
        );
        expect(span.toPlainText(), text);
        expect(
          wi159EditableIn(
            tester,
            find.byKey(const Key('plain-field')),
          ).text?.toPlainText(),
          text,
        );
      },
    );

    testWidgets(
      'LivePreviewController revealGate reports true while the segment has focus and false after focus moves elsewhere',
      (tester) async {
        await _wi159PumpBody(tester);
        final gate0 = _wi159Frame(tester, 0).controller.revealGate;
        final gate2 = _wi159Frame(tester, 2).controller.revealGate;
        expect(gate0.value, isFalse);
        expect(gate2.value, isFalse);
        final seen0 = <bool>[];
        void listener() => seen0.add(gate0.value);
        gate0.addListener(listener);
        addTearDown(() => gate0.removeListener(listener));

        await tester.showKeyboard(_wi159Segment(0));
        await tester.pump();
        expect(gate0.value, isTrue);
        expect(gate2.value, isFalse);

        await tester.showKeyboard(_wi159Segment(2));
        await tester.pump();
        expect(gate0.value, isFalse);
        expect(gate2.value, isTrue);

        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        expect(gate0.value, isFalse);
        expect(gate2.value, isFalse);

        // Listeners heard each change of segment 0 focus.
        expect(seen0, [true, false]);
      },
    );
  });

  group('selection colour (AC8)', () {
    test(
      'OmColors.selection is accent 7CFFB2 at alpha 56 and selectionBg is unchanged',
      () {
        expect(OmColors.selection, const Color(0x387CFFB2));
        expect(OmColors.selection, OmColors.accent.withAlpha(56));
        expect(OmColors.selectionBg, const Color(0x387CFFB2));
      },
    );

    testWidgets(
      'a non-collapsed selection in a segment field paints with OmColors.selection',
      (tester) async {
        await _wi159PumpBody(tester);
        await tester.showKeyboard(_wi159Segment(0));
        await tester.pump();
        segmentEditingAt(
          tester,
          0,
        ).select(const TextSelection(baseOffset: 0, extentOffset: 5));
        await tester.pump();

        // TEST-CHANGE (block selection): the editor row paints the fill
        // behind its field; the field paints none of its own.
        final field = _wi159Field(tester, 0);
        expect(field.selectionColor?.a ?? 0, 0);
        expect(
          tester.renderObject(find.byKey(const ValueKey('editor-row-0-0'))),
          paints..rect(color: OmColors.selection),
        );
      },
      variant: macOnly,
    );
  });

  group('finder migration (AC10)', () {
    test(
      'no robot journey or widget test reads a text segment through EditableText',
      () {
        final banned = RegExp(
          r'widget<EditableText>|widgetList<EditableText>|'
          r'find\.byType\(\s*EditableText\s*[,)]|EditableTextState>',
        );
        final offenders = <String>[];
        for (final path in _wi159MigratedFiles) {
          final file = File(path);
          expect(file.existsSync(), isTrue, reason: path);
          final lines = file.readAsLinesSync();
          for (var i = 0; i < lines.length; i++) {
            if (banned.hasMatch(lines[i])) {
              offenders.add('$path:${i + 1}: ${lines[i].trim()}');
            }
          }
        }
        expect(offenders, isEmpty);
      },
    );
  });
}
