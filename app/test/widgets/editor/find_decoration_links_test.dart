// WI #84 (#61 F4, ruling D7; Spec #61 Req 27): a line Find in note reveals
// for its current match shows its markup, so a plain click on a link there
// places a caret and does not follow (`LinkRegion._plainFollows` reads the
// find reveal range through `revealedLines`).
//
// Two levels: a bare field under a LinkRegion (what the press marks, and the
// plain hover cursor), and the whole workspace (where the click goes; the
// click asserts after settle, 53-C). Click points come from the field's own
// line boxes after the reveal has laid out, never constants.

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/url_opener.dart';
import 'package:open_memex_app/src/widgets/editor/find_decoration.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/link_region.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';

import '../../robots/segmented_editor_robot.dart';
import '../../support/app_harness.dart';
import '../../support/daily_seed.dart';
import '../../support/editor_scope.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import '../../support/recording_tabs.dart';
import '../../support/segment_editing_finder.dart';

/// The note titled `Known` that resolved wikilinks open.
const _wi84KnownId = 'topic-known';

/// `[start, end)` of the first [needle] in [text].
TextRange _wi84Range(String text, String needle) {
  final at = text.indexOf(needle);
  expect(at, isNonNegative, reason: 'text holds "$needle"');
  return TextRange(start: at, end: at + needle.length);
}

/// The mouse cursor the app shows for the test mouse (device 1).
MouseCursor? _wi84Cursor() =>
    RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);

/// A bare unfocused field under a LinkRegion, as live_preview_links_test.dart
/// pumps one.
final class _Wi84LinkField {
  _Wi84LinkField(this.controller, this.fieldKey);

  final LivePreviewController controller;
  final GlobalKey fieldKey;

  LineBoxSource? lookup() {
    final editable = findRenderEditable(
      fieldKey.currentContext?.findRenderObject(),
    );
    return editable == null ? null : RenderEditableLineBoxes(editable);
  }

  /// A global point in the middle of the first [needle] in the field, read
  /// from the field's current layout.
  Offset pointOn(String needle) {
    final r = _wi84Range(controller.text, needle);
    final b = lookup()!;
    final a = b.caretRect(r.start);
    final z = b.caretRect(r.end);
    expect(z.left, greaterThan(a.left), reason: '"$needle" has a width');
    return b.box.localToGlobal(Offset((a.left + z.left) / 2, a.center.dy));
  }
}

Future<_Wi84LinkField> _wi84PumpLinkField(
  WidgetTester tester,
  String text,
) async {
  final controller = LivePreviewController(text: text);
  addTearDown(controller.dispose);
  final field = _Wi84LinkField(controller, GlobalKey());
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
              boxes: field.lookup,
              child: TextField(
                key: field.fieldKey,
                controller: controller,
                maxLines: null,
              ),
            ),
          ),
        ),
      ),
    ),
    titles: [NoteTitle(id: _wi84KnownId, title: 'Known', updatedAt: 1)],
  );
  await tester.pump();
  await tester.pump();
  return field;
}

/// Presses a plain mouse button at [at] and returns what the LinkRegion
/// marked on the controller for that press, then releases and removes the
/// mouse.
Future<MarkedPress?> _wi84PlainPress(
  WidgetTester tester,
  LivePreviewController controller,
  Offset at,
) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: at);
  await mouse.down(at);
  await tester.pump();
  final marked = controller.markedPress;
  await mouse.up();
  await tester.pump();
  await mouse.removePointer();
  await tester.pump();
  return marked;
}

