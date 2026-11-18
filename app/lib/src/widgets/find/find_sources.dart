// WI #80 (Spec #61 F1): the hidden ranges of a live-preview text, for
// `FindSource.hidden` (Reqs 4, 26). Apart from the pure `find_in_note.dart`
// because it reads `buildLivePreviewSpan`'s span tree (package:flutter). It
// only reads that tree: `live_preview_controller.dart` is #57's until F4.
import '../../editor/find_in_note.dart';

/// The UTF-16 runs of [text] that `buildLivePreviewSpan(text, forceHidden:
/// true, itemText: itemText, codeRow: codeRow)` styles with
/// `livePreviewHiddenStyle` (zero width), in order: a link's `[` and
/// `](url)`, a bold run's `**` markers, a heading's `# `. Empty for plain
/// text.
List<FindRange> livePreviewHiddenRanges(
  String text, {
  bool itemText = false,
  bool codeRow = false,
}) => const [];
