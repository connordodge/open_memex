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
        overrides: [hostedServerNameProvider.overrideWithValue('nas')],
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
