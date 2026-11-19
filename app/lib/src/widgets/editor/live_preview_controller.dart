import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../editor/markdown_inline.dart';
import '../../editor/markdown_lines.dart';
import '../../editor/markdown_table.dart';
import '../../editor/tag_grammar.dart' show fencedMdLines;
import '../../theme/colors.dart';
import 'find_decoration.dart';
import 'live_preview_styles.dart';

/// A plain press `LinkRegion` marked on a followable link whose line is not
/// revealed (Spec #232 TD6): the press with this [pointer] follows through
/// [follow], which already holds the link it captured at the press. The
/// segment's pointer layer decides whether it runs.
final class MarkedPress {
  const MarkedPress(this.pointer, this.follow);

  final int pointer;
  final VoidCallback follow;
}

/// The controller of every live preview field (D7): its [buildTextSpan]
/// renders the controller's text with live preview styling and marker
/// hiding ([buildLivePreviewSpan], B1); hosts only set its props.
///
/// Host-set props, all optional with safe defaults:
/// - [itemText]: the field holds only an item row's text (its marker is in
///   the marker column);
/// - [taskDone]: the field is a done task's text;
/// - [quote]: the field is a quote line's text;
/// - [atSegmentStart]: the field's text starts at its text segment's start;
/// - [codeRow]: the field is a code row's text (ruling D18);
/// - [fenced]: which of the field's lines are fenced code on the server;
/// - [revealGate]: true while the field's text segment has focus (markers
///   may reveal only then).
class LivePreviewController extends TextEditingController {
  /// Test-only work counter: how many times any controller's
  /// [buildTextSpan] ran.
  @visibleForTesting
  static int debugBuildTextSpans = 0;

  LivePreviewController({super.text});

  LivePreviewController.fromValue(super.value) : super.fromValue();

  /// The field holds only an item row's text. Default false.
  bool itemText = false;

  /// The field is a done task's text. Default false.
  bool taskDone = false;

  /// The field is a quote line's text. Default false.
  bool quote = false;

  /// The field's text starts at its text segment's start. Default true.
  bool atSegmentStart = true;

  /// Which of the field's lines are fenced code on the server, read over the
  /// whole segment (`fencedRowLines`). Null (the default): the field's text
  /// is judged alone. Like [itemText] and [quote], the host writes it before
  /// it rebuilds the rows.
  List<bool>? fenced;

  /// The field is a code row's text (a fenced block, ruling D18): its hidden
  /// fence lines lay out at the design's 8 px, so [strutStyle] drops the
  /// 22.95 px minimum. Default false. Setting it notifies listeners.
  bool get codeRow => _codeRow;
  set codeRow(bool value) {
    _codeRow = value;
    notifyListeners();
  }

  bool _codeRow = false;

  /// The field is a table row's text (Spec #197 R8; ruling D12). Default
  /// false. Setting it notifies listeners, as [codeRow] does.
  bool get tableRow => _tableRow;
  set tableRow(bool value) {
    _tableRow = value;
    notifyListeners();
  }

  bool _tableRow = false;

  /// Whether this table row shows its raw field (Spec #197 R12, ruling D12):
  /// `tableRow && revealGate.value && selection.isValid`. The only reveal
  /// predicate of a table row; false for every other row.
  bool get tableRevealed => tableRow && revealGate.value && selection.isValid;

  /// True while the field's text segment has focus. Default: never true.
  ValueListenable<bool> revealGate = const AlwaysStoppedAnimation<bool>(false);

  /// Find in note's decoration of this field (WI #84, ruling D7): its
  /// reveal range reveals the lines it touches even while [revealGate] is
  /// false, and its ink ranges recolour the text inside them. Null (the
  /// default), or a listenable holding null: no decoration. Each time the
  /// listenable fires, the controller notifies its listeners once.
  /// Setting it subscribes to the new listenable and unsubscribes from the
  /// old one; setting the same one again changes nothing. [dispose]
  /// unsubscribes.
  ValueListenable<FindDecoration?>? get findDecoration => _findDecoration;
  set findDecoration(ValueListenable<FindDecoration?>? value) {
    if (identical(value, _findDecoration)) return;
    _findDecoration?.removeListener(notifyListeners);
    _findDecoration = value;
    value?.addListener(notifyListeners);
  }

