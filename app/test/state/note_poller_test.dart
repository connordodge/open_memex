// WI #28 (A10): the open daily note's poller (TD8 `notePollerProvider`).
// Polls `updated_at` every 2 s on the fake clock through
// `noteUpdatedAtReaderProvider` (counted here), ignores the app's own saves,
// and runs only while a daily note is the active tab.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/poll_reads.dart';
import 'package:open_memex_app/src/editor/conflict_merge.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/note_poller_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';

import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/poll_fakes.dart';

const _person = 'Morning pages\n';
const _agentText = 'Agent saw the jump arc bug.';
const _topicId = 'topic-player-loop';

Future<(LiveRobot, PollReadCounter)> _launch(
  WidgetTester tester, {
  FakeVaultDb? db,
}) async {
  final vault = db ?? (FakeVaultDb.v5()..seedLiveDaily());
  vault.seedNote(
    id: _topicId,
    title: 'Player Loop',
    role: 'topic',
    content: 'Loop notes\n',
  );
  final clock = FakeClock(DateTime(2026, 10, 3, 9));
  final cli = FakeMemexCli()..onUpdateServer(vault, clock: clock);
  final counter = PollReadCounter();
  final r = await pumpLiveWorkspace(
    tester,
    db: vault,
    cli: cli,
    clock: clock,
    overrides: [
      noteUpdatedAtReaderProvider.overrideWith(
        (ref) => (noteId) {
          counter.record(noteId);
          return vault.noteUpdatedAt(noteId);
        },
      ),
    ],
  );
  return (r, counter);
}

