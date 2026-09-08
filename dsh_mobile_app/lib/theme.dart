/// DeepSeek dark/light themes mirroring the web UI's `--dsw-*` design tokens
/// (`packages/client/ui-theme/src/styles/design-platform.css`). The web UI is
/// the visual reference (http://127.0.0.1:3080/ at phone widths); the
/// Material 3 ColorScheme fields below map to those tokens.
library;

import 'package:flutter/material.dart';

/// Static token palette (design-platform.css dark values; `light*` entries
/// carry the light-theme alias values).
abstract final class DswColors {
  static const bluish50 = Color(0xFFF9FAFB);
  static const bluish60 = Color(0xFFF5F6F7);
  static const bluish75 = Color(0xFFF1F3F5);
  static const bluish100 = Color(0xFFEBEEF2);
  static const bluish150 = Color(0xFFE9ECF2);
  static const bluish200 = Color(0xFFE1E5EE);
  static const bluish300 = Color(0xFFCFD3D6);
  static const bluish400 = Color(0xFFADB2B8);
  static const bluish500 = Color(0xFF979DA6);
  static const bluish600 = Color(0xFF81858C);
  static const bluish700 = Color(0xFF61666B);

  static const bluish750 = Color(0xFF43454A);
  static const bluish800 = Color(0xFF353536);
  static const bluish850 = Color(0xFF2C2C2E);
  static const bluish875 = Color(0xFF232324);
  static const bluish900 = Color(0xFF1B1B1C);
  static const bluish950 = Color(0xFF151517);
  static const bluish1000 = Color(0xFF0F1115);

  static const deepseek50 = Color(0xFFEDF3FE);
  static const deepseek100 = Color(0xFFE4EDFD);
  static const deepseek400 = Color(0xFF679EFE);
  static const deepseek500 = Color(0xFF4176E6);
  static const deepseek800 = Color(0xFF34415B);
  static const deepseek900 = Color(0xFF283142);

  static const green500 = Color(0xFF22C55E);
  static const red50 = Color(0xFFFEF2F2);
  static const red100 = Color(0xFFFEE2E2);
  static const red400 = Color(0xFFF25A5A);
  static const red500 = Color(0xFFEF4444);
  static const red600 = Color(0xFFEC1313);
  static const red900 = Color(0xFF570C0C);
  static const amber500 = Color(0xFFF59E0B);

  static const white = Color(0xFFFFFFFF);

  /// Dark-theme borders: 6% / 12% / 16% white.
  static const borderL1 = Color(0x0FFFFFFF);
  static const borderL2 = Color(0x1FFFFFFF);
  static const borderL3 = Color(0x29FFFFFF);

  /// Light-theme borders: 4% / 10% / 12% black (design-platform.css light).
  static const lightBorderL1 = Color(0x0A000000);
  static const lightBorderL2 = Color(0x1A000000);
  static const lightBorderL3 = Color(0x1F000000);
}

/// Resolve a dark/light token pair by the current theme brightness.
/// @param context - the build context whose theme brightness decides.
/// @param dark - the dark-theme color.
/// @param light - the light-theme color.
/// @returns the color matching the ambient brightness.
Color dswColor(BuildContext context, {required Color dark, required Color light}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? dark : light;
}

/// Material 3 dark ColorScheme built from the DeepSeek web tokens.
ColorScheme dswColorScheme() {
  return const ColorScheme.dark(
    primary: DswColors.deepseek400,
    onPrimary: DswColors.bluish1000,
    primaryContainer: DswColors.bluish800,
    onPrimaryContainer: DswColors.bluish50,
    secondary: DswColors.bluish300,
    onSecondary: DswColors.bluish1000,
    secondaryContainer: DswColors.bluish750,
    onSecondaryContainer: DswColors.bluish50,
    tertiary: DswColors.amber500,
    onTertiary: DswColors.bluish1000,
    error: DswColors.red400,
    onError: DswColors.bluish1000,
    errorContainer: DswColors.red900,
    onErrorContainer: DswColors.red100,
    surface: DswColors.bluish950,
    onSurface: DswColors.bluish50,
    surfaceContainerLowest: DswColors.bluish1000,
    surfaceContainerLow: DswColors.bluish900,
    surfaceContainer: DswColors.bluish875,
    surfaceContainerHigh: DswColors.bluish850,
    surfaceContainerHighest: DswColors.bluish800,
    onSurfaceVariant: DswColors.bluish300,
    outline: DswColors.bluish500,
    outlineVariant: DswColors.bluish700,
    shadow: Colors.black,
    scrim: Colors.black,
  );
}

