// WI #88 (W4): the Graph view over the async graph reader (D14a). Pumped on
// its own, like graph_view_test, so pumpAndSettle can prove the simulation
// stops (never while the hosted loading spinner turns: it repeats forever).
//
// Seams: FakeVaultDb + graph_seeds under LocalVaultAccess, and
// Wi88GatedGraph (extends LocalGraphAccess, D21) to hold a read open.
// vaultDbProvider is null, so a view still fed from the database directly
// would show nothing at all.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_async_view.dart';
import 'package:open_memex_app/src/widgets/graph/graph_view.dart';

import '../support/daily_seed.dart';
import '../support/fake_vault_db.dart';
import '../support/graph_access_doubles.dart';
import '../support/graph_seeds.dart';

const _vaultA = LocalVaultRef('/tmp/om-88-view-a');
const _vaultB = LocalVaultRef('/tmp/om-88-view-b');
const _hostedA = HostedVaultRef('server-1', 'vault-a');
const _hostedB = HostedVaultRef('server-1', 'vault-b');
const _emptyHint = 'Nothing to show in this graph yet.';

Key _node(String id) => Key('graph-node-$id');

/// Every `graph-node-*` keyed widget.
final _anyNode = find.byWidgetPredicate((w) {
  final k = w.key;
  return k is ValueKey<String> && k.value.startsWith('graph-node-');
});

final _loading = find.byKey(vaultAsyncLoadingKey);

FakeVaultDb _db(void Function(FakeVaultDb db) seed) {
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  seed(db);
  return db;
}

/// Alpha extends Beta.
void _seedPair(FakeVaultDb db) {
  db.seedTopicNote(G.alpha, 'Alpha');
  db.seedTopicNote(G.beta, 'Beta');
  db.seedLink(G.alpha, G.beta, kind: 'extends');
}

/// Vault B: none of vault A's ids.
void _seedVaultB(FakeVaultDb db) {
  db.seedTopicNote('b-one', 'B one');
  db.seedTopicNote('b-two', 'B two');
  db.seedLink('b-one', 'b-two');
}

LocalVaultAccess _gated(String path, FakeVaultDb db, Wi88GatedGraph graph) =>
    LocalVaultAccess(vaultPath: path, db: db, graph: graph);

/// Pumps a bare [GraphView] for [scope] in a 1200x900 window over
/// [access] for the open vault [current]. Does not settle.
Future<ProviderContainer> _pumpView(
  WidgetTester tester,
  Map<VaultRef, VaultAccess> access, {
  required VaultRef current,
  GraphScope scope = const GraphScope.vault(),
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => current),
      vaultDbProvider.overrideWithValue(null),
      memexCliProvider.overrideWithValue(null),
      vaultAccessProvider.overrideWith((ref) {
        final vault = ref.watch(currentVaultProvider);
        return vault == null ? null : access[vault];
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(body: GraphView(scope: scope)),
      ),
    ),
  );
  return container;
}

/// pumpAndSettle with a bounded timeout: a simulation that never stops
/// fails here instead of hanging for ten virtual minutes.
Future<void> _settle(WidgetTester tester) => tester.pumpAndSettle(
  const Duration(milliseconds: 16),
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 60),
);

