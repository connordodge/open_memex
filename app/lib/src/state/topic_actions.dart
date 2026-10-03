import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cli/footer_cli.dart';
import '../db.dart';
import '../memex_cli.dart';
import 'daily_state.dart';
import 'editor_controller.dart';
import 'tabs_state.dart';
import 'today_state.dart';
import 'vault_state.dart';

/// The body of a topic note the app creates: a heading with its title.
String topicNoteBody(String title) => '# $title\n\n';

/// Creates the topic note [title] (`memex add --role topic`, body
/// [contentMd]) and records it as a `person` chip in the Topics footer of
/// the daily note [dailyNoteId] (`memex footer add`), in that order
/// (Req 17). Returns the new topic note's id and the footer result.
///
/// A CLI failure throws the [MemexException]; when the footer call fails the
/// topic note exists but is not linked.
Future<({String topicId, FooterAddResult footer})> createLinkedTopic(
  MemexCli cli, {
  required String vaultPath,
  required String title,
  required String contentMd,
  required String dailyNoteId,
}) async {
  final topicId = await cli.addNote(
    vaultPath: vaultPath,
    title: title,
    contentMd: contentMd,
    role: 'topic',
  );
  final footer = await cli.addFooterChip(
    vaultPath: vaultPath,
    dailyNoteId: dailyNoteId,
    topicNoteId: topicId,
  );
  return (topicId: topicId, footer: footer);
}

/// `+ New topic` in the Topics sidebar: creates the topic note [title]
/// (already trimmed, not blank) and links it from today's daily note,
/// creating that note first when today has none (a `daily_note_exists` race
/// uses the existing note). On success the vault revision is bumped and the
/// new note opens in a tab. Returns its id.
///
/// A failure throws the [MemexException] (or the error) with the UI as it
/// was: no tab opens, and the revision is bumped only when a daily note was
/// created on the way.
Future<String> createTopicFromSidebar(WidgetRef ref, String title) async {
  final cli = ref.read(memexCliProvider);
  final vaultPath = ref.read(currentVaultProvider);
  if (cli == null || vaultPath == null) {
    throw MemexException('The memex CLI is not available.');
  }
  var createdDaily = false;
  try {
    var dailyId = ref.read(todayNoteProvider)?.noteId;
    if (dailyId == null) {
      final daily = await createDailyNote(
        cli,
        vaultPath: vaultPath,
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
    );
    createdDaily = false;
    ref.read(vaultRevisionProvider.notifier).state++;
    ref.read(tabsProvider.notifier).openOrFocus(NoteTab(created.topicId));
    return created.topicId;
  } finally {
    // A daily note was created but the topic did not follow: the Days list
    // and today's note must still see it.
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
