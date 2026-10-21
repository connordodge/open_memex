// WI #102 (H8) journeys: a hosted vault's editor when a save can't reach the
// vault server (board A11 state 1, pack 102). The meta line shows "not saved
// yet · will save when <server> is back" (Key `pending-save-label`, warn
// mono 11), the note's tab shows a hollow warn ring with the tooltip "not
// saved yet" (Key `tab-pending-<tabId>`), and both clear when the queued
// save lands. The workspace opens on a local temp vault and then switches
// to a hosted vault ref; `vaultAccessProvider` is the hosted double.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/pending_saves.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/hosted_notes_fakes.dart';
import '../support/today_cli_fakes.dart';

const _planId = '01J9PLANJ000000000000000102';
const _otherId = '01J9OTHERJ00000000000000102';
const _today = '2026-10-03';

class _Hosted {
  _Hosted(this.tester, this.h, this.doubles)
    : r = SegmentedEditorRobot(tester, h);
  final WidgetTester tester;
  final WorkspaceHarness h;
  final HostedVaultDoubles doubles;
  final SegmentedEditorRobot r;

  HostedNotesAccess get notes =>
      doubles.notesFor(h.read(currentVaultProvider)!);

  Finder get label => find.byKey(const Key('pending-save-label'));
  Finder ring(String tabId) => find.byKey(Key('tab-pending-$tabId'));
  Finder get saveIndicator => find.byKey(const Key('save-indicator'));

  bool saveIndicatorShows(String text) => find
      .descendant(of: saveIndicator, matching: find.text(text))
      .evaluate()
      .isNotEmpty;

  Future<void> open(String noteId) async {
    h.read(tabsProvider.notifier).openOrFocus(NoteTab(noteId));
    await pumpFrames(tester);
  }

  /// Type [text] into the open note's body and let its save run.
  Future<void> typeAndSave(String text) async {
    await r.typeInSegment(0, text);
    await r.waitForSave();
  }

  /// The server answers again (the revision poll records connected).
  Future<void> serverAnswers() async {
    notes.writeError = null;
    h.container
            .read(hostedConnectionStatusProvider(hostedServerId).notifier)
            .state =
        HostedConnectionStatus.connected;
    await pumpFrames(tester);
  }
}

/// The workspace on a hosted vault holding "Plan" (`old`, version 3) and
/// "Other" (`other body`, version 7); [hosted] false keeps the local temp
/// vault.
Future<_Hosted> _workspace(
  WidgetTester tester, {
  bool hosted = true,
  List<Override> overrides = const [],
}) async {
  final db = FakeVaultDb.v5()
    ..seedNote(id: _planId, title: 'Plan', content: 'old', version: 3)
    ..seedNote(id: _otherId, title: 'Other', content: 'other body', version: 7);
  final cli = FakeMemexCli()
    ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
    ..onUpdateWrites(db)
    ..onAddDailyCreatesOnce(db);
  final doubles = HostedVaultDoubles(db: db, cli: cli);
  final h = await pumpWorkspace(
    tester,
    db: db,
    cli: cli,
    overrides: [hostedAccessOverride(doubles), ...overrides],
  );
  recordHostedOutcomes(doubles, h.container);
  if (hosted) {
    h.container.read(currentVaultProvider.notifier).state = hostedPlanVault;
    h.container
            .read(hostedConnectionStatusProvider(hostedServerId).notifier)
            .state =
        HostedConnectionStatus.connected;
    await pumpFrames(tester);
  }
  h.read(vaultAccessProvider);
  return _Hosted(tester, h, doubles);
}

String _labelText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('pending-save-label'))).data!;

