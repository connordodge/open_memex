// WI #89 (W5): canvas seeds and VaultAccess doubles for the canvas async
// migration tests. Raw inserts against the real V5 schema (FakeVaultDb);
// nothing here goes through production reads. Doubles `extends` the local
// domain classes (D21), never implement the interfaces.
import 'dart:async';

import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import 'fake_vault_db.dart';
import 'graph_seeds.dart';

/// Ids used by the canvas fixture and the doubles.
abstract final class C89 {
  static const newer = 'cv-89-newer';
  static const middle = 'cv-89-middle';
  static const older = 'cv-89-older';
  static const tieA = 'cv-89-tie-a';
  static const tieB = 'cv-89-tie-b';

  static const alpha = 'n-89-alpha';
  static const beta = 'n-89-beta';
  static const gamma = 'n-89-gamma';

  /// The link Alpha -> Beta placed on [newer].
  static const link = 'l-89-ab';
}

extension CanvasSeed on FakeVaultDb {
  /// One `canvases` row.
  void seedCanvas(
    String id,
    String title, {
    int createdAt = 1759500000000,
    required int updatedAt,
    int version = 1,
  }) {
    db.execute(
      'INSERT INTO canvases (id, title, created_at, updated_at, version) '
      'VALUES (?, ?, ?, ?, ?)',
      [id, title, createdAt, updatedAt, version],
    );
  }

  /// One `canvas_nodes` row (the note must exist).
  void seedCanvasNode(
    String canvasId,
    String noteId, {
    required double x,
    required double y,
    int zOrder = 0,
    int placedAt = 1759500000000,
  }) {
    db.execute(
      'INSERT INTO canvas_nodes (canvas_id, note_id, x, y, z_order, placed_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [canvasId, noteId, x, y, zOrder, placedAt],
    );
  }

  /// Drops the canvas tables, like a vault that predates V4.
  void dropCanvasTables() {
    db.execute('DROP TABLE canvas_nodes');
    db.execute('DROP TABLE canvases');
  }
}

/// Three notes and five canvases, inserted out of order:
/// - [C89.newer] (`updated_at` 300): Alpha at (10.5, 20) z 1 and Beta at
///   (300, 40.25) z 0, plus the link Alpha -> Beta (`references`, label
///   `ties`), so its nodes list Beta before Alpha;
/// - [C89.middle] (200): Gamma;
/// - [C89.older] (100): empty;
/// - [C89.tieA] and [C89.tieB] (both 50): empty, a tie broken by id.
FakeVaultDb seedCanvasFixture(FakeVaultDb db) {
  db.seedNote(id: C89.alpha, title: 'Alpha');
  db.seedNote(id: C89.beta, title: 'Beta');
  db.seedNote(id: C89.gamma, title: 'Gamma');
  db.seedCanvas(C89.middle, 'Middle', updatedAt: 200, version: 2);
  db.seedCanvas(C89.tieB, 'Tie B', updatedAt: 50);
  db.seedCanvas(C89.newer, 'Newer', updatedAt: 300, version: 4);
  db.seedCanvas(C89.older, 'Older', updatedAt: 100);
  db.seedCanvas(C89.tieA, 'Tie A', updatedAt: 50);
  db.seedCanvasNode(C89.newer, C89.alpha, x: 10.5, y: 20, zOrder: 1);
  db.seedCanvasNode(C89.newer, C89.beta, x: 300, y: 40.25, zOrder: 0);
  db.seedCanvasNode(C89.middle, C89.gamma, x: 0, y: 0);
  db.seedLink(
    C89.alpha,
    C89.beta,
    id: C89.link,
    kind: 'references',
    label: 'ties',
  );
  return db;
}

/// A [CanvasRow] built at run time.
CanvasRow wi89CanvasRow(String id, String title, {int nodeCount = 0}) =>
    CanvasRow(
      canvasId: id,
      title: title,
      createdAt: 1759500000000,
      updatedAt: 1759500000000,
      version: 1,
      nodeCount: nodeCount,
    );

/// A [CanvasNodeRow] built at run time.
CanvasNodeRow wi89Node(
  String noteId,
  String title,
  double x,
  double y, {
  int zOrder = 0,
}) => CanvasNodeRow(
  noteId: noteId,
  noteTitle: title,
  x: x,
  y: y,
  zOrder: zOrder,
  placedAt: 1759500000000 + zOrder,
);

/// A [CanvasEdgeRow] built at run time.
CanvasEdgeRow wi89Edge(
  String linkId,
  String from,
  String to, {
  String kind = 'references',
  String? label,
}) => CanvasEdgeRow(
  linkId: linkId,
  fromNoteId: from,
  toNoteId: to,
  linkText: to,
  kind: kind,
  label: label,
  position: 0,
  source: 'inline_body',
);

/// A [CanvasDetailRow] built at run time.
CanvasDetailRow wi89Detail(
  String canvasId, {
  String title = 'Board',
  List<CanvasNodeRow> nodes = const [],
  List<CanvasEdgeRow> edges = const [],
}) => CanvasDetailRow(
  canvasId: canvasId,
  title: title,
  createdAt: 1759500000000,
  updatedAt: 1759500000001,
  version: 1,
  nodes: nodes,
  edges: edges,
);

