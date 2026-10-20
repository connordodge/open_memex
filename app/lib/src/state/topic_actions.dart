import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cli/footer_cli.dart';
import '../db.dart';
import '../memex_cli.dart';
import 'daily_state.dart';
import 'editor_controller.dart';
import 'tabs_state.dart';
import 'today_state.dart';
import 'vault_access_state.dart';
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
Future<({String topicId, FooterAddResult footer})> createLinkedTopic(
  MemexCli cli, {
  required String vaultPath,
  required String title,
  required String contentMd,
  required String dailyNoteId,
  required String linkTarget,
}) async {
  final topicId = await cli.addNote(
    vaultPath: vaultPath,
    title: title,
    contentMd: contentMd,
    role: 'topic',
  );
  final FooterAddResult footer;
  try {
    footer = await cli.addFooterChip(
      vaultPath: vaultPath,
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
/// note, or the topic note when only its footer chip failed, which throws a
/// [TopicNotLinkedException]).
Future<String> createTopicFromSidebar(WidgetRef ref, String title) async {
  final cli = ref.read(memexCliProvider);
  final vaultPath = ref.read(currentVaultProvider).localPath;
  if (cli == null || vaultPath == null) {
    throw MemexException('The memex CLI is not available.');
  }
  var createdDaily = false;
  try {
    var dailyId = ref.read(todayNoteProvider)?.noteId;
    if (dailyId == null) {
      final daily = await createDailyNote(
        ref.read(vaultAccessProvider)!.notes,
        date: ref.read(todayDateProvider),
      );
      dailyId = daily.noteId;
      createdDaily = !daily.existed;
    }
    final created = await createLinkedTopic(
      cli,
      vaultPath: vaultPath,
      title: title,
      contentMd: topicNoteBody(title),
      dailyNoteId: dailyId,
      linkTarget: 'today',
    );
    createdDaily = false;
    ref.read(vaultRevisionProvider.notifier).state++;
    ref.read(tabsProvider.notifier).openOrFocus(NoteTab(created.topicId));
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
void rebaseEditorOnVersion(
  WidgetRef ref, {
  required Note fallback,
  required int version,
  required String content,
}) {
  final editor = ref.read(editorControllerProvider.notifier);
  final title = ref.read(editorControllerProvider).title;
  final stored = ref.read(vaultDbProvider)?.getNote(fallback.id) ?? fallback;
  editor.loadNote(
    Note(
      id: stored.id,
      title: stored.title,
      contentMd: stored.contentMd,
      frontmatter: stored.frontmatter,
      version: version,
      createdAt: stored.createdAt,
      updatedAt: stored.updatedAt,
      tags: stored.tags,
    ),
  );
  editor.onTitleChanged(title);
  editor.onContentChanged(content);
}
