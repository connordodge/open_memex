// WI #30 (A12): the Graph scope builder (Req 64, TS5). Node, edge and hull
// sets only, never positions. Runs against the real V5 schema (FakeVaultDb)
// seeded by test/support/graph_seeds.dart.
//
// WI #88 (W4): buildGraph reads through VaultAccess (a LocalVaultAccess over
// the FakeVaultDb) and is async; the call sites await it (TEST-CHANGE,
// forced signature).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';

import '../support/daily_seed.dart';
import '../support/fake_vault_db.dart';
import '../support/graph_access_doubles.dart';
import '../support/graph_seeds.dart';

const _vaultPath = '/tmp/om-88-graph-scope';

VaultAccess _fixture() {
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  seedGraphFixture(db);
  return LocalVaultAccess(vaultPath: _vaultPath, db: db);
}

Set<String> _ids(GraphData g) => g.nodes.map((n) => n.id).toSet();

Set<EdgeTuple> _edges(GraphData g) =>
    g.edges.map((e) => (e.from, e.to, e.kind, e.label)).toSet();

Map<String, Set<String>> _hulls(GraphData g) => {
  for (final h in g.hulls) h.folderId: h.memberIds.toSet(),
};

GraphNode _node(GraphData g, String id) => g.nodes.singleWhere(
  (n) => n.id == id,
  orElse: () => fail('no node $id in ${_ids(g)}'),
);

GraphHull _hull(GraphData g, String folderId) => g.hulls.singleWhere(
  (h) => h.folderId == folderId,
  orElse: () => fail('no hull $folderId'),
);

void _expectNoDuplicates(GraphData g) {
  expect(g.nodes.length, _ids(g).length, reason: 'each note is one node');
  expect(g.edges.length, _edges(g).length, reason: 'each link is one edge');
  expect(
    g.hulls.length,
    _hulls(g).length,
    reason: 'each Smart Folder is one hull',
  );
}

