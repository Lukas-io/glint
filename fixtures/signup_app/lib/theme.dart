import 'package:flutter/material.dart';

const ink = Color(0xFF17120F);
const surface = Color(0xFF241C18);
const surfaceHigh = Color(0xFF30251F);
const ember = Color(0xFFFF6B3D);
const gold = Color(0xFFFFB547);
const cream = Color(0xFFF7EDE4);
const muted = Color(0xFFA89A8E);
const danger = Color(0xFFFF5A6E);

const emberGradient = LinearGradient(colors: [ember, gold]);

ThemeData emberTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: ember,
      brightness: Brightness.dark,
      surface: ink,
      primary: ember,
    ),
    scaffoldBackgroundColor: ink,
    useMaterial3: true,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: cream, displayColor: cream),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      hintStyle: const TextStyle(color: muted),
      labelStyle: const TextStyle(color: muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: ember, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: danger, width: 1.5),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: surfaceHigh,
      contentTextStyle: TextStyle(color: cream, fontSize: 15),
    ),
  );
}
