// WI #28 (implementer): edges of the live daily note beyond the ACs. Typing
// during a merged save, the poller on a dirty editor and on a topic note,
// non-daily conflicts, non-conflict failures, a note deleted mid-merge,
// dismissing the inline error, and the gutter following unsaved edits.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/poll_reads.dart';
import 'package:open_memex_app/src/editor/conflict_merge.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/note_poller_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';

import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/poll_fakes.dart';

const _person = 'Morning pages\n';
const _typed = '${_person}Then lunch with Sam.\n';
const _agentText = 'Agent saw the jump arc bug.';
const _topicId = 'topic-player-loop';
const _topicBody = 'Loop notes\n';

Future<(LiveRobot, PollReadCounter)> _launch(
  WidgetTester tester, {
  List<SeedBlock> blocks = const [SeedBlock('p-morning', 'Morning pages')],
  BeforeUpdate? before,
  void Function(FakeMemexCli cli, FakeVaultDb db, FakeClock clock)? configure,
}) async {
  final db = FakeVaultDb.v5()
    ..seedLiveDaily(blocks: blocks)
    ..seedNote(
      id: _topicId,
      title: 'Player Loop',
      role: 'topic',
      content: _topicBody,
    );
  final clock = FakeClock(DateTime(2026, 10, 3, 9));
  final cli = FakeMemexCli()..onUpdateServer(db, clock: clock, before: before);
  configure?.call(cli, db, clock);
  final counter = PollReadCounter();
  final r = await pumpLiveWorkspace(
    tester,
    db: db,
    cli: cli,
    clock: clock,
    overrides: [
      noteUpdatedAtReaderProvider.overrideWith(
        (ref) => (noteId) {
          counter.record(noteId);
          return db.noteUpdatedAt(noteId);
        },
      ),
    ],
  );
  return (r, counter);
}

Future<void> _openTopic(LiveRobot r) async {
  r.h.container
      .read(tabsProvider.notifier)
      .openOrFocus(const NoteTab(_topicId));
  await r.settle();
  expect(r.bodyText, _topicBody);
}

