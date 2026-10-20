// WI #70 (W0a): a seeded vault touching every table the app reads, and one
// case per VaultAccess read pairing it with the VaultDb method it mirrors.
// Raw inserts against the real V5 schema; nothing here goes through
// production read code.
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/activity_reads.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/db/graph_reads.dart';
import 'package:open_memex_app/src/db/topics_reads.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';

import 'activity_seeds.dart';
import 'daily_seed.dart';
import 'fake_vault_db.dart';
import 'graph_seeds.dart';

/// Ids the [seedVaultAccessFixture] adds on top of the Graph fixture.
abstract final class VA {
  static const tagged = 'note-tagged';
  static const canvas = 'cv-70';
  static const emptyCanvas = 'cv-70-empty';
  static const missing = 'no-such-id';
}

/// The Graph fixture (notes, links incl. a ghost, Smart Folders, footer
/// chips, three daily notes) plus a tagged note, blocks and a review on
/// 2026-09-05, an agent change on Alpha, and two canvases (one with three
/// placed notes and their edges, one empty).
FakeVaultDb seedVaultAccessFixture(FakeVaultDb db) {
  seedGraphFixture(db);
  db.seedNote(
    id: VA.tagged,
    title: 'Tagged note',
    content: '# Heading\n\nfirst body line',
    tags: const ['zeta', 'alpha'],
    version: 3,
    createdAt: 1759500000000,
    updatedAt: 1759590000000,
  );
  db.seedBlock(G.day0905, 'b1', ord: 0, text: 'first block\nsecond line');
  db.seedBlock(
    G.day0905,
    'b2',
    ord: 1,
    text: 'agent block',
    source: 'agent',
    startByte: 30,
  );
  db.seedDayReview(
    G.day0905,
    contentVersion: 2,
    reviewedContentVersion: 2,
    reviewedAt: 1759550000000,
  );
  db.seedDayReview(
    G.day0906,
    contentVersion: 3,
    reviewedContentVersion: 2,
    reviewedAt: 1759540000000,
  );
  db.seedAgentChange(
    'ac-1',
    G.alpha,
    day: '2026-09-05',
    createdAt: 1759560000000,
    bullets: const ['linked Beta', 'renamed'],
  );
  db.seedAgentChange(
    'ac-2',
    G.alpha,
    day: '2026-09-06',
    createdAt: 1759570000000,
    bullets: const ['added a section'],
  );
  db.db.execute(
    'INSERT INTO canvases (id, title, created_at, updated_at, version) '
    'VALUES (?, ?, ?, ?, ?), (?, ?, ?, ?, ?)',
    [
      VA.canvas, 'Board', 1759500000000, 1759580000000, 4, //
      VA.emptyCanvas, 'Empty board', 1759500000000, 1759500000001, 1,
    ],
  );
  for (final (note, x, y, z) in [
    (G.alpha, 10.5, -20.0, 2),
    (G.beta, 300.0, 40.25, 0),
    (G.gamma, -5.0, 12.0, 1),
  ]) {
    db.db.execute(
      'INSERT INTO canvas_nodes (canvas_id, note_id, x, y, z_order, placed_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [VA.canvas, note, x, y, z, 1759500000000 + z],
    );
  }
  return db;
}

/// One VaultAccess read and the VaultDb call(s) it mirrors. [viaAccess] and
/// [viaDb] return the same structure (often a list of several calls, e.g. a
/// found and a missing id). [emptyShape] is the `vaultAccessShape` a vault
/// with no database gives (today's empty values); null means unpinned.
class VaultAccessReadCase {
  const VaultAccessReadCase(
    this.name,
    this.viaAccess,
    this.viaDb, {
    required this.emptyShape,
  });

  final String name;
  final Future<Object?> Function(VaultAccess a) viaAccess;
  final Object? Function(VaultDb db) viaDb;
  final Object? emptyShape;
}

/// Marker for [VaultAccessReadCase.emptyShape]: not pinned without a database.
const unpinnedWithoutDb = #unpinned;

