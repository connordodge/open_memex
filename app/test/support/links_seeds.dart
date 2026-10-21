// WI #90 (W6): link seeds for the right panel tests, plus Completer-gated
// notes and graph doubles (D21: doubles extend the local domain classes).
// Raw inserts against the real V5 schema; nothing here goes through the
// production read code.
import 'dart:async';

import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/activity_reads.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import 'fake_vault_db.dart';
import 'graph_seeds.dart';

/// Ids of the [seedLinksFixture] notes and links.
abstract final class L {
  static const target = 'n90-target';
  static const other = 'n90-other';
  // Link sources; ids sort zulu, alpha, mike, which differs from title order.
  static const zulu = 'n90-s1';
  static const alpha = 'n90-s2';
  static const mike = 'n90-s3';
  // A link source with no `notes` row: its backlink falls back to this id.
  static const gone = 'n90-gone';
}

/// A target note with outgoing and incoming links.
///
/// Notes: `n90-target` ("Target", 2 tags), `n90-other` ("Other", no links at
/// all) and the sources Zulu, Alpha and Mike.
///
/// Outgoing from the target, by position: `out-ref` references Alpha
/// (label `see also`), `out-ext` extends Mike, `out-zeta` zeta-kind Zulu,
/// `out-ghost` references a ghost (`Nowhere`), `out-beta` beta-kind Alpha.
///
/// Incoming to the target: extends from Zulu, Alpha, Mike and the title-less
/// `n90-gone`; contradicts from Mike; references from Zulu; zeta-kind from
/// Alpha; alpha-kind from Mike.
FakeVaultDb seedLinksFixture(FakeVaultDb db) {
  db.seedNote(id: L.target, title: 'Target', tags: const ['t1', 't2']);
  db.seedNote(id: L.other, title: 'Other');
  db.seedNote(id: L.zulu, title: 'Zulu');
  db.seedNote(id: L.alpha, title: 'Alpha');
  db.seedNote(id: L.mike, title: 'Mike');
  db.seedLink(
    L.target,
    L.alpha,
    id: 'out-ref',
    label: 'see also',
    linkText: 'Alpha',
  );
  db.seedLink(L.target, L.mike, id: 'out-ext', kind: 'extends');
  db.seedLink(L.target, L.zulu, id: 'out-zeta', kind: 'zeta-kind');
  db.seedLink(L.target, null, id: 'out-ghost', linkText: 'Nowhere');
  db.seedLink(L.target, L.alpha, id: 'out-beta', kind: 'beta-kind');

  db.seedLink(L.zulu, L.target, id: 'in-ext-zulu', kind: 'extends');
  db.seedLink(L.alpha, L.target, id: 'in-ext-alpha', kind: 'extends');
  db.seedLink(L.mike, L.target, id: 'in-ext-mike', kind: 'extends');
  db.seedLink(L.gone, L.target, id: 'in-ext-gone', kind: 'extends');
  db.seedLink(L.mike, L.target, id: 'in-con-mike', kind: 'contradicts');
  db.seedLink(L.zulu, L.target, id: 'in-ref-zulu');
  db.seedLink(L.alpha, L.target, id: 'in-zeta-alpha', kind: 'zeta-kind');
  db.seedLink(L.mike, L.target, id: 'in-alpha-mike', kind: 'alpha-kind');
  return db;
}

/// A [LinkRow] built from run-time values.
LinkRow wi90Link(
  String id, {
  required String from,
  String? to,
  String text = 'text',
  String kind = 'references',
  String? label,
  int position = 0,
}) => LinkRow(
  id: id,
  fromNoteId: from,
  toNoteId: to,
  linkText: text,
  kind: kind,
  label: label,
  position: position,
  source: 'inline_body',
);

/// A gate reads wait on. Open: reads answer at once. Closed: reads wait
/// until [open].
class Wi90Gate {
  Wi90Gate({bool open = true}) {
    if (open) _c.complete();
  }

  Completer<void> _c = Completer<void>();

  /// Reads that have started, counting each call (open or closed).
  int calls = 0;

  Future<void> get wait {
    calls++;
    return _c.future;
  }

  void open() {
    if (!_c.isCompleted) _c.complete();
  }

  void close() {
    if (_c.isCompleted) _c = Completer<void>();
  }
}

/// A notes domain whose link reads answer fixed data once [gate] is open.
class Wi90GatedNotes extends LocalNotesAccess {
  Wi90GatedNotes({
    required super.vaultPath,
    super.db,
    required this.gate,
    this.out = const [],
    this.incoming = const [],
    this.titles = const {},
  });

  final Wi90Gate gate;
  List<LinkRow> out;
  List<LinkRow> incoming;
  Map<String, String> titles;

  @override
  Future<List<LinkRow>> linksOutFor(String noteId) async {
    await gate.wait;
    return out;
  }

  @override
  Future<List<LinkRow>> linksInFor(String noteId, {String? kind}) async {
    await gate.wait;
    return incoming;
  }

  @override
  Future<Map<String, String>> titlesForIds(List<String> ids) async => titles;
}

/// A graph domain whose `agentChanges` answers fixed data once [gate] is open.
class Wi90GatedGraph extends LocalGraphAccess {
  Wi90GatedGraph({
    required super.vaultPath,
    super.db,
    required this.gate,
    this.changes = const [],
  });

  final Wi90Gate gate;
  List<AgentChangeRow> changes;

  @override
  Future<List<AgentChangeRow>> agentChanges(String noteId) async {
    await gate.wait;
    return changes;
  }
}
