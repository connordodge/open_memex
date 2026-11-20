// WI #148 (Spec #123 R46-R48, A3): the Command palette's Attachments group,
// fed by the same `search` run as Passages, and its chooser.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../vault_access/search_access.dart';
import 'attachments_state.dart';
import 'command_palette_state.dart';
import 'palette_passages.dart' show passageMarks;

/// How many referencing note titles an Attachments row names before ` +N`.
const _notesShown = 3;

/// The Attachments row's notes line for [notes] (Spec #123 R47):
/// `in <t1>, <t2>, <t3>`, then ` +N` for the notes past the first three.
/// Empty for no notes.
String attachmentNotesLine(List<SearchAttachmentNote> notes) {
  if (notes.isEmpty) return '';
  final titles = [for (final n in notes.take(_notesShown)) n.title].join(', ');
  final more = notes.length - _notesShown;
  return more > 0 ? 'in $titles +$more' : 'in $titles';
}

/// The Attachments rows for an answer's top-level [attachments] (never
/// collected from its passage hits), in the answer's order, with the
/// [query]'s words marked in each content match's snippet.
List<AttachmentItem> paletteAttachmentItems(
  List<SearchAttachment> attachments,
  String query,
) => [
  for (final attachment in attachments)
    AttachmentItem(
      attachment,
      notesLine: attachmentNotesLine(attachment.notes),
      marks: switch (attachment.snippet) {
        final snippet? => passageMarks(snippet, query),
        null => const [],
      },
    ),
];

/// Chooses an Attachments row (D10): opens its path through the open
/// vault's attachments domain (`attachmentsProvider`), which downloads a
/// hosted file first and reveals an executable instead (R33). The Cmd flag
/// changes nothing: a file has no tab. With no open vault it does nothing.
PaletteChooser<AttachmentItem> paletteAttachmentChooser(Ref ref) =>
    (item, {required newTab}) {
      final attachments = ref.read(attachmentsProvider);
      if (attachments == null) return;
      unawaited(attachments.open(item.attachment.path));
    };
