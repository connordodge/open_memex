// WI #87 (W3): doubles for the Topics async migration. Each extends the local
// domain class (D21), records what the app calls through `VaultAccess` and
// forwards to the real local behaviour, so a FakeMemexCli / FakeVaultDb still
// plays the server. Reads can be gated on a Completer, and any method can be
// made to throw, to pin loading, reload and failure behaviour.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' show TestFailure;
import 'package:open_memex_app/src/cli/excerpt_cli.dart';
import 'package:open_memex_app/src/cli/feedback_cli.dart';
import 'package:open_memex_app/src/cli/folder_cli.dart';
import 'package:open_memex_app/src/cli/footer_cli.dart';
import 'package:open_memex_app/src/cli/guide_cli.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/feedback_reads.dart';
import 'package:open_memex_app/src/db/topics_reads.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

/// One call the app made through a domain, with its named arguments.
class RecordedCall {
  RecordedCall(this.method, this.args);

  final String method;
  final Map<String, Object?> args;

  @override
  String toString() => '$method($args)';
}

/// What every recording double shares: a call log, per-method failures and
/// per-method read gates.
mixin Recording {
  final calls = <RecordedCall>[];

  /// Throws the result of the function for the next call of the method (once).
  final _failNext = <String, Object Function()>{};

  /// Throws on every call of the method until cleared.
  final _failAlways = <String, Object Function()>{};

  /// Throws the result of the function on the nth call (1-based) of the
  /// method.
  final _failNth = <String, Map<int, Object Function()>>{};
  final _callCount = <String, int>{};

  /// Completers of the gated reads, in call order (see [gate]).
  final gates = <String, List<Completer<void>>>{};
  final _gated = <String>{};

  List<RecordedCall> callsTo(String method) => [
    for (final c in calls)
      if (c.method == method) c,
  ];

  /// The next call of [method] throws [error] (once).
  void failNext(String method, Object error) => _failNext[method] = () => error;

  /// Every call of [method] throws [error] until [stopFailing].
  void failAlways(String method, Object error) =>
      _failAlways[method] = () => error;

  /// The [n]th call (1-based, counted from now on the whole run) of [method]
  /// throws [error].
  void failNth(String method, int n, Object error) =>
      (_failNth[method] ??= {})[n] = () => error;

  void stopFailing(String method) => _failAlways.remove(method);

  /// From now on every call of [method] waits for its own completer (in
  /// `gates[method]`) before it reads.
  void gate(String method) => _gated.add(method);

  void ungate(String method) => _gated.remove(method);

  /// Records the call, waits on its gate, then throws a scripted failure.
  Future<void> enter(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    calls.add(RecordedCall(method, args));
    if (_gated.contains(method)) {
      final gate = Completer<void>();
      (gates[method] ??= []).add(gate);
      await gate.future;
    }
    final count = _callCount[method] = (_callCount[method] ?? 0) + 1;
    final nth = _failNth[method]?[count];
    if (nth != null) throw nth();
    final once = _failNext.remove(method);
    if (once != null) throw once();
    final always = _failAlways[method];
    if (always != null) throw always();
  }
}

/// A [LocalTopicsAccess] that records every call.
class RecordingTopicsAccess extends LocalTopicsAccess with Recording {
  RecordingTopicsAccess({required super.vaultPath, super.db, super.cli});

  @override
  Future<SmartFolderData> smartFolders() async {
    await enter('smartFolders');
    return super.smartFolders();
  }

  @override
  Future<List<UnsortedNoteRow>> unsortedNotes() async {
    await enter('unsortedNotes');
    return super.unsortedNotes();
  }

  @override
  Future<SmartFolderResult> createFolder({
    required String name,
    String? parentId,
  }) async {
    await enter('createFolder', {'name': name, 'parentId': parentId});
    return super.createFolder(name: name, parentId: parentId);
  }

  @override
  Future<SmartFolderResult> updateFolder({
    required String id,
    String? name,
    String? parentId,
    bool toRoot = false,
    bool? pinned,
  }) async {
    await enter('updateFolder', {
      'id': id,
      'name': name,
      'parentId': parentId,
      'toRoot': toRoot,
      'pinned': pinned,
    });
    return super.updateFolder(
      id: id,
      name: name,
      parentId: parentId,
      toRoot: toRoot,
      pinned: pinned,
    );
  }

  @override
  Future<FolderDeleteResult> deleteFolder({required String id}) async {
    await enter('deleteFolder', {'id': id});
    return super.deleteFolder(id: id);
  }

  @override
  Future<FolderMembershipResult> addToFolder({
    required String folderId,
    required String noteId,
    bool? pinned,
  }) async {
    await enter('addToFolder', {
      'folderId': folderId,
      'noteId': noteId,
      'pinned': pinned,
    });
    return super.addToFolder(
      folderId: folderId,
      noteId: noteId,
      pinned: pinned,
    );
  }

