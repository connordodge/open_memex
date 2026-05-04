import 'package:flutter/material.dart';

import 'colors.dart';
import 'typography.dart';

/// Open Memex app-wide ThemeData. Dark editorial-tech surface; one accent
/// color (terminal green); type via Google Fonts (Inter Tight / JetBrains
/// Mono / Newsreader). Designed to match the static design handoff.
ThemeData buildOmTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  final colorScheme = base.colorScheme.copyWith(
    brightness: Brightness.dark,
    surface: OmColors.surface1,
    onSurface: OmColors.fg0,
    surfaceContainerHighest: OmColors.surface3,
    primary: OmColors.accent,
    onPrimary: OmColors.accentFg,
    secondary: OmColors.accentSoft,
    error: OmColors.danger,
    outline: OmColors.line2,
    outlineVariant: OmColors.line1,
  );

  return base.copyWith(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: OmColors.surface1,
    canvasColor: OmColors.surface1,
    textTheme: base.textTheme.apply(
      bodyColor: OmColors.fg0,
      displayColor: OmColors.fg0,
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: OmColors.surface3,
    dividerTheme: DividerThemeData(
      color: OmColors.line1,
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: false,
      hintStyle: OmType.sans(size: 13, color: OmColors.fg3),
      border: InputBorder.none,
      focusedBorder: InputBorder.none,
      enabledBorder: InputBorder.none,
      contentPadding: EdgeInsets.zero,
    ),
    iconTheme: const IconThemeData(color: OmColors.fg2, size: 14),
    listTileTheme: ListTileThemeData(
      tileColor: Colors.transparent,
      selectedTileColor: OmColors.surface4,
      iconColor: OmColors.fg2,
      textColor: OmColors.fg1,
      selectedColor: OmColors.fg0,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: OmColors.surface4,
      contentTextStyle: OmType.sans(size: 13, color: OmColors.fg0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      behavior: SnackBarBehavior.floating,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: OmColors.surface2,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: OmColors.line2, width: 1),
      ),
      titleTextStyle: OmType.sans(
        size: 16,
        weight: FontWeight.w600,
        color: OmColors.fg0,
      ),
      contentTextStyle: OmType.sans(size: 13, color: OmColors.fg1, height: 1.5),
    ),
    extensions: const [],
  );
}
