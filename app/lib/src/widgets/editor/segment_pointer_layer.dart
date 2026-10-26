import 'dart:async' show scheduleMicrotask;
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../editor/editor_rows.dart';
import '../../editor/markdown_lines.dart';
import '../../editor/row_geometry.dart';
import '../../editor/segment_selection.dart';
import '../../theme/colors.dart';
import 'line_boxes.dart';
import 'live_preview_styles.dart';
import 'segment_view.dart';

/// How far inside the editor page's top or bottom edge a drag starts to
/// scroll the page (Spec R26).
const double _autoScrollZone = 40;

/// The page's scroll speed, in px per second, while a drag is at (or past)
/// the page's edge; it falls off linearly to 0 at [_autoScrollZone].
const double _autoScrollSpeed = 1200;

/// Pointer selection over one text segment's editor rows (Spec R26, R28,
/// D8, D11, TD5): a gesture layer around the segment's rows that C1 creates
/// and C3 fills.
///
/// - A primary-button mouse press puts the caret at the pressed offset and
///   focuses the row holding it; a drag from there selects across rows
///   (hit-tested through the segment's `LineBoxSource.offsetAt`), live while
///   the button is down. A drag over a marker column extends to that item's
///   text start; above the rows it clamps to the segment's start, below them
///   (an excerpt card, the Topics footer) to its end (A4 `clampToSegment`).
/// - Shift+click (and Shift+drag) extends the segment selection from its
///   base to the pressed offset.
/// - A plain click, a double or triple click and a Cmd+click stay the
///   row's (and the link region's): the layer only wins the gesture arena
///   for a drag or a Shift+press.
/// - Dragging into the editor page's top or bottom edge zone scrolls the
///   page while the selection keeps extending under the pointer.
/// - `SelectAllTextIntent` (Cmd+A) selects the whole text segment.
/// - The segment selection's newline marks ([newlineMarks]) are painted
///   behind the rows in `OmColors.selection`.
///
/// The layer is in the rows' `TextFieldTapRegion` group, so a press on it
/// doesn't unfocus the focused row, and shows the text cursor.
class SegmentPointerLayer extends StatefulWidget {
  const SegmentPointerLayer({super.key, required this.child});

  /// The segment's rows.
  final Widget child;

  @override
  State<SegmentPointerLayer> createState() => _SegmentPointerLayerState();
}

/// One tracked primary-button mouse press and its gesture arena entry.
class _Press implements GestureArenaMember {
  _Press({
    required this.pointer,
    required this.down,
    required this.base,
    required this.onReject,
  }) : position = down;

  final int pointer;

  /// Where the press went down (global).
  final Offset down;

  /// The selection's base (segment offset).
  final int base;

  /// The pointer's last position (global).
  Offset position;

  /// True once the layer won the arena: the press is a drag or Shift+press.
  bool accepted = false;

  late final GestureArenaEntry entry;

  final void Function(_Press press) onReject;

  @override
  void acceptGesture(int pointer) => accepted = true;

  @override
  void rejectGesture(int pointer) => onReject(this);
}