/// Material 3 light ColorScheme built from the web light-theme aliases.
ColorScheme dswLightColorScheme() {
  return const ColorScheme.light(
    primary: DswColors.deepseek500,
    onPrimary: DswColors.white,
    primaryContainer: DswColors.deepseek100,
    onPrimaryContainer: DswColors.deepseek900,
    secondary: DswColors.bluish600,
    onSecondary: DswColors.white,
    secondaryContainer: DswColors.bluish100,
    onSecondaryContainer: DswColors.bluish1000,
    tertiary: DswColors.amber500,
    onTertiary: DswColors.white,
    error: DswColors.red600,
    onError: DswColors.white,
    errorContainer: DswColors.red50,
    onErrorContainer: DswColors.red900,
    surface: DswColors.white,
    onSurface: DswColors.bluish1000,
    surfaceContainerLowest: DswColors.white,
    surfaceContainerLow: DswColors.bluish50,
    surfaceContainer: DswColors.bluish75,
    surfaceContainerHigh: DswColors.bluish100,
    surfaceContainerHighest: DswColors.bluish150,
    onSurfaceVariant: DswColors.bluish750,
    outline: DswColors.bluish500,
    outlineVariant: DswColors.bluish200,
    shadow: Colors.black,
    scrim: Colors.black,
  );
}

/// Build one theme (dark or light) from the shared component styling.
/// @param dark - whether to render the dark theme.
/// @returns the DeepSeek ThemeData for the requested brightness.
ThemeData _buildTheme({required bool dark}) {
  final scheme = dark ? dswColorScheme() : dswLightColorScheme();
  final surface = dark ? DswColors.bluish950 : DswColors.white;
  final primaryText = dark ? DswColors.bluish50 : DswColors.bluish1000;
  final secondaryText = dark ? DswColors.bluish300 : DswColors.bluish700;
  final borderL1 = dark ? DswColors.borderL1 : DswColors.lightBorderL1;
  final borderL2 = dark ? DswColors.borderL2 : DswColors.lightBorderL2;
  final cardColor = dark ? DswColors.bluish875 : DswColors.white;
  final inputFill = dark ? DswColors.bluish850 : DswColors.white;
  final railBg = dark ? DswColors.bluish900 : DswColors.bluish50;
  final railIndicator = dark ? DswColors.bluish800 : DswColors.bluish100;

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: surface,
  );
  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      foregroundColor: primaryText,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: primaryText),
    ),
    dividerTheme: DividerThemeData(
      color: borderL1,
      thickness: 1,
      space: 1,
    ),
    cardTheme: CardThemeData(
      color: cardColor,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: borderL1),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: inputFill,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: borderL2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: borderL2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: DswColors.deepseek400),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: railBg,
      indicatorColor: railIndicator,
      selectedIconTheme: IconThemeData(color: primaryText),
      unselectedIconTheme: IconThemeData(color: secondaryText),
      selectedLabelTextStyle: TextStyle(color: primaryText),
      unselectedLabelTextStyle: TextStyle(color: secondaryText),
    ),
  );
}

/// The app's dark ThemeData: the DeepSeek dark theme, the product identity
/// the web UI ships.
ThemeData dshDarkTheme() => _buildTheme(dark: true);

/// The app's light ThemeData: the DeepSeek light theme, mirroring the web
/// UI's light aliases.
ThemeData dshLightTheme() => _buildTheme(dark: false);
