import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'colors.dart';

/// Type system. Three families:
/// - sans (Inter Tight) for UI + body
/// - mono (JetBrains Mono) for status / metadata / micro-labels
/// - serif (Newsreader) for editorial display titles
class OmType {
  OmType._();

  static TextStyle sans({
    double size = 14.5,
    FontWeight weight = FontWeight.w400,
    Color color = OmColors.fg0,
    double height = 1.5,
    double letterSpacing = 0,
  }) => GoogleFonts.interTight(
    fontSize: size,
    fontWeight: weight,
    color: color,
    height: height,
    letterSpacing: letterSpacing,
  );

  static TextStyle mono({
    double size = 12.5,
    FontWeight weight = FontWeight.w400,
    Color color = OmColors.fg1,
    double height = 1.5,
    double letterSpacing = 0,
  }) => GoogleFonts.jetBrainsMono(
    fontSize: size,
    fontWeight: weight,
    color: color,
    height: height,
    letterSpacing: letterSpacing,
  );

  static TextStyle serif({
    double size = 32,
    FontWeight weight = FontWeight.w500,
    Color color = OmColors.fg0,
    double height = 1.12,
    double letterSpacing = -0.5,
    FontStyle style = FontStyle.normal,
  }) => GoogleFonts.newsreader(
    fontSize: size,
    fontWeight: weight,
    color: color,
    height: height,
    letterSpacing: letterSpacing,
    fontStyle: style,
  );

  /// Mono uppercase mini-label used as section headers / status tags.
  static TextStyle eyebrow({Color color = OmColors.fg2}) =>
      mono(size: 11, weight: FontWeight.w500, color: color, letterSpacing: 1.0);

  /// Bigger editorial title (serif).
  static TextStyle h1Serif() => serif(size: 36, weight: FontWeight.w500);

  /// Standard body sans paragraph.
  static TextStyle body({Color color = OmColors.fg0}) =>
      sans(size: 15, height: 1.65, color: color);

  /// Sans heading h2 (used in panels).
  static TextStyle h2() => sans(
    size: 19,
    weight: FontWeight.w600,
    height: 1.28,
    color: OmColors.fg0,
  );
}
