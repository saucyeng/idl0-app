import 'package:flutter/material.dart';

import 'brand/brand.dart';
import 'shell/adaptive_shell.dart';

/// Root application widget. Owns the [MaterialApp] and top-level theme.
///
/// Theme follows the quiet field manual brand system — dark scaffold, IBM
/// Plex Mono throughout (display, body, labels), hairline borders, 7 px soft
/// radius on interactive controls (2 px on structural surfaces), tabular
/// numerals on by default.
///
/// Navigation and tab layout are delegated to [AdaptiveShell].
class IDL0App extends StatelessWidget {
  /// Creates [IDL0App].
  const IDL0App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IDL0',
      theme: _buildFieldManualTheme(),
      // SafeArea bottom: false — AdaptiveScaffold's NavigationBar already
      // handles the bottom inset; top: true pads below the status bar on
      // Android 15+ edge-to-edge.
      home: const SafeArea(bottom: false, child: AdaptiveShell()),
    );
  }
}

ThemeData _buildFieldManualTheme() {
  // Default body and label styles — IBM Plex Mono, tabular numerals on.
  final body = plexMono(fontSize: 14, color: brandFg);
  final bodySmall = plexMono(fontSize: 12, color: brandFgDim);
  final label = plexMono(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: brandFg,
    letterSpacing: brandLabelTracking,
  );
  final labelSmall = plexMono(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: brandFgDim,
    letterSpacing: brandLabelTracking,
  );

  // Display styles — large Plex Mono. The brand carries identity through
  // mono type + hairline structure, not a separate display face.
  TextStyle display(double size) => plexMono(
        fontSize: size,
        fontWeight: FontWeight.w600,
        color: brandFg,
        height: 1.0,
      );

  final textTheme = TextTheme(
    displayLarge: display(48),
    displayMedium: display(36),
    displaySmall: display(28),
    headlineLarge: display(24),
    headlineMedium: display(20),
    headlineSmall: display(18),
    titleLarge: plexMono(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: brandFg,
      letterSpacing: 0.5,
    ),
    titleMedium: plexMono(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      color: brandFg,
    ),
    titleSmall: plexMono(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: brandFgDim,
      letterSpacing: brandLabelTracking,
    ),
    bodyLarge: body,
    bodyMedium: body,
    bodySmall: bodySmall,
    labelLarge: label,
    labelMedium: label,
    labelSmall: labelSmall,
  );

  const colorScheme = ColorScheme.dark(
    brightness: Brightness.dark,
    primary: brandAccent,
    onPrimary: brandFg,
    secondary: brandHivis,
    onSecondary: brandBg,
    surface: brandSurface,
    onSurface: brandFg,
    surfaceContainerHighest: brandSurface2,
    error: brandAccent,
    onError: brandFg,
    outline: brandRule,
    outlineVariant: brandRule,
  );

  // Interactive controls (buttons, segmented) use the softened 7px radius;
  // structural surfaces (cards, sheets, menus) keep the crisp 2px below.
  const controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(brandControlRadiusSoft)),
  );
  const hairlineSide = BorderSide(
    color: brandRule,
    width: brandHairlineWidth,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: brandBg,
    canvasColor: brandBg,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    fontFamilyFallback: const ['monospace'],
    iconTheme: const IconThemeData(color: brandFg, size: 20),
    dividerTheme: const DividerThemeData(
      color: brandRule,
      thickness: brandHairlineWidth,
      space: 1,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: brandBg,
      foregroundColor: brandFg,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: const Border(bottom: hairlineSide),
      titleTextStyle: plexMono(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: brandFg,
        letterSpacing: brandLabelTracking,
      ),
    ),
    cardTheme: const CardThemeData(
      color: brandSurface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: hairlineSide,
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: brandSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: hairlineSide,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: brandSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: hairlineSide,
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: brandSurface2,
      contentTextStyle: TextStyle(color: brandFg, fontFamily: 'monospace'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: hairlineSide,
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: const BoxDecoration(
        color: brandSurface2,
        border: Border.fromBorderSide(hairlineSide),
      ),
      textStyle: plexMono(fontSize: 11, color: brandFg),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStateProperty.all(controlShape),
        elevation: WidgetStateProperty.all(0),
        backgroundColor: WidgetStateProperty.all(brandAccent),
        foregroundColor: WidgetStateProperty.all(brandFg),
        textStyle: WidgetStateProperty.all(label),
        side: WidgetStateProperty.all(hairlineSide),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStateProperty.all(controlShape),
        side: WidgetStateProperty.all(hairlineSide),
        foregroundColor: WidgetStateProperty.all(brandFg),
        textStyle: WidgetStateProperty.all(label),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStateProperty.all(controlShape),
        foregroundColor: WidgetStateProperty.all(brandFg),
        textStyle: WidgetStateProperty.all(label),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStateProperty.all(controlShape),
        backgroundColor: WidgetStateProperty.all(brandSurface2),
        foregroundColor: WidgetStateProperty.all(brandFg),
        textStyle: WidgetStateProperty.all(label),
        side: WidgetStateProperty.all(hairlineSide),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStateProperty.all(controlShape),
        foregroundColor: WidgetStateProperty.all(brandFg),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStateProperty.all(controlShape),
        side: WidgetStateProperty.all(hairlineSide),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return brandControlActive;
          return brandControlFill;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return brandFg;
          return brandFgDim;
        }),
        textStyle: WidgetStateProperty.all(label),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: brandControlFill,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(brandControlRadiusSoft)),
        borderSide: hairlineSide,
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(brandControlRadiusSoft)),
        borderSide: hairlineSide,
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(brandControlRadiusSoft)),
        borderSide: BorderSide(
          color: brandAccent,
          width: brandHairlineWidth,
        ),
      ),
      labelStyle: labelSmall,
      floatingLabelStyle: plexMono(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: brandAccent,
        letterSpacing: brandLabelTracking,
      ),
      hintStyle: plexMono(fontSize: 13, color: brandFgDim),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: brandFgDim,
      textColor: brandFg,
      tileColor: Colors.transparent,
      titleTextStyle: body,
      subtitleTextStyle: bodySmall,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return brandHivis;
        return brandFgDim;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return brandSurface2;
        return brandSurface2;
      }),
      trackOutlineColor: WidgetStateProperty.all(brandRule),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(brandControlRadius)),
      ),
      side: hairlineSide,
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return brandAccent;
        return Colors.transparent;
      }),
      checkColor: WidgetStateProperty.all(brandFg),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return brandAccent;
        return brandFgDim;
      }),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: brandControlFill,
      selectedColor: brandControlActive,
      side: hairlineSide,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(brandControlRadiusSoft)),
      ),
      labelStyle: label,
      secondaryLabelStyle: label,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: brandAccent,
      linearTrackColor: brandRule,
      circularTrackColor: brandRule,
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: brandAccent,
      inactiveTrackColor: brandRule,
      thumbColor: brandFg,
      overlayColor: Color(0x33E63946),
      trackHeight: 2,
    ),
    tabBarTheme: TabBarThemeData(
      labelStyle: label,
      unselectedLabelStyle: labelSmall,
      labelColor: brandFg,
      unselectedLabelColor: brandFgDim,
      indicator: const UnderlineTabIndicator(
        borderSide: BorderSide(color: brandAccent, width: 2),
      ),
      dividerColor: brandRule,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: brandBg,
      elevation: 0,
      indicatorColor: brandSurface2,
      indicatorShape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(brandControlRadius)),
        side: BorderSide(color: brandHivis, width: brandHairlineWidth),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        return plexMono(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: states.contains(WidgetState.selected) ? brandFg : brandFgDim,
          letterSpacing: brandLabelTracking,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        return IconThemeData(
          size: 20,
          color: states.contains(WidgetState.selected) ? brandFg : brandFgDim,
        );
      }),
      surfaceTintColor: brandBg,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: brandBg,
      indicatorColor: brandSurface2,
      indicatorShape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(brandControlRadius)),
        side: BorderSide(color: brandHivis, width: brandHairlineWidth),
      ),
      selectedLabelTextStyle: plexMono(
        fontSize: 10,
        fontWeight: FontWeight.w500,
        color: brandFg,
        letterSpacing: brandLabelTracking,
      ),
      unselectedLabelTextStyle: plexMono(
        fontSize: 10,
        fontWeight: FontWeight.w500,
        color: brandFgDim,
        letterSpacing: brandLabelTracking,
      ),
      selectedIconTheme: const IconThemeData(color: brandFg, size: 20),
      unselectedIconTheme: const IconThemeData(color: brandFgDim, size: 20),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: brandSurface,
      elevation: 0,
      textStyle: body,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: hairlineSide,
      ),
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(brandSurface),
        elevation: WidgetStatePropertyAll(0),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
            side: hairlineSide,
          ),
        ),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: body,
      menuStyle: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(brandSurface),
        elevation: WidgetStatePropertyAll(0),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
            side: hairlineSide,
          ),
        ),
      ),
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      iconColor: brandFgDim,
      collapsedIconColor: brandFgDim,
      textColor: brandFg,
      collapsedTextColor: brandFgDim,
      shape: Border(),
      collapsedShape: Border(),
    ),
  );
}
