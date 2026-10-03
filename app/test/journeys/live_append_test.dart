// WI #28 (A10): agent-appended blocks slide in on poll (Spec TS4 journey).
// Today's daily note is open and clean; the server (FakeVaultDb) gets an
// agent, quick-entry or footer write with a new `updated_at`, and the fake
// clock drives the 2 s poll. No real timers.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/conflict_merge.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';

import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/poll_fakes.dart';

const _person = 'Morning pages\n';
const _agentText = 'Agent saw the jump arc bug.';

Future<LiveRobot> _launchClean(
  WidgetTester tester, {
  List<SeedBlock> blocks = const [SeedBlock('p-morning', 'Morning pages')],
}) async {
  final db = FakeVaultDb.v5()..seedLiveDaily(blocks: blocks);
  final clock = FakeClock(DateTime(2026, 10, 3, 9));
  final cli = FakeMemexCli()..onUpdateServer(db, clock: clock);
  final r = await pumpLiveWorkspace(tester, db: db, cli: cli, clock: clock);
  return r;
}

void main() {
  group('agent-appended blocks slide in on poll (AC1)', () {
    testWidgets(
      'with the daily note open and clean an agent append shows at the end of the person text after the fake clock advances 2 s',
      (tester) async {
        final r = await _launchClean(tester);
        expect(r.bodyText, _person);
        expect(r.editor.status, SaveStatus.clean);

        r.db.serverAppend(
          liveDailyId,
          _agentText,
          blockId: 'a-jump',
          at: DateTime(2026, 10, 3, 9, 0, 1),
        );
        await r.poll();

        expect(r.bodyText.trimRight().endsWith(_agentText), isTrue);
        expect(r.bodyText, appendToPerson(_person, _agentText));
        // Applying a server write is not a local edit: nothing is saved.
        expect(r.updates, isEmpty);
        expect(r.editor.status, SaveStatus.clean);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a quick-entry append also slides in at the end of the person text on the next poll',
      (tester) async {
        final r = await _launchClean(tester);

        r.db.serverAppend(
          liveDailyId,
          'Buy milk.',
          blockId: 'q-milk',
          source: 'quick-entry',
          at: DateTime(2026, 10, 3, 9, 0, 1),
        );
        await r.poll();

        expect(r.bodyText, appendToPerson(_person, 'Buy milk.'));
        expect(r.updates, isEmpty);
      },
    );

    testWidgets('the slid-in agent block gets its gutter rule after the poll', (
      tester,
    ) async {
      final r = await _launchClean(tester);
      expect(r.gutterRule('a-jump'), findsNothing);

      r.db.serverAppend(
        liveDailyId,
        _agentText,
        blockId: 'a-jump',
        at: DateTime(2026, 10, 3, 9, 0, 1),
      );
      await r.poll();

      expect(r.gutterRule('a-jump'), findsOneWidget);
      final agentStart = r.bodyText.indexOf(_agentText);
      final rule = tester.getRect(r.gutterRule('a-jump'));
      final y = r.lineCenterY(agentStart);
      expect(rule.top, lessThanOrEqualTo(y));
      expect(rule.bottom, greaterThanOrEqualTo(y));
    });

    testWidgets(
      'after a polled update the next local edit saves against the new server version without a conflict',
      (tester) async {
        final r = await _launchClean(tester);
        final v = r.db.serverAppend(
          liveDailyId,
          _agentText,
          blockId: 'a-jump',
          at: DateTime(2026, 10, 3, 9, 0, 1),
        );
        await r.poll();
        expect(r.bodyText, appendToPerson(_person, _agentText));

        final typed = '${r.bodyText}Then lunch.\n';
        await r.type(typed);
        await r.fireDebounce();

        expect(r.updates, hasLength(1));
        expect(r.updates.single.flag('expected-version'), '$v');
        expect(
          r.updates.single.stdinBody,
          assembleDailyBody(typed, const [liveZetaTitle]),
        );
        expect(r.db.liveNote(liveDailyId).version, v + 1);
        expect(r.editor.status, SaveStatus.clean);
        expect(r.saveIndicatorShows('synced'), isTrue);
      },
    );
  });

  group('cursor and scroll stay put (AC2)', () {
    testWidgets(
      'the selection offsets and the page scroll offset are the same before and after an agent block slides in',
      (tester) async {
        // A long person section so the page scrolls.
        final lines = [for (var i = 0; i < 150; i++) 'line $i of the morning'];
        final r = await _launchClean(
          tester,
          blocks: [SeedBlock('p-long', lines.join('\n'))],
        );
        final caret = r.bodyText.indexOf('line 40 ');
        await r.placeCaret(caret);
        await r.scrollTo(200);
        final selectionBefore = r.bodySelection;
        final pixelsBefore = r.scrollPixels;
        expect(selectionBefore, TextSelection.collapsed(offset: caret));
        expect(pixelsBefore, 200);

        r.db.serverAppend(
          liveDailyId,
          _agentText,
          blockId: 'a-jump',
          at: DateTime(2026, 10, 3, 9, 0, 1),
        );
        await r.poll();

        expect(r.bodyText.trimRight().endsWith(_agentText), isTrue);
        expect(r.bodySelection.baseOffset, selectionBefore.baseOffset);
        expect(r.bodySelection.extentOffset, selectionBefore.extentOffset);
        expect(r.scrollPixels, pixelsBefore);
        expect(r.bodyHasFocus, isTrue);
      },
    );

    testWidgets(
      'a non-collapsed selection keeps both offsets when a quick-entry block slides in',
      (tester) async {
        final r = await _launchClean(tester);
        await r.placeCaret(0);
        tester.widget<EditableText>(r.body).controller.selection =
            const TextSelection(baseOffset: 2, extentOffset: 9);
        await tester.pump();

        r.db.serverAppend(
          liveDailyId,
          'Buy milk.',
          blockId: 'q-milk',
          source: 'quick-entry',
          at: DateTime(2026, 10, 3, 9, 0, 1),
        );
        await r.poll();

        expect(r.bodyText, appendToPerson(_person, 'Buy milk.'));
        expect(r.bodySelection.baseOffset, 2);
        expect(r.bodySelection.extentOffset, 9);
      },
    );
  });

  group('footer writes refresh the chip row (AC5)', () {
    testWidgets(
      'a footer write shows the new chip after the next poll and leaves the person text unchanged',
      (tester) async {
        final r = await _launchClean(tester);
        expect(r.footerChip(liveZetaId), findsOneWidget);
        expect(r.footerChip(liveAlphaId), findsNothing);
        final before = r.bodyText;
        final revision = r.revision;

        r.db.serverAddFooterChip(
          liveDailyId,
          liveAlphaId,
          liveAlphaTitle,
          at: DateTime(2026, 10, 3, 9, 0, 1),
        );
        await r.advance(const Duration(milliseconds: 1900));
        // Nothing re-reads the footer before the poll.
        expect(r.footerChip(liveAlphaId), findsNothing);

        await r.advance(const Duration(milliseconds: 100));

        expect(r.footerChip(liveZetaId), findsOneWidget);
        expect(r.footerChip(liveAlphaId), findsOneWidget);
        expect(r.bodyText, before);
        expect(r.revision, greaterThan(revision));
        expect(r.updates, isEmpty);
      },
    );

    testWidgets(
      'after a polled footer write the next local save keeps the new chip in the saved body',
      (tester) async {
        final r = await _launchClean(tester);
        final v = r.db.serverAddFooterChip(
          liveDailyId,
          liveAlphaId,
          liveAlphaTitle,
          at: DateTime(2026, 10, 3, 9, 0, 1),
        );
        await r.poll();
        expect(r.footerChip(liveAlphaId), findsOneWidget);

        await r.type('${_person}More.\n');
        await r.fireDebounce();

        expect(r.updates, hasLength(1));
        expect(r.updates.single.flag('expected-version'), '$v');
        expect(splitDailyBody(r.updates.single.stdinBody!).chips, const [
          liveZetaTitle,
          liveAlphaTitle,
        ]);
      },
    );
  });
}
