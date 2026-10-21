// WI #88 (W4): the Graph's async reader, its D14a synchronous facade and the
// Graph tab title, all read through VaultAccess (D13, D14a).
//
// Seams: FakeVaultDb + graph_seeds (G.* ids) under LocalVaultAccess, and
// Wi88GatedGraph (extends LocalGraphAccess, D21) to hold a read open.
// vaultDbProvider is null in every container, so a read that still went to
// the database directly would come back empty.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/graph_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';

import '../support/daily_seed.dart';
import '../support/fake_vault_db.dart';
import '../support/graph_access_doubles.dart';
import '../support/graph_seeds.dart';

const _vaultA = LocalVaultRef('/tmp/om-88-vault-a');
const _vaultB = LocalVaultRef('/tmp/om-88-vault-b');
const _hostedB = HostedVaultRef('server-1', 'vault-b');

FakeVaultDb _db(void Function(FakeVaultDb db) seed) {
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  seed(db);
  return db;
}

/// Vault B's notes: none of vault A's ids.
void _seedVaultB(FakeVaultDb db) {
  db.seedTopicNote('b-one', 'B one');
  db.seedTopicNote('b-two', 'B two');
  db.seedLink('b-one', 'b-two');
}

/// A container whose `vaultAccessProvider` serves [access] for the open
/// vault (null for a vault it has no entry for), with no database handle and
/// no CLI behind the app's own providers.
ProviderContainer _container(
  Map<VaultRef, VaultAccess> access, {
  VaultRef? current = _vaultA,
}) {
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
  return container;
}

/// Keeps the autoDispose reader and facade for [scope] alive.
void _listen(ProviderContainer c, GraphScope scope) {
  c.listen(graphDataAsyncProvider(scope), (_, _) {});
  c.listen(graphDataProvider(scope), (_, _) {});
}

GraphData _facade(ProviderContainer c, GraphScope scope) =>
    c.read(graphDataProvider(scope));

Set<String> _ids(GraphData g) => g.nodes.map((n) => n.id).toSet();

Set<EdgeTuple> _edges(GraphData g) =>
    g.edges.map((e) => (e.from, e.to, e.kind, e.label)).toSet();

Set<String> _hullIds(GraphData g) => g.hulls.map((h) => h.folderId).toSet();

void _switchTo(ProviderContainer c, VaultRef? vault) =>
    c.read(currentVaultProvider.notifier).state = vault;

void _bump(ProviderContainer c) =>
    c.read(vaultRevisionProvider.notifier).state++;

