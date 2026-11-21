import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'prefs.dart';

class Brand {
  static const forest = Color(0xFF117755);
  static const forestDark = Color(0xFF0C6146);
  static const lime = Color(0xFFC4EC78);
  static const ink = Color(0xFF192621);
  static const muted = Color(0xFF58675F);
  static const canvas = Color(0xFFF5F7F6);
  static const line = Color(0xFFDFE7E2);
  static const mint = Color(0xFFEAF5ED);
  static const sidebar = Color(0xFF14221F);
  static const danger = Color(0xFF9A3A26);
  static const warning = Color(0xFF855A07);
}

/// The palette that changes between light, dark and high-contrast light.
class _Palette {
  const _Palette({
    required this.brightness,
    required this.primary,
    required this.ink,
    required this.muted,
    required this.canvas,
    required this.surface,
    required this.field,
    required this.line,
    required this.focus,
    required this.lineWidth,
    required this.snack,
  });
  final Brightness brightness;
  final Color primary;
  final Color ink;
  final Color muted;
  final Color canvas;
  final Color surface;
  final Color field;
  final Color line;
  final Color focus;
  final double lineWidth;
  final Color snack;
}

const _light = _Palette(
  brightness: Brightness.light,
  primary: Brand.forest,
  ink: Brand.ink,
  muted: Brand.muted,
  canvas: Brand.canvas,
  surface: Colors.white,
  field: Color(0xFFF8FAF9),
  line: Brand.line,
  focus: Brand.forest,
  lineWidth: 1,
  snack: Color(0xFF23533D),
);

const _dark = _Palette(
  brightness: Brightness.dark,
  primary: Color(0xFF5FC79E),
  ink: Color(0xFFE6EEE9),
  muted: Color(0xFFA7B6AC),
  canvas: Color(0xFF0F1A17),
  surface: Color(0xFF17241F),
  field: Color(0xFF1D2C26),
  line: Color(0xFF2E4038),
  focus: Brand.lime,
  lineWidth: 1,
  snack: Color(0xFF2A3D32),
);

/// High-contrast light: pure white surfaces, near-black text and heavy borders
/// for bright shop floors and low-vision staff.
const _highContrast = _Palette(
  brightness: Brightness.light,
  primary: Color(0xFF00402B),
  ink: Colors.black,
  muted: Color(0xFF1F2A25),
  canvas: Colors.white,
  surface: Colors.white,
  field: Colors.white,
  line: Color(0xFF1A1A1A),
  focus: Color(0xFF0050C8),
  lineWidth: 1.6,
  snack: Colors.black,
);

ThemeData buildTheme([Appearance appearance = Appearance.light]) {
  final p = switch (appearance) {
    Appearance.light => _light,
    Appearance.dark => _dark,
    Appearance.highContrast => _highContrast,
  };
  final scheme = ColorScheme.fromSeed(
    seedColor: Brand.forest,
    brightness: p.brightness,
    primary: p.primary,
    onPrimary: p.brightness == Brightness.dark ? Colors.black : Colors.white,
    secondary: Brand.lime,
    surface: p.surface,
    onSurface: p.ink,
    onSurfaceVariant: p.muted,
    outline: p.line,
    outlineVariant: p.line,
    error: appearance == Appearance.dark ? const Color(0xFFFF9C85) : Brand.danger,
    contrastLevel: appearance == Appearance.highContrast ? 1 : 0,
  );
  const radius = BorderRadius.all(Radius.circular(10));
  final side = BorderSide(color: p.line, width: p.lineWidth);
  // High contrast: disabled buttons stay readable (dark grey text on light
  // grey) instead of Material's 38% grey on 12% grey.
  final hc = appearance == Appearance.highContrast;
  const hcDisabledText = Color(0xFF3D3D3D);
  const hcDisabledFill = Color(0xFFDADADA);
  return ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    // The web uses the bundled font so pages never wait on a font download.
    fontFamily: kIsWeb ? 'CartunezSans' : null,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.canvas,
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,
    textTheme: TextTheme(
      headlineMedium: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.8, color: p.ink),
      titleLarge: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.3, color: p.ink),
      titleMedium: TextStyle(fontWeight: FontWeight.w700, color: p.ink),
      bodyMedium: TextStyle(color: p.ink),
      bodySmall: TextStyle(color: p.muted, fontWeight: appearance == Appearance.highContrast ? FontWeight.w500 : null),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: p.surface,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: const BorderRadius.all(Radius.circular(14)), side: side),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.field,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      border: OutlineInputBorder(borderRadius: radius, borderSide: side),
      enabledBorder: OutlineInputBorder(borderRadius: radius, borderSide: side),
      focusedBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: p.focus, width: p.lineWidth + 1)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 46),
        shape: const RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
        disabledBackgroundColor: hc ? hcDisabledFill : null,
        disabledForegroundColor: hc ? hcDisabledText : null,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 42),
        foregroundColor: p.ink,
        disabledForegroundColor: hc ? hcDisabledText : null,
        disabledBackgroundColor: hc ? const Color(0xFFEDEDED) : null,
        side: side,
        shape: const RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: hc ? TextButtonThemeData(style: TextButton.styleFrom(disabledForegroundColor: hcDisabledText)) : null,
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(18)),
        side: appearance == Appearance.highContrast ? side : BorderSide.none,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.snack,
      contentTextStyle: const TextStyle(color: Colors.white),
      width: 460,
    ),
    dividerTheme: DividerThemeData(color: p.line, space: 1, thickness: p.lineWidth),
    focusColor: appearance == Appearance.highContrast ? p.focus.withValues(alpha: 0.2) : null,
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}