  ValueListenable<FindDecoration?>? _findDecoration;

  /// Whether a wikilink or transclusion target resolves (B3 sets it; D7).
  /// Called with the token's target: a wikilink's title trimmed of
  /// whitespace, a transclusion's date. Null (the default): every target
  /// resolves. Setting it notifies listeners so the field repaints.
  bool Function(String target)? get isResolved => _isResolved;
  set isResolved(bool Function(String target)? value) {
    _isResolved = value;
    notifyListeners();
  }

  bool Function(String target)? _isResolved;

  /// The latest press `LinkRegion` marked on this field, or null when its
  /// latest press was not marked. Read by the press's pointer, so a mark
  /// left from an earlier press never applies. Setting it notifies nothing.
  MarkedPress? markedPress;

  /// The hovered token's span in [text]: the link a click would follow (B3
  /// sets it; D7). Null (the default): nothing renders hovered. Setting it
  /// notifies listeners so the field repaints.
  TextRange? get cmdHover => _cmdHover;
  set cmdHover(TextRange? value) {
    _cmdHover = value;
    notifyListeners();
  }

  TextRange? _cmdHover;

  /// The strut a `TextSegmentField` editing this controller lays its text
  /// out with: the 22.95 px minimum strut (R13), not forced, so taller
  /// heading lines lay out taller. While [codeRow], an 8 px minimum strut
  /// instead (ruling D18), so a hidden fence line lays out 8 px tall while
  /// code lines keep their 22.95 px body line.
  StrutStyle? get strutStyle => codeRow ? _codeRowStrut : livePreviewStrut();

  /// The live preview span of [text] for the current [selection]: markers
  /// reveal on the lines it touches only while [revealGate] is true, and on
  /// the lines the [findDecoration]'s reveal range touches; its ink ranges
  /// recolour their text. The composing range is not underlined.
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final find = findDecoration?.value;
    return _buildSpan(
      text,
      style: style,
      selection: selection,
      forceHidden: !revealGate.value,
      itemText: itemText,
      taskDone: taskDone,
      quote: quote,
      atSegmentStart: atSegmentStart,
      isResolved: isResolved,
      cmdHover: cmdHover,
      codeRow: codeRow,
      before: null,
      fenced: fenced,
      revealRange: find?.revealRange,
      inkRanges: find?.inkRanges ?? const <TextRange>[],
      current: find?.current,
    );
  }

  @override
  void dispose() {
    findDecoration = null;
    super.dispose();
  }
}

/// The design's hidden fence line height (pack #161: 7 px padding plus a
/// 1 px border; ruling D18).
const double _hiddenFenceLineHeight = 8;

/// A code row's strut: a minimum of [_hiddenFenceLineHeight], not forced.
const StrutStyle _codeRowStrut = StrutStyle(
  fontSize: _hiddenFenceLineHeight,
  height: 1,
);

/// The index of the last line of the table whose header line is
/// `lines[header]`: the run of delimiter and body lines after it.
int tableLastLine(List<MdLine> lines, int header) {
  var last = header;
  while (last + 1 < lines.length &&
      (lines[last + 1].kind == MdLineKind.tableDelimiter ||
          lines[last + 1].kind == MdLineKind.tableBody)) {
    last++;
  }
  return last;
}