/// Every read of the notes, daily, topics, canvas and graph domains, plus the
/// root `schemaVersion`, against [seedVaultAccessFixture].
final vaultAccessReadCases = <VaultAccessReadCase>[
  // ---------- notes ----------
  VaultAccessReadCase(
    'notes.listNotes',
    (a) async => [await a.notes.listNotes(), await a.notes.listNotes(limit: 2)],
    (db) => [db.listNotes(), db.listNotes(limit: 2)],
    emptyShape: [[], []],
  ),
  VaultAccessReadCase(
    'notes.getNote',
    (a) async => [
      await a.notes.getNote(VA.tagged),
      await a.notes.getNote(G.alpha),
      await a.notes.getNote(VA.missing),
    ],
    (db) => [
      db.getNote(VA.tagged),
      db.getNote(G.alpha),
      db.getNote(VA.missing),
    ],
    emptyShape: [null, null, null],
  ),
  VaultAccessReadCase(
    'notes.allTitles',
    (a) async => [await a.notes.allTitles(), await a.notes.allTitles(limit: 3)],
    (db) => [db.allTitles(), db.allTitles(limit: 3)],
    emptyShape: [[], []],
  ),
  VaultAccessReadCase(
    'notes.linksOutFor',
    (a) async => [
      await a.notes.linksOutFor(G.alpha),
      await a.notes.linksOutFor(G.epsilon),
    ],
    (db) => [db.linksOutFor(G.alpha), db.linksOutFor(G.epsilon)],
    emptyShape: [[], []],
  ),
  VaultAccessReadCase(
    'notes.linksInFor without kind',
    (a) async => [
      await a.notes.linksInFor(G.day0905),
      await a.notes.linksInFor(G.delta),
    ],
    (db) => [db.linksInFor(G.day0905), db.linksInFor(G.delta)],
    emptyShape: [[], []],
  ),
  VaultAccessReadCase(
    'notes.linksInFor with kind',
    (a) async => [
      await a.notes.linksInFor(G.day0905, kind: 'from-day'),
      await a.notes.linksInFor(G.delta, kind: 'contradicts'),
      await a.notes.linksInFor(G.delta, kind: 'no-such-kind'),
    ],
    (db) => [
      db.linksInFor(G.day0905, kind: 'from-day'),
      db.linksInFor(G.delta, kind: 'contradicts'),
      db.linksInFor(G.delta, kind: 'no-such-kind'),
    ],
    emptyShape: [[], [], []],
  ),
  VaultAccessReadCase(
    'notes.titlesForIds',
    (a) async => [
      await a.notes.titlesForIds([G.alpha, G.beta, VA.missing]),
      await a.notes.titlesForIds(const []),
    ],
    (db) => [
      db.titlesForIds([G.alpha, G.beta, VA.missing]),
      db.titlesForIds(const []),
    ],
    emptyShape: [{}, {}],
  ),
  VaultAccessReadCase(
    'notes.distinctLinkKinds',
    (a) => a.notes.distinctLinkKinds(),
    (db) => db.distinctLinkKinds(),
    emptyShape: [],
  ),
  // ---------- daily ----------
  VaultAccessReadCase(
    'daily.dailyNotes',
    (a) => a.daily.dailyNotes(),
    (db) => db.dailyNotes(),
    emptyShape: [],
  ),
  VaultAccessReadCase(
    'daily.dailyNoteForDate',
    (a) async => [
      await a.daily.dailyNoteForDate('2026-09-05'),
      await a.daily.dailyNoteForDate('2026-01-01'),
    ],
    (db) => [
      db.dailyNoteForDate('2026-09-05'),
      db.dailyNoteForDate('2026-01-01'),
    ],
    emptyShape: [null, null],
  ),
  VaultAccessReadCase(
    'daily.reviewState',
    (a) async => [
      await a.daily.reviewState(G.day0905),
      await a.daily.reviewState(G.day0906),
      await a.daily.reviewState(G.day0907),
    ],
    (db) => [
      db.reviewState(G.day0905),
      db.reviewState(G.day0906),
      db.reviewState(G.day0907),
    ],
    emptyShape: [null, null, null],
  ),
  VaultAccessReadCase(
    'daily.blocksForNote',
    (a) async => [
      await a.daily.blocksForNote(G.day0905),
      await a.daily.blocksForNote(G.day0907),
    ],
    (db) => [db.blocksForNote(G.day0905), db.blocksForNote(G.day0907)],
    emptyShape: [[], []],
  ),
  VaultAccessReadCase(
    'daily.footerChips',
    (a) async => [
      await a.daily.footerChips(G.day0905),
      await a.daily.footerChips(G.day0906),
    ],
    (db) => [db.footerChips(G.day0905), db.footerChips(G.day0906)],
    emptyShape: [[], []],
  ),
  // ---------- topics ----------
  VaultAccessReadCase(
    'topics.smartFolders',
    (a) => a.topics.smartFolders(),
    (db) => db.smartFolders(),
    emptyShape: {
      'SmartFolderData': [[], []],
    },
  ),
  VaultAccessReadCase(
    'topics.unsortedNotes',
    (a) => a.topics.unsortedNotes(),
    (db) => db.unsortedNotes(),
    emptyShape: [],
  ),
  // ---------- canvas ----------
  VaultAccessReadCase(
    'canvas.listCanvases',
    (a) => a.canvas.listCanvases(),
    (db) => db.listCanvases(),
    emptyShape: [],
  ),
  VaultAccessReadCase(
    'canvas.getCanvasDetail',
    (a) async => [
      await a.canvas.getCanvasDetail(VA.canvas),
      await a.canvas.getCanvasDetail(VA.emptyCanvas),
      await a.canvas.getCanvasDetail(VA.missing),
    ],
    (db) => [
      db.getCanvasDetail(VA.canvas),
      db.getCanvasDetail(VA.emptyCanvas),
      db.getCanvasDetail(VA.missing),
    ],
    emptyShape: [null, null, null],
  ),
  // ---------- graph ----------
  VaultAccessReadCase(
    'graph.graphNotes',
    (a) => a.graph.graphNotes(),
    (db) => db.graphNotes(),
    emptyShape: [],
  ),
  VaultAccessReadCase(
    'graph.graphLinks',
    (a) => a.graph.graphLinks(),
    (db) => db.graphLinks(),
    emptyShape: [],
  ),
  VaultAccessReadCase(
    'graph.agentChanges',
    (a) async => [
      await a.graph.agentChanges(G.alpha),
      await a.graph.agentChanges(G.beta),
    ],
    (db) => [db.agentChanges(G.alpha), db.agentChanges(G.beta)],
    emptyShape: [[], []],
  ),
  // ---------- root ----------
  VaultAccessReadCase(
    'schemaVersion',
    (a) => a.schemaVersion(),
    (db) => db.schemaVersion(),
    emptyShape: unpinnedWithoutDb,
  ),
];
