// WI #439 (Spec #392 Testing Strategy: Journey test; req 3, 13, 13b, 15, 18,
// 25): the spelling journey on today's daily note, end to end through the
// real learned-words path.
//
// 1. Typing a misspelled word shows its squiggle once the 400 ms debounce
//    has passed, and not before.
// 2. Right click, then `Learn Spelling`: one `memex words add`, one
//    `learn` on the fake macOS dictionary, one `vaultRevisionProvider` bump,
//    and the squiggle goes.
// 3. Reopening the vault with the fake macOS dictionary reset: the checker
//    flags the word again, and the vault's learned words filter it out.
//
// Seams: the workspace (`pumpWorkspace`) on a FakeVaultDb at V7 with the real
// `LocalWordsAccess`, a FakeMemexCli whose `words add` writes the
// `learned_words` row into that FakeVaultDb (D22: registered here, never in
// fake_memex_cli.dart), the real learned-words state, a FakeSpellingService
// and the FakeClock. Each step's test runs the steps before it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/spelling_service.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../robots/segmented_editor_robot.dart';
import '../robots/spelling_robot.dart';
import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_spelling_service.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/today_cli_fakes.dart';

/// Today's daily note (the FakeClock's date, 2026-10-03), empty.
const _wi439DailyId = 'daily-2026-10-03';

/// The misspelled word the person types, and the sentence holding it.
const _wi439Word = 'wibblex';
const _wi439Typed = 'Met $_wi439Word today.';

/// What the journey reads after each step.
class _Wi439Journey {
  _Wi439Journey(this.tester, this.h, this.robot, this.spelling);

  final WidgetTester tester;
  final WorkspaceHarness h;
  final SegmentedEditorRobot robot;
  final FakeSpellingService spelling;

  /// `vaultRevisionProvider` changes since the journey started.
  int revisionBumps = 0;

  List<String> get learnedRows => [
    for (final r in h.db.db.select(
      'SELECT word FROM learned_words ORDER BY word_key',
    ))
      r['word'] as String,
  ];

  List<FakeCliCall> get wordsAdds => h.cli.callsFor('words add');

  /// Moves the FakeClock and the binding's time by [d], then pumps.
  Future<void> advance(Duration d) async {
    h.clock.advance(d);
    await tester.pump(d);
    await pumpFrames(tester);
  }

  /// Whether the typed word shows its squiggle: published as a spelling
  /// issue of its row, and named by the row's semantics hint.
  bool get squiggled {
    final flagged = robot.misspelledIn(_wi439Word).contains(_wi439Word);
    final hinted = robot
        .spellingHints(_wi439Word)
        .any((h) => h.contains('misspelled') && h.contains(_wi439Word));
    expect(
      hinted,
      flagged,
      reason: 'the row hint and the published issue agree',
    );
    return flagged;
  }
}

/// Pumps the workspace on today's empty daily note and opens it.
Future<_Wi439Journey> _wi439Launch(WidgetTester tester) async {
  final db = FakeVaultDb.v5()
    ..seedNote(
      id: _wi439DailyId,
      title: '2026-10-03',
      role: 'daily',
      version: 1,
    );
  expect(
    db.hasTables(const ['learned_words']),
    isTrue,
    reason: 'the fixture vault is at V7',
  );
  final cli = FakeMemexCli()
    ..onUpdateWrites(db)
    ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
    ..on('words add', (call) {
      final word = call.flag('word')!;
      final changed = db.db.select(
        'SELECT 1 FROM learned_words WHERE word_key = ?',
        [word.toLowerCase()],
      ).isEmpty;
      db.db.execute(
        'INSERT INTO learned_words (word_key, word, created_at) '
        'VALUES (?, ?, 1759500000000) ON CONFLICT(word_key) DO NOTHING',
        [word.toLowerCase(), word],
      );
      return FakeMemexCli.ok(
        '{"vault_id":"01HV0000000000000000000000","word":"$word",'
        '"changed":$changed}\n',
      );
    });
  final spelling = FakeSpellingService()
    ..misspell(_wi439Word, corrections: const ['wobble']);
  final h = await pumpWorkspace(
    tester,
    db: db,
    cli: cli,
    overrides: [spellingServiceProvider.overrideWithValue(spelling)],
  );
  final robot = SegmentedEditorRobot(tester, h);
  await robot.open(_wi439DailyId);
  robot.expectActiveNote(_wi439DailyId);
  final j = _Wi439Journey(tester, h, robot, spelling);
  h.container.listen<int>(vaultRevisionProvider, (_, _) => j.revisionBumps++);
  return j;
}

/// Step 1: types [_wi439Typed] into the daily note and passes the debounce.
/// Expects no squiggle 1 ms before it ends and one once it has.
Future<void> _wi439TypeMisspelling(_Wi439Journey j) async {
  await j.robot.focusSegment(0);
  await j.robot.typeChars(_wi439Typed);
  expect(j.robot.segmentText(0), _wi439Typed);

  await j.advance(const Duration(milliseconds: 399));
  expect(j.squiggled, isFalse, reason: '1 ms before the debounce ends');

  await j.advance(const Duration(milliseconds: 1));
  expect(j.squiggled, isTrue, reason: 'once the 400 ms debounce has passed');
  final checked = [
    for (final c in j.spelling.callsFor('check')) c.args['text']! as String,
  ];
  expect(
    checked.where((t) => t.contains(_wi439Word)),
    hasLength(1),
    reason: 'one check of the typed paragraph',
  );
}

