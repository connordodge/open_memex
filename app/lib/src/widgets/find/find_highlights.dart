// WI #83 (Spec #61 F3): the Find in note match highlights, painted as an
// overlay over a field's line boxes (TD2), and the mapping from F1's
// FindInNoteState to one field's paint ranges.
//
// SKELETON (test(#83)): signatures only, no behaviour.
import 'package:flutter/widgets.dart';

import '../../editor/find_in_note.dart';
import '../../state/find_in_note_state.dart';
import '../editor/line_boxes.dart';

/// Test-only work counter: incremented once each time any find highlight
/// layer paints. Tests read deltas to prove a rebuild with unchanged ranges
/// does not repaint the layer.
@visibleForTesting
int debugFindHighlightPaints = 0;

/// How one [FindPaintRange] paints (Reqs 24-26, pack 83).
enum FindPaintStyle {
  /// Every match but the current one: `OmColors.findMatch` fill, a 1 px
  /// inside border in `OmColors.findMatchLine`, radius 2.
  other,

  /// The current match: a solid `OmColors.warn` fill, radius 2, plus a 1 px
  /// outward spread in the same colour.
  current,

  /// A hidden match's outline around the visible text that hides it: the
  /// other-match border only, no fill.
  outline,
}

/// A half-open field-local UTF-16 range `[start, end)` and its paint style.
@immutable
final class FindPaintRange {
  const FindPaintRange(this.start, this.end, this.style);

  /// First code unit, field-local.
  final int start;

  /// One past the last code unit, field-local.
  final int end;

  final FindPaintStyle style;

  @override
  bool operator ==(Object other) =>
      other is FindPaintRange &&
      other.start == start &&
      other.end == end &&
      other.style == style;

  @override
  int get hashCode => Object.hash(start, end, style);

  @override
  String toString() => 'FindPaintRange($start, $end, ${style.name})';
}

/// The paint ranges of one field: the matches of [state] in source
/// ([segment], [kind]) that touch the field's `[start, end)` of that
/// source's text, clipped to the field and made field-local (minus
/// [start]). Nothing while the bar is closed or the query is empty
/// (Req 29).
///
/// - A visible match: [FindPaintStyle.current] when it is the current
///   match, else [FindPaintStyle.other], on its own range.
/// - A hidden non-current body match: [FindPaintStyle.outline] on its
///   `outline` range (nothing when it has none). Hidden matches sharing one
///   outline paint it once.
/// - A hidden current body match, where the field [reveals] (F4 reveals its
///   line): [FindPaintStyle.current] on its own range; a hidden non-current
///   match on that same source line then paints [FindPaintStyle.other] on
///   its own range (pack 83, B3.12).
/// - Where the field does not [reveals] (a table grid cell, D8): every
///   hidden match paints its outline, the current one too.
List<FindPaintRange> findPaintRanges(
  FindInNoteState state, {
  required int segment,
  required FindSourceKind kind,
  required int start,
  required int end,
  bool reveals = true,
}) => const [];

/// The match highlights of one field (Reqs 24-26, 28; TD2; D14, D20): an
/// `IgnorePointer` leaf over the line boxes [boxes] reports, painting one
/// box per line box each of [ranges] touches, in this box's coordinates.
///
/// A box is the range's run on that line (its advance width) and 17 px
/// (scaled with the text) tall, centred on its line box: 3 px below the top
/// of a 22.95 px body line (pack 83). Paints no glyphs. Repaints when
/// [ranges] change (by value) or [repaint] notifies (the field's text or
/// reveal), never on an unrelated rebuild.
class FindHighlights extends LeafRenderObjectWidget {
  const FindHighlights({
    super.key,
    required this.ranges,
    required this.boxes,
    this.repaint,
  });

  /// Field-local ranges and styles, from [findPaintRanges].
  final List<FindPaintRange> ranges;

  /// The measured field's line boxes once laid out, else null.
  final LineBoxSource? Function() boxes;

  /// Notifies when the measured field's layout may have changed.
  final Listenable? repaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFindHighlights();
}

class _RenderFindHighlights extends RenderBox {
  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;
}
