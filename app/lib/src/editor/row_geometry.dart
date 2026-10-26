// WI #161 (A2): the live preview design's geometry as pure numbers (Spec R11,
// R12, R13; TD10; design pack `design/156-live-preview/packs/161.md`, which
// wins over any number copied elsewhere).
//
// Pure Dart: no Flutter imports. Painters and row layout draw only what these
// functions return, so every number they need lives here and is tested.
// Pixels are logical pixels, as doubles.

/// JetBrains Mono's advance as a fraction of the font size.
const double _monoAdvanceEm = 0.6;

/// Body, item, blank, rule and code lines: 13.5 x 1.7.
const double _bodyLineHeight = 22.95;

/// A hidden fence line: 7 px padding plus the 1 px code box border.
const double _fenceHiddenLineHeight = 8;

/// The kind of marker an item row's marker column holds (Spec R11).
///
/// Kept local to this file so it doesn't depend on the row model (A1).
enum MarkerColumnKind {
  /// `- `, `* ` or `+ `.
  bullet,

  /// `N. ` (1 to 9 digits).
  numbered,

  /// `> `.
  quote,

  /// `- [ ] ` or `- [x] `.
  task,
}

/// The kind of a line, for its height (Spec R13; pack #161 line-height table).
enum LineHeightKind {
  /// A prose (paragraph) line.
  body,

  /// A bullet or numbered item line.
  item,

  /// A task item line.
  task,

  /// A quote line.
  quote,

  /// `# ` heading line.
  heading1,

  /// `## ` heading line.
  heading2,

  /// `### ` heading line.
  heading3,

  /// `#### ` heading line.
  heading4,

  /// `##### ` heading line.
  heading5,

  /// `###### ` heading line.
  heading6,

  /// An empty line.
  blank,

  /// A horizontal-rule line.
  rule,

  /// A line of code inside a fenced code row.
  code,

  /// A fence line while the code row is not revealed (the box's padding).
  fenceHidden,

  /// A fence line while the code row is revealed (caret inside the block).
  fenceRevealed,
}

/// The base mono size (JetBrains Mono, body text) in px.
double get monoFontSize => 13.5;

/// One mono column at [monoFontSize]: 0.6 em = 8.1 px.
double get monoColumnWidth => monoAdvance(monoFontSize);

/// The mono advance (0.6 em) at [fontSize]: 8.1 at 13.5, 12.0 at H1 20,
/// 10.2 at H2 17, 9.0 at H3 15. Revealed markers on a heading line are
/// [fontSize]-sized, so their width is characters times this.
double monoAdvance(double fontSize) => fontSize * _monoAdvanceEm;

/// The marker column's width in mono columns (Spec R11, pack #161):
/// bullet 2; numbered = [numberDigits] + 2, where [numberDigits] is the digit
/// count of the run's widest number (1-digit run 3, 2-digit 4, 3-digit 5);
/// quote 2; task 4, or 6 when [revealed]. Only a task widens when revealed.
///
/// Throws [ArgumentError] when [kind] is numbered and [numberDigits] is
/// below 1.
int markerColumns(
  MarkerColumnKind kind, {
  int numberDigits = 1,
  bool revealed = false,
}) => switch (kind) {
  MarkerColumnKind.bullet => 2,
  MarkerColumnKind.numbered => _numberedColumns(numberDigits),
  MarkerColumnKind.quote => 2,
  MarkerColumnKind.task => revealed ? 6 : 4,
};

int _numberedColumns(int numberDigits) {
  if (numberDigits < 1) {
    throw ArgumentError.value(
      numberDigits,
      'numberDigits',
      'a numbered run has at least one digit',
    );
  }
  return numberDigits + 2;
}

/// The marker column's width in px: [markerColumns] times [monoColumnWidth].
double markerColumnWidth(
  MarkerColumnKind kind, {
  int numberDigits = 1,
  bool revealed = false,
}) =>
    markerColumns(kind, numberDigits: numberDigits, revealed: revealed) *
    monoColumnWidth;

/// An item row's horizontal geometry (Spec R11, R12).
final class ItemGeometry {
  const ItemGeometry({
    required this.markerX,
    required this.columns,
    required this.columnWidth,
    required this.textX,
    required this.childMarkerX,
  });

  /// Left edge of the marker column.
  final double markerX;

  /// The marker column's width in mono columns (as drawn now).
  final int columns;

  /// The marker column's width in px (as drawn now).
  final double columnWidth;

