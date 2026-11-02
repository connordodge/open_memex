import 'package:flutter/material.dart';

/// Open Memex color system. Mirrors `colors_and_type.css` from the design
/// handoff. A dark editorial-tech surface with one terminal-green accent
/// and a lavender for AI activity.
class OmColors {
  OmColors._();

  // Surface (warm-cool dark grays).
  static const surface0 = Color(0xFF07090B); // page void
  static const surface1 = Color(0xFF0B0E11); // app bg
  static const surface2 = Color(0xFF11151A); // panel bg
  static const surface3 = Color(0xFF181D23); // card bg
  static const surface4 = Color(0xFF20262E); // hover/raised
  static const surface5 = Color(0xFF2A313A); // pressed/border-strong

  // Foreground.
  static const fg0 = Color(0xFFF4F1EA); // bone — primary
  static const fg1 = Color(0xFFD6D3CC); // secondary
  static const fg2 = Color(0xFF9B9A94); // tertiary / metadata
  static const fg3 = Color(0xFF6B6C68); // placeholder / disabled-on
  static const fg4 = Color(0xFF3F433F); // hairlines on dark

  // Heading text (#221, design A + D). Skeleton (WI #223 red commit): a
  // transparent placeholder until the implementer sets the real value.
  /// H1 shown text.
  static const heading1 = Color(0x00000000);

  /// H3 shown text.
  static const heading3 = Color(0x00000000);

  // Borders & strokes (the spec uses opacity over a near-white; we
  // approximate with composited grays so they read on every surface).
  static final line1 = const Color(0xFFFFFCF0).withAlpha(15);
  static final line2 = const Color(0xFFFFFCF0).withAlpha(25);
  static final line3 = const Color(0xFFFFFCF0).withAlpha(40);
  static final lineStrong = const Color(0xFFFFFCF0).withAlpha(70);

  // Accent (terminal green).
  static const accent = Color(0xFF7CFFB2);
  static const accentSoft = Color(0xFF4FCF8A);
  static const accentDeep = Color(0xFF1F6E43);
  static const accentFg = Color(0xFF061410);
  static final accentGlow = const Color(0xFF7CFFB2).withAlpha(46);
  static final successBg = const Color(0xFF7CFFB2).withAlpha(26);

  // Semantic.
  static const info = Color(0xFF7AA2FF);
  static const warn = Color(0xFFFFD27A);
  static const danger = Color(0xFFFF7A8A);
  static final infoBg = const Color(0xFF7AA2FF).withAlpha(26);
  static final warnBg = const Color(0xFFFFD27A).withAlpha(26);
  static final dangerBg = const Color(0xFFFF7A8A).withAlpha(26);

  // Agent (AI activity).
  static const agent = Color(0xFFB9A6FF);
  static final agentBg = const Color(0xFFB9A6FF).withAlpha(26);

  // Selection.
  static final selectionBg = const Color(0xFF7CFFB2).withAlpha(56);

  /// The editor's selection fill (D13, pack #159).
  static final selection = const Color(0xFF7CFFB2).withAlpha(56);

  // Dialog shadow (packs 100, 103: black at 60%).
  static const dialogShadow = Color(0x99000000);
}
