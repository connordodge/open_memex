// WI #161 (A2): the live preview design's geometry as pure numbers (Spec R11,
// R12, R13; TD10; design pack `design/156-live-preview/packs/161.md`, which
// wins over any number copied elsewhere).
//
// Pure Dart: no Flutter imports. Painters and row layout draw only what these
// functions return, so every number they need lives here and is tested.
// Pixels are logical pixels, as doubles.

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
double get monoFontSize => throw UnimplementedError();

/// One mono column at [monoFontSize]: 0.6 em = 8.1 px.
double get monoColumnWidth => throw UnimplementedError();

/// The mono advance (0.6 em) at [fontSize]: 8.1 at 13.5, 12.0 at H1 20,
/// 10.2 at H2 17, 9.0 at H3 15. Revealed markers on a heading line are
/// [fontSize]-sized, so their width is characters times this.
double monoAdvance(double fontSize) => throw UnimplementedError();

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
}) => throw UnimplementedError();

/// The marker column's width in px: [markerColumns] times [monoColumnWidth].
double markerColumnWidth(
  MarkerColumnKind kind, {
  int numberDigits = 1,
  bool revealed = false,
}) => throw UnimplementedError();

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
}) => throw UnimplementedError();

/// The item text's right inset from the text column's right edge: one
/// column (8.1) for a quote row, 0 for every other kind.
double itemTextRightInset(MarkerColumnKind kind) => throw UnimplementedError();

/// The left x of a painted (unrevealed) number such as `9.` or `10.`:
/// right-aligned with a 1-column right padding, so
/// [columnLeft] + [columnWidth] - [monoColumnWidth] - [textWidth]. In a
/// 4-column column `9.` lands at +8.1 and `10.` at +0, and the dots line up.
double numberedMarkerLeft({
  required double columnLeft,
  required double columnWidth,
  required double textWidth,
}) => throw UnimplementedError();

/// The height of one line of [kind] (Spec R13, pack #161): body, item,
/// task, quote, H4-H6, blank, rule, code and revealed fence lines 22.95
/// (13.5 x 1.7); H1 40; H2 34; H3 28.5; hidden fence line 8.
double lineHeight(LineHeightKind kind) => throw UnimplementedError();

/// The line height of a heading of [level] (1 to 6), as [lineHeight].
///
/// Throws [ArgumentError] when [level] is outside 1..6.
double headingLineHeight(int level) => throw UnimplementedError();

/// The field's minimum strut height (Spec R13): the body line height, 22.95.
double get minimumStrutHeight => throw UnimplementedError();

/// The y of the painted horizontal rule below its line's top: 11.
double get ruleOffsetY => throw UnimplementedError();

/// The painted horizontal rule's thickness: 1.
double get ruleThickness => throw UnimplementedError();

/// The code row's text inset from the code box's left edge: 16.2
/// (2 columns: 15.2 padding + 1 border).
double get codeTextInsetLeft => throw UnimplementedError();

/// The code row's text inset from the code box's right edge: 10
/// (9 padding + 1 border).
double get codeTextInsetRight => throw UnimplementedError();

/// The width left for code text in a code row [rowWidth] wide:
/// [rowWidth] - [codeTextInsetLeft] - [codeTextInsetRight] (A1: 746 gives
/// 719.8).
double codeTextWidth(double rowWidth) => throw UnimplementedError();

/// How far the code box reaches above its first and below its last fence
/// line while the code row is revealed: 8 (the hidden fence line's height,
/// so the box keeps its padding when both fences show).
double get codeBoxRevealedOutset => throw UnimplementedError();