  @override
  Future<FolderMemberRemoveResult> removeFromFolder({
    required String folderId,
    required String noteId,
  }) async {
    await enter('removeFromFolder', {'folderId': folderId, 'noteId': noteId});
    return super.removeFromFolder(folderId: folderId, noteId: noteId);
  }

  @override
  Future<int> getSetting(String key) async {
    await enter('getSetting', {'key': key});
    return super.getSetting(key);
  }

  @override
  Future<int> setSetting(String key, int value) async {
    await enter('setSetting', {'key': key, 'value': value});
    return super.setSetting(key, value);
  }

  /// The text `reviewPrompt` answers; null forwards to the CLI.
  String? promptText;

  @override
  Future<String> reviewPrompt() async {
    await enter('reviewPrompt');
    return promptText ?? await super.reviewPrompt();
  }
}

/// A [LocalNotesAccess] that records the calls the Topics flows make.
class RecordingNotesAccess extends LocalNotesAccess with Recording {
  RecordingNotesAccess({required super.vaultPath, super.db, super.cli});

  /// When true `getNote` answers null whatever the database holds.
  bool getNoteIsNull = false;

  /// When true the next `getNote` call (once) answers null whatever the
  /// database holds. Decided when the call is made, so it is the next call
  /// that gets null, not the next one to finish.
  bool nextGetNoteIsNull = false;

  @override
  Future<Note?> getNote(String id) async {
    final answerNull = nextGetNoteIsNull;
    nextGetNoteIsNull = false;
    await enter('getNote', {'id': id});
    return getNoteIsNull || answerNull ? null : super.getNote(id);
  }

  @override
  Future<String> addNote({
    String? title,
    List<String> tags = const [],
    required String contentMd,
    String? role,
  }) async {
    await enter('addNote', {
      'title': title,
      'tags': tags,
      'contentMd': contentMd,
      'role': role,
    });
    return super.addNote(
      title: title,
      tags: tags,
      contentMd: contentMd,
      role: role,
    );
  }
}

/// A [LocalDailyAccess] that records the footer writes.
class RecordingDailyAccess extends LocalDailyAccess with Recording {
  RecordingDailyAccess({required super.vaultPath, super.db, super.cli});

  @override
  Future<FooterAddResult> addFooterChip({
    required String dailyNoteId,
    required String topicNoteId,
  }) async {
    await enter('addFooterChip', {
      'dailyNoteId': dailyNoteId,
      'topicNoteId': topicNoteId,
    });
    return super.addFooterChip(
      dailyNoteId: dailyNoteId,
      topicNoteId: topicNoteId,
    );
  }
}

/// A [LocalFeedbackAccess] that records every call (#259) and forwards to the
/// real local behaviour.
class RecordingFeedbackAccess extends LocalFeedbackAccess with Recording {
  RecordingFeedbackAccess({required super.vaultPath, super.db, super.cli});

  @override
  Future<Filing> filing(String date) async {
    await enter('filing', {'date': date});
    return super.filing(date);
  }

