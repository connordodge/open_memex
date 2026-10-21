// WI #78 (W2) test doubles: notes and daily domains that record every call,
// can hold reads behind a gate (Completer-gated, D21: they extend the local
// domain classes, never implement the interfaces) and can make every write
// throw a chosen error (a MemexException or a VaultUnreachableException).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/excerpt_cli.dart';
import 'package:open_memex_app/src/cli/note_cli.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

/// The error a hosted write throws when the vault server `nas` refused the
/// request (L17).
const unreachableNas = VaultUnreachableException(
  serverName: 'nas',
  mayHaveCommitted: false,
);

/// `guardVaultWrite`'s snackbar for [unreachableNas].
const unreachableNasSnack = "couldn't reach nas. try again.";

/// Holds reads while [holding]: each read waits until [release].
class EditorReadGate {
  bool holding = false;
  final List<Completer<void>> _waiting = [];

  /// Reads waiting on the gate right now.
  int get waiting => _waiting.length;

  /// Start holding every read that arrives from now on.
  void hold() => holding = true;

  /// Let every waiting read through and stop holding.
  void release() {
    holding = false;
    final waiting = [..._waiting];
    _waiting.clear();
    for (final c in waiting) {
      c.complete();
    }
  }

  Future<void> pass() {
    if (!holding) return Future<void>.value();
    final c = Completer<void>();
    _waiting.add(c);
    return c.future;
  }
}

/// A notes domain over [db] / [cli] that records reads (`getNote:<id>`,
/// `allTitles`, `distinctLinkKinds`) and writes (`updateNote:<id>@<expected>`,
/// `addNote:<title>:<role>`, `deleteNote:<id>@<expected>`).
class EditorNotesAccess extends LocalNotesAccess {
  EditorNotesAccess({required super.vaultPath, super.db, super.cli});

  final gate = EditorReadGate();
  final reads = <String>[];
  final writes = <String>[];

  /// When set, every write records itself and then throws this.
  Object? writeError;

  /// The bodies sent with each `updateNote`, in order.
  final updateBodies = <String>[];

  @override
  Future<Note?> getNote(String id) async {
    reads.add('getNote:$id');
    await gate.pass();
    return super.getNote(id);
  }

  @override
  Future<List<NoteTitle>> allTitles({int limit = 1000}) async {
    reads.add('allTitles');
    await gate.pass();
    return super.allTitles(limit: limit);
  }

  @override
  Future<List<String>> distinctLinkKinds() async {
    reads.add('distinctLinkKinds');
    await gate.pass();
    return super.distinctLinkKinds();
  }

  void _throwIfFailing() {
    final e = writeError;
    if (e != null) throw e;
  }

  @override
  Future<NoteUpdateResult> updateNote({
    required String noteId,
    required int expectedVersion,
    String? title,
    required String contentMd,
    bool noRenameLinks = false,
  }) async {
    writes.add('updateNote:$noteId@$expectedVersion');
    updateBodies.add(contentMd);
    _throwIfFailing();
    return super.updateNote(
      noteId: noteId,
      expectedVersion: expectedVersion,
      title: title,
      contentMd: contentMd,
      noRenameLinks: noRenameLinks,
    );
  }

  @override
  Future<String> addNote({
    String? title,
    List<String> tags = const [],
    required String contentMd,
    String? role,
  }) async {
    writes.add('addNote:$title:$role');
    _throwIfFailing();
    return super.addNote(
      title: title,
      tags: tags,
      contentMd: contentMd,
      role: role,
    );
  }

  @override
  Future<NoteDeleteResult> deleteNote({
    required String noteId,
    required int expectedVersion,
  }) async {
    writes.add('deleteNote:$noteId@$expectedVersion');
    _throwIfFailing();
    return super.deleteNote(noteId: noteId, expectedVersion: expectedVersion);
  }
}

/// A daily domain over [db] / [cli] that records reads (`dailyNotes`,
/// `dailyNoteForDate:<date>`, `reviewState:<id>`, `blocksForNote:<id>`,
/// `footerChips:<id>`) and writes (`removeExcerpt:<topic>:<date>:<from>..<to>`).
class EditorDailyAccess extends LocalDailyAccess {
  EditorDailyAccess({required super.vaultPath, super.db, super.cli});

  final gate = EditorReadGate();
  final reads = <String>[];
  final writes = <String>[];

  /// When set, every write records itself and then throws this.
  Object? writeError;

