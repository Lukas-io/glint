import 'package:flutter/material.dart';

/// The one colour that drives the app.
const blue = Color(0xFF1A4BFF);
const ink = Color(0xFF111318);
const grey = Color(0xFF5C5F66);
const soft = Color(0xFFF1F2F5);
const line = Color(0xFFE2E4EA);
const handle = Color(0xFFD5D7DD);

/// Instrument Sans is a variable font, so weight is set as a variation too.
TextStyle t(double size, {FontWeight w = FontWeight.w400, Color c = ink, double? h, double ls = 0}) => TextStyle(
  fontFamily: 'InstrumentSans',
  fontSize: size,
  fontWeight: w,
  fontVariations: [FontVariation('wght', w.value.toDouble().clamp(400, 700))],
  color: c,
  height: h == null ? null : h / size,
  letterSpacing: ls,
  fontFeatures: const [FontFeature.tabularFigures()],
);

ThemeData appTheme() => ThemeData(
  useMaterial3: true,
  fontFamily: 'InstrumentSans',
  colorScheme: ColorScheme.fromSeed(seedColor: blue, primary: blue, surface: Colors.white),
  scaffoldBackgroundColor: const Color(0xFFEEEFF1),
  splashFactory: InkSparkle.splashFactory,
);

const floatShadow = [BoxShadow(color: Color(0x2E111318), blurRadius: 40, offset: Offset(0, 10))];
const chipShadow = [BoxShadow(color: Color(0x24111318), blurRadius: 10, offset: Offset(0, 2))];