/// A bounded number of frames, for states that never settle (the hosted
/// loading spinner).
Future<void> _frames(WidgetTester tester, [int n = 5]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Set<String> _shownIds(WidgetTester tester) => {
  for (final e in _anyNode.evaluate())
    (e.widget.key! as ValueKey<String>).value.substring('graph-node-'.length),
};

void _switchTo(ProviderContainer c, VaultRef vault) =>
    c.read(currentVaultProvider.notifier).state = vault;

void main() {
  group('first load and reload (AC4)', () {
    testWidgets('the Graph view lays out the first graph once it arrives', (
      tester,
    ) async {
      final db = _db(_seedPair);
      final graph = Wi88GatedGraph(vaultPath: _vaultA.path, db: db);
      await _pumpView(tester, {
        _vaultA: _gated(_vaultA.path, db, graph),
      }, current: _vaultA);
      await _frames(tester);

      expect(graph.pending, 1, reason: 'the first read is in flight');
      expect(_anyNode, findsNothing);
      expect(_loading, findsNothing, reason: 'a local vault shows no spinner');

      graph.release();
      await _frames(tester);
      expect(
        tester.binding.hasScheduledFrame,
        isTrue,
        reason: 'the first graph starts the layout simulation',
      );
      await _settle(tester);

      expect(_shownIds(tester), {G.alpha, G.beta});
      expect(find.text(_emptyHint), findsNothing);
    });

    testWidgets(
      'after a revision bump the Graph view keeps the previous nodes until the new graph arrives',
      (tester) async {
        final db = _db(_seedPair);
        final graph = Wi88GatedGraph(vaultPath: _vaultA.path, db: db);
        final c = await _pumpView(tester, {
          _vaultA: _gated(_vaultA.path, db, graph),
        }, current: _vaultA);
        await _frames(tester);
        graph.release();
        await _settle(tester);
        expect(_shownIds(tester), {G.alpha, G.beta});
        final alphaBefore = tester.getCenter(find.byKey(_node(G.alpha)));

        db.seedTopicNote(G.gamma, 'Gamma');
        c.read(vaultRevisionProvider.notifier).state++;
        await _frames(tester);

        expect(graph.calls, 2, reason: 'the bump re-reads the graph');
        expect(graph.pending, 1);
        expect(_shownIds(tester), {
          G.alpha,
          G.beta,
        }, reason: 'the previous nodes stay on screen while the reload runs');
        expect(_loading, findsNothing);
        expect(find.text(_emptyHint), findsNothing);
        expect(
          tester.getCenter(find.byKey(_node(G.alpha))),
          alphaBefore,
          reason: 'the pending reload does not restart the layout',
        );
      },
    );

    testWidgets('the Graph view re-lays out when the reloaded graph arrives', (
      tester,
    ) async {
      final db = _db(_seedPair);
      final graph = Wi88GatedGraph(vaultPath: _vaultA.path, db: db);
      final c = await _pumpView(tester, {
        _vaultA: _gated(_vaultA.path, db, graph),
      }, current: _vaultA);
      await _frames(tester);
      graph.release();
      await _settle(tester);
      expect(tester.binding.hasScheduledFrame, isFalse);

      db.seedTopicNote(G.gamma, 'Gamma');
      db.seedLink(G.gamma, G.alpha);
      c.read(vaultRevisionProvider.notifier).state++;
      await _frames(tester);
      graph.release();
      await _frames(tester);

      expect(_shownIds(tester), {G.alpha, G.beta, G.gamma});
      expect(
        tester.binding.hasScheduledFrame,
        isTrue,
        reason: 'the new graph restarts the layout simulation',
      );
      await _settle(tester);
      expect(_shownIds(tester), {G.alpha, G.beta, G.gamma});
    });

    testWidgets('a failed reload keeps the previous graph on screen', (
      tester,
    ) async {
      final db = _db(_seedPair);
      final graph = Wi88GatedGraph(vaultPath: _vaultA.path, db: db);
      final c = await _pumpView(tester, {
        _vaultA: _gated(_vaultA.path, db, graph),
      }, current: _vaultA);
      await _frames(tester);
      graph.release();
      await _settle(tester);
      expect(_shownIds(tester), {G.alpha, G.beta});

      c.read(vaultRevisionProvider.notifier).state++;
      await _frames(tester);
      graph.fail(StateError('vault server unreachable'));
      await _settle(tester);

      expect(tester.takeException(), isNull);
      expect(_shownIds(tester), {G.alpha, G.beta});
      expect(find.text(_emptyHint), findsNothing);
      expect(_loading, findsNothing);
    });
  });

  group('hosted first load (A12 loading state)', () {
    testWidgets(
      'on a hosted vault the Graph view shows the loading state until the first graph arrives',
      (tester) async {
        final db = _db(_seedPair);
        final graph = Wi88GatedGraph(vaultPath: '/tmp/om-88-hosted', db: db);
        await _pumpView(tester, {
          _hostedA: _gated('/tmp/om-88-hosted', db, graph),
        }, current: _hostedA);
        await _frames(tester);

        expect(graph.pending, 1);
        expect(_loading, findsOneWidget);
        expect(_anyNode, findsNothing);
        expect(find.text(_emptyHint), findsNothing);

        graph.release();
        await _frames(tester);
        expect(_loading, findsNothing);
        await _settle(tester);

        expect(_shownIds(tester), {G.alpha, G.beta});
      },
    );

    testWidgets(
      'a failed first graph read on a hosted vault shows the empty graph hint',
      (tester) async {
        final db = _db(_seedPair);
        final graph = Wi88GatedGraph(vaultPath: '/tmp/om-88-hosted', db: db);
        await _pumpView(tester, {
          _hostedA: _gated('/tmp/om-88-hosted', db, graph),
        }, current: _hostedA);
        await _frames(tester);
        expect(_loading, findsOneWidget);

        graph.fail(StateError('vault server unreachable'));
        await _frames(tester);
        expect(_loading, findsNothing);
        await _settle(tester);

        expect(find.text(_emptyHint), findsOneWidget);
        expect(_anyNode, findsNothing);
      },
    );
  });

  group('vault switch (AC5, D14a)', () {
    testWidgets(
      'switching vaults never shows the previous vault rows in the Graph view',
      (tester) async {
        final dbA = _db(seedGraphFixture);
        final dbB = _db(_seedVaultB);
        final graphB = Wi88GatedGraph(vaultPath: _vaultB.path, db: dbB);
        final c = await _pumpView(tester, {
          _vaultA: LocalVaultAccess(vaultPath: _vaultA.path, db: dbA),
          _vaultB: _gated(_vaultB.path, dbB, graphB),
        }, current: _vaultA);
        await _settle(tester);
        expect(_shownIds(tester), G.allNotes);

        _switchTo(c, _vaultB);
        await _frames(tester);

        expect(graphB.pending, 1, reason: 'the new vault read is in flight');
        expect(
          _shownIds(tester).intersection(G.allNotes),
          isEmpty,
          reason: 'no node of the previous vault while the read is pending',
        );
        expect(find.text(_emptyHint), findsOneWidget);

        graphB.release();
        await _settle(tester);

        expect(_shownIds(tester), {'b-one', 'b-two'});
      },
    );

    testWidgets(
      'switching to a hosted vault shows the loading state and no node from the previous vault',
      (tester) async {
        final dbA = _db(seedGraphFixture);
        final dbB = _db(_seedVaultB);
        final graphB = Wi88GatedGraph(
          vaultPath: '/tmp/om-88-hosted-b',
          db: dbB,
        );
        final c = await _pumpView(tester, {
          _vaultA: LocalVaultAccess(vaultPath: _vaultA.path, db: dbA),
          _hostedB: _gated('/tmp/om-88-hosted-b', dbB, graphB),
        }, current: _vaultA);
        await _settle(tester);
        expect(_shownIds(tester), G.allNotes);

        _switchTo(c, _hostedB);
        await _frames(tester);

        expect(graphB.pending, 1);
        expect(_shownIds(tester).intersection(G.allNotes), isEmpty);
        expect(_loading, findsOneWidget);

        graphB.release();
        await _frames(tester);
        expect(_loading, findsNothing);
        await _settle(tester);

        expect(_shownIds(tester), {'b-one', 'b-two'});
      },
    );
  });

  group('simulation (AC6)', () {
    testWidgets(
      'the Graph view simulation settles on a standalone pump after the graph arrives through VaultAccess',
      (tester) async {
        final db = _db((db) => seedTopicRing(db, 30));
        await _pumpView(tester, {
          _vaultA: LocalVaultAccess(vaultPath: _vaultA.path, db: db),
        }, current: _vaultA);
        await _frames(tester, 2);
        expect(
          tester.binding.hasScheduledFrame,
          isTrue,
          reason: 'the force simulation animates once the graph arrives',
        );

        await _settle(tester);

        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(_anyNode, findsNWidgets(30));
      },
    );
  });
}
