import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cli/footer_cli.dart';
import '../db.dart';
import '../memex_cli.dart';
import 'daily_state.dart';
import 'editor_controller.dart';
import 'tabs_state.dart';
import 'today_state.dart';
import 'vault_access_state.dart';
import '../vault_access/vault_access.dart';
import 'vault_state.dart';

/// The body of a topic note the app creates: a heading with its title.
String topicNoteBody(String title) => '# $title\n\n';

/// `memex add` created the topic note [topicId] but `memex footer add` failed:
/// the note stays (no rollback) and is not linked from the daily note.
class TopicNotLinkedException implements Exception {
  TopicNotLinkedException(this.topicId, this.cause, {required this.target});

  final String topicId;

  /// The footer-add error message.
  final String cause;

  /// Where the chip should have gone: `today` or `this daily note`.
  final String target;

  /// The text for the inline error (Req 54).
  String get message =>
      "Topic created, but it couldn't be linked to $target: $cause";

  @override
  String toString() => message;
}

/// Creates the topic note [title] (`memex add --role topic`, body
/// [contentMd]) and records it as a `person` chip in the Topics footer of
/// the daily note [dailyNoteId] (`memex footer add`), in that order
/// (Req 17). Returns the new topic note's id and the footer result.
///
/// A failed `add` throws its [MemexException]. When only the footer call
/// fails the topic note exists, and a [TopicNotLinkedException] (with
/// [linkTarget] in its message) is thrown.
///
/// [onTopicCreated] runs right after the topic note exists, before the footer
/// call, so a caller can tell "nothing created" from "created but the footer
/// call failed" for failures that are not a [MemexException].
Future<({String topicId, FooterAddResult footer})> createLinkedTopic(
  VaultAccess access, {
  required String title,
  required String contentMd,
  required String dailyNoteId,
  required String linkTarget,
  void Function()? onTopicCreated,
}) async {
  final topicId = await access.notes.addNote(
    title: title,
    contentMd: contentMd,
    role: 'topic',
  );
  onTopicCreated?.call();
  final FooterAddResult footer;
  try {
    footer = await access.daily.addFooterChip(
      dailyNoteId: dailyNoteId,
      topicNoteId: topicId,
    );
  } on MemexException catch (e) {
    throw TopicNotLinkedException(topicId, e.message, target: linkTarget);
  }
  return (topicId: topicId, footer: footer);
}

/// `+ New topic` in the Topics sidebar: creates the topic note [title]
/// (already trimmed, not blank) and links it from today's daily note,
/// creating that note first when today has none (a `daily_note_exists` race
/// uses the existing note). On success the vault revision is bumped and the
/// new note opens in a tab. Returns its id.
///
/// A failure throws the [MemexException] (or the error) with no tab opened;
/// the revision is bumped when something was created on the way (a daily
/// note, or the topic note when its footer chip failed: a
/// [TopicNotLinkedException], or any other failure such as
/// `VaultUnreachableException`).
Future<String> createTopicFromSidebar(WidgetRef ref, String title) async {
  final cli = ref.read(memexCliProvider);
  final vaultPath = ref.read(currentVaultProvider).localPath;
  final access = ref.read(vaultAccessProvider);
  if (cli == null || vaultPath == null || access == null || !access.canWrite) {
    throw MemexException('The memex CLI is not available.');
  }
  var createdDaily = false;
  try {
    // Nothing listens to today's note, so a plain read can still hold the
    // note of the day before midnight: await its fresh value.
    var dailyId = (await awaitVaultValue(
      ref,
      todayNoteAsyncProvider.future,
      null,
    ))?.noteId;
    if (dailyId == null) {
      final daily = await createDailyNote(
        ref.read(vaultAccessProvider)!.notes,
        date: ref.read(todayDateProvider),
      );
      dailyId = daily.noteId;
      createdDaily = !daily.existed;
    }
    final created = await createLinkedTopic(
      access,
      title: title,
      contentMd: topicNoteBody(title),
      dailyNoteId: dailyId,
      linkTarget: 'today',
      // The topic note exists from here on: whatever the footer call does,
      // the tree must see it.
      onTopicCreated: () => createdDaily = true,
    );
    createdDaily = false;
    ref.read(vaultRevisionProvider.notifier).state++;
    ref.read(tabsProvider.notifier).navigate(NoteTab(created.topicId));
    return created.topicId;
  } on TopicNotLinkedException {
    // The topic note exists (shown under Unsorted after the refresh).
    createdDaily = true;
    rethrow;
  } finally {
    // A daily note or the topic note was created but the flow did not
    // finish: the Days list, today's note and the tree must still see them.
    if (createdDaily) ref.read(vaultRevisionProvider.notifier).state++;
  }
}

/// After `memex footer add` changed the open daily note [fallback] on the
/// server (its new version is [version]), makes that version the editor's
/// base and keeps the unsaved [content] (and title) on top of it, so the next
/// save is not a version conflict. [fallback] is also the stored note's
/// stand-in when the vault cannot be read.
///
/// Rebasing reads the note. Text or a title typed during that read wins: it is
/// newer than [content], so the editor keeps it in place of [content].
Future<void> rebaseEditorOnVersion(
  WidgetRef ref, {
  required Note fallback,
  required int version,
  required String content,
}) => _rebaseEditorOnVersion(
  ref.read,
  fallback: fallback,
  version: version,
  content: content,
);