/// Which of [lines] reveal their markers for [selection] (Spec #232 TD6): the
/// one predicate `buildLivePreviewSpan` and `LinkRegion` share.
///
/// Every line the selection touches reveals (a caret at a line's content end
/// touches that line only), both fence lines of a block when any of its lines
/// is touched, and every line of a table when any of its lines is touched
/// (Spec #197 R13). With [itemText] no block reveals as a unit. None while
/// [forceHidden] or with a null or invalid [selection].
///
/// [revealRange] (Find in note's current match, WI #84): the lines it
/// touches reveal as a selection's would, by the same fence and table rules,
/// even while [forceHidden]. Null: none.
List<bool> revealedLines(
  List<MdLine> lines,
  TextSelection? selection, {
  bool forceHidden = false,
  bool itemText = false,
  TextRange? revealRange,
}) {
  final revealed = List<bool>.filled(lines.length, false);
  final ranges = <TextRange>[
    if (!forceHidden && selection != null && selection.isValid) selection,
    if (revealRange != null && revealRange.isValid) revealRange,
  ];
  if (ranges.isEmpty) return revealed;
  for (final (i, line) in lines.indexed) {
    revealed[i] = ranges.any(
      (r) => r.start <= line.contentEnd && r.end >= line.start,
    );
  }
  if (itemText) return revealed;
  for (var open = 0; open < lines.length; open++) {
    if (lines[open].kind != MdLineKind.fenceOpen) continue;
    var close = open + 1;
    while (close < lines.length &&
        lines[close].kind == MdLineKind.fenceInside) {
      close++;
    }
    final last = close < lines.length ? close : lines.length - 1;
    final touched = revealed.sublist(open, last + 1).contains(true);
    revealed[open] = touched;
    revealed[last] = touched;
    open = last;
  }
  for (var header = 0; header < lines.length; header++) {
    if (lines[header].kind != MdLineKind.tableHeader) continue;
    final last = tableLastLine(lines, header);
    final touched = revealed.sublist(header, last + 1).contains(true);
    revealed.fillRange(header, last + 1, touched);
  }
  return revealed;
}

/// Builds the live preview span for [text] (B1, Spec R2-R5): a pure
/// function of the text, the field's props and its [selection], which
/// `LivePreviewController.buildTextSpan` calls with its own props and B4's
/// read-only cards call with [forceHidden] true, so cards never copy
/// styling.
///
/// - [style] is the field's base style (the editor body style).
/// - Markers reveal (in `fg2`, at their normal width) on every logical line
///   [selection] touches, unless [forceHidden]; a null or invalid
///   [selection] touches no line. Every other marker renders zero-width.
/// - Code units inside [selection] that are markers, done-task text, link
///   text or ghost wikilink text render in `fg1`.
/// - [itemText], [taskDone], [quote], [atSegmentStart], [isResolved],
///   [cmdHover] and [codeRow] mean what the controller props of the same
///   names mean.
/// - [before] is the code unit just before [text] in the line it was cut
///   from (null: [text] starts a line); a hash at the very start of [text]
///   is a tag only if [before] opens one (the table grid passes it).
/// - A line the server reads as fenced code, such as a `~~~` fence that the
///   line grammar calls plain, gets no tag ink and keeps its other styling
///   (Rust wins, D34). [fenced] says which, per line of [text], as read over
///   the whole segment (`fencedRowLines`); a line past its end is not fenced.
///   Null judges [text] alone: a fence that crosses rows is not seen, and
///   [itemText] (one cut line) opens none.
/// - While [codeRow], a hidden fence line's terminator renders hidden too,
///   so the line takes its height from the field's strut alone.
/// - A table's lines (Spec #197 R13) take their inline tokens cell by cell
///   (the one cell splitter, D10). While revealed, a touch on any of its
///   lines reveals every line's markers, its cell-splitting `|`s and its
///   whole delimiter line render as markers, and its header line's cell
///   text is bold. Every table line stays one body line (no code-row strut).
///
/// - [inkRanges] and [current] (WI #84, Spec #61 Reqs 24-25): inside a range
///   of [inkRanges] that is not [current], text that would draw in fg2, fg3
///   or info draws in fg1; inside [current] every run draws in surface0.
///   They never reveal anything (cards and grid cells pass them).
///
/// The controller calls it as `buildLivePreviewSpan(text, style: style,
/// selection: selection, forceHidden: !revealGate.value, ...)`, forwarding
/// every prop. `toPlainText()` of the result equals [text] code unit for
/// code unit, and the tree holds only `TextSpan`s (TD4, D17).
TextSpan buildLivePreviewSpan(
  String text, {
  TextStyle? style,
  TextSelection? selection,
  bool forceHidden = false,
  bool itemText = false,
  bool taskDone = false,
  bool quote = false,
  bool atSegmentStart = true,
  bool Function(String target)? isResolved,
  TextRange? cmdHover,
  bool codeRow = false,
  int? before,
  List<bool>? fenced,
  List<TextRange> inkRanges = const <TextRange>[],
  TextRange? current,
}) => _buildSpan(
  text,
  style: style,
  selection: selection,
  forceHidden: forceHidden,
  itemText: itemText,
  taskDone: taskDone,
  quote: quote,
  atSegmentStart: atSegmentStart,
  isResolved: isResolved,
  cmdHover: cmdHover,
  codeRow: codeRow,
  before: before,
  fenced: fenced,
  revealRange: null,
  inkRanges: inkRanges,
  current: current,
);

