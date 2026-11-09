// WI #253 (A5): a note with a Note footer on a V6 FakeVaultDb, a `memex tag rm`
// that acts on it as the server does, finders and state reads for the rail and
// the footer, and a bare pump for narrow-width and text-scale tests.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderAnimatedOpacity, RenderOpacity;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/sidebar_mode_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/tags_browse_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/editor/note_header.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';

import '../robots/segmented_editor_robot.dart';
import 'app_harness.dart';
import 'daily_seed.dart';
import 'fake_clock.dart';
import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';
import 'tags_seed.dart';
import 'today_cli_fakes.dart';

/// The note the footer tests open.
const footerNoteId = 'note-plan';

/// A second note, for what must not leak from one note to the next.
const otherNoteId = 'note-other';

/// Footer topics the seeds can chip.
const pricingTopicId = 'topic-pricing';
const memexTopicId = 'topic-memex';

const footerPerson = 'Annual plan draft\n';

/// [person], the marker, one chip line per title and one `#name` line per tag,
/// as the server renders a Note footer (R11).
String footerBody(
  String person, {
  List<String> chips = const [],
  List<String> tags = const [],
}) {
  final out = StringBuffer(person)..write('$topicsMarker\n');
  for (final chip in chips) {
    out.write('[[$chip~about]]\n');
  }
  for (final tag in tags) {
    out.write('#$tag\n');
  }
  return out.toString();
}

typedef FooterVault = ({FakeVaultDb db, FakeMemexCli cli});

/// A vault holding note [footerNoteId] (title `Plan`, version 4, [role]) with
/// [body], [footerTags] as agent rows, [bodyTags] as body rows, [systemTags]
/// as agent rows and a footer chip per entry of [chips] (topic id, title). The
/// CLI answers `settings get`, `update` and `tag rm` against the vault.
///
/// Row content and footer text are independent, as after a backfill (L10).
FooterVault seedFooterVault({
  String body = footerPerson,
  String role = 'topic',
  List<String> footerTags = const [],
  List<String> bodyTags = const [],
  List<String> systemTags = const [],
  Map<String, String> chips = const {},
}) {
  final db = FakeVaultDb.v6();
  seedFooterNote(
    db,
    id: footerNoteId,
    title: 'Plan',
    body: body,
    role: role,
    footerTags: footerTags,
    bodyTags: bodyTags,
    systemTags: systemTags,
    chips: chips,
  );
  final cli = FakeMemexCli()
    ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
    ..onUpdateWrites(db)
    ..on('tag rm', (call) => applyTagRm(db, call));
  return (db: db, cli: cli);
}

/// Adds a note with its tag rows and chips to [db]; chip targets that don't
/// exist yet are created as topic notes.
void seedFooterNote(
  FakeVaultDb db, {
  required String id,
  required String title,
  String body = footerPerson,
  String role = 'topic',
  List<String> footerTags = const [],
  List<String> bodyTags = const [],
  List<String> systemTags = const [],
  Map<String, String> chips = const {},
}) {
  db.seedNote(id: id, title: title, role: role, content: body, version: 4);
  for (final tag in footerTags) {
    db.seedTag(id, tag, origin: 'agent');
  }
  for (final tag in bodyTags) {
    db.seedTag(id, tag, origin: 'body', firstLine: '$title #$tag');
  }
  for (final tag in systemTags) {
    db.seedTag(id, tag, origin: 'agent');
  }
  chips.forEach((topicId, topicTitle) {
    final exists = db.db.select('SELECT id FROM notes WHERE id = ?', [topicId]);
    if (exists.isEmpty) db.seedTopicNote(topicId, topicTitle);
    db.seedFooterChip(id, topicId);
  });
}

/// `{note_id, tag, removed, correction_id, version}`, the `memex tag rm` shape.
String tagRmJson(String id, String tag, int version, {bool removed = true}) =>
    '${jsonEncode({'note_id': id, 'tag': tag, 'removed': removed, 'correction_id': null, 'version': version})}\n';

