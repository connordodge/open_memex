// WI #80 (Spec #61 F1, TD8): the frozen Find in note Keys. F2 (Find bar),
// F3 (highlight layers) and F6 (integration, robot journey) import these;
// no other file spells these key strings. Each Key names the box it sits on
// (architect.md section 5).
import 'package:flutter/foundation.dart';

/// The Find bar's root: the opaque floating box itself (38 px tall, the
/// surface3 fill and line2 border), `find-bar`.
const Key findBarKey = Key('');

/// The query `TextField` inside the Find bar, `find-bar-field`.
const Key findBarFieldKey = Key('');

/// The counter's text box (`3 of 12`, `3/12`, `None`), `find-bar-counter`.
const Key findBarCounterKey = Key('');

/// The 24 px previous-match (up) ghost button, `find-bar-previous`.
const Key findBarPreviousKey = Key('');

/// The 24 px next-match (down) ghost button, `find-bar-next`.
const Key findBarNextKey = Key('');

/// The 24 px close (x) ghost button, `find-bar-close`.
const Key findBarCloseKey = Key('');

/// The highlight overlay layer covering body row [row] of text segment
/// [segment]: `find-highlights-<segment>-<row>`.
Key findHighlightsKey(int segment, int row) => const Key('');

/// The highlight overlay layer covering row [row] of the excerpt card at
/// segment [segment]: `find-highlights-card-<segment>-<row>`.
Key findCardHighlightsKey(int segment, int row) => const Key('');

/// The highlight overlay layer covering cell [cell] of grid row [row] of a
/// table shown as a grid in text segment [segment]:
/// `find-highlights-grid-<segment>-<row>-<cell>`.
Key findGridHighlightsKey(int segment, int row, int cell) => const Key('');

/// The highlight overlay layer covering the Source-mode field,
/// `find-highlights-source`.
const Key findSourceHighlightsKey = Key('');
