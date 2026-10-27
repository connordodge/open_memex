import 'dart:async' show Timer, scheduleMicrotask;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
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
import 'live_preview_controller.dart';
import 'live_preview_styles.dart';
import 'marker_column.dart';
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
/// - A press inside an editor row's marker column is the column's (its
///   checkbox; a revealed marker is display only): the layer ignores it,
///   with no caret move, focus change, selection or drag.
/// - A plain click, a double or triple click and a Cmd+click stay the
///   row's (and the link region's): the layer only wins the gesture arena
///   for a drag or a Shift+press.
/// - A press on a rendered table grid (a table row that is not
///   `tableRevealed`, Spec #197 R21, ruling D14) is the layer's: the grid
///   has no recognizers. A primary or secondary press puts the caret at the
///   pressed offset and focuses the table row, which reveals it; a
///   Cmd+press does too unless the link region wins the arena (a Cmd+press
///   on a link it opens). A click within `kDoubleTapTimeout` and
///   `kDoubleTapSlop` of a click that started on a grid wins the arena at
///   once and selects the word (second click) or the source line (third
///   and later) at the first press's offset, so the reveal's layout change
///   never retargets it (L7).
/// - A drag extends only once the pointer has moved more than
///   `kPrecisePointerHitSlop` from the press.
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

  /// Whether global [point] lies on a rendered table grid of the segment
  /// whose pointer layer is above [context] (a table row that is not
  /// `tableRevealed`, ruling D14); false without one.
  static bool onRenderedGrid(BuildContext context, Offset point) {
    final layer = context.findAncestorStateOfType<_SegmentPointerLayerState>();
    final host = layer?._host;
    return host != null && layer!._onRenderedGrid(host, point);
  }

  @override
  State<SegmentPointerLayer> createState() => _SegmentPointerLayerState();
}

/// One tracked primary-button mouse press and its gesture arena entry.
class _Press implements GestureArenaMember {
  _Press({
    required this.pointer,
    required this.down,
    required this.base,
    required this.onAccept,
    required this.onReject,
    this.at = 0,
    this.deferred = false,
    this.multi = false,
  }) : position = down;

  final int pointer;

  /// Where the press went down (global).
  final Offset down;

  /// The selection's base (segment offset).
  final int base;

  /// The pointer's last position (global).
  Offset position;

  /// The pressed offset (segment offset).
  final int at;

  /// A Cmd+press on a rendered grid: the caret goes to [at] only once the
  /// layer wins the arena (the link region wins it on a link it opens).
  final bool deferred;

  /// A double or triple click: it has selected, and never drags.
  final bool multi;

  /// True once the layer won the arena: the press is a drag, a Shift+press,
  /// a press on a rendered grid or a multi-click.
  bool accepted = false;

  /// True once the pointer moved more than `kPrecisePointerHitSlop` from
  /// [down].
  bool dragging = false;

  late final GestureArenaEntry entry;

  final void Function(_Press press) onAccept;
  final void Function(_Press press) onReject;

  @override
  void acceptGesture(int pointer) {
    accepted = true;
    onAccept(this);
  }

  @override
  void rejectGesture(int pointer) => onReject(this);
}

/// A click chain that started with a press on a rendered table grid: where
/// its first press went down (global), that press's offset (segment
/// offset) and the clicks so far.
class _Clicks {
  _Clicks(this.down, this.offset);

  final Offset down;
  final int offset;
  int count = 1;
}

