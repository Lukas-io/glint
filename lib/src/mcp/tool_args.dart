import '../../observability.dart' show GlintConfig;

/// First enum value whose [Enum.name] equals [name], or null. Replaces the
/// `X.values.where((e) => e.name == n).firstOrNull` idiom repeated across tools.
T? enumByName<T extends Enum>(List<T> values, String? name) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
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
      awaitReady: (args['awaitReady'] as bool?) ?? false,
      readyTimeoutMs: (args['readyTimeoutMs'] as int?) ?? config.readyTimeoutMs,
      returnScene: (args['returnScene'] as bool?) ?? true,
      fetchScene: (args['fetchScene'] as bool?) ?? false,
      detail: (args['detail'] as bool?) ?? false,
    );

/// A single x,y point (logical points / screenshot pixels), or null when either
/// coordinate is absent — the coordinate branch of tap / long_press.
({double x, double y})? readPoint(Map<String, Object?> args) {
  final x = (args['x'] as num?)?.toDouble();
  final y = (args['y'] as num?)?.toDouble();
  return (x != null && y != null) ? (x: x, y: y) : null;
}

/// A from→to segment (x1,y1 → x2,y2), or null when any is absent — the
/// coordinate branch of swipe / drag.
({double x1, double y1, double x2, double y2})? readSegment(
    Map<String, Object?> args) {
  final x1 = (args['x1'] as num?)?.toDouble();
  final y1 = (args['y1'] as num?)?.toDouble();
  final x2 = (args['x2'] as num?)?.toDouble();
  final y2 = (args['y2'] as num?)?.toDouble();
  return (x1 != null && y1 != null && x2 != null && y2 != null)
      ? (x1: x1, y1: y1, x2: x2, y2: y2)
      : null;
}