/// [rebaseEditorOnVersion] for a caller whose widget may be gone by the time
/// it runs (a write that outlives the widget that started it): reads through
/// [container] instead of a `WidgetRef`.
Future<void> rebaseEditorOnVersionIn(
  ProviderContainer container, {
  required Note fallback,
  required int version,
  required String content,
}) => _rebaseEditorOnVersion(
  container.read,
  fallback: fallback,
  version: version,
  content: content,
);

/// [keepTyped], when given, is applied to text typed during the read before
/// the editor keeps it ([flushThenWrite]'s `carryOver`).
Future<void> _rebaseEditorOnVersion(
  T Function<T>(ProviderListenable<T> provider) read, {
  required Note fallback,
  required int version,
  required String content,
  String Function(String typed)? keepTyped,
}) async {
  final editor = read(editorControllerProvider.notifier);
  final before = read(editorControllerProvider).contentMd;
  final stored =
      await read(vaultAccessProvider)?.notes.getNote(fallback.id) ?? fallback;
  // The user may have opened another note while the read was in flight:
  // loading the first note back would clobber the editor.
  if (editor.activeNoteId != fallback.id) return;
  final now = read(editorControllerProvider);
  editor.loadNote(_atVersion(stored, version));
  editor.onTitleChanged(now.title);
  editor.onContentChanged(
    now.contentMd == before
        ? content
        : (keepTyped?.call(now.contentMd) ?? now.contentMd),
  );
}

/// What a write shows when the edit waiting on the save debounce could not be
/// stored before it (Spec #391 req 31, ruling D19).
const saveFirstFailedMessage = 'Could not save your changes first.';

/// [flushThenWrite] could not store the edit waiting on the save debounce, so
/// it wrote nothing. Its message is [saveFirstFailedMessage]; [saveError] is
/// the editor's save error when it shows one (the guide restore shows that
/// instead, an echo link shows the fixed message).
class SaveFirstFailedException extends MemexException {
  SaveFirstFailedException({this.saveError}) : super(saveFirstFailedMessage);

  /// The editor's `errorMessage` when the flush failed, or null.
  final String? saveError;
}

/// Ruling D19, the one flush-then-write: stores the edit waiting on the save
/// debounce (`flushPendingSaveAndWait`), runs [write] (which returns the
/// version it gave [note]), then reads the stored note and rebases the editor
/// on it with [rebaseEditorOnVersionIn]: the stored text when the editor still
/// holds what was flushed, else the newer editor text. A failed flush runs no
/// [write] and throws [SaveFirstFailedException]. A stored note that cannot be
/// read after the write leaves the editor as it is.
///
/// [carryOver], when given, decides what the editor keeps when it no longer
/// holds what was flushed (text typed while [write] or the read after it
/// ran): from that typed text, the flushed text and the stored text it returns
/// the text to keep, so newer typing does not drop what the write changed (an
/// echo link, ruling D54). Without it the typed text is kept as it is (the
/// guide restore).
///
/// [waitForSaves]: a save of the editor that is still in flight, or a flushed
/// save that waits behind one, is not a failed flush: the helper waits for
/// the editor's saves to land (`savesSettled`) and flushes again, a few times
/// at most, and fails only when the editor shows a save error or conflict or
/// still holds unsaved text after that. Without it any of these fails at once
/// (the guide restore, which asks the person to retry).
///
/// [holdSaves]: from the flush until the rebase, the editor holds its
/// debounced saves (`EditorController.holdSaves`), so text typed while
/// [write] runs is not saved on the version [write] replaces (a version
/// conflict); it saves after the rebase, on the version [write] stored. The
/// helper then bumps `vaultRevisionProvider` exactly once when [write]
/// succeeded or a save landed during the hold (the flushed edit), so the
/// write and the edit saved before it reach the revision's watchers as one
/// change, and nothing when neither happened. Without it the editor's saves
/// bump as they land and the caller bumps for [write].
///
/// Calls on one [container] run one at a time, in call order: a call starts
/// its flush only once every earlier call has finished, failed or not. Two at
/// once would each take what was flushed before either wrote, so the later
/// one would mistake the earlier one's rebase for newer typing and put back
/// text without its own write.
Future<void> flushThenWrite(
  ProviderContainer container, {
  required Note note,
  required Future<int> Function() write,
  FlushThenWriteCarryOver? carryOver,
  bool waitForSaves = false,
  bool holdSaves = false,
}) {
  Future<void> start() => _flushThenWrite(
    container,
    note: note,
    write: write,
    carryOver: carryOver,
    waitForSaves: waitForSaves,
    holdSaves: holdSaves,
  );
  final previous = _flushThenWriteTail[container];
  final run = previous == null ? start() : previous.then((_) => start());
  // The queue's tail never fails: a failed call still lets the next one run.
  final tail = run.then<void>((_) {}, onError: (Object _) {});
  _flushThenWriteTail[container] = tail;
  unawaited(
    tail.then((_) {
      if (identical(_flushThenWriteTail[container], tail)) {
        _flushThenWriteTail[container] = null;
      }
    }),
  );
  return run;
}

