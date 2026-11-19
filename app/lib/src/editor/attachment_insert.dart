// WI #146 (Spec #123 A4, R12; L2, L14): where one attach action's lines go
// in a note body. Pure Dart, no Flutter imports.

/// The edit that places one action's attachment lines in a note body (R12):
/// replace `[start, end)` of the body with [replacement], then put the caret
/// at [caret] (an offset into the edited body). Offsets are UTF-16 offsets.
class AttachmentInsertPlan {
  const AttachmentInsertPlan({
    required this.start,
    required this.end,
    required this.replacement,
    required this.caret,
  });

  final int start;
  final int end;
  final String replacement;

  /// The caret offset in the body after the edit.
  final int caret;
}

/// The R12 insertion of [lines] (the stored attachments' markdown, one line
/// each, in drop or pick order) into [body], after line [anchorLine]
/// (0-based, lines split at `\n`); null [anchorLine] means the end of the
/// person section (no caret, R10). [daily] says which footer the body may
/// have: the Topics footer of a daily note (`splitDailyBody`) or the Note
/// footer of any other note (`splitNoteBody`).
AttachmentInsertPlan planAttachmentInsert({
  required String body,
  required int? anchorLine,
  required List<String> lines,
  required bool daily,
}) => const AttachmentInsertPlan(start: 0, end: 0, replacement: '', caret: 0);