class _SegmentPointerLayerState extends State<SegmentPointerLayer>
    with SingleTickerProviderStateMixin {
  _Press? _press;
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;

  /// The click chain a next click within `kDoubleTapTimeout` continues.
  _Clicks? _clicks;
  Timer? _clicksTimer;

  SegmentViewState? get _host =>
      context.findAncestorStateOfType<SegmentViewState>();

  @override
  void dispose() {
    _ticker?.dispose();
    _clicksTimer?.cancel();
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

  /// The segment's row fields, in row order.
  List<EditableTextState> _rowFields() {
    final fields = <EditableTextState>[];
    void visit(Element element) {
      if (element is StatefulElement && element.state is EditableTextState) {
        fields.add(element.state as EditableTextState);
      } else {
        element.visitChildren(visit);
      }
    }

    context.visitChildElements(visit);
    return fields;
  }

  /// The focus nodes of the segment's row fields, in row order.
  List<FocusNode> _rowFocusNodes() => [
    for (final field in _rowFields()) field.widget.focusNode,
  ];

  /// Whether global [point] lies on a table row that shows its grid (its
  /// controller is not `tableRevealed`, Spec #197 R12, ruling D12).
  bool _onRenderedGrid(SegmentViewState host, Offset point) {
    final boxes = host.lineBoxes();
    if (boxes == null) return false;
    final local = boxes.box.globalToLocal(point);
    if (local.dy < 0 || local.dy >= boxes.box.size.height) return false;
    final fields = _rowFields();
    final rows = splitRows(host.text, atSegmentStart: true);
    if (fields.length != rows.length) return false;
    final offset = boxes.offsetAt(local);
    final i = rows.indexWhere((row) => offset < row.end);
    final controller = fields[i < 0 ? rows.length - 1 : i].widget.controller;
    return controller is LivePreviewController &&
        controller.tableRow &&
        !controller.tableRevealed;
  }

  /// The word at segment [offset], as its row's field finds words.
  TextSelection _wordAt(SegmentViewState host, int offset) {
    final rows = splitRows(host.text, atSegmentStart: true);
    final fields = _rowFields();
    final i = rows.indexWhere((row) => offset < row.end);
    if (fields.length != rows.length || i < 0) {
      return TextSelection.collapsed(offset: offset);
    }
    final row = rows[i];
    final word = fields[i].renderEditable.getWordBoundary(
      TextPosition(offset: offset - row.textStart),
    );
    return TextSelection(
      baseOffset: row.textStart + word.start,
      extentOffset: row.textStart + word.end,
    );
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

  /// Whether global [point] lies inside one of the segment's editor row
  /// marker columns.
  bool _inMarkerColumn(Offset point) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final result = BoxHitTestResult();
    box.hitTest(result, position: box.globalToLocal(point));
    return hitsMarkerColumn(result);
  }

  void _onDown(PointerDownEvent event) {
    if (_press != null || event.kind != PointerDeviceKind.mouse) return;
    // Only a click that continues the chain keeps it.
    _clicksTimer?.cancel();
    final clicks = _clicks;
    _clicks = null;
    if (event.buttons == kSecondaryButton) {
      _onSecondaryDown(event);
      return;
    }
    if (event.buttons != kPrimaryButton) return;
    // A press on a marker column belongs to the column (Spec Q4, D11).
    if (_inMarkerColumn(event.position)) return;
    final host = _host;
    if (host == null) return;
    final keyboard = HardwareKeyboard.instance;
    final cmd = keyboard.isMetaPressed;
    final shift = keyboard.isShiftPressed;
    if (clicks != null &&
        !cmd &&
        !shift &&
        (event.position - clicks.down).distance <= kDoubleTapSlop) {
      _clicks = clicks;
      _onMultiClick(event, host, clicks);
      return;
    }
    final grid = _onRenderedGrid(host, event.position);
    // A Cmd+click belongs to the link region (B3); on a rendered grid only
    // when the link region wins the arena (D14).
    if (cmd && !grid) return;
    final at = _offsetAt(host, event.position);
    if (at == null) return;
    final current = host.selection;
    final press = _Press(
      pointer: event.pointer,
      down: event.position,
      base: shift && current.isValid ? current.baseOffset : at,
      at: at,
      deferred: cmd,
      onAccept: _onAccept,
      onReject: _onReject,
    );
    press.entry = GestureBinding.instance.gestureArena.add(
      event.pointer,
      press,
    );
    _press = press;
    if (cmd) return;
    if (shift) {
      final selection = TextSelection(baseOffset: press.base, extentOffset: at);
      host.select(selection);
      if (host.focusedRow == null) _focusRowAt(host, at, keep: selection);
      press.entry.resolve(GestureDisposition.accepted);
    } else {
      // As a macOS field does on mouse down: the caret goes to the press.
      host.select(TextSelection.collapsed(offset: at));
      _focusRowAt(host, at);
      if (grid) _clicks = _Clicks(event.position, at);
    }
  }

  /// A secondary press on a rendered grid puts the caret at the pressed
  /// offset and focuses the table row, as a plain click does; the selection
  /// ops show the menu (D14). Elsewhere it is the row field's.
  void _onSecondaryDown(PointerDownEvent event) {
    final host = _host;
    if (host == null || !_onRenderedGrid(host, event.position)) return;
    final at = _offsetAt(host, event.position);
    if (at == null) return;
    host.select(TextSelection.collapsed(offset: at));
    _focusRowAt(host, at);
  }

  /// The second (word) or a later (source line) click of [clicks]: wins
  /// the arena at once and selects at the chain's first offset (L7).
  void _onMultiClick(
    PointerDownEvent event,
    SegmentViewState host,
    _Clicks clicks,
  ) {
    clicks.count++;
    final offset = clicks.offset;
    final selection = clicks.count == 2
        ? _wordAt(host, offset)
        : _sourceLineAt(host.text, offset);
    final press = _Press(
      pointer: event.pointer,
      down: event.position,
      base: selection.baseOffset,
      at: offset,
      multi: true,
      onAccept: _onAccept,
      onReject: _onReject,
    );
    press.entry = GestureBinding.instance.gestureArena.add(
      event.pointer,
      press,
    );
    _press = press;
    press.entry.resolve(GestureDisposition.accepted);
    host.select(selection);
    _focusRowAt(host, offset, keep: selection);
  }

  void _onMove(PointerMoveEvent event) {
    final press = _press;
    if (press == null || event.pointer != press.pointer || press.multi) {
      return;
    }
    press.position = event.position;
    if (!press.dragging &&
        (event.position - press.down).distance > kPrecisePointerHitSlop) {
      press.dragging = true;
      _clicks = null;
      // Before the row's own tap-and-drag recognizer sees this move.
      if (!press.accepted) press.entry.resolve(GestureDisposition.accepted);
    }
    if (!press.accepted || !press.dragging) return;
    _extend(press);
    _updateAutoScroll();
  }

  void _onUp(PointerEvent event) {
    final press = _press;
    if (press == null || event.pointer != press.pointer) return;
    _press = null;
    _ticker?.stop();
    if (_clicks != null) {
      _clicksTimer = Timer(kDoubleTapTimeout, () => _clicks = null);
    }
    // A click: the row's (or the empty area's) tap recognizer takes it.
    if (!press.accepted) press.entry.resolve(GestureDisposition.rejected);
  }

  /// A Cmd+press on a rendered grid that the link region left to the layer
  /// is a plain click (pack correction: a ghost link ignores Cmd).
  void _onAccept(_Press press) {
    if (!press.deferred) return;
    final host = _host;
    if (host == null) return;
    host.select(TextSelection.collapsed(offset: press.at));
    _focusRowAt(host, press.at);
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
    // A table row the selection reaches is revealed (`tableRevealed`) only
    // while the segment has focus; rendered, its grid shows no selection
    // (Spec #197 R16).
    final gate = _revealGate;
    final focused = gate is ValueListenable<bool> && gate.value;
    final out = <NewlineMarkLine>[];
    for (final (i, row) in rows.indexed) {
      // A row whose text ends before the selection or starts at or after
      // its end holds no selected line end.
      if (row.textEnd < selection.start || row.textStart >= selection.end) {
        continue;
      }
      if (row.kind == RowKind.table && !focused) continue;
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

/// The source line holding segment [offset] of [text], without its line
/// terminator (a grid row's whole source line, Spec #197 R21).
TextSelection _sourceLineAt(String text, int offset) {
  var start = offset;
  while (start > 0 && !_isLineTerminator(text.codeUnitAt(start - 1))) {
    start--;
  }
  var end = offset;
  while (end < text.length && !_isLineTerminator(text.codeUnitAt(end))) {
    end++;
  }
  return TextSelection(baseOffset: start, extentOffset: end);
}

bool _isLineTerminator(int unit) => unit == 0x0A || unit == 0x0D;