  @override
  Future<List<DailyNoteRow>> dailyNotes() async {
    reads.add('dailyNotes');
    await gate.pass();
    return super.dailyNotes();
  }

  @override
  Future<DailyNoteRow?> dailyNoteForDate(String isoDate) async {
    reads.add('dailyNoteForDate:$isoDate');
    await gate.pass();
    return super.dailyNoteForDate(isoDate);
  }

  @override
  Future<ReviewInfo?> reviewState(String noteId) async {
    reads.add('reviewState:$noteId');
    await gate.pass();
    return super.reviewState(noteId);
  }

  @override
  Future<List<BlockRow>> blocksForNote(String noteId) async {
    reads.add('blocksForNote:$noteId');
    await gate.pass();
    return super.blocksForNote(noteId);
  }

  @override
  Future<List<FooterChipRow>> footerChips(String dailyNoteId) async {
    reads.add('footerChips:$dailyNoteId');
    await gate.pass();
    return super.footerChips(dailyNoteId);
  }

  @override
  Future<ExcerptRemoveResult> removeExcerpt({
    required String topicNoteId,
    required String date,
    required String fromBlockId,
    String? toBlockId,
  }) async {
    writes.add('removeExcerpt:$topicNoteId:$date:$fromBlockId..$toBlockId');
    final e = writeError;
    if (e != null) throw e;
    return super.removeExcerpt(
      topicNoteId: topicNoteId,
      date: date,
      fromBlockId: fromBlockId,
      toBlockId: toBlockId,
    );
  }
}

/// One vault's doubles, built when `vaultAccessProvider` first builds for
/// that vault (the path is the harness's temp dir).
class EditorVaultDoubles {
  EditorVaultDoubles({this.notesDb, this.dailyDb, this.cli});

  /// The database the notes / daily domains read (may differ from
  /// `vaultDbProvider`'s, so a test sees which one a reader used).
  final VaultDb? notesDb;
  final VaultDb? dailyDb;
  final MemexCli? cli;

  EditorNotesAccess? _notes;
  EditorDailyAccess? _daily;

  EditorNotesAccess get notes => _notes!;
  EditorDailyAccess get daily => _daily!;

  /// The notes reads so far; empty when the access was never built.
  List<String> get noteReads => _notes?.reads ?? const [];

  /// Set to hold the next build's reads from the start.
  bool holdFromStart = false;

  LocalVaultAccess build(String vaultPath) {
    _notes ??= EditorNotesAccess(vaultPath: vaultPath, db: notesDb, cli: cli);
    _daily ??= EditorDailyAccess(vaultPath: vaultPath, db: dailyDb, cli: cli);
    if (holdFromStart) {
      _notes!.gate.hold();
      _daily!.gate.hold();
      holdFromStart = false;
    }
    return LocalVaultAccess(
      vaultPath: vaultPath,
      db: notesDb,
      cli: cli,
      notes: _notes,
      daily: _daily,
    );
  }

  /// Hold both domains' reads (from the first build when not built yet).
  void hold() {
    if (_notes == null) {
      holdFromStart = true;
      return;
    }
    _notes!.gate.hold();
    _daily!.gate.hold();
  }

  /// Release both domains' reads.
  void release() {
    holdFromStart = false;
    _notes?.gate.release();
    _daily?.gate.release();
  }
}

/// `vaultAccessProvider` over [byVault]: the doubles of the open vault, keyed
/// by its path (a vault with no entry, or no vault, gives null).
Override editorAccessOverride(Map<String, EditorVaultDoubles> byVault) =>
    vaultAccessProvider.overrideWith((ref) {
      final path = ref.watch(currentVaultProvider).localPath;
      if (path == null) return null;
      return byVault[path]?.build(path);
    });

/// `vaultAccessProvider` over the one vault the harness opens, whatever its
/// (temp) path.
Override editorSingleVaultOverride(EditorVaultDoubles doubles) =>
    vaultAccessProvider.overrideWith((ref) {
      final path = ref.watch(currentVaultProvider).localPath;
      if (path == null) return null;
      return doubles.build(path);
    });

/// Subscribes to [provider] (the subscription stays open until the container
/// is disposed), lets every queued async read finish, and returns its value.
Future<T> settled<T>(
  ProviderContainer c,
  ProviderListenable<T> provider,
) async {
  final sub = c.listen<T>(provider, (_, _) {});
  await pumpEventQueue();
  return sub.read();
}