class _SegmentPointerLayerState extends State<SegmentPointerLayer>
    with SingleTickerProviderStateMixin {
  _Press? _press;
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;

  SegmentViewState? get _host =>
      context.findAncestorStateOfType<SegmentViewState>();

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  /// The segment offset under global [point]: 0 above the rows, the
  /// segment's end below them, else the rows' nearest offset (never inside
  /// a surrogate pair). Null before the rows are laid out.
  int? _offsetAt(SegmentViewState host, Offset point) {
    final boxes = host.lineBoxes();
    if (boxes == null) return null;
    final local = boxes.box.globalToLocal(point);
    final int offset;
    if (local.dy < 0) {
      offset = 0;
    } else if (local.dy >= boxes.box.size.height) {
      offset = host.text.length;
    } else {
      offset = boxes.offsetAt(local);
    }
    return clampToSegment(
      SegmentSelection.collapsed(offset),
      host.text,
    ).extentOffset;
  }

  /// The focus nodes of the segment's row fields, in row order.
  List<FocusNode> _rowFocusNodes() {
    final nodes = <FocusNode>[];
    void visit(Element element) {
      final widget = element.widget;
      if (widget is EditableText) {
        nodes.add(widget.focusNode);
      } else {
        element.visitChildren(visit);
      }
    }

    context.visitChildElements(visit);
    return nodes;
  }

  /// Focuses the row holding segment [offset] unless it has focus. With
  /// [keep], [keep] becomes the segment selection again once the focus
  /// change has settled (a row taking focus reports its own slice).
  void _focusRowAt(SegmentViewState host, int offset, {TextSelection? keep}) {
    final nodes = _rowFocusNodes();
    final rows = splitRows(host.text, atSegmentStart: true);
    if (nodes.length != rows.length) return;
    final i = rows.indexWhere((row) => offset < row.end);
    final node = nodes[i < 0 ? rows.length - 1 : i];
    if (node.hasFocus) return;
    node.requestFocus();
    if (keep != null) {
      // Runs after the focus manager's own microtask.
      scheduleMicrotask(() {
        if (mounted && host.mounted) host.select(keep);
      });
    }
  }

  void _onDown(PointerDownEvent event) {
    if (_press != null ||
        event.kind != PointerDeviceKind.mouse ||
        event.buttons != kPrimaryButton) {
      return;
    }
    final keyboard = HardwareKeyboard.instance;
    // A Cmd+click belongs to the link region (B3).
    if (keyboard.isMetaPressed) return;
    final host = _host;
    if (host == null) return;
    final at = _offsetAt(host, event.position);
    if (at == null) return;
    final shift = keyboard.isShiftPressed;
    final current = host.selection;
    final press = _Press(
      pointer: event.pointer,
      down: event.position,
      base: shift && current.isValid ? current.baseOffset : at,
      onReject: _onReject,
    );
    press.entry = GestureBinding.instance.gestureArena.add(
      event.pointer,
      press,
    );
    _press = press;
    if (shift) {
      final selection = TextSelection(baseOffset: press.base, extentOffset: at);
      host.select(selection);
      if (host.focusedRow == null) _focusRowAt(host, at, keep: selection);
      press.entry.resolve(GestureDisposition.accepted);
    } else {
      // As a macOS field does on mouse down: the caret goes to the press.
      host.select(TextSelection.collapsed(offset: at));
      _focusRowAt(host, at);
    }
  }

  void _onMove(PointerMoveEvent event) {
    final press = _press;
    if (press == null || event.pointer != press.pointer) return;
    press.position = event.position;
    if (!press.accepted &&
        (event.position - press.down).distance > kPrecisePointerHitSlop) {
      // Before the row's own tap-and-drag recognizer sees this move.
      press.entry.resolve(GestureDisposition.accepted);
    }
    if (!press.accepted) return;
    _extend(press);
    _updateAutoScroll();
  }

  void _onUp(PointerEvent event) {
    final press = _press;
    if (press == null || event.pointer != press.pointer) return;
    _press = null;
    _ticker?.stop();
    // A click: the row's (or the empty area's) tap recognizer takes it.
    if (!press.accepted) press.entry.resolve(GestureDisposition.rejected);
  }

  void _onReject(_Press press) {
    if (!identical(press, _press)) return;
    _press = null;
    _ticker?.stop();
  }

  /// Extends the segment selection from [press]'s base to the offset under
  /// the pointer.
  void _extend(_Press press) {
    final host = _host;
    if (host == null) return;
    final at = _offsetAt(host, press.position);
    if (at == null) return;
    final next = clampToSegment(
      SegmentSelection(baseOffset: press.base, extentOffset: at),
      host.text,
    );
    final selection = TextSelection(
      baseOffset: next.baseOffset,
      extentOffset: next.extentOffset,
    );
    if (selection != host.selection) host.select(selection);
  }

  /// The editor page's scroll velocity (px per second, positive down) for a
  /// drag at global [point]: non-zero inside the page's edge zones.
  double _scrollVelocity(Offset point) {
    final box = Scrollable.maybeOf(context)?.context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return 0;
    final top = box.localToGlobal(Offset.zero).dy;
    final toBottom = top + box.size.height - point.dy;
    final toTop = point.dy - top;
    if (toBottom < _autoScrollZone) {
      return _autoScrollSpeed * math.min(1, 1 - toBottom / _autoScrollZone);
    }
    if (toTop < _autoScrollZone) {
      return -_autoScrollSpeed * math.min(1, 1 - toTop / _autoScrollZone);
    }
    return 0;
  }

  /// Starts or stops scrolling the page for the dragging press.
  void _updateAutoScroll() {
    final press = _press;
    if (press == null || _scrollVelocity(press.position) == 0) {
      _ticker?.stop();
      return;
    }
    final ticker = _ticker ??= createTicker(_onTick);
    if (!ticker.isActive) {
      _lastTick = Duration.zero;
      ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final dt =
        (elapsed - _lastTick).inMicroseconds / Duration.microsecondsPerSecond;
    _lastTick = elapsed;
    final press = _press;
    final position = Scrollable.maybeOf(context)?.position;
    final velocity = press == null ? 0.0 : _scrollVelocity(press.position);
    if (press == null || position == null || velocity == 0) {
      _ticker?.stop();
      return;
    }
    final target = (position.pixels + velocity * dt).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target != position.pixels) position.jumpTo(target);
    _extend(press);
  }

  void _selectAll() {
    final host = _host;
    if (host == null) return;
    host.select(TextSelection(baseOffset: 0, extentOffset: host.text.length));
  }

  @override
  Widget build(BuildContext context) {
    final host = _host;
    if (host == null) return widget.child;
    return Actions(
      actions: <Type, Action<Intent>>{
        SelectAllTextIntent: CallbackAction<SelectAllTextIntent>(
          onInvoke: (_) {
            _selectAll();
            return null;
          },
        ),
      },
      child: TextFieldTapRegion(
        child: MouseRegion(
          cursor: SystemMouseCursors.text,
          child: Listener(
            onPointerDown: _onDown,
            onPointerMove: _onMove,
            onPointerUp: _onUp,
            onPointerCancel: _onUp,
            child: _NewlineMarkLayer(
              controller: host.widget.controller,
              revealGate: host.widget.revealGate,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the newline marks of [controller]'s selection (the segment's
/// text and selection) behind the segment's rows.
class _NewlineMarkLayer extends SingleChildRenderObjectWidget {
  const _NewlineMarkLayer({
    required this.controller,
    required this.revealGate,
    required super.child,
  });

  final TextEditingController controller;

  /// Revealing markers moves line ends.
  final Listenable revealGate;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNewlineMarks(controller, revealGate);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderNewlineMarks renderObject,
  ) => renderObject.watch(controller, revealGate);
}

class _RenderNewlineMarks extends RenderProxyBox {
  _RenderNewlineMarks(this._controller, this._revealGate);

  TextEditingController _controller;
  Listenable _revealGate;

  Listenable get _changes => Listenable.merge([_controller, _revealGate]);

  void watch(TextEditingController controller, Listenable revealGate) {
    if (!identical(controller, _controller) ||
        !identical(revealGate, _revealGate)) {
      if (attached) _changes.removeListener(markNeedsPaint);
      _controller = controller;
      _revealGate = revealGate;
      if (attached) _changes.addListener(markNeedsPaint);
    }
    // The rows were rebuilt: their line ends may have moved.
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _changes.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _changes.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final selection = _controller.selection;
    if (selection.isValid && !selection.isCollapsed) {
      final paint = Paint()..color = OmColors.selection;
      for (final mark in newlineMarks(
        _lines(selection),
        TextRange(start: selection.start, end: selection.end),
      )) {
        context.canvas.drawRect(mark.shift(offset), paint);
      }
    }
    super.paint(context, offset);
  }

  /// The laid-out lines of the rows [selection] reaches, in this box's
  /// coordinates and segment offsets.
  List<NewlineMarkLine> _lines(TextSelection selection) {
    final text = _controller.text;
    final rows = splitRows(text, atSegmentStart: true);
    final editables = <RenderEditable>[];
    void visit(RenderObject node) {
      if (node is RenderEditable) {
        editables.add(node);
      } else {
        node.visitChildren(visit);
      }
    }

    visitChildren(visit);
    if (editables.length != rows.length) return const [];
    final out = <NewlineMarkLine>[];
    for (final (i, row) in rows.indexed) {
      // A row whose text ends before the selection or starts at or after
      // its end holds no selected line end.
      if (row.textEnd < selection.start || row.textStart >= selection.end) {
        continue;
      }
      final editable = editables[i];
      final rowText = text.substring(row.textStart, row.textEnd);
      if (!editable.hasSize || editable.plainText != rowText) continue;
      final shift = MatrixUtils.transformPoint(
        editable.getTransformTo(this),
        Offset.zero,
      );
      final boxes = RenderEditableLineBoxes(editable);
      final mdLines = row.isItem
          ? const <MdLine>[]
          : classifyLines(rowText, atSegmentStart: row.textStart == 0);
      for (final line in boxes.lines) {
        final end = row.toSegment(line.range.end);
        out.add(
          NewlineMarkLine(
            end: end,
            breaks: end < text.length && _isTerminator(text.codeUnitAt(end)),
            top: line.top + shift.dy,
            bottom: line.bottom + shift.dy,
            endX: _lineEndX(editable, boxes, line) + shift.dx,
            columnWidth: newlineMarkWidth(
              _headingLevel(mdLines, line.range.start),
            ),
          ),
        );
      }
    }
    return out;
  }

  /// The right end of [line]'s last glyph in [editable]; its text left (0)
  /// on a blank line.
  static double _lineEndX(
    RenderEditable editable,
    RenderEditableLineBoxes boxes,
    LineBox line,
  ) {
    if (line.range.isCollapsed) return 0;
    final glyphs = editable.getBoxesForSelection(
      TextSelection(baseOffset: line.range.start, extentOffset: line.range.end),
    );
    if (glyphs.isEmpty) return boxes.boxesFor(line.range).last.right;
    return glyphs.map((box) => box.right).reduce(math.max);
  }

  /// The heading level of the source line holding row-local [offset], null
  /// when it isn't a heading.
  static int? _headingLevel(List<MdLine> lines, int offset) {
    for (final line in lines) {
      if (offset < line.end || line.terminator.isEmpty) {
        return line.kind == MdLineKind.heading ? line.level : null;
      }
    }
    return null;
  }

  static bool _isTerminator(int unit) => unit == 0x0A || unit == 0x0D;
}

/// One laid-out line, as [newlineMarks] reads it (TD10, pack #170).
///
/// Offsets and the selection [newlineMarks] gets are in the same coordinate
/// space (e.g. segment offsets); x and y are in the painter's coordinates.
@immutable
class NewlineMarkLine {
  const NewlineMarkLine({
    required this.end,
    required this.breaks,
    required this.top,
    required this.bottom,
    required this.endX,
    required this.columnWidth,
  });

  /// Where the line's characters end: its line terminator starts here when
  /// [breaks].
  final int end;

  /// True when a line terminator follows the line at [end] (the end of a
  /// logical line); false at a soft wrap and on a text's last line.
  final bool breaks;

  /// The line box's top.
  final double top;

  /// The line box's bottom.
  final double bottom;

  /// The right end of the line's last glyph; the text's left x on a blank
  /// line.
  final double endX;

  /// One mono column at the line's font size ([newlineMarkWidth]).
  final double columnWidth;
}

/// The newline marks of [selection] over [lines], in line order (Spec R26,
/// TD10, pack #170 board A4 cells H and K): one rect per line whose line
/// terminator is inside [selection], starting at the line's [NewlineMarkLine.endX],
/// one [NewlineMarkLine.columnWidth] wide and the line box's full height. A
/// selected blank line's mark is its fill.
List<Rect> newlineMarks(List<NewlineMarkLine> lines, TextRange selection) => [
  for (final line in lines)
    if (line.breaks && selection.start <= line.end && line.end < selection.end)
      Rect.fromLTRB(
        line.endX,
        line.top,
        line.endX + line.columnWidth,
        line.bottom,
      ),
];

/// The newline mark's width on a line: one mono column at the line's font
/// size (8.1 on a body line; H1 20, H2 17, H3 15, H4 to H6 13.5 px fonts).
/// [headingLevel] is the line's heading level, null for every other line.
///
/// Throws [ArgumentError] when [headingLevel] is outside 1..6.
double newlineMarkWidth(int? headingLevel) {
  if (headingLevel == null) return monoColumnWidth;
  RangeError.checkValueInInterval(headingLevel, 1, 6, 'headingLevel');
  return monoAdvance(headingFontSize(headingLevel));
}
