import 'dart:convert';

import '../../observability.dart' show GlintConfig, looseBool, looseInt, looseNum;

/// First enum value whose [Enum.name] equals [name], or null. Replaces the
/// `X.values.where((e) => e.name == n).firstOrNull` idiom repeated across tools.
T? enumByName<T extends Enum>(List<T> values, String? name) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
}

/// A tool argument whose value cannot be read as the type its schema declares.
class ArgTypeError implements Exception {
  ArgTypeError(this.key, this.expected, this.value);
  final String key;
  final String expected;
  final Object? value;
  @override
  String toString() => '$key must be $expected, got ${jsonEncode(value)}';
}

/// [key] as an int: an int, a whole double or a numeric string; null when absent, [ArgTypeError] when unreadable.
int? argInt(Map<String, Object?>? args, String key) =>
    _arg(args, key, looseInt, 'a whole number');

/// [key] as a number (num or numeric string); null when absent, [ArgTypeError] when unreadable.
double? argNum(Map<String, Object?>? args, String key) =>
    _arg(args, key, looseNum, 'a number');

/// [key] as a bool (bool or "true"/"false"); null when absent, [ArgTypeError] when unreadable.
bool? argBool(Map<String, Object?>? args, String key) =>
    _arg(args, key, looseBool, 'true or false');

T? _arg<T>(Map<String, Object?>? args, String key, T? Function(Object?) parse,
    String expected) {
  final raw = args?[key];
  if (raw == null) return null;
  return parse(raw) ?? (throw ArgTypeError(key, expected, raw));
}

/// The arming + return-shape args shared by the targeted gesture tools.
typedef TargetedArgs = ({
  bool awaitReady,
  int readyTimeoutMs,
  bool returnScene,
  bool fetchScene,
  bool detail,
});

TargetedArgs readTargetedArgs(Map<String, Object?> args, GlintConfig config) => (
      awaitReady: argBool(args, 'awaitReady') ?? false,
      readyTimeoutMs: argInt(args, 'readyTimeoutMs') ?? config.readyTimeoutMs,
      returnScene: argBool(args, 'returnScene') ?? true,
      fetchScene: argBool(args, 'fetchScene') ?? false,
      detail: argBool(args, 'detail') ?? false,
    );

/// A single x,y point (logical points / screenshot pixels), or null when either
/// coordinate is absent — the coordinate branch of tap / long_press.
({double x, double y})? readPoint(Map<String, Object?> args) {
  final x = argNum(args, 'x')?.toDouble();
  final y = argNum(args, 'y')?.toDouble();
  return (x != null && y != null) ? (x: x, y: y) : null;
}

/// A from→to segment (x1,y1 → x2,y2), or null when any is absent — the
/// coordinate branch of swipe / drag.
({double x1, double y1, double x2, double y2})? readSegment(
    Map<String, Object?> args) {
  final x1 = argNum(args, 'x1')?.toDouble();
  final y1 = argNum(args, 'y1')?.toDouble();
  final x2 = argNum(args, 'x2')?.toDouble();
  final y2 = argNum(args, 'y2')?.toDouble();
  return (x1 != null && y1 != null && x2 != null && y2 != null)
      ? (x1: x1, y1: y1, x2: x2, y2: y2)
      : null;
}