/// The last [flushThenWrite] still running on each container, if any.
final _flushThenWriteTail = Expando<Future<void>>('flushThenWrite');

/// What [flushThenWrite] keeps in the editor once it no longer holds the
/// `flushed` text: made from the `typed` text it holds instead and the
/// `stored` text the write left.
typedef FlushThenWriteCarryOver =
    String Function({
      required String typed,
      required String flushed,
      required String stored,
    });

/// How many times [flushThenWrite] with `waitForSaves` waits for the
/// editor's saves to land before it gives up on the flush.
const _flushWaits = 3;

Future<void> _flushThenWrite(
  ProviderContainer container, {
  required Note note,
  required Future<int> Function() write,
  FlushThenWriteCarryOver? carryOver,
  required bool waitForSaves,
  required bool holdSaves,
}) async {
  final editor = container.read(editorControllerProvider.notifier);
  if (holdSaves) editor.holdSaves();
  var wrote = false;
  try {
    if (!await _flush(container, editor, waitForSaves: waitForSaves)) {
      throw SaveFirstFailedException(
        saveError: container.read(editorControllerProvider).errorMessage,
      );
    }
    final flushed = container.read(editorControllerProvider).contentMd;
    final version = await write();
    wrote = true;
    final stored = await container
        .read(vaultAccessProvider)
        ?.notes
        .getNote(note.id);
    if (stored == null) return;
    final carry = carryOver;
    final keepTyped = carry == null
        ? null
        : (String typed) =>
              carry(typed: typed, flushed: flushed, stored: stored.contentMd);
    final now = container.read(editorControllerProvider).contentMd;
    await _rebaseEditorOnVersion(
      container.read,
      fallback: note,
      version: version,
      content: now == flushed
          ? stored.contentMd
          : (keepTyped?.call(now) ?? now),
      keepTyped: keepTyped,
    );
  } finally {
    if (holdSaves) {
      final saved = editor.releaseSaves();
      if (wrote || saved) {
        container.read(vaultRevisionProvider.notifier).state++;
      }
    }
  }
}

/// [flushThenWrite]'s flush: true once the editor holds nothing unsaved.
/// With [waitForSaves], a save in flight (or a flushed save waiting behind
/// one) is waited for and the flush made again, at most [_flushWaits] times;
/// a save error or conflict fails at once.
Future<bool> _flush(
  ProviderContainer container,
  EditorController editor, {
  required bool waitForSaves,
}) async {
  for (var waits = 0; ; waits++) {
    if (await editor.flushPendingSaveAndWait()) return true;
    final status = container.read(editorControllerProvider).status;
    final vault = container.read(currentVaultProvider);
    if (!waitForSaves ||
        waits == _flushWaits ||
        vault == null ||
        (status != SaveStatus.saving && status != SaveStatus.dirty)) {
      return false;
    }
    await editor.savesSettled(vault);
  }
}

/// After a write to [note] through [access] has already succeeded (its new
/// version is [version]), makes that version the editor's base when the note
/// is open, for a caller that may be gone by then: everything goes through
/// [container], not a `WidgetRef`, and no read failure escapes.
///
/// A clean editor takes the stored note and stays clean, because its copy
/// still has what the write changed and keeping it would write again. A stored
/// note that cannot be read leaves its title and text as they are, still
/// clean. An editor with a pending edit keeps its title and text as they stand
/// once the read is over (it can last a whole timeout), on the stored note or,
/// failing that, on [note].
Future<void> rebaseEditorAfterWrite(
  ProviderContainer container,
  VaultAccess access, {
  required Note note,
  required int version,
}) async {
  final editor = container.read(editorControllerProvider.notifier);
  if (editor.activeNoteId != note.id) return;
  Note? stored;
  try {
    stored = await access.notes.getNote(note.id);
  } on Object {
    // The write went through; the rebase still has to happen.
    stored = null;
  }
  // The user may have opened another note while the read was in flight.
  if (editor.activeNoteId != note.id) return;
  final now = container.read(editorControllerProvider);
  if (now.status == SaveStatus.clean) {
    editor.loadNote(
      stored != null
          ? _atVersion(stored, version)
          : _atVersion(
              note,
              version,
              title: now.title,
              contentMd: now.contentMd,
            ),
    );
    return;
  }
  editor.loadNote(_atVersion(stored ?? note, version));
  editor.onTitleChanged(now.title);
  editor.onContentChanged(now.contentMd);
}

/// [note] at [version], optionally with another title or text.
Note _atVersion(Note note, int version, {String? title, String? contentMd}) =>
    Note(
      id: note.id,
      title: title ?? note.title,
      contentMd: contentMd ?? note.contentMd,
      frontmatter: note.frontmatter,
      version: version,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      tags: note.tags,
      footerTags: note.footerTags,
    );