  @override
  Future<ExcerptEditResult> fileBlock({
    required String topicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) async {
    await enter('fileBlock', {
      'topicNoteId': topicNoteId,
      'date': date,
      'blockId': blockId,
      'note': note,
    });
    return super.fileBlock(
      topicNoteId: topicNoteId,
      date: date,
      blockId: blockId,
      note: note,
    );
  }

  @override
  Future<ExcerptMoveResult> moveBlock({
    required String fromTopicNoteId,
    required String toTopicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) async {
    await enter('moveBlock', {
      'fromTopicNoteId': fromTopicNoteId,
      'toTopicNoteId': toTopicNoteId,
      'date': date,
      'blockId': blockId,
      'note': note,
    });
    return super.moveBlock(
      fromTopicNoteId: fromTopicNoteId,
      toTopicNoteId: toTopicNoteId,
      date: date,
      blockId: blockId,
      note: note,
    );
  }

  @override
  Future<ExcerptEditResult> removeBlock({
    required String topicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) async {
    await enter('removeBlock', {
      'topicNoteId': topicNoteId,
      'date': date,
      'blockId': blockId,
      'note': note,
    });
    return super.removeBlock(
      topicNoteId: topicNoteId,
      date: date,
      blockId: blockId,
      note: note,
    );
  }

  @override
  Future<FeedbackRow> addComment({
    required String noteId,
    required String date,
    required String changeId,
    required String text,
  }) async {
    await enter('addComment', {
      'noteId': noteId,
      'date': date,
      'changeId': changeId,
      'text': text,
    });
    return super.addComment(
      noteId: noteId,
      date: date,
      changeId: changeId,
      text: text,
    );
  }

  @override
  Future<FeedbackRow> editComment({
    required String id,
    required String text,
  }) async {
    await enter('editComment', {'id': id, 'text': text});
    return super.editComment(id: id, text: text);
  }

  @override
  Future<FeedbackRemoveResult> deleteComment({required String id}) async {
    await enter('deleteComment', {'id': id});
    return super.deleteComment(id: id);
  }

  @override
  Future<List<FeedbackRow>> feedbackForNote(String noteId) async {
    await enter('feedbackForNote', {'noteId': noteId});
    return super.feedbackForNote(noteId);
  }

  @override
  Future<List<FeedbackRow>> feedbackWithoutNote() async {
    await enter('feedbackWithoutNote');
    return super.feedbackWithoutNote();
  }

  @override
  Future<VaultGuide> guide() async {
    await enter('guide');
    return super.guide();
  }

  @override
  Future<List<GuideRevisionRow>> guideRevisions() async {
    await enter('guideRevisions');
    return super.guideRevisions();
  }

  @override
  Future<GuideRestoreResult> restoreGuide(String revisionId) async {
    await enter('restoreGuide', {'revisionId': revisionId});
    return super.restoreGuide(revisionId);
  }
}

typedef _Make<T> = T Function(String vaultPath, VaultDb? db, MemexCli? cli);

/// Builds one recording double per vault path and serves them through
/// `vaultAccessProvider`. [override] goes in a harness's `overrides`.
///
/// [dbFor] picks the database a vault path reads (default: the one
/// `vaultDbProvider` holds), so two vaults can hold different rows.
class AccessDoubles {
  AccessDoubles({
    VaultDb? Function(String vaultPath, VaultDb? db)? dbFor,
    this.configureTopics,
    this.configureNotes,
    this.configureDaily,
    this.configureFeedback,
  }) : _dbFor = dbFor ?? ((_, db) => db);

  final VaultDb? Function(String vaultPath, VaultDb? db) _dbFor;

  /// Runs once for each vault path's topics double, right after it is
  /// created and before its first call (e.g. to gate a read).
  final void Function(String vaultPath, RecordingTopicsAccess topics)?
  configureTopics;

  /// Like [configureTopics] for the notes and daily doubles.
  final void Function(String vaultPath, RecordingNotesAccess notes)?
  configureNotes;
  final void Function(String vaultPath, RecordingDailyAccess daily)?
  configureDaily;
  final void Function(String vaultPath, RecordingFeedbackAccess feedback)?
  configureFeedback;

  final topics = <String, RecordingTopicsAccess>{};
  final notes = <String, RecordingNotesAccess>{};
  final daily = <String, RecordingDailyAccess>{};
  final feedback = <String, RecordingFeedbackAccess>{};

  /// The double for [vaultPath] (created on first use).
  RecordingTopicsAccess topicsAt(String vaultPath) =>
      _at(topics, vaultPath, 'topics');
  RecordingNotesAccess notesAt(String vaultPath) =>
      _at(notes, vaultPath, 'notes');
  RecordingDailyAccess dailyAt(String vaultPath) =>
      _at(daily, vaultPath, 'daily');
  RecordingFeedbackAccess feedbackAt(String vaultPath) =>
      _at(feedback, vaultPath, 'feedback');

  /// The recorded calls of [method] on the notes / daily double of
  /// [vaultPath]; empty while that double does not exist yet.
  List<RecordedCall> notesCalls(String vaultPath, String method) =>
      notes[vaultPath]?.callsTo(method) ?? const [];
  List<RecordedCall> dailyCalls(String vaultPath, String method) =>
      daily[vaultPath]?.callsTo(method) ?? const [];

  T _at<T>(Map<String, T> from, String vaultPath, String domain) {
    final found = from[vaultPath];
    if (found == null) {
      throw TestFailure(
        'no $domain double for $vaultPath: the app never read '
        'vaultAccessProvider for it (have ${from.keys.toList()})',
      );
    }
    return found;
  }

  Override get override => vaultAccessProvider.overrideWith((ref) {
    final path = ref.watch(currentVaultProvider).localPath;
    if (path == null) return null;
    final db = _dbFor(path, ref.watch(vaultDbProvider));
    final cli = ref.watch(memexCliProvider);
    T make<T>(Map<String, T> into, _Make<T> create) =>
        into.putIfAbsent(path, () => create(path, db, cli));
    return LocalVaultAccess(
      vaultPath: path,
      db: db,
      cli: cli,
      feedback: make<RecordingFeedbackAccess>(feedback, (p, d, c) {
        final f = RecordingFeedbackAccess(vaultPath: p, db: d, cli: c);
        configureFeedback?.call(p, f);
        return f;
      }),
      topics: make<RecordingTopicsAccess>(topics, (p, d, c) {
        final t = RecordingTopicsAccess(vaultPath: p, db: d, cli: c);
        configureTopics?.call(p, t);
        return t;
      }),
      notes: make<RecordingNotesAccess>(notes, (p, d, c) {
        final n = RecordingNotesAccess(vaultPath: p, db: d, cli: c);
        configureNotes?.call(p, n);
        return n;
      }),
      daily: make<RecordingDailyAccess>(daily, (p, d, c) {
        final x = RecordingDailyAccess(vaultPath: p, db: d, cli: c);
        configureDaily?.call(p, x);
        return x;
      }),
    );
  });
}