/// What `memex tag rm` does: drops the row, re-renders the footer text (the
/// `#tag` line goes, and on a non-daily note the marker goes with the last
/// footer line, R11) and moves the version. A tag already gone changes nothing
/// and answers `removed: false`.
MemexResult applyTagRm(FakeVaultDb db, FakeCliCall call) {
  final id = call.flag('note-id')!;
  final tag = call.flag('tag')!;
  final note = db.getNote(id)!;
  final held = db.db.select(
    'SELECT tag FROM tags WHERE note_id = ? AND tag = ?',
    [id, tag],
  );
  if (held.isEmpty) {
    return FakeMemexCli.ok(tagRmJson(id, tag, note.version, removed: false));
  }
  db.db.execute('DELETE FROM tags WHERE note_id = ? AND tag = ?', [id, tag]);
  db.db.execute(
    'UPDATE notes SET content_md = ?, version = version + 1 WHERE id = ?',
    [_withoutFooterTag(note.contentMd, tag, daily: note.role == 'daily'), id],
  );
  return FakeMemexCli.ok(tagRmJson(id, tag, note.version + 1));
}

String _withoutFooterTag(String body, String tag, {required bool daily}) {
  final at = body.indexOf('$topicsMarker\n');
  if (at < 0) return body;
  final person = body.substring(0, at);
  final below = body
      .substring(at + topicsMarker.length + 1)
      .split('\n')
      .where((l) => l.isNotEmpty && l != '#$tag')
      .toList();
  if (below.isEmpty && !daily) return person;
  return '$person$topicsMarker\n${below.map((l) => '$l\n').join()}';
}

/// Pumps the workspace on [vault] with [noteId] open.
Future<SegmentedEditorRobot> launchFooterNote(
  WidgetTester tester,
  FooterVault vault, {
  String noteId = footerNoteId,
  List<Override> overrides = const [],
}) async {
  final h = await pumpWorkspace(
    tester,
    db: vault.db,
    cli: vault.cli,
    overrides: overrides,
  );
  final r = SegmentedEditorRobot(tester, h);
  await r.open(noteId);
  return r;
}

// ------------------------------------------------------------------- finders

Finder get footerRow => find.byKey(const Key('footer-chip-row'));
Finder footerTag(String tag) => find.byKey(Key('footer-tag-$tag'));
Finder footerRemove(String tag) => find.byKey(Key('footer-tag-remove-$tag'));
Finder footerChip(String topicId) => find.byKey(Key('footer-chip-$topicId'));
Finder get noteHeader => find.byKey(const Key('note-header'));

/// An eyebrow label of the footer, as drawn (`TOPICS`, `TAGS`).
Finder footerLabel(String label) =>
    find.descendant(of: footerRow, matching: find.text(label));

/// The border colour of the footer pill at [item] (a topic or tag key).
Color footerPillBorder(WidgetTester tester, Finder item) {
  final box = tester.widget<Container>(
    find.descendant(of: item, matching: find.byType(Container)).first,
  );
  final border = (box.decoration! as BoxDecoration).border! as Border;
  return border.top.color;
}

/// The `#tag` text inside its footer item.
Finder footerTagName(String tag) =>
    find.descendant(of: footerTag(tag), matching: find.text('#$tag'));

Finder footerSpinner(String tag) => find.descendant(
  of: footerTag(tag),
  matching: find.byIcon(LucideIcons.loader2),
);

Finder get footerError => find.descendant(
  of: footerRow,
  matching: find.byKey(const Key('inline-error')),
);

// --------------------------------------------------------------- state reads

/// The style [text] paints with: its `style` over the `DefaultTextStyle` above
/// it, so `AnimatedDefaultTextStyle` and a plain `style:` read the same.
TextStyle effectiveStyle(WidgetTester tester, Finder text) {
  final element = text.evaluate().single;
  return DefaultTextStyle.of(
    element,
  ).style.merge((element.widget as Text).style);
}

Color? colorOf(WidgetTester tester, Finder text) =>
    effectiveStyle(tester, text).color;

