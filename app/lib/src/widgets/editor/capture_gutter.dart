import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../dates.dart';
import '../../db/daily_reads.dart';
import '../../editor/byte_offsets.dart';
import '../../state/daily_state.dart';
import '../../state/vault_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import 'line_boxes.dart';
import 'segment_view.dart' show SegmentLineBoxes;

// The captured-text gutter (WI #28, Req 33): a thin rule beside a daily
// note's person field for every `agent` and `quick-entry` block, aligned to
// the lines the block occupies in the field, with a hover caption saying who
// added it and when. The field itself stays one editable text.

/// Test-only work counter: every read of measured lines the gutter takes
/// from its source rather than from its own row cache (one per editor row
/// whose text or size changed, or one whole-field read without rows),
/// summed over all gutters (WI #129, Spec #122 R11).
@visibleForTesting
int debugCaptureGutterLineReads = 0;

/// Width of the gutter column left of the person field.
const double captureGutterWidth = 14;

/// Width of one rule inside the gutter.
const double _ruleWidth = 2;

/// Block sources that get a rule.
const Set<String> _capturedSources = {'agent', 'quick-entry'};

/// The rule colour of a captured block's [source]: the agent token for
/// `agent`, the info token for `quick-entry`.
Color captureRuleColor(String source) =>
    source == 'agent' ? OmColors.agent : OmColors.info;

/// The C5 hover caption of a captured block: `captured via agent, 14:32` or
/// `added via quick entry, 14:32` (its `created_at`, local time).
String captureCaption(BlockRow block) {
  final at = DateTime.fromMillisecondsSinceEpoch(block.createdAt);
  return block.source == 'agent'
      ? formatCapturedViaAgent(at)
      : formatAddedViaQuickEntry(at);
}

/// Where [block] sits in the field's [text], as UTF-16 indexes.
///
/// Its stored UTF-8 byte range is converted with [utf8ToUtf16] (never used as
/// a string index). When the field's text no longer holds the block's text
/// at that range (unsaved edits moved it), the first occurrence of the text
/// is used instead; null when the text is gone.
TextRange? capturedRange(String text, BlockRow block) {
  try {
    final start = utf8ToUtf16(text, block.startByte);
    final end = utf8ToUtf16(text, block.endByte);
    if (text.substring(start, end) == block.text) {
      return TextRange(start: start, end: end);
    }
  } on ArgumentError {
    // The range is past the text or splits a character: look the text up.
  }
  final at = text.indexOf(block.text);
  if (at < 0) return null;
  return TextRange(start: at, end: at + block.text.length);
}

/// The gutter column (Key `capture-gutter`) beside the daily person field of
/// note [noteId]: one rule (Key `capture-gutter-rule-<blockId>`) per agent
/// or quick-entry block of the note, spanning that block's lines in the
/// field. [controller] is the field's text. Its lines come from [boxes] (the
/// person segment's editor rows, in segment offsets) or, without it, from
/// the single field [editable] finds. Rules are measured after layout,
/// whenever the text, the blocks or the gutter's size change.
class CaptureGutter extends ConsumerStatefulWidget {
  const CaptureGutter({
    super.key,
    required this.noteId,
    required this.controller,
    this.editable,
    this.boxes,
  });

  final String noteId;
  final TextEditingController controller;
  final RenderEditable? Function()? editable;
  final LineBoxSource? Function()? boxes;

  @override
  ConsumerState<CaptureGutter> createState() => _CaptureGutterState();
}

/// One measured rule: the block, its caption and its vertical span in the
/// gutter (records compare by value, so an unchanged measure is a no-op).
typedef _Rule = ({
  String blockId,
  String source,
  String caption,
  double top,
  double bottom,
});

/// One editor row's measured lines and the text and size they were measured
/// at.
typedef _RowLines = ({String text, Size size, List<LineBox> lines});