void main() {
  group('poll read (AC1)', () {
    test('noteUpdatedAt returns the stored updated_at of a note', () {
      final db = FakeVaultDb.v5()
        ..seedLiveDaily(updatedAt: 1759474812345)
        ..seedNote(id: 'other', title: 'Other', updatedAt: 1759474899999);
      addTearDown(db.close);

      expect(db.noteUpdatedAt(liveDailyId), 1759474812345);
      expect(db.noteUpdatedAt('other'), 1759474899999);

      db.serverAppend(
        liveDailyId,
        _agentText,
        blockId: 'a-1',
        at: DateTime.fromMillisecondsSinceEpoch(1759474900000),
      );
      expect(db.noteUpdatedAt(liveDailyId), 1759474900000);
    });

    test('noteUpdatedAt returns null for a note that does not exist', () {
      final db = FakeVaultDb.v5()..seedLiveDaily();
      addTearDown(db.close);

      expect(db.noteUpdatedAt('missing-note'), isNull);
    });

    testWidgets(
      'each poll reads the open daily note updated_at once and leaves no read transaction open',
      (tester) async {
        final (r, counter) = await _launch(tester);
        counter.reads = 0;
        counter.noteIds.clear();

        await r.poll();
        expect(counter.reads, 1);
        expect(counter.noteIds, [liveDailyId]);
        expect(r.db.db.autocommit, isTrue);

        await r.poll();
        expect(counter.reads, 2);
        expect(r.db.db.autocommit, isTrue);
      },
    );

    testWidgets('a foreign change seen by the poll bumps the vault revision', (
      tester,
    ) async {
      final (r, _) = await _launch(tester);
      final revision = r.revision;

      await r.poll();
      // No change on the server: no bump.
      expect(r.revision, revision);

      r.db.serverAppend(
        liveDailyId,
        _agentText,
        blockId: 'a-1',
        at: DateTime(2026, 10, 3, 9, 0, 3),
      );
      await r.poll();
      expect(r.revision, greaterThan(revision));
    });
  });

  group('poll interval (AC3)', () {
    testWidgets(
      'the editor text is unchanged 1.9 s after an agent append and shows it once the clock reaches 2 s',
      (tester) async {
        final (r, counter) = await _launch(tester);
        counter.reads = 0;

        r.db.serverAppend(
          liveDailyId,
          _agentText,
          blockId: 'a-1',
          at: DateTime(2026, 10, 3, 9),
        );
        await r.advance(const Duration(milliseconds: 1900));

        expect(r.bodyText, _person);
        expect(counter.reads, 0);

        await r.advance(const Duration(milliseconds: 100));

        expect(counter.reads, 1);
        expect(r.bodyText, appendToPerson(_person, _agentText));
      },
    );

    testWidgets('the poller reads every 2 s, not more often', (tester) async {
      final (r, counter) = await _launch(tester);
      counter.reads = 0;

      await r.advance(const Duration(seconds: 10));
      expect(counter.reads, 5);

      await r.advance(const Duration(milliseconds: 1999));
      expect(counter.reads, 5);
      await r.advance(const Duration(milliseconds: 1));
      expect(counter.reads, 6);
    });
  });

  group('own saves are ignored (AC4)', () {
    testWidgets(
      'after a local save completes the next poll triggers no rebuild from the server',
      (tester) async {
        final (r, counter) = await _launch(tester);
        const typed = '${_person}Then lunch.\n';
        await r.type(typed);
        await r.placeCaret(3);
        await r.fireDebounce();
        expect(r.updates, hasLength(1));
        expect(r.editor.status, SaveStatus.clean);
        // The save changed the stored updated_at.
        expect(r.db.liveNote(liveDailyId).updatedAt, isNot(1759474800000));
        final revision = r.revision;
        final selection = r.bodySelection;
        counter.reads = 0;

        await r.poll();

        expect(counter.reads, 1, reason: 'the poll ran');
        expect(r.revision, revision);
        expect(r.bodyText, typed);
        expect(r.bodySelection, selection);
        expect(r.updates, hasLength(1));
        expect(r.editor.status, SaveStatus.clean);
      },
    );

    testWidgets(
      'after ignoring its own save the poller still picks up a later agent append',
      (tester) async {
        final (r, _) = await _launch(tester);
        const typed = '${_person}Then lunch.\n';
        await r.type(typed);
        await r.fireDebounce();
        await r.poll();
        final revision = r.revision;

        r.db.serverAppend(
          liveDailyId,
          _agentText,
          blockId: 'a-1',
          at: r.clock.now().add(const Duration(milliseconds: 1)),
        );
        await r.poll();

        expect(r.revision, greaterThan(revision));
        expect(r.bodyText, appendToPerson(typed, _agentText));
        expect(r.updates, hasLength(1));
      },
    );
  });

  group('polling stops off the daily note (AC6)', () {
    testWidgets(
      'closing the daily note tab stops polling: 10 s on the fake clock makes no updated_at reads',
      (tester) async {
        final (r, counter) = await _launch(tester);
        await r.poll();
        expect(counter.reads, greaterThan(0), reason: 'polling while open');

        r.h.container
            .read(tabsProvider.notifier)
            .close(const NoteTab(liveDailyId));
        await r.settle();
        expect(r.activeTab, isNot(const NoteTab(liveDailyId)));
        counter.reads = 0;

        r.db.serverAppend(
          liveDailyId,
          _agentText,
          blockId: 'a-1',
          at: DateTime(2026, 10, 3, 9, 0, 3),
        );
        final revision = r.revision;
        await r.advance(const Duration(seconds: 10));

        expect(counter.reads, 0);
        expect(r.revision, revision);
      },
    );

    testWidgets(
      'switching to another tab stops polling: 10 s on the fake clock makes no updated_at reads',
      (tester) async {
        final (r, counter) = await _launch(tester);
        await r.poll();
        expect(counter.reads, greaterThan(0), reason: 'polling while open');

        r.h.container
            .read(tabsProvider.notifier)
            .openOrFocus(const NoteTab(_topicId));
        await r.settle();
        expect(r.activeTab, const NoteTab(_topicId));
        counter.reads = 0;

        await r.advance(const Duration(seconds: 10));

        expect(counter.reads, 0);
      },
    );

    testWidgets(
      'switching back to the daily note tab polls again and applies an append made while away',
      (tester) async {
        final (r, counter) = await _launch(tester);
        final tabs = r.h.container.read(tabsProvider.notifier);
        tabs.openOrFocus(const NoteTab(_topicId));
        await r.settle();
        r.db.serverAppend(
          liveDailyId,
          _agentText,
          blockId: 'a-1',
          at: DateTime(2026, 10, 3, 9, 0, 1),
        );
        await r.advance(const Duration(seconds: 4));

        tabs.openOrFocus(const NoteTab(liveDailyId));
        await r.settle();
        counter.reads = 0;
        r.db.serverAppend(
          liveDailyId,
          'Second capture.',
          blockId: 'a-2',
          at: DateTime(2026, 10, 3, 9, 0, 5),
        );
        await r.poll();

        expect(counter.reads, greaterThan(0));
        expect(
          r.bodyText,
          appendToPerson(
            appendToPerson(_person, _agentText),
            'Second capture.',
          ),
        );
      },
    );
  });
}
