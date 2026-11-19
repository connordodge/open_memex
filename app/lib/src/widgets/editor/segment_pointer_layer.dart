import 'dart:async' show Timer, unawaited;
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, Ticker;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../editor/editor_rows.dart';
import '../../editor/markdown_lines.dart';
import '../../editor/row_geometry.dart';
import '../../editor/segment_selection.dart';
import 'live_preview_controller.dart';
import 'live_preview_styles.dart';
import 'marker_column.dart';
import 'segment_view.dart';
import 'spelling_menu.dart' show rowSpellingIssue, showRowSpellingMenu;
import 'text_segment.dart' show hideRowTextMenu, showRowTextMenu;

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
///   with no caret move, focus change, selection or drag. So is a press a
///   row's presenter owns (`RowKindPresenter.ownsPress`, WI #124 ruling D5),
///   such as one on an attachment's block.
/// - A plain click on an editor row line whose markup is hidden (not
///   `revealedLines` in its row field) is the layer's (Spec #57 R5-R8,
///   TD4): it wins the gesture arena when it goes down and puts the caret at
///   the offset it resolved then, on the layout shown then, so neither the
///   row field's tap nor the line's reveal moves it. A press on a heading
///   line whose marker is hidden, at or before the end of the marker and its
///   space, puts the caret after them (R7). A click within
///   `kDoubleTapTimeout` and `kDoubleTapSlop` of it wins the arena at once
///   and selects at the first press's offset: the word a double click
///   selects on that line already revealed (second click), or its line with
///   its line terminator, as a triple click does (third and later). A press
///   the link region marked follows its link instead.
/// - A plain, double or triple click on a revealed line (and on the empty
///   area below the rows) and a Cmd+click stay the row's (and the link
///   region's).
/// - On a row without a field (its text slot a `RichText`, WI #128, Spec
///   #122 Req 30) every press is the layer's, as on a hidden line: a plain
///   click on any of its lines and the click chain it starts, as above; a
///   Cmd+click puts the caret at the pressed offset on its release, after
///   the link region has seen it (as a field's tap does); a right click
///   selects the word under the pointer (`RenderEditable.selectWord` on
///   macOS) and, once the row has taken focus, opens SpellingMenu on a
///   flagged word (`showRowSpellingMenu`) or else the text context menu
///   (`showRowTextMenu`). A press that moves the caret, and a right click,
///   make the row the host's active row (`SegmentViewState.activateRow`),
///   which mounts its field and focuses it.
/// - Every press that moves focus does so through
///   `SegmentViewState.activateRow`: a click focuses the row it puts the
///   caret in; a drag and a Shift+click keep focus in the row it was in.
/// - A press the link region marked on a rendered link (Spec #232 TD6) wins
///   the arena when it goes down, so no row recognizer sees it, and moves no
///   caret. A release inside `kPrecisePointerHitSlop` follows the link it
///   captured and starts no click chain; past the slop it selects from the
///   press as a drag does. It never follows once it has gone past the slop.
/// - A press on a rendered table grid (a table row that is not
///   `tableRevealed`, Spec #197 R21, ruling D14) is the layer's: the grid
///   has no recognizers. A primary or secondary press puts the caret at the
///   pressed offset and focuses the table row, which reveals it; a
///   Cmd+press does too unless the link region wins the arena (a Cmd or
///   marked press on a link it follows, which never reveals the table, even
///   past the slop). A click within `kDoubleTapTimeout` and
///   `kDoubleTapSlop` of a click that started on a grid wins the arena at
///   once and selects the word (second click) or the source line (third
///   and later) at the first press's offset, so the reveal's layout change
///   never retargets it (L7).
/// - A drag extends only once the pointer has moved more than
///   `kPrecisePointerHitSlop` from the press.
/// - Dragging into the editor page's top or bottom edge zone scrolls the
///   page while the selection keeps extending under the pointer.
/// - `SelectAllTextIntent` (Cmd+A) selects the whole text segment.
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
    this.onRelease = false,
    this.multi = false,
    this.follow,
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
  /// layer wins the arena (the link region wins it on a link it opens). A
  /// marked press: only once it drags past the slop.
  final bool deferred;

  /// A deferred Cmd+press on a row without a field (WI #128): the caret
  /// goes to [at] on its release, after the link region has seen it (a row
  /// field's tap puts it there then), or once it drags past the slop.
  final bool onRelease;

  /// A double or triple click: it has selected, and never drags.
  final bool multi;

  /// What a release inside the slop does: set on a press the link region
  /// marked.
  final VoidCallback? follow;

  /// True once the layer won the arena: the press is a drag, a Shift+press,
  /// a marked press, a plain press on the rows, a press on a rendered grid
  /// or a multi-click.
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

