// WI #413 (Spec #394 req 13, D5a; guard ACs from the architect): when the
// Semantic recall tab reads `memex embeddings status`. It reads when the tab
// is shown; while it stays shown it re-reads on a `vaultRevisionProvider`
// change at most once every 10 s since the last read started, and on a 10 s
// tick (vector-only writes no longer move the revision); nothing runs while
// another tab is shown or after the sheet closes; a run in flight is never
// stacked: changes and ticks during it give exactly one follow-up read after
// it. Time moves only through the harness FakeClock (`clockProvider`), never
// wall time, and the tab is driven through the real sheet.
//
// The 10 s tick may be counted from when the tab was shown or from the last
// read's start; the expectations below hold for both.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/recall_tab.dart';

import '../../support/agents_sheet_harness.dart';
import '../../support/api_fixtures.dart';
import '../../support/fake_memex_cli.dart';
import '../../support/fake_vault_server.dart';
import '../../support/font_fetch_hold.dart';

String _wi413Status({int chunks = 71, int embedded = 64}) => jsonEncode({
  'server_embeddings': null,
  'chunks': chunks,
  'embedded': embedded,
  'model_cached': true,
  'model_bytes': 127000000,
});

/// A FakeMemexCli whose `embeddings status` answers [_wi413Status] at once,
/// or, while [hold] is true, parks each read until [releaseOne].
class _Wi413Cli {
  _Wi413Cli() {
    cli.on('embeddings status', (_) async {
      final embedded = answerEmbedded;
      if (!hold) return FakeMemexCli.ok(_wi413Status(embedded: embedded));
      final gate = Completer<void>();
      _held.add(gate);
      await gate.future;
      return FakeMemexCli.ok(_wi413Status(embedded: embedded));
    });
  }

  final cli = FakeMemexCli();
  final _held = <Completer<void>>[];

  /// While true, new reads wait for [releaseOne].
  bool hold = false;

  /// The `embedded` count the next read reports.
  int answerEmbedded = 64;

  int get reads => cli.callsFor('embeddings status').length;

  int get inFlight => _held.where((c) => !c.isCompleted).length;

  void releaseOne() => _held.firstWhere((c) => !c.isCompleted).complete();

  void releaseAll() {
    for (final c in _held) {
      if (!c.isCompleted) c.complete();
    }
  }
}

Future<(AgentsSheetHarness, _Wi413Cli)> _open(WidgetTester tester) async {
  final fake = _Wi413Cli();
  addTearDown(fake.releaseAll);
  final h = await pumpAgentsSheet(tester, cli: fake.cli);
  return (h, fake);
}

Future<void> _tapTab(
  WidgetTester tester,
  AgentsSheetHarness h,
  String tab,
) async {
  await tester.ensureVisible(find.byKey(Key('agents-tab-$tab')));
  await tester.pump();
  await tester.tap(find.byKey(Key('agents-tab-$tab')));
  await h.settle();
}

/// Moves the FakeClock by [by] and lets the reads it starts run.
Future<void> _advance(AgentsSheetHarness h, Duration by) async {
  h.clock.advance(by);
  await h.settle();
}

/// Moves the FakeClock to [at] after [start] and settles.
Future<void> _advanceTo(
  AgentsSheetHarness h,
  DateTime start,
  Duration at,
) async {
  final target = start.add(at);
  final step = target.difference(h.clock.now());
  if (step > Duration.zero) await _advance(h, step);
}

void _bumpRevision(AgentsSheetHarness h) =>
    h.container.read(vaultRevisionProvider.notifier).state++;

Duration _t(int seconds) => Duration(seconds: seconds);
const _ms = Duration(milliseconds: 1);