/// The detail the view tests open: Alpha at (10, 20) and Beta at (300, 40)
/// with one edge Alpha -> Beta (`references`, label `ties`).
CanvasDetailRow wi89BoardDetail(String canvasId) => wi89Detail(
  canvasId,
  nodes: [
    wi89Node(C89.alpha, 'Alpha', 10, 20),
    wi89Node(C89.beta, 'Beta', 300, 40, zOrder: 1),
  ],
  edges: [wi89Edge(C89.link, C89.alpha, C89.beta, label: 'ties')],
);

typedef Wi89Move = ({
  String canvasId,
  String noteId,
  double x,
  double y,
  int? zOrder,
});
typedef Wi89Add = ({String canvasId, String noteId, double x, double y});

/// A canvas domain that serves [canvases] and [details], optionally holds
/// every read on a [Completer], and records (then optionally fails) every
/// write instead of running the CLI.
class Wi89Canvas extends LocalCanvasAccess {
  Wi89Canvas({
    super.vaultPath = '/tmp/om-89-vault',
    this.canvases = const [],
    Map<String, CanvasDetailRow?>? details,
  }) : details = details ?? {};

  /// What `listCanvases` returns when [hold] is false.
  List<CanvasRow> canvases;

  /// What `getCanvasDetail` returns per id when [hold] is false (null for a
  /// missing key).
  final Map<String, CanvasDetailRow?> details;

  /// While true each read waits on a new gate in [heldLists] /
  /// [heldDetails] instead of answering.
  bool hold = false;

  int listCalls = 0;
  final heldLists = <Completer<List<CanvasRow>>>[];
  final detailCalls = <String>[];
  final heldDetails = <Completer<CanvasDetailRow?>>[];

  /// Every `moveNode` / `addToCanvas`, recorded before any [writeError].
  final moves = <Wi89Move>[];
  final adds = <Wi89Add>[];

  /// Thrown by every write after it is recorded.
  Object? writeError;

  @override
  Future<List<CanvasRow>> listCanvases() {
    listCalls++;
    if (!hold) return Future.value(canvases);
    final gate = Completer<List<CanvasRow>>();
    heldLists.add(gate);
    return gate.future;
  }

  @override
  Future<CanvasDetailRow?> getCanvasDetail(String canvasId) {
    detailCalls.add(canvasId);
    if (!hold) return Future.value(details[canvasId]);
    final gate = Completer<CanvasDetailRow?>();
    heldDetails.add(gate);
    return gate.future;
  }

  @override
  Future<CanvasNodeInfo> moveNode({
    required String canvasId,
    required String noteId,
    required double x,
    required double y,
    int? zOrder,
  }) async {
    moves.add((canvasId: canvasId, noteId: noteId, x: x, y: y, zOrder: zOrder));
    if (writeError != null) throw writeError!;
    return CanvasNodeInfo(
      canvasId: canvasId,
      noteId: noteId,
      noteTitle: 'moved',
      x: x,
      y: y,
      zOrder: zOrder ?? 0,
      placedAt: 1759500000000,
    );
  }

  @override
  Future<CanvasNodeInfo> addToCanvas({
    required String canvasId,
    required String noteId,
    double x = 0.0,
    double y = 0.0,
  }) async {
    adds.add((canvasId: canvasId, noteId: noteId, x: x, y: y));
    if (writeError != null) throw writeError!;
    return CanvasNodeInfo(
      canvasId: canvasId,
      noteId: noteId,
      noteTitle: 'placed',
      x: x,
      y: y,
      zOrder: 0,
      placedAt: 1759500000000,
    );
  }
}

typedef Wi89AddedLink = ({String from, String to, String kind, String? label});
typedef Wi89UpdatedLink = ({
  String linkId,
  String? kind,
  String? label,
  bool clearLabel,
});

/// A notes domain that records (then optionally fails) `addLink` and
/// `updateLink` instead of running the CLI. Every other method keeps the
/// local behaviour.
class Wi89Notes extends LocalNotesAccess {
  Wi89Notes({super.vaultPath = '/tmp/om-89-vault'});

  final addedLinks = <Wi89AddedLink>[];
  final updatedLinks = <Wi89UpdatedLink>[];

  /// Thrown by both writes after they are recorded.
  Object? writeError;

  @override
  Future<AddLinkResult> addLink({
    required String fromNoteId,
    required String toNoteId,
    String kind = 'references',
    String? label,
  }) async {
    addedLinks.add((from: fromNoteId, to: toNoteId, kind: kind, label: label));
    if (writeError != null) throw writeError!;
    return AddLinkResult(
      linkId: 'l-89-new',
      fromNoteId: fromNoteId,
      toNoteId: toNoteId,
      kind: kind,
      source: 'inline_body',
      wasExisting: false,
      noteVersion: 2,
    );
  }

  @override
  Future<UpdateLinkResult> updateLink({
    required String linkId,
    String? kind,
    String? label,
    bool clearLabel = false,
  }) async {
    updatedLinks.add((
      linkId: linkId,
      kind: kind,
      label: label,
      clearLabel: clearLabel,
    ));
    if (writeError != null) throw writeError!;
    return UpdateLinkResult(
      linkId: linkId,
      fromNoteId: C89.alpha,
      toNoteId: C89.beta,
      kind: kind ?? 'references',
      label: label,
      source: 'inline_body',
      position: 0,
    );
  }
}
