import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../editor/outline.dart';
import '../../state/note_reveal.dart';
import '../../state/outline_section.dart';

// The Outline's jump (#69, Spec #58 R17-R21, R34, TD4): one request on the
// note reveal seam.

/// How far below the top of the visible body a jump lands a heading line.
const double outlineJumpInset = 16;

/// Jumps the editor showing note [noteId] to [entry]'s heading, 16 px below
/// the top of the visible body, with the arrival highlight. [content] is the
/// live text [entry] came from.
///
/// The seam lands it without animation, from Source mode too, and records
/// the offset; it never moves the caret, focus or history. A note the
/// editor no longer shows, or [content] the editor no longer shows, makes
/// it a no-op. The jumped-to entry is the current section right after it
/// lands (`outlineSectionProvider`).
void jumpToOutlineEntry(
  WidgetRef ref,
  String noteId,
  OutlineEntry entry,
  String content,
) {
  final reveal = ref.read(noteRevealProvider.notifier);
  reveal.request(
    NoteRevealRequest(
      noteId,
      RevealAtText(
        segment: entry.segment,
        start: entry.local,
        content: content,
      ),
      const RevealTop(outlineJumpInset),
      flash: true,
      leaveSource: true,
    ),
  );
  ref
      .read(outlineSectionHubProvider)
      .jumped(
        OutlineJump(
          noteId: noteId,
          entry: entry,
          content: content,
          arrivals: ref.read(noteRevealProvider)?.arrivals,
        ),
      );
}