void main() {
  holdFontFetches();

  group('shown', () {
    testWidgets('showing the tab reads once', (tester) async {
      final (h, cli) = await _open(tester);
      expect(find.byType(RecallTab), findsNothing);
      expect(cli.reads, 0);
      await _tapTab(tester, h, 'recall');
      expect(find.byType(RecallTab), findsOneWidget);
      expect(cli.reads, 1);
      expect(
        cli.cli.callsFor('embeddings status').single.flag('vault'),
        agentsSheetLocalVault.path,
      );
      // Settling frames without moving the clock reads nothing more.
      await h.settle();
      await h.settle();
      expect(cli.reads, 1);
    });

    testWidgets(
      'nothing reads while another tab is shown, through ticks and revision changes',
      (tester) async {
        final (h, cli) = await _open(tester);
        // The sheet opened on Connect.
        for (var i = 0; i < 4; i++) {
          _bumpRevision(h);
          await _advance(h, _t(11));
        }
        expect(cli.reads, 0);
        await _tapTab(tester, h, 'recall');
        expect(cli.reads, 1);
        await _tapTab(tester, h, 'tools');
        for (var i = 0; i < 4; i++) {
          _bumpRevision(h);
          await _advance(h, _t(11));
        }
        expect(cli.reads, 1);
        await _tapTab(tester, h, 'live');
        await _advance(h, _t(30));
        expect(cli.reads, 1);
      },
    );

    testWidgets('showing the tab again after another tab reads again', (
      tester,
    ) async {
      final (h, cli) = await _open(tester);
      await _tapTab(tester, h, 'recall');
      expect(cli.reads, 1);
      await _tapTab(tester, h, 'connect');
      await _advance(h, _t(30));
      expect(cli.reads, 1);
      cli.answerEmbedded = 70;
      await _tapTab(tester, h, 'recall');
      expect(cli.reads, 2);
      expect(
        find.text('70 of 71 passages embedded', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('closing the sheet stops every read', (tester) async {
      final (h, cli) = await _open(tester);
      await _tapTab(tester, h, 'recall');
      expect(cli.reads, 1);
      await tester.tap(find.byKey(const Key('agents-sheet-footer-close')));
      // Past the 150 ms fade-out and the route's removal.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(agentsSheetFinder, findsNothing);
      for (var i = 0; i < 4; i++) {
        _bumpRevision(h);
        await _advance(h, _t(11));
      }
      expect(cli.reads, 1);
    });
  });

  group('tick', () {
    testWidgets('the 10 s tick re-reads once while the tab is shown', (
      tester,
    ) async {
      final (h, cli) = await _open(tester);
      await _tapTab(tester, h, 'recall');
      final start = h.clock.now();
      expect(cli.reads, 1);
      await _advanceTo(h, start, _t(10) - _ms);
      expect(cli.reads, 1);
      await _advanceTo(h, start, _t(10));
      expect(cli.reads, 2);
      await _advanceTo(h, start, _t(19));
      expect(cli.reads, 2);
      await _advanceTo(h, start, _t(20));
      expect(cli.reads, 3);
    });

    testWidgets(
      'a tick re-read keeps the last status on screen and then shows the new counts',
      (tester) async {
        final (h, cli) = await _open(tester);
        await _tapTab(tester, h, 'recall');
        final start = h.clock.now();
        expect(
          find.text('64 of 71 passages embedded', findRichText: true),
          findsOneWidget,
        );
        cli
          ..hold = true
          ..answerEmbedded = 71;
        await _advanceTo(h, start, _t(10));
        expect(cli.reads, 2);
        expect(cli.inFlight, 1);
        // The re-read is in flight: no loading state, the old counts stay.
        expect(
          find.text('64 of 71 passages embedded', findRichText: true),
          findsOneWidget,
        );
        expect(find.text('loading…'), findsNothing);
        await _advance(h, Duration(milliseconds: 500));
        expect(find.text('loading…'), findsNothing);
        cli.releaseOne();
        await h.settle();
        expect(
          find.text('71 of 71 passages embedded', findRichText: true),
          findsOneWidget,
        );
        expect(find.text('0 waiting', findRichText: true), findsOneWidget);
      },
    );
  });

  group('revision', () {
    testWidgets(
      'a revision change 3 s after a read re-reads at the 10 s mark, not before',
      (tester) async {
        final (h, cli) = await _open(tester);
        await _tapTab(tester, h, 'recall');
        final start = h.clock.now();
        expect(cli.reads, 1);
        await _advanceTo(h, start, _t(3));
        cli.answerEmbedded = 65;
        _bumpRevision(h);
        await h.settle();
        expect(cli.reads, 1);
        await _advanceTo(h, start, _t(9));
        expect(cli.reads, 1);
        await _advanceTo(h, start, _t(10) - _ms);
        expect(cli.reads, 1);
        await _advanceTo(h, start, _t(10));
        // Exactly one read at the mark: the change and the tick coincide.
        expect(cli.reads, 2);
        await _advanceTo(h, start, _t(10) + Duration(milliseconds: 500));
        expect(cli.reads, 2);
        expect(
          find.text('65 of 71 passages embedded', findRichText: true),
          findsOneWidget,
        );
      },
    );

    testWidgets('several revision changes inside 10 s give one re-read', (
      tester,
    ) async {
      final (h, cli) = await _open(tester);
      await _tapTab(tester, h, 'recall');
      final start = h.clock.now();
      for (final at in [1, 2, 4, 7, 9]) {
        await _advanceTo(h, start, _t(at));
        _bumpRevision(h);
        await h.settle();
      }
      expect(cli.reads, 1);
      await _advanceTo(h, start, _t(10));
      expect(cli.reads, 2);
      await _advanceTo(h, start, _t(19));
      expect(cli.reads, 2);
    });

    testWidgets(
      'a revision change 3 s after a tick read waits for 10 s after that read',
      (tester) async {
        final (h, cli) = await _open(tester);
        await _tapTab(tester, h, 'recall');
        final start = h.clock.now();
        await _advanceTo(h, start, _t(10));
        expect(cli.reads, 2);
        await _advanceTo(h, start, _t(13));
        _bumpRevision(h);
        await h.settle();
        expect(cli.reads, 2);
        await _advanceTo(h, start, _t(20) - _ms);
        expect(cli.reads, 2);
        await _advanceTo(h, start, _t(20));
        expect(cli.reads, 3);
      },
    );
  });

  group('no stacking', () {
    testWidgets(
      'a revision change and a tick during an in flight read give exactly one follow up read after it',
      (tester) async {
        final (h, cli) = await _open(tester);
        await _tapTab(tester, h, 'recall');
        final start = h.clock.now();
        expect(cli.reads, 1);
        cli.hold = true;
        await _advanceTo(h, start, _t(10));
        expect(cli.reads, 2);
        expect(cli.inFlight, 1);
        // During the held read: three revision changes and two ticks.
        for (final at in [12, 13, 16]) {
          await _advanceTo(h, start, _t(at));
          _bumpRevision(h);
          await h.settle();
        }
        await _advanceTo(h, start, _t(21));
        await _advanceTo(h, start, _t(30) + Duration(milliseconds: 500));
        expect(cli.reads, 2, reason: 'nothing stacks on the in-flight read');
        cli.hold = false;
        cli.releaseOne();
        await h.settle();
        expect(cli.reads, 3, reason: 'exactly one follow-up after it');
        await _advanceTo(h, start, _t(39));
        expect(cli.reads, 3);
      },
    );

    testWidgets(
      'a tick alone during an in flight read gives one follow up read',
      (tester) async {
        final (h, cli) = await _open(tester);
        await _tapTab(tester, h, 'recall');
        final start = h.clock.now();
        cli.hold = true;
        await _advanceTo(h, start, _t(10));
        expect(cli.reads, 2);
        await _advanceTo(h, start, _t(20) + Duration(milliseconds: 100));
        expect(cli.reads, 2);
        cli.hold = false;
        cli.releaseOne();
        await h.settle();
        expect(cli.reads, 3);
        await _advanceTo(h, start, _t(29));
        expect(cli.reads, 3);
      },
    );

    testWidgets(
      'a revision change during a short in flight read waits for the 10 s tick',
      (tester) async {
        final (h, cli) = await _open(tester);
        await _tapTab(tester, h, 'recall');
        final start = h.clock.now();
        cli.hold = true;
        await _advanceTo(h, start, _t(10));
        expect(cli.reads, 2);
        // The only trigger during the held read is a revision change, less
        // than 10 s after the read started: it queues nothing.
        await _advanceTo(h, start, _t(12));
        _bumpRevision(h);
        await h.settle();
        await _advanceTo(h, start, _t(13));
        cli.hold = false;
        cli.releaseOne();
        await h.settle();
        expect(cli.reads, 2, reason: 'no read starts when the read ends');
        await _advanceTo(h, start, _t(20) - _ms);
        expect(cli.reads, 2);
        await _advanceTo(h, start, _t(20));
        expect(cli.reads, 3, reason: 'the tick re-reads once');
        await _advanceTo(h, start, _t(29));
        expect(cli.reads, 3);
      },
    );

    testWidgets(
      'a read in flight when the tab is hidden gives no follow up while hidden',
      (tester) async {
        final (h, cli) = await _open(tester);
        await _tapTab(tester, h, 'recall');
        final start = h.clock.now();
        cli.hold = true;
        await _advanceTo(h, start, _t(10));
        expect(cli.reads, 2);
        _bumpRevision(h);
        await h.settle();
        await _tapTab(tester, h, 'connect');
        cli.hold = false;
        cli.releaseOne();
        await h.settle();
        await _advanceTo(h, start, _t(45));
        expect(cli.reads, 2);
        await _tapTab(tester, h, 'recall');
        expect(cli.reads, 3);
      },
    );
  });

  group('hosted', () {
    testWidgets(
      'a hosted vault reads the server when the tab is shown and on the tick',
      (tester) async {
        final server = FakeVaultServer()
          ..route(
            'GET',
            '/vaults/$seedVaultName/api/v1/embeddings',
            json: {
              'server_embeddings': true,
              'chunks': 10,
              'embedded': 4,
              'model_cached': false,
              'model_bytes': 0,
            },
          );
        int reads() => server.requests
            .where((r) => r.url.path.endsWith('/embeddings'))
            .length;
        const vault = HostedVaultRef(fakeServerId, seedVaultName);
        final h = await pumpAgentsSheet(tester, vault: vault, open: false);
        h.container.read(hostedSessionProvider.notifier).state = HostedSession(
          vault,
          server.connect(h.container),
        );
        await h.open();
        await _advance(h, _t(30));
        expect(reads(), 0);
        await _tapTab(tester, h, 'recall');
        final start = h.clock.now();
        expect(reads(), 1);
        await _advanceTo(h, start, _t(10) - _ms);
        expect(reads(), 1);
        await _advanceTo(h, start, _t(10));
        expect(reads(), 2);
      },
    );
  });
}
