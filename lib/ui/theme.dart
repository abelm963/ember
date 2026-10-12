import 'package:flutter/material.dart';

/// Ember's colours, matching the design canvas.
class C {
  static const bg = Color(0xFF0A0A0B);
  static const surface = Color(0xFF141416);
  static const surface2 = Color(0xFF1E1E22);
  static const surface3 = Color(0xFF2A2A2F);
  static const text = Color(0xFFF4F1EC);
  static const soft = Color(0xFFD9D4CC);
  static const muted = Color(0xFFB9B4AC);
  static const faint = Color(0xFF8E8982);
  static const accent = Color(0xFFFF7A2F);
  static const accentInk = Color(0xFF1A0E05);
  static const accentDark = Color(0xFF2A1A10);
  static const good = Color(0xFF7BD88F);
  static const warn = Color(0xFFF2D27A);
  static const bad = Color(0xFFF0A0A0);
  static const blue = Color(0xFF9CC3F0);
}

TextStyle display(double size, {Color color = C.text, FontWeight weight = FontWeight.w800, double? height}) =>
    TextStyle(
      fontFamily: 'Bricolage Grotesque',
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height ?? 0.95,
      letterSpacing: -size * 0.025,
    );

TextStyle body(double size, {Color color = C.text, FontWeight weight = FontWeight.w500, double? height}) =>
    TextStyle(fontFamily: 'Figtree', fontSize: size, fontWeight: weight, color: color, height: height);

ThemeData emberTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: C.bg,
    colorScheme: base.colorScheme.copyWith(primary: C.accent, secondary: C.accent, surface: C.surface),
    textTheme: base.textTheme.apply(fontFamily: 'Figtree', bodyColor: C.text, displayColor: C.text),
    focusColor: Colors.transparent,
    hoverColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    textSelectionTheme: const TextSelectionThemeData(cursorColor: C.accent, selectionColor: Color(0x55FF7A2F)),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: C.accent),
  );
}
