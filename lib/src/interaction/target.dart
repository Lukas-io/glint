/// What an [Action] is aimed at.
sealed class Target {
  const Target();
}

/// Names an element by its stable [glintId] from a [Scene].
/// Interactor resolves to live coordinates at action time, never cached.
class SymbolicTarget extends Target {
  const SymbolicTarget(this.glintId);
  final String glintId;

  @override
  String toString() => 'SymbolicTarget($glintId)';
}

/// Raw logical-pixel point on the device. Escape hatch when the target
/// genuinely isn't in the render tree (custom canvas, native overlay).
class CoordinateTarget extends Target {
  const CoordinateTarget({required this.x, required this.y});
  final double x;
  final double y;

  @override
  String toString() => 'CoordinateTarget($x, $y)';
}
