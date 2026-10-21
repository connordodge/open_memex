// WI #88 (W4): VaultAccess doubles for the Graph async migration. Every
// double extends #70's local domain class (D21) and reads the real
// FakeVaultDb underneath; it only gates or rewrites what that class returns.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/db/graph_reads.dart';
import 'package:open_memex_app/src/db/topics_reads.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

/// A graph domain whose `graphNotes` waits on a gate per call. A released
/// gate reads the database at release time, so a test can change the
/// database while a read is pending and see the new rows only once it lets
/// the read through.
class Wi88GatedGraph extends LocalGraphAccess {
  Wi88GatedGraph({required super.vaultPath, super.db});

  final _gates = <Completer<void>>[];

  /// Number of `graphNotes` calls so far.
  int get calls => _gates.length;

  /// Number of calls still waiting on their gate.
  int get pending => _gates.where((g) => !g.isCompleted).length;

  /// Lets the oldest waiting `graphNotes` call through.
  void release() => _gates.firstWhere((g) => !g.isCompleted).complete();

  /// Fails the oldest waiting `graphNotes` call with [error].
  void fail(Object error) =>
      _gates.firstWhere((g) => !g.isCompleted).completeError(error);

  @override
  Future<List<GraphNoteRow>> graphNotes() async {
    final gate = Completer<void>();
    _gates.add(gate);
    await gate.future;
    return super.graphNotes();
  }
}

/// A notes domain whose `getNote` and `titlesForIds` rename the notes in
/// [titles] and hide the notes in [hidden] (null / left out of the map).
class Wi88RewritingNotes extends LocalNotesAccess {
  Wi88RewritingNotes({
    required super.vaultPath,
    super.db,
    super.cli,
    this.titles = const {},
    this.hidden = const {},
  });

  final Map<String, String> titles;
  final Set<String> hidden;

  @override
  Future<Note?> getNote(String id) async {
    if (hidden.contains(id)) return null;
    final note = await super.getNote(id);
    final title = titles[id];
    if (note == null || title == null) return note;
    return Note(
      id: note.id,
      title: title,
      contentMd: note.contentMd,
      frontmatter: note.frontmatter,
      version: note.version,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      tags: note.tags,
    );
  }

  @override
  Future<Map<String, String>> titlesForIds(List<String> ids) async => {
    for (final e in (await super.titlesForIds(ids)).entries)
      if (!hidden.contains(e.key)) e.key: titles[e.key] ?? e.value,
  };
}

/// A topics domain whose `smartFolders` renames the folders in [names] and
/// leaves out the folders in [hidden] (with their memberships).
class Wi88RewritingTopics extends LocalTopicsAccess {
  Wi88RewritingTopics({
    required super.vaultPath,
    super.db,
    super.cli,
    this.names = const {},
    this.hidden = const {},
  });

  final Map<String, String> names;
  final Set<String> hidden;

  @override
  Future<SmartFolderData> smartFolders() async {
    final data = await super.smartFolders();
    return SmartFolderData(
      folders: [
        for (final f in data.folders)
          if (!hidden.contains(f.id))
            SmartFolderRow(
              id: f.id,
              name: names[f.id] ?? f.name,
              parentId: f.parentId,
              pinned: f.pinned,
            ),
      ],
      members: [
        for (final m in data.members)
          if (!hidden.contains(m.folderId)) m,
      ],
    );
  }
}

/// A daily domain whose `footerChips` adds [extraChips] to a day's chips.
class Wi88ExtraChipsDaily extends LocalDailyAccess {
  Wi88ExtraChipsDaily({
    required super.vaultPath,
    super.db,
    super.cli,
    this.extraChips = const {},
  });

  final Map<String, List<FooterChipRow>> extraChips;

  @override
  Future<List<FooterChipRow>> footerChips(String dailyNoteId) async => [
    ...await super.footerChips(dailyNoteId),
    ...?extraChips[dailyNoteId],
  ];
}

/// Overrides `vaultAccessProvider` with a [LocalVaultAccess] over the
/// harness's own `vaultDbProvider` and `memexCliProvider`, whose notes and
/// topics domains rewrite titles and folder names. With these the chip
/// shows a title only VaultAccess knows, so a chip still read from
/// `vaultDbProvider` shows the database's title instead.
Override wi88RewritingAccessOverride({
  Map<String, String> noteTitles = const {},
  Set<String> hiddenNotes = const {},
  Map<String, String> folderNames = const {},
  Set<String> hiddenFolders = const {},
}) => vaultAccessProvider.overrideWith((ref) {
  final path = ref.watch(currentVaultProvider).localPath;
  if (path == null) return null;
  final db = ref.watch(vaultDbProvider);
  final cli = ref.watch(memexCliProvider);
  return LocalVaultAccess(
    vaultPath: path,
    db: db,
    cli: cli,
    notes: Wi88RewritingNotes(
      vaultPath: path,
      db: db,
      cli: cli,
      titles: noteTitles,
      hidden: hiddenNotes,
    ),
    topics: Wi88RewritingTopics(
      vaultPath: path,
      db: db,
      cli: cli,
      names: folderNames,
      hidden: hiddenFolders,
    ),
  );
});

/// Holds every read made through the [Wi88HeldGraph], [Wi88HeldTopics] and
/// [Wi88HeldDaily] doubles that share it, and records the order the reads
/// started in. Nothing a held read returns arrives until the test releases
/// it, so a reader that awaited one read before starting the next would
/// show a single started read.
class Wi88ReadGates {
  final _gates = <String, Completer<void>>{};

  /// The reads started so far, in order (`footerChips` carries its note id).
  final started = <String>[];

  Future<void> hold(String read) {
    started.add(read);
    return (_gates[read] = Completer<void>()).future;
  }

  /// Lets [read] through.
  void release(String read) => _gates[read]!.complete();

  /// Fails [read] with [error].
  void fail(String read, Object error) => _gates[read]!.completeError(error);

  /// Lets every read still held through.
  void releaseAll() {
    for (final gate in _gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
  }
}

/// A graph domain whose `graphNotes` and `graphLinks` wait on [gates].
class Wi88HeldGraph extends LocalGraphAccess {
  Wi88HeldGraph({required super.vaultPath, super.db, required this.gates});

  final Wi88ReadGates gates;

  @override
  Future<List<GraphNoteRow>> graphNotes() async {
    await gates.hold('graphNotes');
    return super.graphNotes();
  }

  @override
  Future<List<GraphLinkRow>> graphLinks() async {
    await gates.hold('graphLinks');
    return super.graphLinks();
  }
}

/// A topics domain whose `smartFolders` waits on [gates].
class Wi88HeldTopics extends LocalTopicsAccess {
  Wi88HeldTopics({
    required super.vaultPath,
    super.db,
    super.cli,
    required this.gates,
  });

  final Wi88ReadGates gates;

  @override
  Future<SmartFolderData> smartFolders() async {
    await gates.hold('smartFolders');
    return super.smartFolders();
  }
}

/// A daily domain whose `footerChips` waits on [gates].
class Wi88HeldDaily extends LocalDailyAccess {
  Wi88HeldDaily({
    required super.vaultPath,
    super.db,
    super.cli,
    required this.gates,
  });

  final Wi88ReadGates gates;

  @override
  Future<List<FooterChipRow>> footerChips(String dailyNoteId) async {
    await gates.hold('footerChips:$dailyNoteId');
    return super.footerChips(dailyNoteId);
  }
}