/// [buildLivePreviewSpan] plus the field's find [revealRange] (WI #84),
/// which only the controller passes: cards and grid cells never reveal.
TextSpan _buildSpan(
  String text, {
  required TextStyle? style,
  required TextSelection? selection,
  required bool forceHidden,
  required bool itemText,
  required bool taskDone,
  required bool quote,
  required bool atSegmentStart,
  required bool Function(String target)? isResolved,
  required TextRange? cmdHover,
  required bool codeRow,
  required int? before,
  required List<bool>? fenced,
  required TextRange? revealRange,
  required List<TextRange> inkRanges,
  required TextRange? current,
}) {
  if (text.isEmpty) return TextSpan(style: style, text: text);
  return _SpanBuilder(
    text,
    selection: selection,
    forceHidden: forceHidden,
    itemText: itemText,
    taskDone: taskDone,
    quote: quote,
    atSegmentStart: atSegmentStart,
    isResolved: isResolved,
    cmdHover: cmdHover,
    codeRow: codeRow,
    before: before,
    fenced: fenced,
    revealRange: revealRange,
    inkRanges: inkRanges,
    current: current,
  ).build(style);
}

// Per code unit flags the line grammar and the inline tokens set.
const int _marker = 1;
const int _bold = 2;
const int _italic = 4;
const int _strike = 8;
const int _link = 16;
const int _ghost = 32;
const int _hover = 64;

// Per code unit find ink (WI #84): inside another match, inside the current
// one.
const int _findOther = 1;
const int _findCurrent = 2;

// Run keys that are not a shown-text key.
const int _hiddenKey = -1;
const int _terminatorKey = -2;

/// Builds one [buildLivePreviewSpan] result: classifies the lines (A1),
/// tokenizes each line's text (A2), then emits one leaf per run of code
/// units that share a style, every leaf a direct child of the root.
final class _SpanBuilder {
  _SpanBuilder(
    this.text, {
    required TextSelection? selection,
    required this.forceHidden,
    required this.itemText,
    required this.taskDone,
    required this.quote,
    required this.atSegmentStart,
    required this.isResolved,
    required this.cmdHover,
    required this.codeRow,
    required this.before,
    required this.fenced,
    required this.revealRange,
    required List<TextRange> inkRanges,
    required TextRange? current,
  }) : _selection = selection != null && selection.isValid ? selection : null,
       _flags = Uint8List(text.length),
       _ink = Uint8List(text.length),
       _find = Uint8List(text.length) {
    for (final range in inkRanges) {
      _findRange(range, _findOther);
    }
    if (current != null) _findRange(current, _findCurrent);
  }

  final String text;
  final bool forceHidden;
  final bool itemText;
  final bool taskDone;
  final bool quote;
  final bool atSegmentStart;
  final bool Function(String target)? isResolved;
  final TextRange? cmdHover;
  final bool codeRow;