/// Whether the × glyph of [tag] is painted, however it is hidden at rest:
/// absent from the tree, offstage, `Visibility`, an `Opacity` or a colour with
/// no alpha. The hit box stays in the tree either way.
bool footerXShown(WidgetTester tester, String tag) {
  final glyph = find.descendant(
    of: footerTag(tag),
    matching: find.byIcon(LucideIcons.x),
  );
  if (glyph.evaluate().isEmpty) return false;
  final element = glyph.evaluate().single;
  if (!Visibility.of(element)) return false;
  if ((element.widget as Icon).color?.a == 0) return false;
  RenderObject? box = element.renderObject;
  while (box != null) {
    if (box is RenderOpacity && box.opacity == 0) return false;
    if (box is RenderAnimatedOpacity && box.opacity.value == 0) return false;
    box = box.parent;
  }
  return true;
}

/// A mouse pointer, removed when the test ends.
Future<TestGesture> addMouse(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(1, 1));
  addTearDown(mouse.removePointer);
  await tester.pump();
  return mouse;
}

Future<void> hover(WidgetTester tester, TestGesture mouse, Finder what) async {
  await mouse.moveTo(tester.getCenter(what));
  await pumpFrames(tester);
}

/// Hovers [tag] and clicks its ×, without waiting for the write's frames.
Future<void> clickX(WidgetTester tester, TestGesture mouse, String tag) async {
  await hover(tester, mouse, footerRemove(tag));
  await mouse.down(tester.getCenter(footerRemove(tag)));
  await mouse.up();
  await tester.pump();
}

/// Whether keyboard focus sits on [tag]'s ×.
bool xHasFocus(WidgetTester tester, String tag) {
  final rect = FocusManager.instance.primaryFocus?.rect;
  if (rect == null || footerRemove(tag).evaluate().isEmpty) return false;
  return tester.getRect(footerRemove(tag)).contains(rect.center);
}

/// Moves keyboard focus backwards from outside the editor with real Shift+Tab
/// presses until it reaches [tag]'s ×. Tab never leaves the editor body (it
/// indents, Spec #193 TD4), so this is the path a keyboard has. False when no
/// press got there.
Future<bool> shiftTabToX(WidgetTester tester, String tag) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  var reached = false;
  for (var i = 0; i < 80 && !reached; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    reached = xHasFocus(tester, tag);
  }
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await pumpFrames(tester);
  return reached;
}

/// The note editor's scroll position.
ScrollPosition editorScroll(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.ancestor(of: noteHeader, matching: find.byType(Scrollable)).first,
    )
    .position;

/// `revealTag` ran for [tag]: the sidebar is in Tags mode with it expanded.
void expectRevealed(WorkspaceHarness h, String tag) {
  expect(h.read(sidebarModeProvider), SidebarMode.tags);
  expect(h.read(expandedTagProvider), tag);
  expect(find.byKey(Key('tag-row-$tag')), findsOneWidget);
}

/// Nothing called `revealTag`.
void expectNotRevealed(WorkspaceHarness h) {
  expect(h.read(sidebarModeProvider), isNot(SidebarMode.tags));
  expect(h.read(expandedTagProvider), isNull);
}

// ------------------------------------------------------------------ bare pump

/// The note body with its header alone, [width] wide, at [textScale], with the
/// note's tab open. The workspace around it has its own fixed-width panes, so
/// overflow and row geometry are measured here.
Future<void> pumpBareNote(
  WidgetTester tester,
  FakeVaultDb db, {
  required double width,
  required double textScale,
  String noteId = footerNoteId,
}) async {
  final dir = Directory.systemTemp.createTempSync('om253');
  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(FakeMemexCli()),
      clockProvider.overrideWithValue(FakeClock()),
    ],
  );
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // A queued ui_state write raced the delete.
    }
  });
  addTearDown(db.close);
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  container.read(tabsProvider.notifier).openOrFocus(NoteTab(noteId));
  final note = db.getNote(noteId)!;
  final title = TextEditingController(text: note.title);
  addTearDown(title.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 1200,
              child: SegmentedBody(
                note: note,
                content: note.contentMd,
                savedVersion: note.version,
                onContentChanged: (_) {},
                header: NoteHeader(
                  note: note,
                  titleCtrl: title,
                  onTitleChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
}
