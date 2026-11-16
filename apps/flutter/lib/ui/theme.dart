import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: Brand.forest,
    primary: Brand.forest,
    secondary: Brand.lime,
    surface: Colors.white,
    error: Brand.danger,
  );
  const radius = BorderRadius.all(Radius.circular(10));
  return ThemeData(
    useMaterial3: true,
    // The web uses the bundled font so pages never wait on a font download.
    fontFamily: kIsWeb ? 'CartunezSans' : null,
    colorScheme: scheme,
    scaffoldBackgroundColor: Brand.canvas,
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,
    textTheme: const TextTheme(
      headlineMedium: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.8, color: Brand.ink),
      titleLarge: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.3, color: Brand.ink),
      titleMedium: TextStyle(fontWeight: FontWeight.w700, color: Brand.ink),
      bodyMedium: TextStyle(color: Brand.ink),
      bodySmall: TextStyle(color: Brand.muted),
    ),
    cardTheme: const CardThemeData(
      elevation: 0,
      color: Colors.white,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(14)), side: BorderSide(color: Brand.line)),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: Color(0xFFF8FAF9),
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: Brand.line)),
      enabledBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: Brand.line)),
      focusedBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: Brand.forest, width: 1.6)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 46),
        shape: const RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 42),
        foregroundColor: Brand.ink,
        side: const BorderSide(color: Brand.line),
        shape: const RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(18))),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Color(0xFF23533D),
      width: 460,
    ),
    dividerTheme: const DividerThemeData(color: Brand.line, space: 1),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}
