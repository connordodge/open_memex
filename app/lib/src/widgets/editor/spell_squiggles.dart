// WI #437 (Spec #392 reqs 6, 7, 9, 21): painted spelling and grammar
// squiggles under the issues of a field's `SpellIssueRegistry` entry.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../editor/spell_issues.dart';
import '../../theme/colors.dart';
import 'line_boxes.dart';
import 'live_preview_controller.dart';
import 'segment_view.dart';
import 'spell_issue_scope.dart';

/// Test-only work counter: incremented once each time any squiggle layer
/// paints. Tests read deltas to prove a rebuild with an unchanged issue
/// list does not repaint the layer.
@visibleForTesting
int debugSpellSquigglePaints = 0;

/// Where a squiggle's top sits below its line's baseline (architect's probe
/// rule: the band from baseline + 2 to baseline + 4 px).
const double _squiggleDrop = 2;

/// The squiggle's vertical thickness.
const double _squiggleThickness = 1;

/// How far the squiggle's top rises and falls; with [_squiggleThickness] it
/// stays inside the 2 px band.
const double _squiggleAmplitude = 0.9;

/// Half a wave's length.
const double _squiggleHalfWave = 2;

/// Wraps the field [child] of [controller] (Spec #392 reqs 6, 7, 9, 21):
/// paints a 1 px wavy underline under each of the field's issues in the
/// nearest [SpellIssueScope]'s registry (spelling in [OmColors.danger],
/// grammar in [OmColors.info]), its top at its line's baseline + 2 px, over
/// exactly the flagged characters of every line the issue covers, and adds a
/// semantics hint naming the issues (`misspelled: teh`, `grammar: <the
/// checker's description>`).
///
/// The squiggles are a painted foreground layer above the field's text: the
/// field's text span, line heights, caret and layout are untouched. The
/// layer is its own repaint boundary and repaints only when the issue list,
/// the field's value (text, selection), its reveal gate, its scroll or its
/// size change, or its segment's value changes while the row's selection
/// equals a flagged range; never on an unrelated rebuild.
///
/// No squiggle and no hint while [controller] is an unrevealed table row's
/// (its field is offstage). A non-collapsed selection that covers an issue's
/// range hides that squiggle, unless it equals the range. For a segment
/// row ([host] and [index] given) "equals" is judged on the segment's own
/// selection, so a selection that runs on into a neighbouring row hides the
/// squiggle even where the row's clamped slice of it equals the range.
/// Without a scope above, [child] is returned as is.
class SpellSquiggles extends StatelessWidget {
  const SpellSquiggles({
    super.key,
    required this.controller,
    required this.child,
    this.host,
    this.index,
  });

  /// The wrapped field's controller (its issues' registry key).
  final TextEditingController controller;

  /// The segment the field is row [index] of; null outside one (Source
  /// mode, a field pumped alone).
  final SegmentViewState? host;

  /// The field's row index in [host].
  final int? index;

