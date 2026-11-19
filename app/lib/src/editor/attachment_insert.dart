// WI #146 (Spec #123 A4, R12; L2, L14): where one attach action's lines go
// in a note body. Pure Dart, no Flutter imports.

import 'markdown_lines.dart';
import 'segments.dart';

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
///
/// - The group never goes into the footer: an anchor on or below the
///   footer's marker line, or past the body, is the person section's last
///   line.
/// - An anchor on a frontmatter, fence or table line moves to that block's
///   closing line (an unclosed fence's last line).
/// - An empty or whitespace-only anchor line is replaced by the group;
///   otherwise the group goes after the anchor line, which is never split.
/// - One blank line separates the group from the text above and below it,
///   unless the neighbouring line is already blank or the group starts or
///   ends the person section.
/// - The caret goes to the start of the line after the group when that line
///   is in the person section, else to the end of the group's last line.
AttachmentInsertPlan planAttachmentInsert({
  required String body,
  required int? anchorLine,
  required List<String> lines,
  required bool daily,
}) {
  final group = lines.join('\n');
  final all = classifyLines(body, atSegmentStart: true);
  // The person section is lines [0, person).
  final person = _personLineCount(body, all, daily: daily);
  if (person == 0) {
    // The footer's marker is the body's first line.
    return AttachmentInsertPlan(
      start: 0,
      end: 0,
      replacement: '$group\n',
      caret: group.length,
    );
  }
  var at = anchorLine == null || anchorLine >= person ? person - 1 : anchorLine;
  if (at < 0) at = 0;
  at = _blockEnd(all, at);
  if (at >= person) at = person - 1;

  bool blank(int i) => _isBlank(body, all[i]);
  final line = all[at];
  final next = at + 1 < person;
  final below = next && !blank(at + 1);
  final String replacement;
  final int start;
  final int end;
  if (line.kind == MdLineKind.blank) {
    final above = at > 0 && !blank(at - 1);
    replacement = '${above ? '\n' : ''}$group${below ? '\n' : ''}';
    start = line.start;
    end = line.contentEnd;
  } else {
    replacement = '\n\n$group${below ? '\n' : ''}';
    start = line.contentEnd;
    end = line.contentEnd;
  }
  final afterGroup = start + replacement.length;
  // The line after the group starts right after an added blank line, or
  // after the anchor line's own terminator.
  final caret = below
      ? afterGroup
      : next
      ? afterGroup + line.terminator.length
      : afterGroup;
  return AttachmentInsertPlan(
    start: start,
    end: end,
    replacement: replacement,
    caret: caret,
  );
}

/// Whether [line] of [body] is empty or holds only spaces and tabs.
bool _isBlank(String body, MdLine line) =>
    body.substring(line.start, line.contentEnd).trim().isEmpty;

/// How many of [all] (the lines of [body]) are in the person section: the
/// lines above the footer's marker line, or every line without a footer.
int _personLineCount(String body, List<MdLine> all, {required bool daily}) {
  final footer = daily ? _dailyFooterStart(all, body) : _noteFooterStart(body);
  if (footer == null) return all.length;
  return all.indexWhere((l) => l.start == footer);
}

/// The offset of a daily note's first marker line (`splitDailyBody`), or
/// null without one.
int? _dailyFooterStart(List<MdLine> all, String body) {
  for (final line in all) {
    final content = body.substring(line.start, line.contentEnd);
    if (_trimLineEnd(content) == topicsMarker) return line.start;
  }
  return null;
}

/// The offset of another note's Note footer, the first marker line outside
/// fenced code (`splitNoteBody`), or null without one.
int? _noteFooterStart(String body) {
  final segments = split(body, isDaily: false);
  final last = segments.last;
  if (last is! FooterSegment) return null;
  final raw = last.raw;
  return raw == null ? null : body.length - raw.length;
}

/// [content] without trailing spaces and `\r`, as `segments.dart` matches
/// a marker line.
String _trimLineEnd(String content) {
  var end = content.length;
  while (end > 0) {
    final c = content.codeUnitAt(end - 1);
    if (c != 0x20 && c != 0x0D) break;
    end--;
  }
  return content.substring(0, end);
}

/// Line [at] of [all], or the closing line of the frontmatter, fence or
/// table holding it (R12: such a block is never split).
int _blockEnd(List<MdLine> all, int at) {
  final kind = all[at].kind;
  bool within(Set<MdLineKind> kinds) =>
      at + 1 < all.length && kinds.contains(all[at + 1].kind);
  switch (kind) {
    case MdLineKind.frontmatter:
      while (within(const {MdLineKind.frontmatter})) {
        at++;
      }
    case MdLineKind.fenceOpen || MdLineKind.fenceInside:
      while (within(const {MdLineKind.fenceInside, MdLineKind.fenceClose})) {
        at++;
        if (all[at].kind == MdLineKind.fenceClose) break;
      }
    case MdLineKind.tableHeader ||
        MdLineKind.tableDelimiter ||
        MdLineKind.tableBody:
      while (within(const {
        MdLineKind.tableHeader,
        MdLineKind.tableDelimiter,
        MdLineKind.tableBody,
      })) {
        at++;
      }
    default:
      break;
  }
  return at;
}

/// Line [line] of [before] carried into [after], the text an edit made of
/// it (R13: the anchor follows text typed above it). Lines split at `\n`.
/// The edit is taken as the lines between [before] and [after]'s common
/// leading and trailing lines: a line above it keeps its index, a line
/// below it moves by the change in line count, and a line it rewrote in
/// place (one line in, one or more out) stays at that index. Null when the
/// edit removed or replaced the line along with others.
int? carryAttachmentAnchor(String before, String after, int line) {
  if (before == after) return line;
  final b = before.split('\n');
  final a = after.split('\n');
  var prefix = 0;
  while (prefix < b.length && prefix < a.length && b[prefix] == a[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < b.length - prefix &&
      suffix < a.length - prefix &&
      b[b.length - 1 - suffix] == a[a.length - 1 - suffix]) {
    suffix++;
  }
  final changedEnd = b.length - suffix;
  if (line < prefix) return line;
  if (line >= changedEnd) return line + a.length - b.length;
  final out = a.length - suffix - prefix;
  return changedEnd - prefix == 1 && out >= 1 ? prefix : null;
}
