// WI #148 (Spec #123 R46-R48, A3): the Command palette's Attachments group,
// fed by the same `search` run as Passages, and its chooser.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../vault_access/attachments_access.dart';
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

/// Reports that opening the Attachments row named `name` failed with
/// `failure` (Spec #123 R42, ruling D22).
typedef PaletteAttachmentOpenFailure =
    void Function(String name, AttachmentLookupFailure failure);

/// Where a failed open of a chosen Attachments row is reported. The
/// chooser calls the provided function when the row is chosen, before it
/// opens the file, and reports the open's failure, if any, to the reporter
/// it returned, which may run after the palette has closed. The widget
/// layer overrides it to close the palette at that call (Spec #59 req 8)
/// and to show the R42 toast over the context the palette was opened over.
/// Default: closes nothing and reports nothing.
final paletteAttachmentOpenFailureProvider =
    Provider.autoDispose<PaletteAttachmentOpenFailure Function()>(
      (ref) =>
          () => (_, _) {},
    );

/// Chooses an Attachments row (D10): opens its path through the open
/// vault's attachments domain (`attachmentsProvider`), which downloads a
/// hosted file first and reveals an executable instead (R33). It first
/// takes its reporter from `paletteAttachmentOpenFailureProvider` (the
/// shell closes the palette then), then opens; a failed open goes to that
/// reporter. The Cmd flag changes nothing: a file has no tab. With no
/// open vault it does nothing.
PaletteChooser<AttachmentItem> paletteAttachmentChooser(Ref ref) =>
    (item, {required newTab}) {
      final attachments = ref.read(attachmentsProvider);
      if (attachments == null) return;
      final report = ref.read(paletteAttachmentOpenFailureProvider)();
      final name = item.attachment.name;
      unawaited(
        attachments.open(item.attachment.path).then((result) {
          if (result case AttachmentActionFailed(:final failure)) {
            report(name, failure);
          }
        }),
      );
    };
