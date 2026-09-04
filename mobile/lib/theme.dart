import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// "Brief" theme tokens - keep in sync with THEME.md and web/src/index.css.
/// Ink on paper, one accent, hairlines instead of fills.
abstract class PbColors {
  static const paper = Color(0xFFFFFFFF);
  static const surface = Color(0xFFF5F6F7);
  static const surface2 = Color(0xFFECEEF1);
  static const ink = Color(0xFF101418);
  static const ink2 = Color(0xFF2B3239);
  static const muted = Color(0xFF4B535C);
  static const faint = Color(0xFF7B848E);
  static const line = Color(0xFFE3E6EA);
  static const line2 = Color(0xFFB9C0C8);
  static const accent = Color(0xFFFF4A1C);

  // aliases kept for existing widgets
  static const bg = paper;
  static const bgRaised = surface;
  static const border = line;
  static const text = ink;
  static const textDim = faint;
  static const danger = accent;
  static const onAccent = paper;
}

/// Mono metadata style: uppercase + tracked (eyebrows, tags, nav labels).
TextStyle pbMono({double size = 11, Color color = PbColors.faint, FontWeight weight = FontWeight.w500}) =>
    GoogleFonts.dmMono(fontSize: size, color: color, fontWeight: weight, letterSpacing: size * 0.14);

TextStyle pbDisplay({double size = 28, Color color = PbColors.ink, FontWeight weight = FontWeight.w700}) =>
    GoogleFonts.bricolageGrotesque(fontSize: size, color: color, fontWeight: weight, letterSpacing: -size * 0.02, height: 1.05);

ThemeData photobankTheme() {
  const scheme = ColorScheme.light(
    surface: PbColors.paper,
    surfaceContainer: PbColors.surface,
    surfaceContainerHighest: PbColors.surface2,
    primary: PbColors.ink,
    onPrimary: PbColors.paper,
    secondary: PbColors.ink2,
    onSecondary: PbColors.paper,
    error: PbColors.accent,
    onSurface: PbColors.ink,
    onSurfaceVariant: PbColors.faint,
    outline: PbColors.line2,
    outlineVariant: PbColors.line,
  );

  const shape = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(6)));
  final sans = GoogleFonts.instrumentSansTextTheme();
  final text = sans.copyWith(
    headlineMedium: pbDisplay(size: 30),
    headlineSmall: pbDisplay(size: 24),
    titleLarge: pbDisplay(size: 22, weight: FontWeight.w600),
    titleMedium: pbDisplay(size: 18, weight: FontWeight.w600),
    titleSmall: pbMono(size: 11),
    bodyLarge: GoogleFonts.instrumentSans(fontSize: 16, color: PbColors.ink, height: 1.45),
    bodyMedium: GoogleFonts.instrumentSans(fontSize: 15, color: PbColors.muted, height: 1.45),
    bodySmall: GoogleFonts.instrumentSans(fontSize: 13, color: PbColors.faint, height: 1.4),
    labelLarge: GoogleFonts.instrumentSans(fontSize: 14, fontWeight: FontWeight.w500),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: PbColors.paper,
    textTheme: text,
    dividerColor: PbColors.line,
    appBarTheme: AppBarTheme(
      backgroundColor: PbColors.paper,
      foregroundColor: PbColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: const Border(bottom: BorderSide(color: PbColors.line)),
      titleTextStyle: pbDisplay(size: 22),
    ),
    cardTheme: const CardThemeData(
      color: PbColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
        side: BorderSide(color: PbColors.line),
      ),
      margin: EdgeInsets.symmetric(vertical: 4),
    ),
    // primary = paper on ink; never an accent fill
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: PbColors.ink,
        foregroundColor: PbColors.paper,
        shape: shape,
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: PbColors.ink,
        backgroundColor: PbColors.paper,
        side: const BorderSide(color: PbColors.line2),
        shape: shape,
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: PbColors.ink, shape: shape, textStyle: text.labelLarge),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: PbColors.ink,
        selectedForegroundColor: PbColors.paper,
        foregroundColor: PbColors.ink,
        side: const BorderSide(color: PbColors.line2),
        shape: shape,
        textStyle: pbMono(size: 10, color: PbColors.ink),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: PbColors.surface,
      selectedColor: PbColors.ink,
      side: const BorderSide(color: PbColors.line),
      shape: shape,
      labelStyle: pbMono(size: 10, color: PbColors.ink),
      secondaryLabelStyle: pbMono(size: 10, color: PbColors.paper),
      checkmarkColor: PbColors.paper,
      showCheckmark: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: PbColors.surface,
      hintStyle: GoogleFonts.instrumentSans(color: PbColors.faint),
      labelStyle: pbMono(size: 10),
      enabledBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
        borderSide: BorderSide(color: PbColors.line),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
        borderSide: BorderSide(color: PbColors.ink),
      ),
    ),
    dividerTheme: const DividerThemeData(color: PbColors.line, thickness: 1),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: PbColors.ink,
      linearTrackColor: PbColors.line,
      circularTrackColor: PbColors.line,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? PbColors.paper : PbColors.faint),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? PbColors.ink : PbColors.surface2),
      trackOutlineColor: const WidgetStatePropertyAll(PbColors.line2),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: PbColors.ink,
      contentTextStyle: GoogleFonts.instrumentSans(color: PbColors.paper),
      shape: shape,
      behavior: SnackBarBehavior.floating,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: PbColors.paper,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(6))),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: PbColors.paper,
      indicatorColor: PbColors.surface2,
      indicatorShape: shape,
      elevation: 0,
      iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? PbColors.ink : PbColors.faint, size: 22)),
      labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => pbMono(size: 9, color: s.contains(WidgetState.selected) ? PbColors.ink : PbColors.faint)),
    ),
    // menus: paper, hairline, 6px - not Material's tinted, oversized card
    popupMenuTheme: PopupMenuThemeData(
      color: PbColors.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 3,
      shadowColor: const Color(0x22000000),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
        side: BorderSide(color: PbColors.line),
      ),
      textStyle: GoogleFonts.instrumentSans(fontSize: 15, color: PbColors.ink),
      labelTextStyle: WidgetStatePropertyAll(GoogleFonts.instrumentSans(fontSize: 15, color: PbColors.ink)),
      iconColor: PbColors.ink,
      iconSize: 22,
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(PbColors.paper),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(6)),
          side: BorderSide(color: PbColors.line),
        )),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: PbColors.paper,
      shape: shape,
      titleTextStyle: pbDisplay(size: 22),
      contentTextStyle: GoogleFonts.instrumentSans(fontSize: 15, color: PbColors.muted, height: 1.45),
    ),
    listTileTheme: ListTileThemeData(
      titleTextStyle: GoogleFonts.instrumentSans(fontSize: 15, color: PbColors.ink, fontWeight: FontWeight.w500),
      subtitleTextStyle: GoogleFonts.instrumentSans(fontSize: 13, color: PbColors.faint),
      iconColor: PbColors.ink,
    ),
  );
}
