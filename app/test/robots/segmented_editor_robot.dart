import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/widgets/editor/segment_editing.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/excerpt_cli_fakes.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/review_fakes.dart';
import '../support/segment_editing_finder.dart';
import '../support/today_cli_fakes.dart';

/// The C4 fixture daily note (`2026-09-05`).
const fixtureDailyId = 'daily-2026-09-05';

/// The topic note the excerpt tests edit.
const fixtureTopicId = 'topic-player-loop';

/// Footer topics of the fixture daily note, in footer (rowid) order. The
/// titles are deliberately not in alphabetical order.
const fixtureZetaId = 'topic-zeta';
const fixtureAlphaId = 'topic-alpha';

/// The fixture daily note's person section (one line per C4 block).
const fixturePerson =
    'Fixed the jump arc.\n- tried coyote time\nSleep was bad.\n';

/// The fixture range token (C4 X2).
const fixtureRangeToken = '![[2026-09-05#^b7k2m9..^c3d4e5]]';

/// The default topic body: text, the X2 card, more text.
const fixtureTopicBody = 'Intro line\n$fixtureRangeToken\nOutro line\n';

/// A V5 vault with:
/// - daily note `2026-09-05` (id [fixtureDailyId], version 2) holding the C4
///   blocks (b7k2m9, c3d4e5, f6g7h8) and footer chips `Zeta Game` then
///   `Alpha Topic` (body = canonical daily body of [fixturePerson]);
/// - topic note `Player Loop` ([fixtureTopicId]) with [topicBody] at
///   [topicVersion];
/// - topic notes `Zeta Game`, `Alpha Topic` and `Other note`.
///
/// The CLI answers `settings get`, `update` (writes stdin, version + 1,
/// `version_conflict` on a stale version) and `excerpt rm` (removes the
/// token line, version = [rmVersion] or + 1).
({FakeVaultDb db, FakeMemexCli cli}) seedSegmentedVault({
  String topicBody = fixtureTopicBody,
  int topicVersion = 4,
  int? rmVersion,
  String? dailyBody,
}) {
  final db = FakeVaultDb.v5();
  db.seedDailyNote('2026-09-05', id: fixtureDailyId, version: 2);
  db.seedTopicNote(fixtureZetaId, 'Zeta Game');
  db.seedTopicNote(fixtureAlphaId, 'Alpha Topic');
  db.seedTopicNote('topic-other', 'Other note');
  db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
    dailyBody ??
        assembleDailyBody(fixturePerson, const ['Zeta Game', 'Alpha Topic']),
    fixtureDailyId,
  ]);
  db.seedBlock(fixtureDailyId, 'b7k2m9', ord: 0, text: 'Fixed the jump arc.');
  db.seedBlock(fixtureDailyId, 'c3d4e5', ord: 1, text: '- tried coyote time');
  db.seedBlock(fixtureDailyId, 'f6g7h8', ord: 2, text: 'Sleep was bad.');
  db.seedFooterChip(fixtureDailyId, fixtureZetaId);
  db.seedFooterChip(fixtureDailyId, fixtureAlphaId, origin: 'person');
  db.seedNote(
    id: fixtureTopicId,
    title: 'Player Loop',
    role: 'topic',
    content: topicBody,
    version: topicVersion,
  );
  final cli = FakeMemexCli()
    ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
    ..onUpdateWrites(db)
    ..onExcerptRmRemoves(db, newVersion: rmVersion);
  return (db: db, cli: cli);
}

/// Pump the workspace on [seedSegmentedVault]'s vault and return a robot.
Future<SegmentedEditorRobot> launchSegmented(
  WidgetTester tester, {
  required ({FakeVaultDb db, FakeMemexCli cli}) vault,
}) async {
  final h = await pumpWorkspace(tester, db: vault.db, cli: vault.cli);
  return SegmentedEditorRobot(tester, h);
}

/// Robot for the segmented note editor (WI #27). Finds widgets by the Spec's
/// TS4 Keys only:
/// - `text-segment-<i>`, `excerpt-card-<i>`, `excerpt-card-remove-<i>`,
///   `excerpt-card-caption-<i>`, where `<i>` is the segment's index in the
///   list #20's `split` returns (body `Intro\n<token>\nOutro\n` gives
///   `text-segment-0`, `excerpt-card-1`, `text-segment-2`);
/// - `footer-chip-<topicNoteId>`, `editor-source-toggle`, `inline-error`,
///   `inline-error-dismiss`;
/// - Source mode: `editor-source-surface` with the body field `editor-body`.
class SegmentedEditorRobot {
  SegmentedEditorRobot(this.tester, this.h);

  final WidgetTester tester;
  final WorkspaceHarness h;

  // ---------------------------------------------------------------- finders

