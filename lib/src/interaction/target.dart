sealed class Target {
  const Target();
}

class SymbolicTarget extends Target {
  const SymbolicTarget(this.glintId);
  final String glintId;

  @override
  String toString() => glintId;
}

/// Physical-pixel point on the device. Escape hatch when the target
/// isn't in the render tree (custom canvas, native overlay) — also
/// used internally by direction-based scroll tools.
class CoordinateTarget extends Target {
  const CoordinateTarget({required this.x, required this.y});
  final double x;
  final double y;

  @override
  String toString() => '($x, $y)';
}