void main() {
  group('graph data through VaultAccess (AC1)', () {
    for (final (name, scope, nodes, edges, hulls)
        in <(String, GraphScope, Set<String>, Set<EdgeTuple>, Set<String>)>[
          (
            'the graph data async provider reads the Whole vault scope through VaultAccess',
            const GraphScope.vault(),
            G.allNotes,
            graphFixtureEdges,
            {G.projects, G.research, G.deep, G.archive},
          ),
          (
            'the graph data async provider reads a Smart Folder scope through VaultAccess',
            const GraphScope.folder(G.projects),
            {G.alpha, G.beta, G.gamma, G.loose},
            {
              (G.alpha, G.beta, 'extends', 'builds on'),
              (G.beta, G.gamma, 'references', null),
            },
            {G.projects, G.research, G.deep, G.archive},
          ),
          (
            'the graph data async provider reads a topic scope through VaultAccess',
            const GraphScope.topic(G.alpha),
            {G.alpha, G.beta, G.epsilon, G.day0905},
            {
              (G.alpha, G.beta, 'extends', 'builds on'),
              (G.epsilon, G.alpha, 'references', null),
              (G.alpha, G.day0905, 'from-day', null),
              (G.beta, G.day0905, 'from-day', null),
              (G.day0905, G.alpha, 'about', null),
            },
            {G.projects, G.archive},
          ),
          (
            'the graph data async provider reads a day scope through VaultAccess',
            const GraphScope.day(G.day0905),
            {G.day0905, G.alpha, G.gamma, G.beta},
            {
              (G.alpha, G.beta, 'extends', 'builds on'),
              (G.beta, G.gamma, 'references', null),
              (G.alpha, G.day0905, 'from-day', null),
              (G.beta, G.day0905, 'from-day', null),
              (G.day0905, G.alpha, 'about', null),
              (G.day0905, G.gamma, 'about', null),
            },
            {G.projects, G.research, G.archive},
          ),
        ]) {
      test(name, () async {
        final db = _db(seedGraphFixture);
        final c = _container({
          _vaultA: LocalVaultAccess(vaultPath: _vaultA.path, db: db),
        });
        _listen(c, scope);

        final scoped = await c.read(graphDataAsyncProvider(scope).future);

        expect(scoped.vault, _vaultA, reason: 'stamped with the open vault');
        expect(_ids(scoped.value), nodes);
        expect(_edges(scoped.value), edges);
        expect(_hullIds(scoped.value), hulls);
        final facade = _facade(c, scope);
        expect(_ids(facade), nodes, reason: 'the facade shows the same graph');
        expect(_edges(facade), edges);
        expect(_hullIds(facade), hulls);
      });
    }
  });

  group('graph data facade (AC3)', () {
    test(
      'with no vault open the graph data facade is GraphData.empty',
      () async {
        final db = _db(seedGraphFixture);
        final c = _container({
          _vaultA: LocalVaultAccess(vaultPath: _vaultA.path, db: db),
        }, current: null);
        const scope = GraphScope.vault();
        _listen(c, scope);

        final scoped = await c.read(graphDataAsyncProvider(scope).future);

        expect(scoped.vault, isNull);
        expect(scoped.value.nodes, isEmpty);
        expect(scoped.value.edges, isEmpty);
        expect(scoped.value.hulls, isEmpty);
        expect(_facade(c, scope), same(GraphData.empty));
      },
    );

    test(
      'before the first load completes the graph data facade is GraphData.empty',
      () async {
        final db = _db(seedGraphFixture);
        final graph = Wi88GatedGraph(vaultPath: _vaultA.path, db: db);
        final c = _container({
          _vaultA: LocalVaultAccess(
            vaultPath: _vaultA.path,
            db: db,
            graph: graph,
          ),
        });
        const scope = GraphScope.vault();
        _listen(c, scope);
        await pumpEventQueue();

        expect(graph.pending, 1, reason: 'the first read is in flight');
        expect(c.read(graphDataAsyncProvider(scope)).isLoading, isTrue);
        expect(_facade(c, scope), same(GraphData.empty));

        graph.release();
        await c.read(graphDataAsyncProvider(scope).future);

        expect(_ids(_facade(c, scope)), G.allNotes);
      },
    );

    test(
      'a revision bump keeps the previous graph in the facade until the reload arrives',
      () async {
        final db = _db((db) {
          db.seedTopicNote(G.alpha, 'Alpha');
          db.seedTopicNote(G.beta, 'Beta');
        });
        final graph = Wi88GatedGraph(vaultPath: _vaultA.path, db: db);
        final c = _container({
          _vaultA: LocalVaultAccess(
            vaultPath: _vaultA.path,
            db: db,
            graph: graph,
          ),
        });
        const scope = GraphScope.vault();
        _listen(c, scope);
        await pumpEventQueue();
        graph.release();
        await c.read(graphDataAsyncProvider(scope).future);
        expect(_ids(_facade(c, scope)), {G.alpha, G.beta});

        db.seedTopicNote(G.gamma, 'Gamma');
        _bump(c);
        await pumpEventQueue();

        expect(graph.calls, 2, reason: 'a revision bump re-reads the graph');
        expect(graph.pending, 1);
        expect(_ids(_facade(c, scope)), {
          G.alpha,
          G.beta,
        }, reason: 'a same-vault reload keeps the previous graph');

        graph.release();
        await pumpEventQueue();

        expect(_ids(_facade(c, scope)), {G.alpha, G.beta, G.gamma});
      },
    );

    test(
      'a failed first graph read leaves the graph data facade empty',
      () async {
        final db = _db(seedGraphFixture);
        final graph = Wi88GatedGraph(vaultPath: _vaultA.path, db: db);
        final c = _container({
          _vaultA: LocalVaultAccess(
            vaultPath: _vaultA.path,
            db: db,
            graph: graph,
          ),
        });
        const scope = GraphScope.vault();
        _listen(c, scope);
        await pumpEventQueue();

        graph.fail(StateError('vault server unreachable'));
        await pumpEventQueue();

        expect(c.read(graphDataAsyncProvider(scope)).hasError, isTrue);
        expect(_facade(c, scope), same(GraphData.empty));
      },
    );
  });

  group('vault switch (AC5, D14a)', () {
    for (final (name, target) in <(String, VaultRef)>[
      ('switching vaults never shows the previous vault rows', _vaultB),
      (
        'switching to a hosted vault never shows the previous vault rows',
        _hostedB,
      ),
    ]) {
      test(name, () async {
        final dbA = _db(seedGraphFixture);
        final dbB = _db(_seedVaultB);
        final graphB = Wi88GatedGraph(vaultPath: '/tmp/om-88-b', db: dbB);
        final c = _container({
          _vaultA: LocalVaultAccess(vaultPath: _vaultA.path, db: dbA),
          target: LocalVaultAccess(
            vaultPath: '/tmp/om-88-b',
            db: dbB,
            graph: graphB,
          ),
        });
        const scope = GraphScope.vault();
        _listen(c, scope);
        await c.read(graphDataAsyncProvider(scope).future);
        expect(_ids(_facade(c, scope)), G.allNotes);

        _switchTo(c, target);
        await pumpEventQueue();

        expect(graphB.pending, 1, reason: 'the new vault read is in flight');
        final facade = _facade(c, scope);
        expect(
          _ids(facade).intersection(G.allNotes),
          isEmpty,
          reason: 'no node of the previous vault',
        );
        expect(facade, same(GraphData.empty));
        expect(
          currentVaultData(
            c.read(graphDataAsyncProvider(scope)),
            c.read(currentVaultProvider),
          ),
          isNull,
          reason: 'the async value holds no data for the new vault yet',
        );

        graphB.release();
        await pumpEventQueue();

        final scoped = c.read(graphDataAsyncProvider(scope)).requireValue;
        expect(scoped.vault, target);
        expect(_ids(scoped.value), {'b-one', 'b-two'});
        expect(_ids(_facade(c, scope)), {'b-one', 'b-two'});
      });
    }
  });

  group('graph tab title through VaultAccess (AC7)', () {
    VaultAccess access({
      Map<String, String> noteTitles = const {},
      Set<String> hiddenNotes = const {},
      Map<String, String> folderNames = const {},
      Set<String> hiddenFolders = const {},
    }) {
      final db = _db(seedGraphFixture);
      const path = '/tmp/om-88-title';
      return LocalVaultAccess(
        vaultPath: path,
        db: db,
        notes: Wi88RewritingNotes(
          vaultPath: path,
          db: db,
          titles: noteTitles,
          hidden: hiddenNotes,
        ),
        topics: Wi88RewritingTopics(
          vaultPath: path,
          db: db,
          names: folderNames,
          hidden: hiddenFolders,
        ),
      );
    }

    test(
      'the graph tab title reads the folder name through VaultAccess',
      () async {
        expect(
          await graphTabTitle(
            access(folderNames: {G.projects: 'Projects via access'}),
            const GraphScope.folder(G.projects),
          ),
          'Graph · Projects via access',
        );
        expect(
          await graphTabTitle(access(), const GraphScope.folder(G.research)),
          'Graph · Research',
        );
      },
    );

    test(
      'the graph tab title reads the note title through VaultAccess',
      () async {
        final a = access(noteTitles: {G.alpha: 'Alpha via access'});
        expect(
          await graphTabTitle(a, const GraphScope.topic(G.alpha)),
          'Graph · Alpha via access',
        );
        expect(
          await graphTabTitle(a, const GraphScope.day(G.day0905)),
          'Graph · 2026-09-05',
        );
      },
    );

    test('the graph tab title reads Whole vault for the vault scope', () async {
      expect(
        await graphTabTitle(access(), const GraphScope.vault()),
        'Graph · Whole vault',
      );
      expect(
        await graphTabTitle(null, const GraphScope.vault()),
        'Graph · Whole vault',
      );
    });

    test(
      'the graph tab title falls back to the scope id when the folder or note is gone',
      () async {
        final a = access(hiddenNotes: {G.alpha}, hiddenFolders: {G.projects});
        expect(
          await graphTabTitle(a, const GraphScope.folder(G.projects)),
          'Graph · ${G.projects}',
        );
        expect(
          await graphTabTitle(a, const GraphScope.topic(G.alpha)),
          'Graph · ${G.alpha}',
        );
        expect(
          await graphTabTitle(a, const GraphScope.day('day-missing')),
          'Graph · day-missing',
        );
        expect(
          await graphTabTitle(a, const GraphScope.folder('sf-missing')),
          'Graph · sf-missing',
        );
      },
    );

    test(
      'the graph tab title falls back to the scope id with no vault open',
      () async {
        expect(
          await graphTabTitle(null, const GraphScope.folder(G.projects)),
          'Graph · ${G.projects}',
        );
        expect(
          await graphTabTitle(null, const GraphScope.topic(G.alpha)),
          'Graph · ${G.alpha}',
        );
        expect(
          await graphTabTitle(null, const GraphScope.day(G.day0905)),
          'Graph · ${G.day0905}',
        );
      },
    );
  });
}