  /// The code unit just before [text] in its real line, for a [text] that
  /// is a stretch of a longer line (a table cell); null = a line start.
  final int? before;

  /// Which lines of [text] are fenced code, from the host; null = judge
  /// [text] alone.
  final List<bool>? fenced;

  /// Find in note's reveal range (WI #84): the lines it touches reveal even
  /// while [forceHidden]. Null: none.
  final TextRange? revealRange;
  final TextSelection? _selection;
  final Uint8List _flags;
  final Uint8List _ink;

  /// Each code unit's find ink: 0, [_findOther] or [_findCurrent].
  final Uint8List _find;
  final Map<int, TextStyle?> _styles = {};

  /// Whether the line being tokenized is fenced code on the server, so a tag
  /// token there gets no ink.
  bool _fencedLine = false;

  TextSpan build(TextStyle? style) {
    final lines = classifyLines(text, atSegmentStart: atSegmentStart);
    final revealed = revealedLines(
      lines,
      _selection,
      forceHidden: forceHidden,
      itemText: itemText,
      revealRange: revealRange,
    );
    final levels = List<int>.filled(lines.length, 0);
    final codeLines = List<bool>.filled(lines.length, false);
    final fenceLines = List<bool>.filled(lines.length, false);
    final serverFenced = _serverFenced(lines);
    for (final (i, line) in lines.indexed) {
      _fencedLine = serverFenced[i];
      switch (itemText ? MdLineKind.plain : line.kind) {
        case MdLineKind.heading:
          levels[i] = line.level;
          // While revealed, spaces after the separator with no word yet join
          // the marker run (#90): split across the marker's body face and a
          // whitespace-only heading-face run, their boxes overlap and the
          // caret after the last space draws one space short. Hidden, the
          // spaces stay shown text so the line keeps the heading's height.
          final markerEnd =
              revealed[i] && _onlySpaces(line.textStart, line.contentEnd)
              ? line.contentEnd
              : line.separatorEnd;
          _markRange(line.markerStart, markerEnd, _marker);
          _tokenize(line.textStart, line.contentEnd);
        case MdLineKind.bullet ||
            MdLineKind.numbered ||
            MdLineKind.task ||
            MdLineKind.quote:
          // Before rows (C1) an item line keeps its marker as plain text.
          _tokenize(line.textStart, line.contentEnd);
        case MdLineKind.plain:
          _tokenize(line.start, line.contentEnd);
        case MdLineKind.rule:
          _markRange(line.start, line.contentEnd, _marker);
        case MdLineKind.fenceOpen || MdLineKind.fenceClose:
          fenceLines[i] = true;
          _markRange(line.start, line.contentEnd, _marker);
        case MdLineKind.fenceInside:
          codeLines[i] = true;
        case MdLineKind.blank || MdLineKind.frontmatter:
          break;
        case MdLineKind.tableHeader ||
            MdLineKind.tableDelimiter ||
            MdLineKind.tableBody:
          _tableLine(line, revealed[i]);
      }
    }

    final children = <TextSpan>[];
    var runStart = 0;
    int? runKey;
    void flush(int end) {
      if (runKey != null && end > runStart) {
        children.add(
          TextSpan(text: text.substring(runStart, end), style: _style(runKey)),
        );
      }
      runStart = end;
    }

    for (final (i, line) in lines.indexed) {
      // A code row's hidden fence line hides its terminator too (D18). A
      // revealed heading line's terminator takes the style of the code unit
      // before it (#64): the caret at the line end reads the terminator's
      // box, so a body-styled terminator draws it before a trailing space
      // in the heading's face and size. Its markers are shown, so that unit
      // is never hidden, and the line's height is unchanged.
      final terminator = codeRow && fenceLines[i] && !revealed[i]
          ? _hiddenKey
          : levels[i] > 0 && revealed[i]
          ? _key(line.contentEnd - 1, levels[i], codeLines[i], true)
          : _terminatorKey;
      for (var at = line.start; at < line.end; at++) {
        final key = at >= line.contentEnd
            ? terminator
            : _key(at, levels[i], codeLines[i], revealed[i]);
        if (key != runKey) {
          flush(at);
          runKey = key;
        }
      }
    }
    flush(text.length);
    return TextSpan(style: style, children: children);
  }