  /// Text segment [i]'s root (Key `text-segment-<i>`). Read and drive the
  /// segment through its handle, [segment]; type into it with
  /// [typeInSegment].
  Finder textSegment(int i) => find.byKey(textSegmentKey(i));
  Finder card(int i) => find.byKey(Key('excerpt-card-$i'));
  Finder cardRemove(int i) => find.byKey(Key('excerpt-card-remove-$i'));
  Finder cardCaption(int i) => find.byKey(Key('excerpt-card-caption-$i'));
  Finder footerChip(String topicNoteId) =>
      find.byKey(Key('footer-chip-$topicNoteId'));
  Finder get sourceToggle => find.byKey(const Key('editor-source-toggle'));
  Finder get sourceSurface => find.byKey(const Key('editor-source-surface'));
  Finder get sourceBody =>
      find.descendant(of: sourceSurface, matching: find.byKey(editorBodyKey));
  Finder get inlineError => find.byKey(const Key('inline-error'));
  Finder get inlineErrorDismiss =>
      find.byKey(const Key('inline-error-dismiss'));
  Finder get popover => find.byKey(const Key('wikilink-popover'));
  Finder get kindChip => find.byKey(const Key('kind-chip'));

  /// Every editable text field inside the note editor (title field
  /// included).
  Finder get editorEditables =>
      editableTextFields(under: find.byType(NoteEditor));

  /// Every excerpt card root (`excerpt-card-<digits>`, not the × or caption).
  Finder get allCards => find.byWidgetPredicate((w) {
    final k = w.key;
    return k is ValueKey<String> &&
        RegExp(r'^excerpt-card-\d+$').hasMatch(k.value);
  });

  /// Every text segment root (`text-segment-<digits>`).
  Finder get allTextSegments => find.byWidgetPredicate((w) {
    final k = w.key;
    return k is ValueKey<String> &&
        RegExp(r'^text-segment-\d+$').hasMatch(k.value);
  });

  /// [text] as one text run under [parent] (a `Text`, `Text.rich` or
  /// `RichText`).
  Finder textIn(Finder parent, String text) => find.descendant(
    of: parent,
    matching: find.text(text, findRichText: true),
  );

  /// A `Text` under [parent] whose text equals [label] ignoring case (chips
  /// may upper-case their label).
  Finder labelIn(Finder parent, String label) => find.descendant(
    of: parent,
    matching: find.byWidgetPredicate(
      (w) => w is Text && w.data?.toLowerCase() == label.toLowerCase(),
    ),
  );

  // ------------------------------------------------------------------ state

  /// Text segment [i]'s [SegmentEditing] handle (re-found on every call).
  SegmentEditing segment(int i) => segmentEditingAt(tester, i);

  /// Every text segment's handle, in segment order.
  List<SegmentEditing> get allSegments => allSegmentEditings(tester);
  String segmentText(int i) => segment(i).text;
  TextSelection segmentSelection(int i) => segment(i).selection;
  bool segmentHasFocus(int i) => segment(i).focusedRow != null;

  /// The Source mode body field's text.
  String get sourceText =>
      renderedEditableTexts(tester, under: sourceBody).single;

  WorkspaceTab? get activeTab => h.read(tabsProvider).activeTab;
  List<FakeCliCall> get updates => h.cli.callsFor('update');
  List<FakeCliCall> get excerptRms => h.cli.callsFor('excerpt rm');

  // ---------------------------------------------------------------- actions

  /// Open [noteId] as the active note tab.
  Future<void> open(String noteId) async {
    await openNoteTab(tester, h, noteId);
    await pumpFrames(tester);
  }

  /// Replace text segment [i]'s text as the person typing would (caret at
  /// the end), without waiting for the save.
  Future<void> typeInSegment(int i, String text) async {
    await tester.enterText(textSegment(i), text);
    await tester.pump();
  }

  /// Focus text segment [i] and put the caret at [offset] (default: end).
  Future<void> focusSegment(int i, {int? offset}) async {
    await tester.showKeyboard(textSegment(i));
    await tester.pump();
    final handle = segment(i);
    handle.select(
      TextSelection.collapsed(offset: offset ?? handle.text.length),
    );
    await tester.pump();
  }

  Future<void> pressKey(LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
  }

  /// Let the 500 ms debounce fire and the fake CLI round trip complete: the
  /// debounce runs on the [FakeClock] (D14, WI #28), so both it and the
  /// test binding's time move 600 ms.
  Future<void> waitForSave() async {
    h.clock.advance(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await pumpFrames(tester);
  }

  Future<void> tapRemove(int i) async {
    await tester.tap(cardRemove(i));
    await pumpFrames(tester);
  }

  Future<void> tapCaption(int i) async {
    await tester.tap(cardCaption(i));
    await pumpFrames(tester);
  }

  Future<void> tapFooterChip(String topicNoteId) async {
    await tester.tap(footerChip(topicNoteId));
    await pumpFrames(tester);
  }

  Future<void> toggleSource() async {
    await tester.tap(sourceToggle);
    await pumpFrames(tester);
  }

  // ------------------------------------------------------------- assertions

  /// The active tab is the note tab for [noteId].
  void expectActiveNote(String noteId) {
    final active = activeTab;
    expect(active, isA<NoteTab>());
    expect(active!.id, noteId);
  }

  /// Top edge of [finder] (for vertical order checks).
  double top(Finder finder) => tester.getTopLeft(finder).dy;
}
