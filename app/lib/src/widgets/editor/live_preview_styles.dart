// WI #164 (B1): every text style live preview draws (Spec #157 R2, R4, R13;
// design pack design/156-live-preview/packs/164.md, which wins over the WI).
//
// Colours come only from OmColors and faces only from OmType (R6). The span
// builder in live_preview_controller.dart decides which style each run of
// code units takes; this file only says what each style is.

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
}

/// The font size of a heading of [level]: H1 20, H2 17, H3 15, H4-H6 13.5.
double headingFontSize(int level) => switch (level) {
  1 => 20,
  2 => 17,
  3 => 15,
  _ => monoFontSize,
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
TextStyle _lineMetrics(int level) {
  if (level == 0) return const TextStyle();
  final size = headingFontSize(level);
  return TextStyle(fontSize: size, height: headingLineHeight(level) / size);
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
/// - [headingLevel] (0: not a heading) sets the size, line height and bold.
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
    LivePreviewInk.none when codeLine || quote => OmColors.fg1,
    LivePreviewInk.none when done => selected ? OmColors.fg1 : OmColors.fg2,
    LivePreviewInk.none => null,
  };
  final heavy = bold || headingLevel > 0;
  final slanted = italic || quote;
  if (!heavy && !slanted && !struck && !underlined && colour == null) {
    return null;
  }
  final face = heavy ? OmType.mono(weight: FontWeight.w700) : null;
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