  /// Which of [lines] the server skips as fenced code: the host's answer
  /// when it gave one. Otherwise [text] alone: item text and a table cell are
  /// cut from a line that starts with a marker or a pipe, which opens no
  /// fence.
  List<bool> _serverFenced(List<MdLine> lines) {
    final hosted = fenced;
    if (hosted != null) {
      return [
        for (var i = 0; i < lines.length; i++)
          hosted.elementAtOrNull(i) ?? false,
      ];
    }
    return itemText
        ? List<bool>.filled(lines.length, false)
        : fencedMdLines(text, lines);
  }

  /// Marks the table line [line] (Spec #197 R13): each cell's inline tokens
  /// (cells from the one cell splitter, D10). While [revealed], also its
  /// cell-splitting `|`s, or the whole delimiter line, as markers (`fg2`,
  /// `fg1` while selected), and a header line's cell text bold. A `\|` and
  /// the `|` inside a wikilink split no cell, so they keep their cell style.
  void _tableLine(MdLine line, bool revealed) {
    final split = splitTableLine(text, start: line.start, end: line.contentEnd);
    final header = revealed && line.kind == MdLineKind.tableHeader;
    for (final cell in split.cells) {
      _tokenize(cell.start, cell.end);
      if (header) _markRange(cell.start, cell.end, _bold);
    }
    if (!revealed) return;
    if (line.kind == MdLineKind.tableDelimiter) {
      _markRange(line.start, line.contentEnd, _marker);
      return;
    }
    for (final pipe in split.pipes) {
      _markRange(pipe, pipe + 1, _marker);
    }
  }

  /// Whether `[start, end)` of [text] holds only spaces (true when empty).
  bool _onlySpaces(int start, int end) {
    for (var at = start; at < end; at++) {
      if (text.codeUnitAt(at) != 0x20) return false;
    }
    return true;
  }

  void _markRange(int start, int end, int flag) {
    for (var at = start; at < end; at++) {
      _flags[at] |= flag;
    }
  }

  /// Sets the find ink of [range]'s code units inside [text] to [find].
  void _findRange(TextRange range, int find) {
    final end = math.min(range.end, text.length);
    for (var at = math.max(range.start, 0); at < end; at++) {
      _find[at] = find;
    }
  }

  void _inkRange(int start, int end, LivePreviewInk ink) {
    for (var at = start; at < end; at++) {
      _ink[at] = ink.index;
    }
  }

  /// Marks the inline tokens of `[start, end)` (one line's text). Tokens
  /// come sorted by start, so an inner token's ink overwrites its outer
  /// token's while flags accumulate.
  void _tokenize(int start, int end) {
    for (final token in tokenizeInline(
      text.substring(start, end),
      before: start == 0 ? before : unitBeforeInLine(text, start),
    )) {
      for (final m in token.markers) {
        _markRange(start + m.start, start + m.end, _marker);
      }
      final from = start + token.content.start;
      final to = start + token.content.end;
      void flag(int f) => _markRange(from, to, f);
      switch (token) {
        case WikilinkToken(:final target) ||
            TransclusionLinkToken(date: final target):
          if (isResolved?.call(target) ?? true) {
            _inkRange(from, to, LivePreviewInk.wikilink);
            final hover = cmdHover;
            if (hover != null &&
                hover.start <= start + token.start &&
                start + token.end <= hover.end) {
              flag(_hover);
            }
          } else {
            _inkRange(from, to, LivePreviewInk.ghost);
            flag(_ghost);
          }
        case LinkToken():
          _inkRange(from, to, LivePreviewInk.link);
          flag(_link);
        case InlineToken(kind: InlineTokenKind.tag) when _fencedLine:
          break;
        case InlineToken(kind: InlineTokenKind.tag):
          // Only the colour changes (and the underline on hover): the tag
          // keeps the line's size, weight, slant and strike. A Cmd hover is
          // not gated by [forceHidden] (cards hover too); a caret is.
          final hover = cmdHover;
          final hovered =
              hover != null &&
              hover.start <= start + token.start &&
              start + token.end <= hover.end;
          if (hovered) flag(_hover);
          final caret = _selection;
          final lit =
              hovered ||
              (!forceHidden &&
                  caret != null &&
                  caret.isCollapsed &&
                  start + token.start <= caret.baseOffset &&
                  caret.baseOffset <= start + token.end);
          _inkRange(
            from,
            to,
            lit ? LivePreviewInk.tagActive : LivePreviewInk.tag,
          );
        case InlineToken(kind: InlineTokenKind.codeSpan):
          _inkRange(from, to, LivePreviewInk.code);
        case InlineToken(kind: InlineTokenKind.strike):
          _inkRange(from, to, LivePreviewInk.strike);
          flag(_strike);
        case InlineToken(kind: InlineTokenKind.bold):
          flag(_bold);
        case InlineToken(kind: InlineTokenKind.italic):
          flag(_italic);
        case InlineToken(kind: InlineTokenKind.boldItalic):
          flag(_bold | _italic);
        case InlineToken():
          // An escape: its backslash and character stay plain text.
          break;
      }
    }
  }