/// A click chain that started with a plain press on an editor row or a
/// rendered table grid: where its first press went down (global), that
/// press's offset (segment offset) and the clicks so far.
class _Clicks {
  _Clicks(
    this.down,
    this.offset, {
    this.grid = false,
    this.affinity = TextAffinity.downstream,
  });

  final Offset down;
  final int offset;

  /// The chain started on a rendered table grid.
  final bool grid;

  /// The first press's affinity in its row's field: upstream on the right
  /// half of the glyph before [offset] (the word a double click selects).
  final TextAffinity affinity;
  int count = 1;
}

/// A source line of a row's live preview field as the field shows it: where
/// the field's text starts in the segment, the line in field offsets,
/// whether it renders as a heading, and whether its markup is revealed
/// (`revealedLines`, as the field renders it).
typedef _ShownLine = ({
  int textStart,
  MdLine line,
  bool heading,
  bool revealed,
});

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

  /// The index of the host's row holding segment [offset]: the first row
  /// ending after it, else -1 (past every row).
  static int _rowIndexAt(SegmentViewState host, int offset) {
    for (var i = 0; i < host.rowCount; i++) {
      if (offset < host.rowSpec(i)!.end) return i;
    }
    return -1;
  }

  /// Whether global [point] lies on a table row that shows its grid (its
  /// controller is not `tableRevealed`, Spec #197 R12, ruling D12).
  bool _onRenderedGrid(SegmentViewState host, Offset point) {
    final boxes = host.lineBoxes();
    if (boxes == null) return false;
    final local = boxes.box.globalToLocal(point);
    if (local.dy < 0 || local.dy >= boxes.box.size.height) return false;
    final hit = _rowAt(host, boxes.offsetAt(local));
    return hit != null && hit.controller.textHidden;
  }

  /// The word at segment [offset], as its row's text finds words (a
  /// rendered table row's field, mounted offstage, does).
  TextSelection _wordAt(SegmentViewState host, int offset) {
    final i = _rowIndexAt(host, offset);
    final row = host.rowSpec(i);
    final word = row == null
        ? null
        : host.rowWordBoundary(i, TextPosition(offset: offset - row.textStart));
    if (row == null || word == null) {
      return TextSelection.collapsed(offset: offset);
    }
    return TextSelection(
      baseOffset: row.textStart + word.start,
      extentOffset: row.textStart + word.end,
    );
  }

  /// The host's row holding segment [offset] (the last row past them): its
  /// index, spec and controller; null without rows.
  ({int index, RowSpec row, LivePreviewController controller})? _rowAt(
    SegmentViewState host,
    int offset,
  ) {
    final count = host.rowCount;
    if (count == 0) return null;
    final i = _rowIndexAt(host, offset);
    final r = i < 0 ? count - 1 : i;
    return (
      index: r,
      row: host.rowSpec(r)!,
      controller: host.rowController(r)!,
    );
  }

  /// Whether global [point] lies on the segment's rows (not the empty area
  /// below them).
  bool _onRows(SegmentViewState host, Offset point) {
    final boxes = host.lineBoxes();
    if (boxes == null) return false;
    final dy = boxes.box.globalToLocal(point).dy;
    return dy >= 0 && dy < boxes.box.size.height;
  }

  /// The source line holding segment [at] in its row's live preview text,
  /// read from the row's controller now (before a press reveals it). Null
  /// without rows.
  _ShownLine? _shownLineAt(SegmentViewState host, int at) {
    final hit = _rowAt(host, at);
    if (hit == null) return null;
    final controller = hit.controller;
    final lines = classifyLines(
      controller.text,
      atSegmentStart: controller.atSegmentStart,
    );
    if (lines.isEmpty) return null;
    final local = at - hit.row.textStart;
    final i = lines.indexWhere((line) => local < line.end);
    final index = i < 0 ? lines.length - 1 : i;
    final revealed = revealedLines(
      lines,
      controller.selection,
      forceHidden: !controller.revealGate.value,
      itemText: controller.itemText,
    );
    return (
      textStart: hit.row.textStart,
      line: lines[index],
      // An item row's field holds no heading (`buildLivePreviewSpan`).
      heading: !controller.itemText && lines[index].kind == MdLineKind.heading,
      revealed: revealed[index],
    );
  }

  /// [at], or the end of the marker and its space when [at] lies inside the
  /// hidden marker of [shown], a heading line (Spec #57 R7): a click at or
  /// left of the heading's first shown character, or on an empty heading,
  /// never puts the caret before `#` or between `#` and its space.
  int _pastHiddenHeadingMarker(_ShownLine shown, int at) {
    final line = shown.line;
    final local = at - shown.textStart;
    if (shown.revealed ||
        !shown.heading ||
        local < line.markerStart ||
        local >= line.separatorEnd) {
      return at;
    }
    return shown.textStart + line.separatorEnd;
  }

  /// The affinity of the press at global [point] in the text of the row
  /// holding segment [at], as the row's text resolves it on the layout
  /// shown now: upstream on the right half of the glyph before [at].
  TextAffinity _affinityAt(SegmentViewState host, Offset point, int at) {
    final hit = _rowAt(host, at);
    final position = hit == null ? null : host.rowPositionAt(hit.index, point);
    if (hit == null || position == null) return TextAffinity.downstream;
    return hit.row.textStart + position.offset == at
        ? position.affinity
        : TextAffinity.downstream;
  }

  /// The word a double click on an editor row selects at segment [offset]
  /// with [affinity], as the row's field selects it on macOS
  /// (`RenderEditable.selectWord`): a caret past the row's text.
  TextSelection _rowWordAt(
    SegmentViewState host,
    int offset,
    TextAffinity affinity,
  ) {
    final hit = _rowAt(host, offset);
    if (hit == null) return TextSelection.collapsed(offset: offset);
    final start = hit.row.textStart;
    final length = hit.controller.text.length;
    final local = offset - start;
    if (local >= length) return TextSelection.collapsed(offset: start + length);
    final word = host.rowWordBoundary(
      hit.index,
      TextPosition(offset: math.max(0, local), affinity: affinity),
    );
    if (word == null) return TextSelection.collapsed(offset: offset);
    return TextSelection(
      baseOffset: start + word.start,
      extentOffset: start + word.end,
    );
  }

  /// The line a triple click on an editor row selects at segment [offset],
  /// as the row's field selects it on macOS (its paragraph, with the line
  /// terminator).
  TextSelection _rowLineAt(SegmentViewState host, int offset) {
    final hit = _rowAt(host, offset);
    if (hit == null) return _sourceLineAt(host.text, offset);
    final start = hit.row.textStart;
    final text = hit.controller.text;
    final local = math.max(0, math.min(offset - start, text.length));
    final boundary = ParagraphBoundary(text);
    final from =
        boundary.getLeadingTextBoundaryAt(
          local == text.length ? local - 1 : local,
        ) ??
        0;
    final to = boundary.getTrailingTextBoundaryAt(local) ?? text.length;
    return TextSelection(baseOffset: start + from, extentOffset: start + to);
  }

  /// Makes the row holding segment [offset] the host's active row with the
  /// segment selection as it is now (`SegmentViewState.activateRow`, WI
  /// #128): it takes focus, mounting its field first when it has none, and
  /// that focus keeps the selection (a row taking focus would report its
  /// own slice).
  void _activateRowAt(SegmentViewState host, int offset) {
    final hit = _rowAt(host, offset);
    if (hit != null) host.activateRow(hit.index, host.selection);
  }

  /// Whether the row holding segment [offset] has no field (WI #128): its
  /// text slot is a `RichText`, so every press on it is the layer's.
  bool _withoutField(SegmentViewState host, int offset) {
    final hit = _rowAt(host, offset);
    return hit != null && host.rowField(hit.index) == null;
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

  /// What a release of the press [pointer] does when a row's link region
  /// marked it, else null.
  VoidCallback? _markedFollow(SegmentViewState host, int pointer) {
    for (var i = 0; i < host.rowCount; i++) {
      if (host.rowController(i)?.markedPress case final marked?
          when marked.pointer == pointer) {
        return marked.follow;
      }
    }
    return null;
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
    // A press closes the text menu of a row without a field, as a field's
    // own press closes its menu.
    hideRowTextMenu();
    // A press on a marker column belongs to the column (Spec Q4, D11).
    if (_inMarkerColumn(event.position)) return;
    final host = _host;
    if (host == null) return;
    // A press a row's presenter owns (an attachment's block) is its own
    // (WI #124, D5).
    if (host.rowOwnsPress(event.position)) return;
    final keyboard = HardwareKeyboard.instance;
    final cmd = keyboard.isMetaPressed;
    final shift = keyboard.isShiftPressed;
    // A press the link region marked follows its link, also inside a row
    // click chain's window (Spec #57 R6); a grid chain wins it (L7).
    final follow = _markedFollow(host, event.pointer);
    if (clicks != null &&
        !cmd &&
        !shift &&
        (clicks.grid || follow == null) &&
        (event.position - clicks.down).distance <= kDoubleTapSlop) {
      _clicks = clicks;
      _onMultiClick(event, host, clicks);
      return;
    }
    final grid = _onRenderedGrid(host, event.position);
    final pressed = _offsetAt(host, event.position);
    if (pressed == null) return;
    // A press on a row without a field is the layer's (WI #128): no field
    // takes a click, a click chain or a Cmd+click there.
    final bare =
        !grid && _onRows(host, event.position) && _withoutField(host, pressed);
    // A Cmd+click belongs to the link region (B3); on a rendered grid only
    // when the link region wins the arena (D14). On a row without a field
    // the caret goes to it on its release, as a field puts it there.
    if (cmd && !grid && !bare) return;
    // A plain press on a row line whose markup is hidden, or on any line of
    // a row without a field: the layer's from its down, since the press
    // reveals the line (Spec #57 R5, R6). On a revealed line of a row field
    // the click stays the field's.
    final shown = !grid && !cmd && !shift && follow == null
        ? _shownLineAt(host, pressed)
        : null;
    final row =
        shown != null &&
        (!shown.revealed || bare) &&
        _onRows(host, event.position);
    final at = row ? _pastHiddenHeadingMarker(shown, pressed) : pressed;
    final current = host.selection;
    final press = _Press(
      pointer: event.pointer,
      down: event.position,
      base: shift && current.isValid ? current.baseOffset : at,
      at: at,
      deferred: cmd || follow != null,
      onRelease: cmd && bare,
      follow: follow,
      onAccept: _onAccept,
      onReject: _onReject,
    );
    press.entry = GestureBinding.instance.gestureArena.add(
      event.pointer,
      press,
    );
    _press = press;
    // Before the row's tap recognizer, which puts the caret at the press once
    // its press timeout runs out. On a grid the link region has already won.
    if (follow != null) press.entry.resolve(GestureDisposition.accepted);
    if (press.deferred) return;
    if (shift) {
      final selection = TextSelection(baseOffset: press.base, extentOffset: at);
      host.select(selection);
      if (host.focusedRow == null) _activateRowAt(host, at);
      press.entry.resolve(GestureDisposition.accepted);
    } else {
      // As a macOS field does on mouse down: the caret goes to the press.
      // Read before the select, which may reveal the line.
      final affinity = row
          ? _affinityAt(host, event.position, at)
          : TextAffinity.downstream;
      host.select(TextSelection.collapsed(offset: at));
      _activateRowAt(host, at);
      if (grid) {
        _clicks = _Clicks(event.position, at, grid: true);
      } else if (row) {
        // Before the row field's tap, which would resolve the press again
        // on the revealed layout; it would also have closed its menu.
        if (_rowAt(host, at) case final hit?) {
          host.rowPressed(hit.index, at - hit.row.textStart);
        }
        press.entry.resolve(GestureDisposition.accepted);
        _clicks = _Clicks(event.position, at, affinity: affinity);
      }
    }
  }

  /// A secondary press on a rendered grid puts the caret at the pressed
  /// offset and focuses the table row, as a plain click does; the selection
  /// ops show the menu (D14). On a row without a field it is the layer's
  /// ([_onSecondaryBare]). Elsewhere it is the row field's.
  void _onSecondaryDown(PointerDownEvent event) {
    final host = _host;
    if (host == null) return;
    if (!_onRenderedGrid(host, event.position)) {
      _onSecondaryBare(host, event);
      return;
    }
    final at = _offsetAt(host, event.position);
    if (at == null) return;
    host.select(TextSelection.collapsed(offset: at));
    _activateRowAt(host, at);
  }

  /// A secondary press on the text of a row without a field (WI #128), as
  /// a macOS field takes a right click: selects the word under the pointer
  /// (`RenderEditable.selectWord`), makes the row the active row and, once
  /// it has taken focus (after this frame), opens the menu a field would:
  /// SpellingMenu when the selection is a flagged word
  /// ([rowSpellingIssue], read now, while the row's spell checks are the
  /// ones it showed), else the text context menu ([showRowTextMenu]), both
  /// at the pointer. A press on a marker column, on a block a presenter
  /// owns or below the rows is not the layer's.
  void _onSecondaryBare(SegmentViewState host, PointerDownEvent event) {
    final point = event.position;
    if (!_onRows(host, point) ||
        _inMarkerColumn(point) ||
        host.rowOwnsPress(point)) {
      return;
    }
    final at = _offsetAt(host, point);
    if (at == null || !_withoutField(host, at)) return;
    final hit = _rowAt(host, at)!;
    host.select(_rowWordAt(host, at, _affinityAt(host, point, at)));
    final issue = rowSpellingIssue(host, hit.index);
    _activateRowAt(host, at);
    final controller = hit.controller;
    final binding = SchedulerBinding.instance;
    binding.addPostFrameCallback((_) {
      if (!mounted || !host.mounted) return;
      final i = host.rowIndexOf(controller);
      if (i == null) return;
      if (issue != null) {
        unawaited(showRowSpellingMenu(host, i, issue: issue, anchor: point));
      } else {
        unawaited(showRowTextMenu(host, i, anchor: point));
      }
    }, debugLabel: 'SegmentPointerLayer.rowMenu');
    binding.ensureVisualUpdate();
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
    final selection = switch ((clicks.grid, clicks.count == 2)) {
      (true, true) => _wordAt(host, offset),
      (true, false) => _sourceLineAt(host.text, offset),
      (false, true) => _rowWordAt(host, offset, clicks.affinity),
      (false, false) => _rowLineAt(host, offset),
    };
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
    _activateRowAt(host, offset);
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
      if (!press.accepted) {
        press.entry.resolve(GestureDisposition.accepted);
      } else if (press.follow != null || press.onRelease) {
        _placeCaret(press);
      }
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
    // A click on a revealed line or the empty area below the rows: the row's
    // (or the empty area's) tap recognizer takes it.
    if (!press.accepted) press.entry.resolve(GestureDisposition.rejected);
    // A Cmd+click on a row without a field: the link region has seen its
    // release (WI #128).
    if (event is PointerUpEvent &&
        press.onRelease &&
        press.accepted &&
        !press.dragging) {
      _placeCaret(press);
    }
    // Last: this leaves the note, and the press is over by now.
    if (event is PointerUpEvent && !press.dragging) press.follow?.call();
  }

  /// A Cmd+press on a rendered grid that the link region left to the layer
  /// is a plain click (pack correction: a ghost link ignores Cmd). A marked
  /// press wins at its down and places no caret until it drags. A Cmd+press
  /// on a row without a field places it on its release (WI #128).
  void _onAccept(_Press press) {
    if (press.deferred &&
        press.follow == null &&
        (!press.onRelease || press.dragging)) {
      _placeCaret(press);
    }
  }

  /// Puts the caret at [press]'s offset and makes the row holding it the
  /// active row.
  void _placeCaret(_Press press) {
    final host = _host;
    if (host == null) return;
    host.select(TextSelection.collapsed(offset: press.at));
    _activateRowAt(host, press.at);
  }

  void _onReject(_Press press) {
    if (!identical(press, _press)) return;
    // Lost to the link region on a grid. A marked press stays tracked for its
    // slop, and a multi-click so its release starts the chain's timer.
    if (press.follow != null || press.multi) return;
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
            child: widget.child,
          ),
        ),
      ),
    );
  }
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
/// size (8.1 on a body line; 15.6, 11.4, 9.0 and 6.6 on H1 26, H2 19, H3 15
/// and H4 to H6 11 px fonts).
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