void main() {
  holdFontFetches();

  group('find revealed link line', () {
    testWidgets(
      'a plain press on a link in a find revealed line marks no follow and a press after the range moves off marks one',
      (tester) async {
        const text = 'Go [docs](https://x.y) now\nSecond line';
        final f = await _wi84PumpLinkField(tester, text);
        final n = ValueNotifier<FindDecoration?>(null);
        addTearDown(n.dispose);
        f.controller.findDecoration = n;

        // No decoration: the line is rendered, a plain press marks a follow.
        expect(
          await _wi84PlainPress(tester, f.controller, f.pointOn('docs')),
          isNotNull,
          reason: 'a rendered link line marks the press',
        );

        // The current match is in the URL: the line reveals.
        final url = _wi84Range(text, 'x.y');
        n.value = FindDecoration(
          revealRange: url,
          inkRanges: [url],
          current: url,
        );
        await tester.pump();
        await tester.pump();
        expect(
          await _wi84PlainPress(tester, f.controller, f.pointOn('docs')),
          isNull,
          reason: 'a find revealed line marks no follow',
        );

        // The range moves to the next line: the link line is rendered again.
        final second = _wi84Range(text, 'Second');
        n.value = FindDecoration(
          revealRange: second,
          inkRanges: [url, second],
          current: second,
        );
        await tester.pump();
        await tester.pump();
        expect(
          await _wi84PlainPress(tester, f.controller, f.pointOn('docs')),
          isNotNull,
          reason: 'the range left the line',
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain hover over a link in a find revealed line keeps the text cursor and sets no hover',
      (tester) async {
        const text = 'Go [[Known]] now\nSecond line';
        final f = await _wi84PumpLinkField(tester, text);
        final n = ValueNotifier<FindDecoration?>(null);
        addTearDown(n.dispose);
        f.controller.findDecoration = n;
        final known = _wi84Range(text, 'Known');
        final token = _wi84Range(text, '[[Known]]');

        Future<void> hover(String reason, {required bool follows}) async {
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          final at = f.pointOn('Known');
          await mouse.addPointer(location: at);
          await tester.pump();
          await mouse.moveTo(at);
          await tester.pump();
          try {
            if (follows) {
              expect(_wi84Cursor(), SystemMouseCursors.click, reason: reason);
              expect(f.controller.cmdHover, token, reason: reason);
            } else {
              expect(_wi84Cursor(), SystemMouseCursors.text, reason: reason);
              expect(f.controller.cmdHover, isNull, reason: reason);
            }
          } finally {
            await mouse.removePointer();
            await tester.pump();
          }
        }

        n.value = FindDecoration(
          revealRange: _wi84Range(text, 'Second'),
          inkRanges: [known],
        );
        await tester.pump();
        await tester.pump();
        await hover('the range is on the next line', follows: true);

        n.value = FindDecoration(
          revealRange: known,
          inkRanges: [known],
          current: known,
        );
        await tester.pump();
        await tester.pump();
        await hover('the link line is find revealed', follows: false);
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain click on a link in a find revealed line places a caret and does not follow the link',
      (tester) async {
        const body = 'See [[Known]] now\nSecond line\n';
        final tabs = TabsRecorder();
        final vault = seedSegmentedVault(topicBody: body);
        vault.db.seedTopicNote(_wi84KnownId, 'Known');
        final opener = RecordingUrlOpener();
        final h = await pumpWorkspace(
          tester,
          db: vault.db,
          cli: vault.cli,
          overrides: [
            urlOpenerProvider.overrideWithValue(opener),
            tabs.override,
          ],
        );
        final r = SegmentedEditorRobot(tester, h);
        await r.open(fixtureTopicId);
        await pumpFrames(tester);
        tabs.followed.clear();
        tabs.navigated.clear();

        final segmentText = r.segmentText(0);
        final token = _wi84Range(segmentText, '[[Known]]');
        final known = _wi84Range(segmentText, 'Known');
        final handle = segmentEditingAt(tester, 0);
        final regions = tester
            .widgetList<LinkRegion>(
              find.descendant(
                of: find.byKey(textSegmentKey(0)),
                matching: find.byType(LinkRegion),
              ),
            )
            .toList();
        expect(regions, hasLength(handle.rowCount));
        final controller =
            regions[segmentRowHolding(handle, token.start)].controller;
        // The link's row starts the segment: row and segment offsets agree.
        final local = _wi84Range(controller.text, '[[Known]]');
        expect(local, token, reason: 'the first row starts at offset 0');

        final n = ValueNotifier<FindDecoration?>(null);
        addTearDown(n.dispose);
        controller.findDecoration = n;
        n.value = FindDecoration(
          revealRange: local,
          inkRanges: [local],
          current: local,
        );
        await pumpFrames(tester);

        // The click point comes from the revealed layout.
        final seg = r.segment(0);
        final a = seg.rectForOffset(known.start);
        final z = seg.rectForOffset(known.end);
        expect(z.left, greaterThan(a.left), reason: '"Known" has a width');
        expect(a.center.dy, closeTo(z.center.dy, 0.5), reason: 'one line');
        await tester.tapAt(
          Offset((a.left + z.left) / 2, a.center.dy),
          kind: PointerDeviceKind.mouse,
        );
        await pumpFrames(tester);

        expect(tabs.followed, isEmpty, reason: 'the link did not follow');
        expect(tabs.navigated, isEmpty);
        r.expectActiveNote(fixtureTopicId);
        expect(opener.opened, isEmpty);
        expect(r.segmentHasFocus(0), isTrue, reason: 'the click focused it');
        final sel = r.segmentSelection(0);
        expect(sel.isCollapsed, isTrue, reason: 'a caret');
        expect(
          sel.baseOffset,
          inInclusiveRange(known.start, known.end),
          reason: 'the caret is where the click landed, in the link text',
        );
        await _wi84Settle(tester, h);
      },
      variant: macOnly,
    );
  });
}

/// Lets queued tab persistence finish before the harness deletes the temp
/// vault (as live_preview_links_test.dart `_Links.settle` does).
Future<void> _wi84Settle(WidgetTester tester, WorkspaceHarness h) async {
  await pumpFrames(tester);
  final store = h.read(tabsProvider.notifier).store;
  var flushed = false;
  unawaited(store.flush().then((_) => flushed = true));
  for (var i = 0; i < 5000 && !flushed; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump();
  }
  expect(flushed, isTrue, reason: 'tab persistence finished');
}
