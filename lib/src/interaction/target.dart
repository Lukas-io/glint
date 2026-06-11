/// What an [Action] is aimed at.
///
/// Two flavours in v1:
///
/// - [SymbolicTarget] — the canonical, agent-facing path. Names an element
///   by its stable [glintId] from a [Scene]. The [Interactor] resolves
///   this to coordinates against the live render tree at action time
///   (§3 lazy resolution; never cached).
///
/// - [CoordinateTarget] — the escape hatch. Raw logical-pixel point on
///   the device. Used when a target genuinely isn't in the render tree
///   (custom-painted canvas, native overlay) or in tests / debugging.
sealed class Target {
  const Target();
}

class SymbolicTarget extends Target {
  const SymbolicTarget(this.glintId);

  /// The stable id from a [Scene] node. See [SceneNode.glintId].
  final String glintId;

  @override
  String toString() => 'SymbolicTarget($glintId)';
}

class CoordinateTarget extends Target {
  const CoordinateTarget({required this.x, required this.y});

  /// Logical device-point x. Same coordinate system the Flutter render
  /// tree speaks (post-DPR-division). Module A's backends are responsible
  /// for converting to whatever their input layer wants.
  final double x;
  final double y;

  @override
  String toString() => 'CoordinateTarget($x, $y)';
}
