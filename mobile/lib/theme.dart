import 'package:flutter/material.dart';

/// Photobank theme tokens - keep in sync with THEME.md (source of truth)
/// and web/src/index.css.
abstract class PbColors {
  static const bg = Color(0xFF101418);
  static const bgRaised = Color(0xFF1A2027);
  static const border = Color(0xFF2A333D);
  static const text = Color(0xFFE8EDF2);
  static const textDim = Color(0xFF8B98A5);
  static const accent = Color(0xFF4A9EFF);
  static const danger = Color(0xFFFF5C5C);
  static const onAccent = Color(0xFFFFFFFF);
}

ThemeData photobankTheme() {
  const scheme = ColorScheme.dark(
    surface: PbColors.bg,
    surfaceContainer: PbColors.bgRaised,
    surfaceContainerHighest: PbColors.bgRaised,
    primary: PbColors.accent,
    onPrimary: PbColors.onAccent,
    secondary: PbColors.accent,
    onSecondary: PbColors.onAccent,
    error: PbColors.danger,
    onSurface: PbColors.text,
    onSurfaceVariant: PbColors.textDim,
    outline: PbColors.border,
    outlineVariant: PbColors.border,
  );

  const buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(6)));

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: PbColors.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: PbColors.bgRaised,
      foregroundColor: PbColors.text,
      elevation: 0,
    ),
    cardTheme: const CardThemeData(
      color: PbColors.bgRaised,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        side: BorderSide(color: PbColors.border),
      ),
      margin: EdgeInsets.symmetric(vertical: 4),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: PbColors.accent,
        foregroundColor: PbColors.onAccent,
        shape: buttonShape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: PbColors.text,
        backgroundColor: PbColors.bgRaised,
        side: const BorderSide(color: PbColors.border),
        shape: buttonShape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: PbColors.accent, shape: buttonShape),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: PbColors.bgRaised,
      hintStyle: TextStyle(color: PbColors.textDim),
      labelStyle: TextStyle(color: PbColors.textDim),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
        borderSide: BorderSide(color: PbColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
        borderSide: BorderSide(color: PbColors.accent),
      ),
    ),
    dividerTheme: const DividerThemeData(color: PbColors.border, thickness: 1),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: PbColors.accent,
      linearTrackColor: PbColors.border,
      circularTrackColor: PbColors.border,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: PbColors.bgRaised,
      contentTextStyle: TextStyle(color: PbColors.text),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        side: BorderSide(color: PbColors.border),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: PbColors.bgRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: PbColors.bgRaised,
      indicatorColor: PbColors.accent.withValues(alpha: 0.22),
      iconTheme: WidgetStatePropertyAll(const IconThemeData(color: PbColors.text)),
      labelTextStyle: WidgetStatePropertyAll(
        const TextStyle(color: PbColors.textDim, fontSize: 12),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: PbColors.bgRaised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
    ),
  );
}