void main() {
  group('the not saved yet label (AC1, A11 state 1)', () {
    testWidgets(
      'the meta line shows not saved yet with the server name in warn mono 11 when a hosted save cannot reach the server',
      (tester) async {
        final w = await _workspace(tester);
        await w.open(_planId);
        w.notes.writeError = nasUnreachable();

        await w.typeAndSave('new text');

        expect(w.label, findsOneWidget);
        expect(_labelText(tester), pendingLabelNas);
        final style = tester.widget<Text>(w.label).style!;
        expect(style.fontSize, 11);
        expect(style.color, OmColors.warn);
        expect(style.fontFamily, contains('JetBrains'));
        // The label sits in the meta line of the note header, alone.
        expect(
          find.descendant(
            of: find.byKey(const Key('note-header')),
            matching: w.label,
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('note-header')),
            matching: find.textContaining('updated '),
          ),
          findsNothing,
        );
        expect(w.r.segmentText(0), 'new text');
        expect(w.r.inlineError, findsNothing);
        expect(w.saveIndicatorShows('save failed'), isFalse);
        expect(w.saveIndicatorShows('conflict'), isFalse);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a save that timed out after sending shows the same not saved yet label',
      (tester) async {
        final w = await _workspace(tester);
        await w.open(_planId);
        w.notes.writeError = nasUnreachable(mayHaveCommitted: true);

        await w.typeAndSave('new text');

        expect(_labelText(tester), pendingLabelNas);
        expect(w.r.inlineError, findsNothing);
      },
    );

    testWidgets('a save rejected with 401 shows the same not saved yet label', (
      tester,
    ) async {
      final w = await _workspace(
        tester,
        overrides: [
          hostedServerNameProvider(hostedServerId).overrideWithValue('nas'),
        ],
      );
      await w.open(_planId);
      w.notes.writeError = unauthorized401();

      await w.typeAndSave('new text');

      expect(_labelText(tester), pendingLabelNas);
      expect(w.r.inlineError, findsNothing);
      expect(w.saveIndicatorShows('save failed'), isFalse);
    });
  });

  group('the tab chip of a queued note (AC6)', () {
    testWidgets(
      'the tab chip of a queued note shows the not saved yet ring and keeps it after switching notes',
      (tester) async {
        final w = await _workspace(tester);
        await w.open(_planId);
        w.notes.writeError = nasUnreachable();
        await w.typeAndSave('new text');

        final ring = w.ring('note-$_planId');
        expect(ring, findsOneWidget);
        final dot = find.descendant(
          of: find.byKey(const Key('tab-note-$_planId')),
          matching: find.byType(StatusDot),
        );
        expect(dot, findsOneWidget);
        expect(tester.widget<StatusDot>(dot).state, StatusDotState.cantReach);
        expect(
          find.ancestor(
            of: dot,
            matching: find.byWidgetPredicate(
              (w) => w is Tooltip && w.message == 'not saved yet',
            ),
          ),
          findsOneWidget,
        );

        await w.open(_otherId);

        expect(w.ring('note-$_planId'), findsOneWidget);
        expect(w.ring('note-$_otherId'), findsNothing);
        expect(w.r.segmentText(0), 'other body');
        expect(w.label, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'returning to a queued note shows the queued text and the label after a revision bump',
      (tester) async {
        final w = await _workspace(tester);
        await w.open(_planId);
        w.notes.writeError = nasUnreachable();
        await w.typeAndSave('new text');
        await w.open(_otherId);
        w.h.db.db.execute(
          'UPDATE notes SET content_md = ?, version = 5 WHERE id = ?',
          ['server copy', _planId],
        );
        w.h.container.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);

        await w.open(_planId);

        expect(w.r.segmentText(0), 'new text');
        expect(_labelText(tester), pendingLabelNas);
        expect(w.ring('note-$_planId'), findsOneWidget);
      },
    );
  });

  group('the queued save lands (AC2)', () {
    testWidgets('the label and the tab ring clear when the queued save lands', (
      tester,
    ) async {
      final w = await _workspace(tester);
      await w.open(_planId);
      w.notes.writeError = nasUnreachable();
      await w.typeAndSave('new text');
      expect(w.label, findsOneWidget);

      await w.serverAnswers();

      expect(w.label, findsNothing);
      expect(w.ring('note-$_planId'), findsNothing);
      expect(w.saveIndicatorShows('saved'), isTrue);
      expect(w.h.db.getNote(_planId)!.contentMd, 'new text');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'the ring of a queued note that is not open clears when its save lands',
      (tester) async {
        final w = await _workspace(tester);
        await w.open(_planId);
        w.notes.writeError = nasUnreachable();
        await w.typeAndSave('new text');
        await w.open(_otherId);

        await w.serverAnswers();

        expect(w.ring('note-$_planId'), findsNothing);
        expect(w.h.db.getNote(_planId)!.contentMd, 'new text');
        expect(w.r.segmentText(0), 'other body');
      },
    );
  });

  group('the virtual Today note (AC9)', () {
    testWidgets(
      'a virtual Today note whose create cannot reach the server shows the label and its tab ring',
      (tester) async {
        final w = await _workspace(tester);
        w.h.read(tabsProvider.notifier).openToday(date: _today);
        await pumpFrames(tester);
        w.notes.writeError = nasUnreachable();

        await w.typeAndSave('Morning pages');

        expect(_labelText(tester), pendingLabelNas);
        expect(w.ring(const VirtualTodayTab(_today).tabId), findsOneWidget);
        expect(w.r.inlineError, findsNothing);
        expect(w.saveIndicatorShows('save failed'), isFalse);

        await w.serverAnswers();
        await w.r.waitForSave();

        expect(w.label, findsNothing);
        expect(w.ring(const VirtualTodayTab(_today).tabId), findsNothing);
        expect(w.ring('note-$createdDailyId'), findsNothing);
        expect(w.h.read(tabsProvider).activeTab, const NoteTab(createdDailyId));
      },
    );
  });

  group('switching tabs while the server cannot be reached (AC6)', () {
    /// Every editable text field the editor shows right now.
    List<String> shownTexts(WidgetTester tester) => [
      for (final e in tester.widgetList<EditableText>(
        find.byType(EditableText),
      ))
        e.controller.text,
    ];

    testWidgets(
      'switching tabs while the server cannot be reached never shows the previous note and never saves it with the other note text',
      (tester) async {
        final w = await _workspace(tester);
        // Other has a queued save; Plan then opens from the server.
        await w.open(_otherId);
        w.notes.writeError = nasUnreachable();
        await w.typeAndSave('other queued');
        await w.open(_planId);
        expect(w.r.segmentText(0), 'old');

        // The server stops answering reads too; switch to Other.
        w.notes.readError = nasUnreachable();
        await w.open(_otherId);

        expect(shownTexts(tester), isNot(contains('old')));
        expect(shownTexts(tester), isNot(contains('Plan')));
        expect(w.r.segmentText(0), 'other queued');

        await w.typeAndSave('typed under other');

        expect(shownTexts(tester), isNot(contains('old')));
        for (final (i, write) in w.notes.writes.indexed) {
          if (write.startsWith('updateNote:$_planId@')) {
            expect(w.notes.updateBodies[i], isNot(contains('typed')));
          }
        }
        final queue = w.h.read(pendingSavesProvider);
        for (final p in queue.where((p) => p.noteId == _planId)) {
          expect(p.text, isNot(contains('typed')));
        }
        expect(
          queue.singleWhere((p) => p.noteId == _otherId).text,
          'typed under other',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'switching to a note that cannot be read while the server cannot be reached shows no note rather than the previous one',
      (tester) async {
        final w = await _workspace(tester);
        await w.open(_planId);
        expect(w.r.segmentText(0), 'old');
        w.notes
          ..writeError = nasUnreachable()
          ..readError = nasUnreachable();
        // The revision poll already saw the server unreachable.
        w.h.container
                .read(hostedConnectionStatusProvider(hostedServerId).notifier)
                .state =
            HostedConnectionStatus.unreachable;
        await pumpFrames(tester);

        await w.open(_otherId);

        expect(shownTexts(tester), isNot(contains('old')));
        expect(shownTexts(tester), isNot(contains('Plan')));
        expect(find.byKey(const Key('note-header')), findsNothing);
        await w.r.waitForSave();
        expect(w.notes.updatesOf(_planId), isEmpty);
        expect(w.h.read(pendingSavesProvider), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('a note loaded before the server became unreachable (#105 AC7)', () {
    /// Every editable text field the editor shows right now.
    List<String> shownTexts(WidgetTester tester) => [
      for (final e in tester.widgetList<EditableText>(
        find.byType(EditableText),
      ))
        e.controller.text,
    ];

    /// The server stops answering reads and writes of the open vault.
    Future<void> serverStops(_Hosted w) async {
      w.notes
        ..writeError = nasUnreachable()
        ..readError = nasUnreachable();
      setHostedStatus(w.h.container, HostedConnectionStatus.unreachable);
      await pumpFrames(w.tester);
    }

    testWidgets(
      'a note loaded before the server became unreachable still shows its text when switched back to while unreachable',
      (tester) async {
        final w = await _workspace(tester);
        await w.open(_planId);
        expect(w.r.segmentText(0), 'old');
        await w.open(_otherId);
        expect(w.r.segmentText(0), 'other body');
        await serverStops(w);

        await w.open(_planId);
        expect(find.byKey(const Key('note-header')), findsOneWidget);
        expect(w.r.segmentText(0), 'old');
        expect(shownTexts(tester), contains('Plan'));

        // Switching on shows the other loaded note, never this one.
        await w.open(_otherId);
        expect(w.r.segmentText(0), 'other body');
        expect(shownTexts(tester), isNot(contains('old')));
        expect(shownTexts(tester), isNot(contains('Plan')));

        await w.open(_planId);
        expect(w.r.segmentText(0), 'old');
        expect(shownTexts(tester), isNot(contains('other body')));

        await w.typeAndSave('typed offline');

        final queue = w.h.read(pendingSavesProvider);
        final plan = queue.singleWhere((p) => p.noteId == _planId);
        expect(plan.text, 'typed offline');
        expect(plan.title, 'Plan');
        expect(queue.where((p) => p.noteId == _otherId), isEmpty);
        expect(w.label, findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'an edit typed on a loaded note while unreachable is based on its loaded version and meets a later server change as a conflict',
      (tester) async {
        final w = await _workspace(tester);
        await w.open(_planId);
        await w.open(_otherId);
        await serverStops(w);
        // Someone else saves Plan on the server meanwhile.
        w.doubles.db.db.execute(
          'UPDATE notes SET content_md = ?, version = ? WHERE id = ?',
          ['their text', 4, _planId],
        );

        await w.open(_planId);
        expect(w.r.segmentText(0), 'old');
        await w.typeAndSave('typed offline');

        expect(
          w.h.read(pendingSavesProvider).single.baseVersion,
          3,
          reason: 'the queued save is based on the loaded version',
        );
        expect(w.notes.updatesOf(_planId), everyElement(endsWith('@3')));

        w.notes.readError = null;
        await w.serverAnswers();
        await pumpFrames(tester);

        expect(w.notes.updatesOf(_planId).last, 'updateNote:$_planId@3');
        final stored = w.doubles.db.getNote(_planId)!;
        expect(stored.contentMd, 'their text');
        expect(stored.version, 4);
        final entry = w.h
            .read(pendingSaveQueueProvider)
            .singleWhere((q) => q.save.noteId == _planId);
        expect(entry.heldStatus, SaveStatus.conflict);
        expect(entry.save.text, 'typed offline');
        expect(w.r.segmentText(0), 'typed offline');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'an edit typed on a loaded daily note while unreachable merges with a later server change when the server answers',
      (tester) async {
        const dailyId = '01J9DAILYJ00000000000000102';
        final w = await _workspace(tester);
        final db = w.doubles.db
          ..seedDailyNote('2026-10-01', id: dailyId, version: 3);
        db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
          assembleDailyBody('Morning pages\n', const []),
          dailyId,
        ]);
        db.seedBlock(dailyId, 'p-morning', ord: 0, text: 'Morning pages');
        await w.open(dailyId);
        expect(w.r.segmentText(0), 'Morning pages\n');
        await w.open(_otherId);
        await serverStops(w);
        // An agent appends to the daily note on the server meanwhile.
        db.db.execute(
          'UPDATE notes SET content_md = ?, version = ? WHERE id = ?',
          [
            assembleDailyBody('Morning pages\nAgent note.\n', const []),
            4,
            dailyId,
          ],
        );
        db.seedBlock(
          dailyId,
          'a-agent',
          ord: 1,
          text: 'Agent note.',
          source: 'agent',
          createdVersion: 4,
        );

        await w.open(dailyId);
        expect(w.r.segmentText(0), 'Morning pages\n');
        await w.typeAndSave('Morning pages and lunch');
        expect(w.h.read(pendingSavesProvider).single.baseVersion, 3);

        w.notes.readError = null;
        await w.serverAnswers();
        await pumpFrames(tester);

        expect(w.notes.updatesOf(dailyId).first, 'updateNote:$dailyId@3');
        final stored = db.getNote(dailyId)!;
        expect(stored.version, greaterThan(4));
        expect(stored.contentMd, contains('Agent note.'));
        expect(stored.contentMd, contains('Morning pages and lunch'));
        expect(w.h.read(pendingSavesProvider), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a note loaded in one hosted vault never shows in another hosted vault with the same note id while unreachable',
      (tester) async {
        final w = await _workspace(tester);
        await w.open(_planId);
        expect(w.r.segmentText(0), 'old');
        const archive = HostedVaultRef(hostedServerId, 'archive');
        // The poll already saw the server unreachable (a read's outcome
        // can't be recorded while the vault's first read builds).
        setHostedStatus(w.h.container, HostedConnectionStatus.unreachable);
        w.doubles.notesFor(archive)
          ..onOutcome = null
          ..writeError = nasUnreachable()
          ..readError = nasUnreachable();

        w.h.container.read(currentVaultProvider.notifier).state = archive;
        await pumpFrames(tester);
        await w.open(_planId);
        await pumpFrames(tester);

        expect(shownTexts(tester), isNot(contains('old')));
        expect(shownTexts(tester), isNot(contains('Plan')));
        expect(find.byKey(const Key('note-header')), findsNothing);
        await w.r.waitForSave();
        expect(w.doubles.notesFor(archive).writes, isEmpty);
        expect(w.h.read(pendingSavesProvider), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a note loaded before another vault was opened does not show when its vault is opened again while unreachable',
      (tester) async {
        final w = await _workspace(tester);
        await w.open(_planId);
        expect(w.r.segmentText(0), 'old');
        const archive = HostedVaultRef(hostedServerId, 'archive');
        w.h.container.read(currentVaultProvider.notifier).state = archive;
        await pumpFrames(tester);

        setHostedStatus(w.h.container, HostedConnectionStatus.unreachable);
        w.doubles.notesFor(hostedPlanVault)
          ..onOutcome = null
          ..writeError = nasUnreachable()
          ..readError = nasUnreachable();
        w.h.container.read(currentVaultProvider.notifier).state =
            hostedPlanVault;
        await pumpFrames(tester);
        await w.open(_planId);
        await pumpFrames(tester);

        expect(shownTexts(tester), isNot(contains('old')));
        expect(find.byKey(const Key('note-header')), findsNothing);
        expect(w.h.read(pendingSavesProvider), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('local vaults are unchanged (AC12)', () {
    testWidgets(
      'a failed save on a local vault shows the save failed state and no not saved yet label',
      (tester) async {
        final w = await _workspace(tester, hosted: false);
        await w.open(_planId);
        w.notes.writeError = MemexException('update failed: disk full');

        await w.typeAndSave('new text');

        expect(w.saveIndicatorShows('save failed'), isTrue);
        expect(w.label, findsNothing);
        expect(w.ring('note-$_planId'), findsNothing);
        expect(w.h.read(pendingSavesProvider), isEmpty);
      },
    );
  });
}