class _CaptureGutterState extends ConsumerState<CaptureGutter> {
  List<BlockRow> _blocks = const [];
  List<_Rule> _rules = const [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scheduleMeasure);
  }

  @override
  void didUpdateWidget(CaptureGutter old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_scheduleMeasure);
      widget.controller.addListener(_scheduleMeasure);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scheduleMeasure);
    super.dispose();
  }

  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  /// The measured lines' source: [CaptureGutter.boxes], else the single
  /// field's.
  LineBoxSource? _source() {
    if (widget.boxes case final boxes?) return boxes();
    final editable = widget.editable?.call();
    return editable == null ? null : RenderEditableLineBoxes(editable);
  }

  /// Positions each captured block's rule from the field's real line boxes
  /// (R33): from the top of the line holding the block's first character to
  /// the bottom of the line holding its last, in the gutter's coordinates.
  ///
  /// Over editor rows ([SegmentLineBoxes]) only the rows holding a block's
  /// ends are read, and a row's lines are measured again only when its text
  /// or laid-out size changed (WI #129, Spec #122 R11); a row that moved
  /// keeps its lines and takes its new position.
  void _measure() {
    if (!mounted) return;
    final source = _source();
    if (source == null) return;
    final gutter = context.findRenderObject();
    if (gutter is! RenderBox) return;
    final text = widget.controller.text;
    final dy = gutter.globalToLocal(source.box.localToGlobal(Offset.zero)).dy;
    List<LineBox>? lines;
    final measured = <RenderBox, _RowLines>{};
    LineBox holding(int offset) => source is SegmentLineBoxes
        ? _rowLine(source, text, offset, measured)
        : lineHolding(lines ??= _readLines(source), offset);
    final rules = <_Rule>[];
    for (final block in _blocks) {
      if (!_capturedSources.contains(block.source)) continue;
      final range = capturedRange(text, block);
      if (range == null) continue;
      final first = holding(range.start);
      final last = holding(math.max(range.start, range.end - 1));
      rules.add((
        blockId: block.blockId,
        source: block.source,
        caption: captureCaption(block),
        top: dy + first.top,
        bottom: dy + last.bottom,
      ));
    }
    _rowLines = measured;
    if (!listEquals(rules, _rules)) setState(() => _rules = rules);
  }

  /// [source]'s measured lines, counted in [debugCaptureGutterLineReads].
  List<LineBox> _readLines(LineBoxSource source) {
    debugCaptureGutterLineReads++;
    return source.lines;
  }

  /// The lines of the rows the last [_measure] read, by their text slot's
  /// box.
  Map<RenderBox, _RowLines> _rowLines = const {};

  /// The line holding segment [offset] of [text] in the rows' box: its
  /// row's lines (the last measure's while the row's text and size are the
  /// same, else measured now, kept in [measured]) shifted to where the row
  /// sits now. A row's first line starts at its marker.
  LineBox _rowLine(
    SegmentLineBoxes rows,
    String text,
    int offset,
    Map<RenderBox, _RowLines> measured,
  ) {
    final row = rows.rowHolding(offset);
    final spec = row.spec;
    final box = row.source.box;
    final rowText = text.substring(spec.textStart, spec.textEnd);
    final size = box.size;
    final cached = measured[box] ?? _rowLines[box];
    final lines =
        cached != null && cached.size == size && cached.text == rowText
        ? cached.lines
        : _readLines(row.source);
    measured[box] = (text: rowText, size: size, lines: lines);
    final line = lineHolding(lines, spec.toLocal(offset));
    return LineBox(
      range: line.range,
      top: line.top + row.shift.dy,
      bottom: line.bottom + row.shift.dy,
      baseline: line.baseline + row.shift.dy,
    );
  }

  @override
  Widget build(BuildContext context) {
    _blocks = watchVaultValue(
      ref,
      blocksForNoteAsyncProvider(widget.noteId),
      const <BlockRow>[],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        _scheduleMeasure();
        return Stack(
          key: const Key('capture-gutter'),
          children: [
            for (final rule in _rules)
              Positioned(
                left: 0,
                width: captureGutterWidth,
                top: rule.top,
                height: rule.bottom - rule.top,
                child: Tooltip(
                  key: Key('capture-gutter-rule-${rule.blockId}'),
                  message: rule.caption,
                  textStyle: OmType.mono(size: 11, color: OmColors.fg0),
                  decoration: BoxDecoration(
                    color: OmColors.surface4,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Center(
                    child: SizedBox(
                      width: _ruleWidth,
                      height: double.infinity,
                      child: ColoredBox(color: captureRuleColor(rule.source)),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