  bool _selected(int at) {
    final s = _selection;
    return s != null && s.start <= at && at < s.end;
  }

  /// The run key of the code unit [at] on a line of heading [level]
  /// (0: none), inside a fenced block when [codeLine], its markers shown
  /// when [revealed]. Equal keys mean equal styles.
  int _key(int at, int level, bool codeLine, bool revealed) {
    final flags = _flags[at];
    final selected = _selected(at) ? 1 : 0;
    final find = _find[at] << 17;
    if (flags & _marker != 0) {
      if (!revealed) return _hiddenKey;
      return 1 << 24 | find | selected << 16 | level;
    }
    return find |
        selected << 16 |
        _ink[at] << 12 |
        flags << 4 |
        (codeLine ? 1 : 0) << 3 |
        level;
  }

  TextStyle? _style(int key) => _styles.putIfAbsent(key, () {
    if (key == _terminatorKey) return null;
    if (key == _hiddenKey) return livePreviewHiddenStyle;
    return _findInk(_shownStyle(key), key >> 17 & 3);
  });

  /// [style] under the find ink [find] (Spec #61 Reqs 24-25): inside the
  /// current match every run draws in surface0; inside another match a run
  /// that would draw in fg2, fg3 or info draws in fg1. Only the colour
  /// changes.
  static TextStyle? _findInk(TextStyle? style, int find) {
    if (find == _findCurrent) {
      return (style ?? const TextStyle()).copyWith(color: OmColors.surface0);
    }
    if (find == _findOther && _lifted.contains(style?.color)) {
      return style!.copyWith(color: OmColors.fg1);
    }
    return style;
  }

  /// The colours another match lifts to fg1 (Req 24).
  static const List<Color> _lifted = [
    OmColors.fg2,
    OmColors.fg3,
    OmColors.info,
  ];

  /// The style of a shown run's [key] before any find ink.
  TextStyle? _shownStyle(int key) {
    final selected = key >> 16 & 1 == 1;
    final level = key & 7;
    if (key >> 24 & 1 == 1) {
      return livePreviewMarkerStyle(headingLevel: level, selected: selected);
    }
    final flags = key >> 4 & 0xFF;
    return livePreviewTextStyle(
      headingLevel: level,
      codeLine: key >> 3 & 1 == 1,
      bold: flags & _bold != 0,
      italic: flags & _italic != 0,
      strike: flags & _strike != 0,
      link: flags & _link != 0,
      ghost: flags & _ghost != 0,
      hover: flags & _hover != 0,
      ink: LivePreviewInk.values[key >> 12 & 0xF],
      quote: quote,
      done: taskDone,
      selected: selected,
    );
  }
}