void main() {
  group('typing during a merged save', () {
    testWidgets(
      'text typed while the merged retry is in flight is saved with the merged blocks on the next tick',
      (tester) async {
        const later = '${_typed}And a nap.\n';
        late LiveRobot r;
        (r, _) = await _launch(
          tester,
          before: (call, _) {
            // The person keeps typing while the merged retry is in flight.
            if (call == 2) {
              r.h.container
                  .read(editorControllerProvider.notifier)
                  .onContentChanged(
                    assembleDailyBody(later, const [liveZetaTitle]),
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
        expect(r.editor.status, SaveStatus.dirty);
        expect(r.bodyText, later);

        await r.fireDebounce();

        expect(r.updates, hasLength(3));
        expect(r.updates[2].flag('expected-version'), '5');
        expect(
          r.updates[2].stdinBody,
          assembleDailyBody(appendToPerson(later, _agentText), const [
            liveZetaTitle,
          ]),
        );
        expect(r.editor.status, SaveStatus.clean);
        expect(r.bodyText, appendToPerson(later, _agentText));
      },
    );
  });

  group('the poller', () {
    testWidgets(
      'a foreign change seen while a save is in flight bumps the revision once and leaves the text',
      (tester) async {
        final (r, _) = await _launch(
          tester,
          // The save never answers: the editor stays unsaved.
          configure: (cli, _, _) =>
              cli.on('update', (_) => Completer<MemexResult>().future),
        );
        await r.type(_typed);
        r.db.serverAppend(
          liveDailyId,
          _agentText,
          blockId: 'a-jump',
          at: DateTime(2026, 10, 3, 9, 0, 1),
        );
        final revision = r.revision;

        await r.poll();
        expect(r.updates, hasLength(1));
        expect(r.editor.status, SaveStatus.saving);
        expect(r.revision, revision + 1);

        await r.poll();
        await r.poll();
        expect(r.revision, revision + 1);
        expect(r.bodyText, _typed);
      },
    );

    testWidgets('a topic note tab is never polled', (tester) async {
      final (r, counter) = await _launch(tester);
      await _openTopic(r);
      counter.reads = 0;

      await r.advance(const Duration(seconds: 10));

      expect(counter.reads, 0);
    });
  });

  group('saves that do not merge', () {
    testWidgets('a topic note conflict is reported as it is and never merged', (
      tester,
    ) async {
      final (r, _) = await _launch(tester);
      await _openTopic(r);
      await r.type('${_topicBody}One.\n');
      await r.fireDebounce();
      expect(r.updates.single.stdinBody, '${_topicBody}One.\n');

      await r.type('${_topicBody}One.\nTwo.\n');
      await r.fireDebounce();
      expect(r.updates, hasLength(2));
      expect(r.updates[1].stdinBody, '${_topicBody}One.\nTwo.\n');

      // A server write makes the next save stale.
      r.db.db.execute('UPDATE notes SET version = version + 1 WHERE id = ?', [
        _topicId,
      ]);
      await r.type('${_topicBody}One.\nTwo.\nThree.\n');
      await r.fireDebounce();

      expect(r.updates, hasLength(3));
      expect(r.updates[2].stdinBody, '${_topicBody}One.\nTwo.\nThree.\n');
      expect(r.editor.status, SaveStatus.conflict);
      expect(r.editor.errorMessage, contains('version conflict'));
      expect(r.saveIndicatorShows('conflict'), isTrue);
      expect(find.textContaining("Couldn't save"), findsNothing);
      expect(r.bodyText, '${_topicBody}One.\nTwo.\nThree.\n');
    });

    testWidgets(
      'a daily note save that fails without a conflict shows the error and does not merge',
      (tester) async {
        final (r, _) = await _launch(
          tester,
          configure: (cli, _, _) => cli.on(
            'update',
            (_) => FakeMemexCli.error('io_error', 'disk full'),
          ),
        );
        await r.type(_typed);

        await r.fireDebounce();

        expect(r.updates, hasLength(1));
        expect(r.editor.status, SaveStatus.error);
        expect(r.editor.errorMessage, contains('disk full'));
        expect(r.saveIndicatorShows('save failed'), isTrue);
        expect(r.bodyText, _typed);
      },
    );

    testWidgets(
      'a conflict on a daily note already deleted on the server is reported and not merged',
      (tester) async {
        final (r, _) = await _launch(
          tester,
          configure: (cli, db, _) => cli.on('update', (_) {
            db.db.execute('DELETE FROM notes WHERE id = ?', [liveDailyId]);
            return FakeMemexCli.error(
              'version_conflict',
              'version conflict: expected 3, current 4',
            );
          }),
        );
        await r.type(_typed);

        await r.fireDebounce();

        expect(r.updates, hasLength(1));
        expect(r.editor.status, SaveStatus.conflict);
        expect(r.editor.errorMessage, contains('version conflict'));
        expect(r.bodyText, _typed);
      },
    );

    testWidgets(
      'a daily note deleted on the server before the repeated merge ends in a save error',
      (tester) async {
        late LiveRobot r;
        (r, _) = await _launch(
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
        r.db.db.execute('DELETE FROM notes WHERE id = ?', [liveDailyId]);

        await r.fireDebounce();

        expect(r.updates, hasLength(2));
        expect(r.editor.status, SaveStatus.error);
        expect(r.editor.errorMessage, contains('not found'));
        expect(r.bodyText, _typed);
      },
    );
  });

  group('the Couldnt save error', () {
    testWidgets(
      'dismissing the inline error hides it and the next tick still merges and saves',
      (tester) async {
        late LiveRobot r;
        (r, _) = await _launch(
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
        expect(r.inlineError, findsOneWidget);
        expect(r.saveIndicatorShows('conflict'), isTrue);

        await tester.tap(
          find.descendant(
            of: r.inlineError,
            matching: find.byKey(const Key('inline-error-dismiss')),
          ),
        );
        await r.settle();
        expect(r.inlineError, findsNothing);
        expect(r.editor.status, SaveStatus.conflict);

        await r.fireDebounce();

        expect(r.updates, hasLength(3));
        expect(r.editor.status, SaveStatus.clean);
        expect(r.saveIndicatorShows('synced'), isTrue);
      },
    );
  });

  group('the gutter while editing', () {
    testWidgets(
      'an unsaved edit above an agent block keeps its rule on the agent lines',
      (tester) async {
        final (r, _) = await _launch(
          tester,
          blocks: const [
            SeedBlock('p-morning', 'Morning pages'),
            SeedBlock('a-bug', 'Agent saw a bug.', source: 'agent'),
            SeedBlock('p-sleep', 'Sleep was bad.'),
          ],
        );
        final inserted =
            'Inserted line one.\nInserted line two.\n\n'
            '${r.bodyText}';
        await r.type(inserted);
        await r.settle();

        final rule = tester.getRect(r.gutterRule('a-bug'));
        final y = r.lineCenterY(inserted.indexOf('Agent saw a bug.'));
        expect(rule.top <= y && y <= rule.bottom, isTrue);
        final sleep = r.lineCenterY(inserted.indexOf('Sleep was bad.'));
        expect(sleep > rule.bottom, isTrue);
        expect(r.editor.status, SaveStatus.dirty);
      },
    );

    testWidgets('a topic note has no capture gutter', (tester) async {
      final (r, _) = await _launch(tester);
      expect(r.gutter, findsOneWidget);

      await _openTopic(r);

      expect(r.gutter, findsNothing);
    });
  });
}
