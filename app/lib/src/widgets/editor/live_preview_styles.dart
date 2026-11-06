// WI #164 (B1): every text style live preview draws (Spec #157 R2, R4, R13;
// design pack design/156-live-preview/packs/164.md, which wins over the WI).
//
// Colours come only from OmColors and faces only from OmType (R6). The span
// builder in live_preview_controller.dart decides which style each run of
// code units takes; this file only says what each style is.

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../editor/row_geometry.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// The colour a run's innermost inline token gives its shown text.
enum LivePreviewInk {
  /// No token colours the run: it takes the line's or the field's colour.
  none,

  /// Inline code content: `fg1` (B2 paints the pill).
  code,

  /// `~~strike~~` content: `fg2`.
  strike,

  /// `[text](url)` text: `info`, `fg1` while selected.
  link,

  /// A resolved wikilink or transclusion's shown text: `accent`.
  wikilink,

  /// An unresolved (ghost) wikilink's shown text: `fg2`, `fg1` while
  /// selected.
  ghost,

  /// A `#tag` at rest, or inside a range selection: `fg2` (WI #245).
  tag,

  /// A `#tag` a collapsed caret is in, or a Cmd hover is over: `accentSoft`
  /// (WI #245).
  tagActive,
}

/// The font size of a heading of [level] (#221, design A + D): H1 26, H2 19,
/// H3 15, H4-H6 11.
double headingFontSize(int level) => switch (level) {
  1 => 26,
  2 => 19,
  3 => 15,
  _ => 11,
};

/// The colour of a heading of [level]'s uncoloured shown text (#221): H1
/// `heading1`, H2 and H3 `fg0`, H4-H6 `fg2`; null for 0.
Color? _headingColour(int level) => switch (level) {
  0 => null,
  1 => OmColors.heading1,
  2 || 3 => OmColors.fg0,
  _ => OmColors.fg2,
};

/// The weight of a heading of [level]'s text (#221): w700 for H1-H3, w500
/// for H4-H6; null for 0.
FontWeight? _headingWeight(int level) => switch (level) {
  0 => null,
  1 || 2 || 3 => FontWeight.w700,
  _ => FontWeight.w500,
};

/// The live preview field's strut (R13): a 22.95 px minimum (13.5 x 1.7) in
/// the body face, never forced, so heading lines lay out taller.
///
/// With [codeRow] (a code row's text, ruling D18): an 8 px minimum (the
/// design's hidden fence line, pack #161: 7 px padding plus a 1 px border)
/// instead, not forced, so a hidden fence line lays out 8 px tall while code
/// lines keep their 22.95 px body line. Default false.
StrutStyle livePreviewStrut({bool codeRow = false}) {
  if (codeRow) return const StrutStyle(fontSize: 8, height: 1);
  final body = OmType.mono(size: monoFontSize);
  return StrutStyle(
    fontFamily: body.fontFamily,
    fontFamilyFallback: body.fontFamilyFallback,
    fontSize: monoFontSize,
    height: minimumStrutHeight / monoFontSize,
  );
}

/// A hidden marker: zero-width, its characters kept (TD4, D17). The line
/// keeps its height from the field's strut and its other runs.
const TextStyle livePreviewHiddenStyle = TextStyle(
  fontSize: 0,
  letterSpacing: 0,
);

/// The size and line height of a heading line of [level]; empty for 0 (a
/// non-heading line keeps the field's base style).
///
/// A heading larger than the body takes its line height outright. One
/// smaller than the body (H4-H6, 11 px) takes the body's ratio instead
/// (22.95 / 13.5), not 22.95 / 11 (Spec #222 R5a): under even leading its
/// box is then the strut's box scaled about the shared baseline, so it fits
/// inside it and the strut sets the 22.95 px line. A 22.95 px box at 11 px
/// sits lower than the strut's and makes the line taller.
TextStyle _lineMetrics(int level) {
  if (level == 0) return const TextStyle();
  final size = headingFontSize(level);
  return TextStyle(
    fontSize: size,
    height: headingLineHeight(level) / math.max(size, monoFontSize),
  );
}

/// A revealed marker on a line of [headingLevel] (0: not a heading): `fg2`,
/// or `fg1` while [selected], regular, upright and undecorated, at the
/// line's own size so it keeps its normal width.
TextStyle livePreviewMarkerStyle({
  required int headingLevel,
  required bool selected,
}) => _lineMetrics(
  headingLevel,
).copyWith(color: selected ? OmColors.fg1 : OmColors.fg2);

/// The style of shown text, or null when it is plain body text.
///
/// - [headingLevel] (0: not a heading) sets the size, line height, weight
///   (w700 for H1-H3, w500 for H4-H6; [bold] is always w700) and the colour
///   of runs nothing else colours. Colour precedence: [ink], then
///   [codeLine] or [quote], then [done], then the heading colour.
/// - [codeLine]: a line inside a fenced block, plain `fg1`.
/// - [bold], [italic], [strike], [link], [ghost] and [hover] come from the
///   inline tokens around the run; [ink] from the innermost colouring one.
/// - [quote]: the field is a quote row's text, italic `fg1`.
/// - [done]: the field is a done task's text, struck through in `fg2` (not
///   for a quote).
/// - [selected]: link, ghost and done-task text turn `fg1`.
TextStyle? livePreviewTextStyle({
  required int headingLevel,
  required bool codeLine,
  required bool bold,
  required bool italic,
  required bool strike,
  required bool link,
  required bool ghost,
  required bool hover,
  required LivePreviewInk ink,
  required bool quote,
  required bool done,
  required bool selected,
}) {
  final struck = strike || (done && !quote);
  final underlined = link || ghost || hover;
  final colour = switch (ink) {
    LivePreviewInk.code => OmColors.fg1,
    LivePreviewInk.strike => OmColors.fg2,
    LivePreviewInk.link || LivePreviewInk.ghost when selected => OmColors.fg1,
    LivePreviewInk.link => OmColors.info,
    LivePreviewInk.wikilink => OmColors.accent,
    LivePreviewInk.ghost => OmColors.fg2,
    LivePreviewInk.tag => OmColors.fg2,
    LivePreviewInk.tagActive => OmColors.accentSoft,
    LivePreviewInk.none when codeLine || quote => OmColors.fg1,
    LivePreviewInk.none when done => selected ? OmColors.fg1 : OmColors.fg2,
    LivePreviewInk.none => _headingColour(headingLevel),
  };
  final weight = bold ? FontWeight.w700 : _headingWeight(headingLevel);
  final slanted = italic || quote;
  if (weight == null && !slanted && !struck && !underlined && colour == null) {
    return null;
  }
  final face = weight == null ? null : OmType.mono(weight: weight);
  return _lineMetrics(headingLevel).copyWith(
    fontFamily: face?.fontFamily,
    fontFamilyFallback: face?.fontFamilyFallback,
    fontWeight: face?.fontWeight,
    fontStyle: slanted ? FontStyle.italic : null,
    color: colour,
    decoration: struck || underlined
        ? TextDecoration.combine([
            if (struck) TextDecoration.lineThrough,
            if (underlined) TextDecoration.underline,
          ])
        : null,
    decorationStyle: ghost ? TextDecorationStyle.dashed : null,
    decorationColor: ghost ? OmColors.fg3 : null,
  );
}
