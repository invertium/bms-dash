import 'package:flutter/material.dart';

/// Dashboard palette: pink/purple accents on deep navy. The four accent
/// colors are validated for contrast and color-vision-deficiency separation
/// against [card].
abstract final class BmsColors {
  static const Color background = Color(0xFF1C1B2E);
  static const Color card = Color(0xFF2A2942);
  static const Color cardInner = Color(0xFF343357);
  static const Color hairline = Color(0xFF3D3C5E);

  static const Color pink = Color(0xFFF1437E);
  static const Color purple = Color(0xFF8B5CF6);
  static const Color good = Color(0xFF1F9D5F);
  static const Color warning = Color(0xFFD97706);

  static const Color textPrimary = Color(0xFFF2F1FA);
  static const Color textSecondary = Color(0xFFA9A7C7);
  static const Color textMuted = Color(0xFF6F6D91);

  /// Unfilled gauge track: a dim step of the purple ramp so the meter reads
  /// as one piece.
  static const Color gaugeTrack = Color(0xFF3A3763);

  static const Gradient accent = LinearGradient(
    colors: [pink, purple],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );
}

/// Shared rounded-card look for the dashboard panels.
BoxDecoration bmsCardDecoration({Color color = BmsColors.card}) {
  return BoxDecoration(
    color: color,
    borderRadius: BorderRadius.circular(20),
    border: Border.all(color: BmsColors.hairline),
  );
}

ThemeData buildBmsTheme() {
  const scheme = ColorScheme.dark(
    primary: BmsColors.pink,
    onPrimary: Colors.white,
    secondary: BmsColors.purple,
    onSecondary: Colors.white,
    surface: BmsColors.background,
    onSurface: BmsColors.textPrimary,
    surfaceContainerHighest: BmsColors.cardInner,
    outlineVariant: BmsColors.hairline,
    error: BmsColors.warning,
  );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: BmsColors.background,
    appBarTheme: const AppBarTheme(
      backgroundColor: BmsColors.background,
      foregroundColor: BmsColors.textPrimary,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: BmsColors.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : BmsColors.textMuted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? BmsColors.pink
            : BmsColors.gaugeTrack,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    listTileTheme: const ListTileThemeData(
      textColor: BmsColors.textPrimary,
      iconColor: BmsColors.textSecondary,
    ),
    dividerTheme: const DividerThemeData(
      color: BmsColors.hairline,
      thickness: 1,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: BmsColors.pink,
      linearTrackColor: BmsColors.gaugeTrack,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: BmsColors.card,
      indicatorColor: BmsColors.pink.withValues(alpha: 0.2),
      surfaceTintColor: Colors.transparent,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? BmsColors.pink
              : BmsColors.textSecondary,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: states.contains(WidgetState.selected)
              ? BmsColors.textPrimary
              : BmsColors.textSecondary,
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: BmsColors.cardInner,
      selectedColor: BmsColors.pink,
      checkmarkColor: Colors.white,
      labelStyle: const TextStyle(
        color: BmsColors.textSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      secondaryLabelStyle: const TextStyle(
        color: Colors.white,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
  );
}