  /// Where the item's text (and every wrapped line of it) starts:
  /// [markerX] + [columnWidth].
  final double textX;

  /// Where a child item's marker column starts: this item's *unrevealed*
  /// text x, so revealing a task never moves its children (R12).
  final double childMarkerX;
}

/// The geometry of an item row whose marker column starts at [markerX].
/// A level-1 item starts at the text column left; a child starts at its
/// parent's [ItemGeometry.childMarkerX].
ItemGeometry itemGeometry({
  required double markerX,
  required MarkerColumnKind kind,
  int numberDigits = 1,
  bool revealed = false,
}) {
  final columns = markerColumns(
    kind,
    numberDigits: numberDigits,
    revealed: revealed,
  );
  final columnWidth = columns * monoColumnWidth;
  return ItemGeometry(
    markerX: markerX,
    columns: columns,
    columnWidth: columnWidth,
    textX: markerX + columnWidth,
    childMarkerX: markerX + markerColumnWidth(kind, numberDigits: numberDigits),
  );
}

/// The item text's right inset from the text column's right edge: one
/// column (8.1) for a quote row, 0 for every other kind.
double itemTextRightInset(MarkerColumnKind kind) =>
    kind == MarkerColumnKind.quote ? monoColumnWidth : 0;

/// The left x of a painted (unrevealed) number such as `9.` or `10.`:
/// right-aligned with a 1-column right padding, so
/// [columnLeft] + [columnWidth] - [monoColumnWidth] - [textWidth]. In a
/// 4-column column `9.` lands at +8.1 and `10.` at +0, and the dots line up.
double numberedMarkerLeft({
  required double columnLeft,
  required double columnWidth,
  required double textWidth,
}) => columnLeft + columnWidth - monoColumnWidth - textWidth;

/// The height of one line of [kind] (Spec R13, pack #161): body, item,
/// task, quote, H4-H6, blank, rule, code and revealed fence lines 22.95
/// (13.5 x 1.7); H1 40; H2 34; H3 28.5; hidden fence line 8.
double lineHeight(LineHeightKind kind) => switch (kind) {
  LineHeightKind.heading1 => 40,
  LineHeightKind.heading2 => 34,
  LineHeightKind.heading3 => 28.5,
  LineHeightKind.fenceHidden => _fenceHiddenLineHeight,
  LineHeightKind.body ||
  LineHeightKind.item ||
  LineHeightKind.task ||
  LineHeightKind.quote ||
  LineHeightKind.heading4 ||
  LineHeightKind.heading5 ||
  LineHeightKind.heading6 ||
  LineHeightKind.blank ||
  LineHeightKind.rule ||
  LineHeightKind.code ||
  LineHeightKind.fenceRevealed => _bodyLineHeight,
};

const _headingKinds = [
  LineHeightKind.heading1,
  LineHeightKind.heading2,
  LineHeightKind.heading3,
  LineHeightKind.heading4,
  LineHeightKind.heading5,
  LineHeightKind.heading6,
];

/// The line height of a heading of [level] (1 to 6), as [lineHeight].
///
/// Throws [ArgumentError] when [level] is outside 1..6.
double headingLineHeight(int level) {
  RangeError.checkValueInInterval(level, 1, 6, 'level');
  return lineHeight(_headingKinds[level - 1]);
}

/// The field's minimum strut height (Spec R13): the body line height, 22.95.
double get minimumStrutHeight => _bodyLineHeight;

/// The y of the painted horizontal rule below its line's top: 11.
double get ruleOffsetY => 11;

/// The painted horizontal rule's thickness: 1.
double get ruleThickness => 1;

/// The code row's text inset from the code box's left edge: 16.2
/// (2 columns: 15.2 padding + 1 border).
double get codeTextInsetLeft => 2 * monoColumnWidth;

/// The code row's text inset from the code box's right edge: 10
/// (9 padding + 1 border).
double get codeTextInsetRight => 10;

/// The width left for code text in a code row [rowWidth] wide:
/// [rowWidth] - [codeTextInsetLeft] - [codeTextInsetRight] (A1: 746 gives
/// 719.8).
double codeTextWidth(double rowWidth) =>
    rowWidth - codeTextInsetLeft - codeTextInsetRight;

/// How far the code box reaches above its first and below its last fence
/// line while the code row is revealed: 8 (the hidden fence line's height,
/// so the box keeps its padding when both fences show).
double get codeBoxRevealedOutset => _fenceHiddenLineHeight;
