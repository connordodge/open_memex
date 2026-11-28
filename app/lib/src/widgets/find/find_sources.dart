// WI #80 (Spec #61 F1): the hidden ranges of a live-preview text, for
// `FindSource.hidden` (Reqs 4, 26). Apart from the pure `find_in_note.dart`
// because it reads `buildLivePreviewSpan`'s span tree (package:flutter). It
// only reads that tree: `live_preview_controller.dart` is #57's until F4.
import 'package:flutter/painting.dart';

import '../../editor/find_in_note.dart';
import '../editor/live_preview_controller.dart' show buildLivePreviewSpan;
import '../editor/live_preview_styles.dart' show livePreviewHiddenStyle;

/// The UTF-16 runs of [text] that `buildLivePreviewSpan(text, forceHidden:
/// true, itemText: itemText, codeRow: codeRow)` styles with
/// `livePreviewHiddenStyle` (zero width), in order: a link's `[` and
/// `](url)`, a bold run's `**` markers, a heading's `# `. Empty for plain
/// text.
///
/// Adjacent hidden runs join into one range. A child span with no style of
/// its own inherits whether its parent is hidden.
List<FindRange> livePreviewHiddenRanges(
  String text, {
  bool itemText = false,
  bool codeRow = false,
}) {
  final root = buildLivePreviewSpan(
    text,
    forceHidden: true,
    itemText: itemText,
    codeRow: codeRow,
  );
  final out = <FindRange>[];
  var at = 0;
  void walk(InlineSpan span, bool parentHidden) {
    if (span is! TextSpan) {
      // A placeholder is one code unit of plain text (U+FFFC); the builder
      // makes none today.
      at += 1;
      return;
    }
    final style = span.style;
    final hidden = style == null
        ? parentHidden
        : style == livePreviewHiddenStyle;
    final length = span.text?.length ?? 0;
    if (hidden && length > 0) {
      if (out.isNotEmpty && out.last.end == at) {
        out.last = FindRange(out.last.start, at + length);
      } else {
        out.add(FindRange(at, at + length));
      }
    }
    at += length;
    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child, hidden);
    }
  }

  walk(root, false);
  return out;
}
