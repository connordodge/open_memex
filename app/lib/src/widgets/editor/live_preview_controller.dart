import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../editor/markdown_inline.dart';
import '../../editor/markdown_lines.dart';
import '../../editor/markdown_table.dart';
import 'live_preview_styles.dart';

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
/// - [revealGate]: true while the field's text segment has focus (markers
///   may reveal only then).
class LivePreviewController extends TextEditingController {
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

  /// The Cmd-hovered token's span in [text] (B3 sets it; D7). Null (the
  /// default): nothing renders hovered. Setting it notifies listeners so the
  /// field repaints.
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

  /// The live preview span of [text] for the current [selection], markers
  /// revealed only while [revealGate] is true. The composing range is not
  /// underlined.
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) => buildLivePreviewSpan(
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
  );
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
/// - While [codeRow], a hidden fence line's terminator renders hidden too,
///   so the line takes its height from the field's strut alone.
/// - A table's lines (Spec #197 R13) take their inline tokens cell by cell
///   (the one cell splitter, D10). While revealed, a touch on any of its
///   lines reveals every line's markers, its cell-splitting `|`s and its
///   whole delimiter line render as markers, and its header line's cell
///   text is bold. Every table line stays one body line (no code-row strut).
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
  }) : _selection = selection != null && selection.isValid ? selection : null,
       _flags = Uint8List(text.length),
       _ink = Uint8List(text.length);

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
  final TextSelection? _selection;
  final Uint8List _flags;
  final Uint8List _ink;
  final Map<int, TextStyle?> _styles = {};

  TextSpan build(TextStyle? style) {
    final lines = classifyLines(text, atSegmentStart: atSegmentStart);
    final revealed = _revealed(lines);
    final levels = List<int>.filled(lines.length, 0);
    final codeLines = List<bool>.filled(lines.length, false);
    final fenceLines = List<bool>.filled(lines.length, false);
    for (final (i, line) in lines.indexed) {
      switch (itemText ? MdLineKind.plain : line.kind) {
        case MdLineKind.heading:
          levels[i] = line.level;
          _markRange(line.markerStart, line.separatorEnd, _marker);
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
      // A code row's hidden fence line hides its terminator too (D18).
      final terminator = codeRow && fenceLines[i] && !revealed[i]
          ? _hiddenKey
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

  /// Which lines reveal their markers: every line the selection touches
  /// (a caret at a line's content end touches that line only), both fence
  /// lines of a block when any of its lines is touched, and every line of a
  /// table when any of its lines is touched (Spec #197 R13). None while
  /// [forceHidden].
  List<bool> _revealed(List<MdLine> lines) {
    final selection = _selection;
    final revealed = List<bool>.filled(lines.length, false);
    if (forceHidden || selection == null) return revealed;
    for (final (i, line) in lines.indexed) {
      revealed[i] =
          selection.start <= line.contentEnd && selection.end >= line.start;
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

  void _markRange(int start, int end, int flag) {
    for (var at = start; at < end; at++) {
      _flags[at] |= flag;
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
    if (flags & _marker != 0) {
      if (!revealed) return _hiddenKey;
      return 1 << 24 | selected << 16 | level;
    }
    return selected << 16 |
        _ink[at] << 12 |
        flags << 4 |
        (codeLine ? 1 : 0) << 3 |
        level;
  }

  TextStyle? _style(int key) => _styles.putIfAbsent(key, () {
    if (key == _terminatorKey) return null;
    if (key == _hiddenKey) return livePreviewHiddenStyle;
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
  });
}
