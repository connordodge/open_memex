import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tabs_state.dart' show tabsProvider;

// The note reveal seam (#66, architect rulings D1-D6): one "reveal a place in
// the open note" request for every feature that scrolls the editor to a
// passage (the Outline, Find in note, Passages, and echo arrivals through
// `NoteEditor`). The D2 signature below is frozen: #69, #85 and #78 build on
// exactly these names and fields.

/// Where in the note a reveal lands.
sealed class RevealAt {
  const RevealAt();
}

/// A UTF-8 byte offset into the note's STORED `contentMd` (an echo, a
/// Passage). Null: open at the top.
final class RevealAtByte extends RevealAt {
  const RevealAtByte(this.startByte);

  final int? startByte;
}

/// UTF-16 offsets into the text of `split(content)[segment]`, a
/// `TextSegment`; [content] is the live text the offsets came from.
final class RevealAtText extends RevealAt {
  const RevealAtText({
    required this.segment,
    required this.start,
    this.end,
    required this.content,
  });

  final int segment;
  final int start;
  final int? end;
  final String content;
}

/// The whole excerpt card at `split(content)` index [segment].
final class RevealAtCard extends RevealAt {
  const RevealAtCard({required this.segment, required this.content});

  final int segment;
  final String content;
}

/// Where the anchor sits in the viewport after the reveal.
sealed class RevealPlacement {
  const RevealPlacement();
}

/// A third of the way down the viewport (echo, Passage).
final class RevealThird extends RevealPlacement {
  const RevealThird();
}

/// [inset] px below the viewport top; always scrolls (Outline: 16).
final class RevealTop extends RevealPlacement {
  const RevealTop(this.inset);

  final double inset;
}

/// No scroll when the anchor already lies in [viewport top + [topInset],
/// viewport bottom]; else the smallest scroll that brings it there (Find: 60).
final class RevealWithin extends RevealPlacement {
  const RevealWithin(this.topInset);

  final double topInset;
}

/// One request to reveal [at] in note [noteId] at [placement].
final class NoteRevealRequest {
  const NoteRevealRequest(
    this.noteId,
    this.at,
    this.placement, {
    this.flash = false,
    this.leaveSource = false,
  });

  final String noteId;
  final RevealAt at;
  final RevealPlacement placement;

  /// Show the arrival highlight on the anchor's band.
  final bool flash;

  /// In Source mode, switch to live preview and land; otherwise the request
  /// is dropped there.
  final bool leaveSource;
}

/// The pending request with its stamps: a sequence number (two equal
/// requests are two requests) and `tabsProvider.arrivals` when it was made
/// (it is valid only while that is unchanged, D3b).
final class PendingReveal {
  const PendingReveal({
    required this.request,
    required this.seq,
    required this.arrivals,
  });

  final NoteRevealRequest request;
  final int seq;
  final int? arrivals;
}

/// The one-shot reveal request holder: callers navigate or `openOrFocus`
/// first, then [request]; the editor [take]s it (D3a, D3b).
class NoteRevealNotifier extends Notifier<PendingReveal?> {
  /// The last sequence number handed out.
  int _seq = 0;

  @override
  PendingReveal? build() => null;

  /// `tabsProvider.arrivals` now; null when nothing created the tabs.
  int? get _arrivals =>
      ref.exists(tabsProvider) ? ref.read(tabsProvider).arrivals : null;

  /// Holds [r], replacing any earlier request, stamped with the next
  /// sequence number and the current `tabsProvider.arrivals`.
  void request(NoteRevealRequest r) =>
      state = PendingReveal(request: r, seq: ++_seq, arrivals: _arrivals);

  /// The pending request when it is for [noteId] and no arrival came since
  /// it was made (an untaken request dies at the next arrival), else null.
  /// Either way nothing is pending afterwards.
  NoteRevealRequest? take(String noteId) {
    final held = state;
    state = null;
    if (held == null || held.request.noteId != noteId) return null;
    return held.arrivals == _arrivals ? held.request : null;
  }
}

final noteRevealProvider = NotifierProvider<NoteRevealNotifier, PendingReveal?>(
  NoteRevealNotifier.new,
);
