import 'package:flutter/rendering.dart';

import 'echo_arrival_highlight.dart';

// The editor side of the note reveal seam (#66, D1, D3): row lookup, anchor
// maths and the after-frame retry for `NoteEditor._reveal`.

/// The anchor a Text reveal lands on, in [row]'s local coordinates (D3c,
/// D3h): for a prose row, the line boxes holding `[arrival.local, end)` at
/// their real `line.top` (only the line holding `arrival.local` when [end]
/// is null); [end] is a row-local UTF-16 offset into `arrival.rowText`,
/// exclusive. Any other row, or a card, anchors on the whole row.
Rect revealAnchorRect(RenderBox row, EchoArrival arrival, {int? end}) =>
    Rect.zero;