void main() {
  group('Smart Folder scope (AC1)', () {
    test(
      'a Smart Folder scope returns its members and the members of its descendant folders',
      () async {
        final g = await buildGraph(
          _fixture(),
          const GraphScope.folder(G.projects),
        );
        expect(_ids(g), {G.alpha, G.beta, G.gamma, G.loose});
        _expectNoDuplicates(g);
      },
    );

    test(
      'a Smart Folder scope returns exactly the links between its nodes as edges',
      () async {
        final g = await buildGraph(
          _fixture(),
          const GraphScope.folder(G.projects),
        );
        expect(_edges(g), {
          (G.alpha, G.beta, 'extends', 'builds on'),
          (G.beta, G.gamma, 'references', null),
        });
      },
    );

    test(
      'a child Smart Folder scope leaves out the members of its parent folder',
      () async {
        final g = await buildGraph(
          _fixture(),
          const GraphScope.folder(G.research),
        );
        expect(_ids(g), {G.gamma, G.loose});
        expect(_edges(g), isEmpty, reason: 'Beta to Gamma leaves the scope');
      },
    );

    test('a Smart Folder scope for an unknown folder is empty', () async {
      final g = await buildGraph(
        _fixture(),
        const GraphScope.folder('sf-missing'),
      );
      expect(g.nodes, isEmpty);
      expect(g.edges, isEmpty);
      expect(g.hulls, isEmpty);
    });
  });

  group('topic scope (AC2)', () {
    test(
      'a topic scope returns the topic, its 1-hop neighbours in both directions and the daily notes it transcludes',
      () async {
        final g = await buildGraph(_fixture(), const GraphScope.topic(G.alpha));
        expect(_ids(g), {G.alpha, G.beta, G.epsilon, G.day0905});
        _expectNoDuplicates(g);
      },
    );

    test(
      'a topic scope returns the links among its nodes including links between two neighbours',
      () async {
        final g = await buildGraph(_fixture(), const GraphScope.topic(G.alpha));
        expect(_edges(g), {
          (G.alpha, G.beta, 'extends', 'builds on'),
          (G.epsilon, G.alpha, 'references', null),
          (G.alpha, G.day0905, 'from-day', null),
          (G.beta, G.day0905, 'from-day', null),
          (G.day0905, G.alpha, 'about', null),
        });
      },
    );

    test('a topic scope leaves out notes two hops away', () async {
      final g = await buildGraph(_fixture(), const GraphScope.topic(G.gamma));
      // Gamma: Beta links in, Gamma links out to Delta, 2026-09-05 links in
      // (about). Alpha, Epsilon and 2026-09-06 are two hops away.
      expect(_ids(g), {G.gamma, G.beta, G.delta, G.day0905});
      expect(_edges(g), {
        (G.beta, G.gamma, 'references', null),
        (G.gamma, G.delta, 'references', null),
        (G.beta, G.day0905, 'from-day', null),
        (G.day0905, G.gamma, 'about', null),
      });
    });

    test('a topic scope for a missing note is empty', () async {
      final g = await buildGraph(
        _fixture(),
        const GraphScope.topic('note-missing'),
      );
      expect(g.nodes, isEmpty);
      expect(g.edges, isEmpty);
      expect(g.hulls, isEmpty);
    });
  });

  group('day scope (AC3)', () {
    test(
      'a day scope returns the daily note, its footer topics and the topics that transclude it',
      () async {
        final g = await buildGraph(_fixture(), const GraphScope.day(G.day0905));
        // Footer: Alpha, Gamma. Transcluders: Alpha, Beta.
        expect(_ids(g), {G.day0905, G.alpha, G.gamma, G.beta});
        _expectNoDuplicates(g);
      },
    );

    test('a day scope returns the links among its nodes', () async {
      final g = await buildGraph(_fixture(), const GraphScope.day(G.day0905));
      expect(_edges(g), {
        (G.alpha, G.beta, 'extends', 'builds on'),
        (G.beta, G.gamma, 'references', null),
        (G.alpha, G.day0905, 'from-day', null),
        (G.beta, G.day0905, 'from-day', null),
        (G.day0905, G.alpha, 'about', null),
        (G.day0905, G.gamma, 'about', null),
      });
    });

    test(
      'a day scope leaves out notes that link to the day with a plain wikilink',
      () async {
        final g = await buildGraph(_fixture(), const GraphScope.day(G.day0905));
        expect(_ids(g), isNot(contains(G.loose)));
        expect(_ids(g), isNot(contains(G.epsilon)));
      },
    );

    test(
      'a topic that is both a footer chip and a transcluder appears once in a day scope',
      () async {
        final g = await buildGraph(_fixture(), const GraphScope.day(G.day0906));
        expect(
          g.nodes.map((n) => n.id).toList()..sort(),
          [G.day0906, G.delta]..sort(),
        );
        expect(_edges(g), {
          (G.delta, G.day0906, 'from-day', null),
          (G.day0906, G.delta, 'about', null),
        });
      },
    );

    test(
      'a day with no footer chips and no transclusions is a single node',
      () async {
        final g = await buildGraph(_fixture(), const GraphScope.day(G.day0907));
        expect(_ids(g), {G.day0907});
        expect(g.edges, isEmpty);
        expect(g.hulls, isEmpty);
      },
    );
  });

  group('Whole vault scope (AC4)', () {
    test('the Whole vault scope returns every note', () async {
      final g = await buildGraph(_fixture(), const GraphScope.vault());
      expect(_ids(g), G.allNotes);
      _expectNoDuplicates(g);
    });

    test(
      'the Whole vault scope returns every link that has a target',
      () async {
        final g = await buildGraph(_fixture(), const GraphScope.vault());
        expect(_edges(g), graphFixtureEdges);
        expect(g.edges.length, graphFixtureEdges.length);
      },
    );
  });

  group('node kinds, labels, hulls and pinned flags (AC5)', () {
    test('nodes carry kind daily, topic or note by role', () async {
      final g = await buildGraph(_fixture(), const GraphScope.vault());
      final kinds = {for (final n in g.nodes) n.id: n.kind};
      expect(kinds, {
        G.day0905: GraphNodeKind.daily,
        G.day0906: GraphNodeKind.daily,
        G.day0907: GraphNodeKind.daily,
        G.alpha: GraphNodeKind.topic,
        G.beta: GraphNodeKind.topic,
        G.gamma: GraphNodeKind.topic,
        G.delta: GraphNodeKind.topic,
        G.epsilon: GraphNodeKind.topic,
        G.loose: GraphNodeKind.note,
        G.badFrontmatter: GraphNodeKind.note,
        G.otherRole: GraphNodeKind.note,
      });
    });

    test('daily nodes are labelled by date and other nodes by title', () async {
      final g = await buildGraph(_fixture(), const GraphScope.vault());
      expect(_node(g, G.day0905).label, '2026-09-05');
      expect(_node(g, G.day0907).label, '2026-09-07');
      expect(_node(g, G.alpha).label, 'Alpha');
      expect(_node(g, G.loose).label, 'Loose idea');
      expect(_node(g, G.badFrontmatter).label, 'Bad frontmatter');
    });

    test(
      'hulls list every Smart Folder with at least one member in a topic scope',
      () async {
        final g = await buildGraph(_fixture(), const GraphScope.topic(G.alpha));
        expect(_hulls(g), {
          G.projects: {G.alpha, G.beta},
          G.archive: {G.beta},
        });
      },
    );

    test(
      'hulls in a Smart Folder scope include other folders that share a member',
      () async {
        final g = await buildGraph(
          _fixture(),
          const GraphScope.folder(G.projects),
        );
        expect(_hulls(g), {
          G.projects: {G.alpha, G.beta},
          G.research: {G.gamma},
          G.deep: {G.loose},
          G.archive: {G.beta},
        });
      },
    );

    test('hull names and pinned flags come from smart_folders', () async {
      final g = await buildGraph(_fixture(), const GraphScope.vault());
      expect(_hull(g, G.projects).name, 'Projects');
      expect(_hull(g, G.research).name, 'Research');
      expect(_hull(g, G.archive).name, 'Archive');
      expect(_hull(g, G.projects).pinned, isTrue);
      expect(_hull(g, G.research).pinned, isFalse);
      expect(_hull(g, G.deep).pinned, isFalse);
      expect(_hull(g, G.archive).pinned, isFalse);
      expect(_hulls(g), {
        G.projects: {G.alpha, G.beta},
        G.research: {G.gamma},
        G.deep: {G.loose},
        G.archive: {G.delta, G.beta},
      });
    });

    test('node pinned flags come from smart_folder_members.pinned', () async {
      final g = await buildGraph(_fixture(), const GraphScope.vault());
      final pinned = {
        for (final n in g.nodes)
          if (n.pinned) n.id,
      };
      // Alpha: pinned in Projects. Beta: unpinned in Projects, pinned in
      // Archive. Everything else is unpinned or has no membership.
      expect(pinned, {G.alpha, G.beta});
    });

    test('a scope with no Smart Folder members has no hulls', () async {
      final g = await buildGraph(_fixture(), const GraphScope.day(G.day0907));
      expect(g.hulls, isEmpty);
    });
  });

  group('vault below V5', () {
    VaultAccess v4() {
      final db = FakeVaultDb.v4();
      addTearDown(db.close);
      db.seedDailyNote('2026-09-05', id: G.day0905);
      db.seedTopicNote(G.alpha, 'Alpha');
      db.seedTopicNote(G.beta, 'Beta');
      db.seedLink(G.alpha, G.beta, kind: 'extends', label: 'builds on');
      db.seedLink(G.alpha, G.day0905, kind: 'from-day');
      return LocalVaultAccess(vaultPath: _vaultPath, db: db);
    }

    test(
      'on a vault below V5 the Whole vault scope returns notes and links without hulls',
      () async {
        final g = await buildGraph(v4(), const GraphScope.vault());
        expect(_ids(g), {G.day0905, G.alpha, G.beta});
        expect(_edges(g), {
          (G.alpha, G.beta, 'extends', 'builds on'),
          (G.alpha, G.day0905, 'from-day', null),
        });
        expect(g.hulls, isEmpty);
        expect(_node(g, G.day0905).kind, GraphNodeKind.daily);
        expect(g.nodes.where((n) => n.pinned), isEmpty);
      },
    );

    test('on a vault below V5 a Smart Folder scope is empty', () async {
      final g = await buildGraph(v4(), const GraphScope.folder(G.projects));
      expect(g.nodes, isEmpty);
      expect(g.edges, isEmpty);
      expect(g.hulls, isEmpty);
    });

    test(
      'on a vault below V5 a day scope returns the day and the topics that transclude it',
      () async {
        final g = await buildGraph(v4(), const GraphScope.day(G.day0905));
        expect(_ids(g), {G.day0905, G.alpha});
        expect(_edges(g), {(G.alpha, G.day0905, 'from-day', null)});
      },
    );
  });

  // WI #88 (W4) AC2: a missing scope target never throws.
  group('missing scope targets (WI 88)', () {
    test('a day scope for a missing note is empty', () async {
      final g = await buildGraph(
        _fixture(),
        const GraphScope.day('day-missing'),
      );
      expect(g.nodes, isEmpty);
      expect(g.edges, isEmpty);
      expect(g.hulls, isEmpty);
    });

    test(
      'a day scope whose footer topic is missing yields a partial graph',
      () async {
        final db = FakeVaultDb.v5();
        addTearDown(db.close);
        seedGraphFixture(db);
        final access = LocalVaultAccess(
          vaultPath: _vaultPath,
          db: db,
          daily: Wi88ExtraChipsDaily(
            vaultPath: _vaultPath,
            db: db,
            extraChips: {
              G.day0907: [
                const FooterChipRow(
                  topicNoteId: 'topic-missing',
                  topicTitle: 'Gone',
                  origin: 'agent',
                ),
                const FooterChipRow(
                  topicNoteId: G.epsilon,
                  topicTitle: 'Epsilon',
                  origin: 'agent',
                ),
              ],
            },
          ),
        );
        final g = await buildGraph(access, const GraphScope.day(G.day0907));
        expect(_ids(g), {G.day0907, G.epsilon});
        expect(g.edges, isEmpty);
      },
    );

    test('a vault with no database handle yields an empty graph', () async {
      final access = LocalVaultAccess(vaultPath: _vaultPath);
      for (final scope in const [
        GraphScope.vault(),
        GraphScope.folder(G.projects),
        GraphScope.topic(G.alpha),
        GraphScope.day(G.day0905),
      ]) {
        final g = await buildGraph(access, scope);
        expect(g.nodes, isEmpty, reason: '$scope');
        expect(g.edges, isEmpty, reason: '$scope');
        expect(g.hulls, isEmpty, reason: '$scope');
      }
    });
  });
}
