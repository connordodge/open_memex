// WI #434 (Spec #392): the shared spelling editor pump. Every #392 editor WI
// (E3 scheduler, E4 squiggles, E5 SpellingMenu, E6 journey) pumps a note
// body through [pumpSpellingEditor]. Callers call `holdFontFetches()` at the
// top of `main()`.
//
// It runs the whole workspace (app_harness `pumpWorkspace`) on
// `seedSegmentedVault`, with the topic note `Player Loop` holding [body],
// opened as the active tab, in live preview or (with `source: true`) in
// Source mode. Seams: `spellingServiceProvider` (a [FakeSpellingService]),
// `learnedWordKeysProvider`, `learnedWordsActionsProvider` (only when
// `actions` is given) and `clockProvider` (a [FakeClock]).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/learned_words_seam.dart';
import 'package:open_memex_app/src/state/spelling_service.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../robots/segmented_editor_robot.dart';
import 'app_harness.dart';
import 'fake_clock.dart';
import 'fake_spelling_service.dart';

/// The id of the note [pumpSpellingEditor] opens.
const spellingNoteId = fixtureTopicId;

/// What [pumpSpellingEditor] pumped.
class SpellingEditorHarness {
  SpellingEditorHarness({
    required this.tester,
    required this.robot,
    required this.spelling,
  });

  final WidgetTester tester;

  /// The segmented editor robot over the same workspace (typing, focus,
  /// Source toggle, save).
  final SegmentedEditorRobot robot;

  final FakeSpellingService spelling;

  FakeClock get clock => robot.h.clock;
  WorkspaceHarness get workspace => robot.h;
  ProviderContainer get container => robot.h.container;

  // -------------------------------------------------------------- finders

  /// The note editor.
  Finder get editor => find.byType(NoteEditor);

  /// Live preview text segment [i]'s root (Key `text-segment-<i>`).
  Finder textSegment(int i) => robot.textSegment(i);

  /// Source mode's surface (Key `editor-source-surface`).
  Finder get sourceSurface => robot.sourceSurface;

  /// Source mode's body field (an [EditableText]).
  Finder get sourceField => find.descendant(
    of: robot.sourceBody,
    matching: find.byType(EditableText),
  );

  /// Every row field of live preview text segment [i], in row order.
  Finder rowFields(int i) =>
      find.descendant(of: textSegment(i), matching: find.byType(EditableText));

  /// The body text the note editor holds: Source mode's field, or the live
  /// preview's text segments joined (cards excluded).
  String get bodyText => robot.sourceSurface.evaluate().isNotEmpty
      ? robot.sourceText
      : robot.allSegments.map((s) => s.text).join();

  // -------------------------------------------------------------- actions

  /// Types [text] at the end of the body: into Source mode's field, or at
  /// the end of live preview text segment [segment].
  Future<void> typeAtEnd(String text, {int segment = 0}) async {
    if (robot.sourceSurface.evaluate().isNotEmpty) {
      final field = tester.widget<EditableText>(sourceField);
      await tester.enterText(sourceField, field.controller.text + text);
      await tester.pump();
      return;
    }
    await robot.typeInSegment(segment, robot.segmentText(segment) + text);
    await tester.pump();
  }

  Future<void> toggleSource() => robot.toggleSource();

  /// Moves the fake clock and the test binding's time by [d], then pumps.
  Future<void> advance(Duration d) async {
    clock.advance(d);
    await tester.pump(d);
    await pumpFrames(tester);
  }
}

/// Pumps the note editor on [body] (a topic note) in live preview, or in
/// Source mode when [source] is true. [spelling] defaults to a fresh
/// [FakeSpellingService]; [learnedKeys] is `learnedWordKeysProvider`;
/// [actions], when given, is `learnedWordsActionsProvider`; [clock]
/// defaults to a fresh [FakeClock]. [overrides] are appended and must not
/// repeat a provider this pump overrides.
Future<SpellingEditorHarness> pumpSpellingEditor(
  WidgetTester tester, {
  required String body,
  bool source = false,
  FakeSpellingService? spelling,
  Set<String> learnedKeys = const {},
  LearnedWordsActions? actions,
  FakeClock? clock,
  List<Override> overrides = const [],
}) async {
  final fake = spelling ?? FakeSpellingService();
  final vault = seedSegmentedVault(topicBody: body);
  final h = await pumpWorkspace(
    tester,
    db: vault.db,
    cli: vault.cli,
    clock: clock,
    overrides: [
      spellingServiceProvider.overrideWithValue(fake),
      learnedWordKeysProvider.overrideWithValue(learnedKeys),
      if (actions != null)
        learnedWordsActionsProvider.overrideWithValue(actions),
      ...overrides,
    ],
  );
  final robot = SegmentedEditorRobot(tester, h);
  await robot.open(spellingNoteId);
  if (source) await robot.toggleSource();
  return SpellingEditorHarness(tester: tester, robot: robot, spelling: fake);
}
