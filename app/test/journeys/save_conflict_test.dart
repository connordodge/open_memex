// WI #28 (A10): conflict merge on save (Req 60). A `version_conflict` from
// `memex update` refetches the note, rebuilds the body with #20's
// mergeConflict (local person text, then unseen agent / quick-entry blocks,
// then the server footer) and retries once with the refetched version. A
// second conflict keeps the local text, shows `Couldn't save` and merges
// again on the next debounce tick.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/conflict_merge.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';

import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/poll_fakes.dart';

const _person = 'Morning pages\n';
const _typed = '${_person}Then lunch with Sam.\n';
const _agentText = 'Agent saw the jump arc bug.';

Future<LiveRobot> _launch(
  WidgetTester tester, {
  List<SeedBlock> blocks = const [SeedBlock('p-morning', 'Morning pages')],
  BeforeUpdate? before,
}) async {
  final db = FakeVaultDb.v5()..seedLiveDaily(blocks: blocks);
  final clock = FakeClock(DateTime(2026, 10, 3, 9));
  final cli = FakeMemexCli()..onUpdateServer(db, clock: clock, before: before);
  return pumpLiveWorkspace(tester, db: db, cli: cli, clock: clock);
}

/// The inline error under Key `inline-error` shows [text].
Finder _inlineErrorText(LiveRobot r, String text) =>
    find.descendant(of: r.inlineError, matching: find.textContaining(text));