/// Step 2: lets the autosave land, then right-clicks the word and chooses
/// Learn Spelling. Expects one `words add`, one `learn`, one revision bump
/// and the squiggle gone.
Future<void> _wi439Learn(_Wi439Journey j) async {
  await j.robot.waitForSave();
  expect(j.robot.updates, isNotEmpty, reason: 'the typed text was saved');
  expect(j.squiggled, isTrue, reason: 'the save keeps the squiggle');
  final bumpsBefore = j.revisionBumps;
  final addsBefore = j.wordsAdds.length;
  final learnsBefore = j.spelling.count('learn');

  await j.robot.rightClickWord(_wi439Word, _wi439Word);
  expect(j.robot.spellingMenu, findsOneWidget, reason: 'SpellingMenu opened');
  await j.robot.chooseSpellingItem('Learn Spelling');

  expect(j.wordsAdds.length - addsBefore, 1, reason: 'one memex words add');
  final add = j.wordsAdds.last;
  expect(add.flag('word'), _wi439Word);
  expect(add.flag('vault'), j.h.vaultPath);
  expect(j.learnedRows, [_wi439Word], reason: 'the vault holds the word');
  expect(j.spelling.count('learn') - learnsBefore, 1, reason: 'one learn');
  expect(j.spelling.callsFor('learn').last.args['word'], _wi439Word);
  expect(
    j.revisionBumps - bumpsBefore,
    1,
    reason: 'one vaultRevisionProvider bump',
  );
  expect(j.robot.spellingMenu, findsNothing, reason: 'the menu closed');
  expect(j.squiggled, isFalse, reason: 'the squiggle is gone');
  expect(j.robot.inlineError, findsNothing, reason: 'no learn error');
}

void main() {
  holdFontFetches();

  testWidgets(
    'spelling journey a misspelled word typed in a daily note shows its squiggle after the 400 ms debounce',
    (tester) async {
      final j = await _wi439Launch(tester);
      await _wi439TypeMisspelling(j);
      expect(tester.takeException(), isNull);
    },
    variant: macOnly,
  );

  testWidgets(
    'spelling journey Learn Spelling calls memex words add once and learn once bumps the vault revision once and removes the squiggle',
    (tester) async {
      final j = await _wi439Launch(tester);
      await _wi439TypeMisspelling(j);
      await _wi439Learn(j);
      expect(tester.takeException(), isNull);
    },
    variant: macOnly,
  );

  testWidgets(
    'spelling journey after reopening the vault with the macOS dictionary reset the learned word is not flagged',
    (tester) async {
      final j = await _wi439Launch(tester);
      await _wi439TypeMisspelling(j);
      await _wi439Learn(j);

      // This Mac's dictionary never saw the word: only the vault knows it.
      j.spelling.resetDictionary();
      expect(j.spelling.learned, isEmpty);
      final checksBefore = j.spelling.count('check');

      final vault = j.h.read(currentVaultProvider);
      j.h.container.read(currentVaultProvider.notifier).state = null;
      await pumpFrames(tester);
      j.h.container.read(currentVaultProvider.notifier).state = vault;
      await pumpFrames(tester);
      await j.robot.open(_wi439DailyId);
      j.robot.expectActiveNote(_wi439DailyId);
      await j.advance(const Duration(seconds: 1));
      await j.advance(const Duration(seconds: 1));

      expect(j.robot.segmentText(0), _wi439Typed, reason: 'the saved text');
      final rechecks = [
        for (final c in j.spelling.callsFor('check').skip(checksBefore)) c,
      ].where((c) => (c.args['text']! as String).contains(_wi439Word));
      expect(rechecks, isNotEmpty, reason: 'the reopened note was checked');
      final reply = j.spelling.issuesFor(
        rechecks.last.args['text']! as String,
        documentTag: rechecks.last.args['documentTag']! as int,
      );
      expect(
        reply,
        isNotEmpty,
        reason: 'the reset dictionary flags the word again',
      );
      expect(
        j.squiggled,
        isFalse,
        reason: 'the vault learned words filter it out',
      );
      expect(j.learnedRows, [_wi439Word]);
      expect(tester.takeException(), isNull);
    },
    variant: macOnly,
  );

  group('glossary', () {
    test(
      'GLOSSARY.md has a Spelling section right before Markdown tables with the Learned word entry and its Avoid line',
      () {
        final glossary = File('../GLOSSARY.md').readAsStringSync();
        expect('## Spelling (#392)'.allMatches(glossary), hasLength(1));
        final headers = [
          for (final m in RegExp(
            r'^## .*$',
            multiLine: true,
          ).allMatches(glossary))
            m.group(0)!,
        ];
        final tables = headers.indexOf('## Markdown tables (#192)');
        expect(tables, greaterThan(0), reason: 'the D25 anchor exists');
        expect(
          headers[tables - 1],
          '## Spelling (#392)',
          reason: 'Spelling comes right before Markdown tables (D25)',
        );
        final start = glossary.indexOf('## Spelling (#392)');
        final end = glossary.indexOf('## Markdown tables (#192)');
        final section = glossary.substring(start, end);
        final entry = RegExp(
          r'^\*\*Learned word\*\*:\s*\n(.+)\n(_Avoid_?:_?.*)$',
          multiLine: true,
        ).firstMatch(section);
        expect(entry, isNotNull, reason: 'a Learned word entry');
        final definition = entry!.group(1)!;
        expect(definition, contains('`Learn Spelling`'));
        expect(definition, contains("vault's learned words"));
        expect(definition, contains('never flagged as misspelled'));
        final avoid = entry.group(2)!;
        expect(avoid, contains('dictionary word'));
        expect(avoid, contains('custom word'));
      },
    );
  });
}