  /// The field.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final registry = SpellIssueScope.maybeOf(context);
    if (registry == null) return child;
    final controller = this.controller;
    final issues = registry.issuesFor(controller);
    final gate = controller is LivePreviewController
        ? controller.revealGate
        : null;
    return ListenableBuilder(
      listenable: Listenable.merge([issues, controller, ?gate]),
      builder: (context, child) {
        final hint = spellIssuesHint(controller, issues.value);
        return Semantics(
          container: hint != null,
          explicitChildNodes: hint != null,
          hint: hint,
          child: child,
        );
      },
      child: Stack(
        fit: StackFit.passthrough,
        clipBehavior: Clip.none,
        children: [
          child,
          Positioned.fill(
            child: IgnorePointer(
              child: _SquiggleLayer(
                controller: controller,
                issues: issues,
                gate: gate,
                host: host,
                index: index,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The semantics hint naming [issues] of [controller]'s field, one entry per
/// issue in list order (`misspelled: <word>`, `grammar: <description>`),
/// or null when there are none or the field is an unrevealed table row's.
String? spellIssuesHint(
  TextEditingController controller,
  List<SpellIssue> issues,
) {
  if (_hidden(controller)) return null;
  final text = controller.text;
  final names = <String>[];
  for (final issue in issues) {
    final range = _clamped(issue, text.length);
    final flagged = range == null ? '' : range.textInside(text);
    switch (issue.kind) {
      case SpellIssueKind.spelling:
        if (flagged.isNotEmpty) names.add('misspelled: $flagged');
      case SpellIssueKind.grammar:
        final what = issue.description ?? flagged;
        if (what.isNotEmpty) names.add('grammar: $what');
    }
  }
  return names.isEmpty ? null : names.join('; ');
}

/// Whether [controller]'s field is an unrevealed table row's (offstage).
bool _hidden(TextEditingController controller) =>
    controller is LivePreviewController &&
    controller.tableRow &&
    !controller.tableRevealed;

/// [issue]'s range inside a text of [length], or null when nothing of it is.
TextRange? _clamped(SpellIssue issue, int length) {
  final start = issue.start.clamp(0, length);
  final end = (issue.start + issue.length).clamp(start, length);
  return start < end ? TextRange(start: start, end: end) : null;
}

/// Whether [selection] hides the squiggle of [range] (req 9): it is not
/// collapsed and covers the range, without being equal to it. [equal]
/// overrides the equality check (a segment row's selection is clamped to
/// the row, so equality is judged on the segment's selection).
bool _selectionHides(
  TextSelection selection,
  TextRange range, {
  bool Function(TextRange range)? equal,
}) =>
    selection.isValid &&
    !selection.isCollapsed &&
    selection.start <= range.start &&
    selection.end >= range.end &&
    !(selection.start == range.start &&
        selection.end == range.end &&
        (equal == null || equal(range)));

class _SquiggleLayer extends LeafRenderObjectWidget {
  const _SquiggleLayer({
    required this.controller,
    required this.issues,
    required this.gate,
    required this.host,
    required this.index,
  });

  final TextEditingController controller;
  final ValueListenable<List<SpellIssue>> issues;
  final Listenable? gate;
  final SegmentViewState? host;
  final int? index;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSquiggles(controller, issues, gate, host, index);

  @override
  void updateRenderObject(BuildContext context, _RenderSquiggles render) =>
      render.watch(controller, issues, gate, host, index);
}

/// Paints the squiggles of the field laid out in the nearest stack above
/// (the [SpellSquiggles] stack, whose first child holds the field), in this
/// box's coordinates.
class _RenderSquiggles extends RenderBox {
  _RenderSquiggles(
    this._controller,
    this._issues,
    this._gate,
    this._host,
    this._index,
  ) : _segment = _host?.widget.controller;

  TextEditingController _controller;
  ValueListenable<List<SpellIssue>> _issues;
  Listenable? _gate;

  /// The segment this field is row [_index] of, and its controller: a
  /// segment selection change can leave the row's clamped slice unchanged
  /// while changing whether it equals a flagged range.
  SegmentViewState? _host;
  int? _index;
  TextEditingController? _segment;

  /// The measured field's scroll offset, listened to once seen.
  ViewportOffset? _scroll;

  Iterable<Listenable> get _sources => [_controller, _issues, ?_gate];

  void watch(
    TextEditingController controller,
    ValueListenable<List<SpellIssue>> issues,
    Listenable? gate,
    SegmentViewState? host,
    int? index,
  ) {
    final segment = host?.widget.controller;
    if (identical(controller, _controller) &&
        identical(issues, _issues) &&
        identical(gate, _gate) &&
        identical(host, _host) &&
        identical(segment, _segment) &&
        index == _index) {
      return;
    }
    _unlisten();
    _controller = controller;
    _issues = issues;
    _gate = gate;
    _host = host;
    _index = index;
    _segment = segment;
    if (attached) _listen();
    markNeedsPaint();
  }

  void _listen() {
    for (final source in _sources) {
      source.addListener(markNeedsPaint);
    }
    _segment?.addListener(_segmentChanged);
  }

  void _unlisten() {
    if (!attached) return;
    for (final source in _sources) {
      source.removeListener(markNeedsPaint);
    }
    _segment?.removeListener(_segmentChanged);
  }

  /// Whether the last paint judged a squiggle on the segment's selection
  /// (the row's selection equalled a flagged range). Every other input of
  /// the paint (the row's value, the issues, the gate, the scroll, the
  /// size) repaints on its own, so only then can a segment change alone
  /// flip what the layer paints.
  bool _segmentConsulted = false;

  /// The segment's value changed: repaint only when the last paint
  /// consulted the segment's selection.
  void _segmentChanged() {
    if (_segmentConsulted) markNeedsPaint();
  }

  /// Whether the segment's selection equals [range] of this row, in segment
  /// offsets; true outside a segment (the row's selection is the truth).
  bool _segmentEquals(TextRange range) {
    _segmentConsulted = true;
    final host = _host;
    final index = _index;
    final spec = host == null || index == null ? null : host.rowSpec(index);
    if (host == null || spec == null) return true;
    final segment = host.selection;
    if (!segment.isValid) return true;
    return segment.start == spec.textStart + range.start &&
        segment.end == spec.textStart + range.end;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listen();
  }

  @override
  void detach() {
    _unlisten();
    _scroll?.removeListener(markNeedsPaint);
    _scroll = null;
    super.detach();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(PaintingContext context, Offset offset) {
    debugSpellSquigglePaints++;
    _segmentConsulted = false;
    final editable = findRenderEditable(_stack);
    if (editable == null || !editable.hasSize) return;
    _follow(editable.offset);
    final issues = _issues.value;
    if (issues.isEmpty || _hidden(_controller)) return;

    final length = editable.plainText.length;
    final selection = _controller.selection;
    final boxes = RenderEditableLineBoxes(editable);
    final lines = boxes.lines;
    final toHere = editable.getTransformTo(this);
    final canvas = context.canvas;
    for (final issue in issues) {
      final range = _clamped(issue, length);
      if (range == null ||
          _selectionHides(selection, range, equal: _segmentEquals)) {
        continue;
      }
      final paint = Paint()
        ..color = switch (issue.kind) {
          SpellIssueKind.spelling => OmColors.danger,
          SpellIssueKind.grammar => OmColors.info,
        };
      for (final rect in boxes.boxesFor(range)) {
        final line = _lineOf(lines, rect);
        if (line == null || rect.width <= 0) continue;
        final left = MatrixUtils.transformPoint(
          toHere,
          Offset(rect.left, line.baseline),
        );
        final right = MatrixUtils.transformPoint(
          toHere,
          Offset(rect.right, line.baseline),
        );
        canvas.drawPath(
          _wave(left.dx, right.dx, left.dy + _squiggleDrop).shift(offset),
          paint,
        );
      }
    }
  }

  /// The [SpellSquiggles] stack this layer sits in, over the field.
  RenderStack? get _stack {
    for (var node = parent; node != null; node = node.parent) {
      if (node is RenderStack) return node;
    }
    return null;
  }

  /// Repaints when the field scrolls its text.
  void _follow(ViewportOffset scroll) {
    if (identical(scroll, _scroll)) return;
    _scroll?.removeListener(markNeedsPaint);
    _scroll = scroll..addListener(markNeedsPaint);
  }

  /// The line of [lines] whose box spans [rect] (a `boxesFor` rect spans
  /// its line box's full height).
  static LineBox? _lineOf(List<LineBox> lines, Rect rect) {
    final y = rect.center.dy;
    for (final line in lines) {
      if (y >= line.top && y < line.bottom) return line;
    }
    return null;
  }

  /// A wavy band [_squiggleThickness] tall from [left] to [right], its top
  /// zig-zagging between [top] and [top] + [_squiggleAmplitude].
  static Path _wave(double left, double right, double top) {
    double topAt(double x) {
      final t = (x - left) / _squiggleHalfWave;
      final step = t.floor();
      final f = t - step;
      return top + _squiggleAmplitude * (step.isEven ? f : 1 - f);
    }

    final xs = <double>[
      left,
      for (var x = left + _squiggleHalfWave; x < right; x += _squiggleHalfWave)
        x,
      math.max(left, right),
    ];
    final path = Path()..moveTo(xs.first, topAt(xs.first));
    for (final x in xs.skip(1)) {
      path.lineTo(x, topAt(x));
    }
    for (final x in xs.reversed) {
      path.lineTo(x, topAt(x) + _squiggleThickness);
    }
    return path..close();
  }
}