void main() {
  group('one conflict: merge and retry (AC7)', () {
    testWidgets(
      'a version_conflict refetches the note and saves local text then the unseen agent block then the server footer with the refetched version',
      (tester) async {
        final r = await _launch(tester);
        await r.type(_typed);
        // The agent appends and a footer chip lands before the debounce
        // fires (no poll in between: the clock is still under 2 s).
        r.db.serverAppend(
          liveDailyId,
          _agentText,
          blockId: 'a-jump',
          at: DateTime(2026, 10, 3, 9, 0, 0, 100),
        );
        final serverVersion = r.db.serverAddFooterChip(
          liveDailyId,
          liveAlphaId,
          liveAlphaTitle,
          at: DateTime(2026, 10, 3, 9, 0, 0, 200),
        );
        expect(serverVersion, 5);

        await r.fireDebounce();

        final merged = assembleDailyBody(
          appendToPerson(_typed, _agentText),
          const [liveZetaTitle, liveAlphaTitle],
        );
        expect(r.updates, hasLength(2));
        expect(r.updates[0].flag('expected-version'), '3');
        expect(r.updates[1].flag('expected-version'), '$serverVersion');
        expect(r.updates[1].stdinBody, merged);
        expect(r.db.liveNote(liveDailyId).content, merged);
        expect(r.db.liveNote(liveDailyId).version, serverVersion + 1);
        expect(r.editor.status, SaveStatus.clean);
        expect(r.saveIndicatorShows('saved'), isTrue);
        expect(r.inlineError, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'after the merged save the editor shows the merged person text and the next edit saves against the new version',
      (tester) async {
        final r = await _launch(tester);
        await r.type(_typed);
        r.db.serverAppend(
          liveDailyId,
          _agentText,
          blockId: 'a-jump',
          at: DateTime(2026, 10, 3, 9, 0, 0, 100),
        );
        await r.fireDebounce();
        expect(r.updates, hasLength(2));
        final mergedPerson = appendToPerson(_typed, _agentText);
        expect(r.bodyText, mergedPerson);
        expect(r.editor.lastSavedVersion, 5);

        await r.type('${mergedPerson}Evening run.\n');
        await r.fireDebounce();

        expect(r.updates, hasLength(3));
        expect(r.updates[2].flag('expected-version'), '5');
        expect(
          r.updates[2].stdinBody,
          assembleDailyBody('${mergedPerson}Evening run.\n', const [
            liveZetaTitle,
          ]),
        );
      },
    );

    testWidgets(
      'an agent block the person already deleted locally is not re-appended when a newer quick-entry write causes the conflict',
      (tester) async {
        // Base version 3 already holds the agent block (created at v2); the
        // person deletes it locally while a quick entry lands at v4.
        final r = await _launch(
          tester,
          blocks: const [
            SeedBlock('p-morning', 'Morning pages'),
            SeedBlock(
              'a-old',
              'Old agent capture.',
              source: 'agent',
              createdVersion: 2,
            ),
          ],
        );
        expect(r.bodyText, contains('Old agent capture.'));
        await r.type(_typed);
        r.db.serverAppend(
          liveDailyId,
          'Buy milk.',
          blockId: 'q-milk',
          source: 'quick-entry',
          at: DateTime(2026, 10, 3, 9, 0, 0, 100),
        );

        await r.fireDebounce();

        expect(r.updates, hasLength(2));
        expect(r.updates[1].flag('expected-version'), '4');
        expect(
          r.updates[1].stdinBody,
          assembleDailyBody(appendToPerson(_typed, 'Buy milk.'), const [
            liveZetaTitle,
          ]),
        );
        expect(r.updates[1].stdinBody, isNot(contains('Old agent capture.')));
      },
    );

    testWidgets(
      'a poll that sees an agent append while the editor is dirty keeps the typed text and caret and the next save merges',
      (tester) async {
        final r = await _launch(tester);
        await r.advance(const Duration(milliseconds: 1800));
        await r.type(_typed);
        final caret = r.bodySelection;
        r.db.serverAppend(
          liveDailyId,
          _agentText,
          blockId: 'a-jump',
          at: DateTime(2026, 10, 3, 9, 0, 1, 900),
        );

        // The poll at 2 s sees the foreign change; the debounce (due at
        // 2.3 s) has not fired yet.
        await r.advance(const Duration(milliseconds: 200));
        expect(r.bodyText, _typed);
        expect(r.bodySelection, caret);
        expect(r.updates, isEmpty);

        await r.fireDebounce();

        expect(r.updates, hasLength(2));
        expect(r.updates[1].flag('expected-version'), '4');
        expect(
          r.updates[1].stdinBody,
          assembleDailyBody(appendToPerson(_typed, _agentText), const [
            liveZetaTitle,
          ]),
        );
        expect(r.editor.status, SaveStatus.clean);
        expect(r.bodyText, appendToPerson(_typed, _agentText));
      },
    );
  });

  group('retry also conflicts (AC8)', () {
    testWidgets(
      'when the retry also returns version_conflict the editor keeps the local text and shows the inline Couldnt save error',
      (tester) async {
        // A second agent append races the retry.
        late LiveRobot r;
        r = await _launch(
          tester,
          before: (call, _) {
            if (call == 2) {
              r.db.serverAppend(
                liveDailyId,
                'Second capture.',
                blockId: 'a-second',
                at: DateTime(2026, 10, 3, 9, 0, 0, 600),
              );
            }
          },
        );
        await r.type(_typed);
        r.db.serverAppend(
          liveDailyId,
          _agentText,
          blockId: 'a-jump',
          at: DateTime(2026, 10, 3, 9, 0, 0, 100),
        );

        await r.fireDebounce();

        expect(r.updates, hasLength(2), reason: 'one save and one retry');
        expect(r.updates[1].flag('expected-version'), '4');
        expect(r.bodyText, _typed);
        expect(r.inlineError, findsOneWidget);
        expect(_inlineErrorText(r, "Couldn't save"), findsOneWidget);
        expect(r.db.liveNote(liveDailyId).version, 5);
      },
    );

    testWidgets(
      'after a double conflict the next debounce tick merges again and saves with the refetched version',
      (tester) async {
        late LiveRobot r;
        r = await _launch(
          tester,
          before: (call, _) {
            if (call == 2) {
              r.db.serverAppend(
                liveDailyId,
                'Second capture.',
                blockId: 'a-second',
                at: DateTime(2026, 10, 3, 9, 0, 0, 600),
              );
            }
          },
        );
        await r.type(_typed);
        r.db.serverAppend(
          liveDailyId,
          _agentText,
          blockId: 'a-jump',
          at: DateTime(2026, 10, 3, 9, 0, 0, 100),
        );
        await r.fireDebounce();
        expect(r.updates, hasLength(2));

        // No new keystroke: the next debounce tick repeats the merge.
        await r.fireDebounce();

        final mergedPerson = appendToPerson(
          appendToPerson(_typed, _agentText),
          'Second capture.',
        );
        expect(r.updates, hasLength(3));
        expect(r.updates[2].flag('expected-version'), '5');
        expect(
          r.updates[2].stdinBody,
          assembleDailyBody(mergedPerson, const [liveZetaTitle]),
        );
        expect(r.db.liveNote(liveDailyId).version, 6);
        expect(r.editor.status, SaveStatus.clean);
        expect(r.saveIndicatorShows('saved'), isTrue);
        expect(r.inlineError, findsNothing);
        expect(r.bodyText, mergedPerson);
      },
    );

    testWidgets('a double conflict retries only once per debounce tick', (
      tester,
    ) async {
      // Every update conflicts: each tick makes one save and one retry.
      late LiveRobot r;
      var n = 0;
      r = await _launch(
        tester,
        before: (call, _) {
          n++;
          r.db.serverAppend(
            liveDailyId,
            'Capture $n.',
            blockId: 'a-$n',
            at: DateTime(2026, 10, 3, 9, 0, 0, 100 + n),
          );
        },
      );
      await r.type(_typed);

      await r.fireDebounce();
      expect(r.updates, hasLength(2));
      expect(_inlineErrorText(r, "Couldn't save"), findsOneWidget);
      expect(r.bodyText, _typed);

      await r.fireDebounce();
      expect(r.updates.length, inInclusiveRange(3, 4));
      expect(r.bodyText, _typed);
    });
  });

  group('no duplicates (AC9)', () {
    testWidgets(
      'a merge does not duplicate an agent block whose text is already in the local text',
      (tester) async {
        final r = await _launch(tester);
        // The person pasted the agent's line themselves.
        const local = '$_person$_agentText\n';
        await r.type(local);
        r.db.serverAppend(
          liveDailyId,
          _agentText,
          blockId: 'a-jump',
          at: DateTime(2026, 10, 3, 9, 0, 0, 100),
        );

        await r.fireDebounce();

        expect(r.updates, hasLength(2));
        final saved = r.updates[1].stdinBody!;
        expect(saved, assembleDailyBody(local, const [liveZetaTitle]));
        expect(_agentText.allMatches(saved), hasLength(1));
      },
    );

    testWidgets(
      'a merge does not duplicate a quick-entry block whose text is already in the local text but still adds a new agent block',
      (tester) async {
        final r = await _launch(tester);
        const local = '${_person}Buy milk.\n';
        await r.type(local);
        r.db.serverAppend(
          liveDailyId,
          'Buy milk.',
          blockId: 'q-milk',
          source: 'quick-entry',
          at: DateTime(2026, 10, 3, 9, 0, 0, 100),
        );
        r.db.serverAppend(
          liveDailyId,
          _agentText,
          blockId: 'a-jump',
          at: DateTime(2026, 10, 3, 9, 0, 0, 200),
        );

        await r.fireDebounce();

        expect(r.updates, hasLength(2));
        final saved = r.updates[1].stdinBody!;
        expect(
          saved,
          assembleDailyBody(appendToPerson(local, _agentText), const [
            liveZetaTitle,
          ]),
        );
        expect('Buy milk.'.allMatches(saved), hasLength(1));
        expect(_agentText.allMatches(saved), hasLength(1));
      },
    );

    testWidgets(
      'merging again after a double conflict does not duplicate the block appended by the first merge',
      (tester) async {
        late LiveRobot r;
        r = await _launch(
          tester,
          before: (call, _) {
            if (call == 2) {
              r.db.serverAppend(
                liveDailyId,
                'Second capture.',
                blockId: 'a-second',
                at: DateTime(2026, 10, 3, 9, 0, 0, 600),
              );
            }
          },
        );
        await r.type(_typed);
        r.db.serverAppend(
          liveDailyId,
          _agentText,
          blockId: 'a-jump',
          at: DateTime(2026, 10, 3, 9, 0, 0, 100),
        );
        await r.fireDebounce();
        await r.fireDebounce();

        expect(r.updates, hasLength(3));
        final saved = r.updates[2].stdinBody!;
        expect(_agentText.allMatches(saved), hasLength(1));
        expect('Second capture.'.allMatches(saved), hasLength(1));
        expect(topicsMarker.allMatches(saved), hasLength(1));
      },
    );
  });
}
