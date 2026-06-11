import '../perception/geometry.dart';
import '../perception/scene_reader.dart';
import 'action.dart';
import 'backend.dart';
import 'result.dart';
import 'target.dart';

/// Orchestrates one action against the device.
///
/// Owns three concerns:
///   1. Resolve every [SymbolicTarget] to physical-pixel coordinates via
///      Module B's [CoordinateResolver] (lazy; never cached).
///   2. Check painted / hittable and surface warnings (the agent decides
///      whether to proceed).
///   3. Hand off to the [InteractionBackend] and wrap the outcome in an
///      [ActionResult].
///
/// The MCP server in P4 calls into this — it's the seam between Module D
/// (instruction layer) and the platform-native input.
class Interactor {
  Interactor({
    required this.backend,
    required this.resolver,
  });

  final InteractionBackend backend;
  final CoordinateResolver resolver;

  /// Whether to refuse actions on non-hittable targets. Default: false —
  /// the agent gets a warning but the action still fires. §3 "agent gets
  /// everything; structured response shows what was found" applies.
  bool refuseNotHittable = false;

  /// Run [action] against [scene]. The [scene] is the current Module B
  /// read — the resolver uses it to map glintIds to inspector handles
  /// and then to live geometry.
  Future<ActionResult> run(Scene scene, Action action) async {
    try {
      return await _dispatch(scene, action);
    } on UnsupportedBackendAction catch (e) {
      return ActionResult(
        action: action,
        ok: false,
        summary: 'backend rejected ${action.label}: ${e.detail}',
        error: e.detail,
        errorClass: 'UnsupportedBackendAction',
      );
    } on BackendToolError catch (e) {
      return ActionResult(
        action: action,
        ok: false,
        summary: '${backend.label} failed ${action.label}',
        error: 'exit=${e.exitCode} ${e.stderr}',
        errorClass: 'BackendToolError',
      );
    } on UnresolvedTarget catch (e) {
      return ActionResult(
        action: action,
        ok: false,
        summary: e.message,
        error: e.message,
        errorClass: 'UnresolvedTarget',
        nextSteps: const [
          'read the scene with get_scene to see current glintIds',
          'use CoordinateTarget if the target genuinely isn\'t in the tree',
        ],
      );
    } on NotHittableRefused catch (e) {
      return ActionResult(
        action: action,
        ok: false,
        summary: e.message,
        error: e.message,
        errorClass: 'NotHittable',
        physicalCenter: e.physicalCenter,
        devicePixelRatio: e.devicePixelRatio,
        painted: e.painted,
        hittable: false,
        nextSteps: const [
          'check what\'s on top with the scene read — a modal or absorber probably covers the target',
        ],
      );
    } on GeometryResolveError catch (e) {
      return ActionResult(
        action: action,
        ok: false,
        summary: 'resolve failed for ${action.label}',
        error: e.message,
        errorClass: 'GeometryResolveError',
      );
    }
  }

  Future<ActionResult> _dispatch(Scene scene, Action action) async {
    switch (action) {
      case Tap():
        final coord = await _resolveOrThrow(scene, action.target);
        _gateHittable(coord);
        await backend.tap(
          physicalX: coord.physicalCenter.x,
          physicalY: coord.physicalCenter.y,
        );
        return _okResult(action, coord,
            verb: 'tapped', extraWarnings: _hittableWarnings(coord));

      case LongPress():
        final coord = await _resolveOrThrow(scene, action.target);
        _gateHittable(coord);
        await backend.longPress(
          physicalX: coord.physicalCenter.x,
          physicalY: coord.physicalCenter.y,
          durationMs: action.durationMs,
        );
        return _okResult(action, coord,
            verb: 'long-pressed', extraWarnings: _hittableWarnings(coord));

      case DoubleTap():
        final coord = await _resolveOrThrow(scene, action.target);
        _gateHittable(coord);
        // Decompose into two taps with the configured gap. Each tap is a
        // single backend call so the backend's timing semantics apply
        // (e.g. iOS HID dwell). The gap is wall-clock here.
        await backend.tap(
          physicalX: coord.physicalCenter.x,
          physicalY: coord.physicalCenter.y,
        );
        await Future<void>.delayed(Duration(milliseconds: action.gapMs));
        await backend.tap(
          physicalX: coord.physicalCenter.x,
          physicalY: coord.physicalCenter.y,
        );
        return _okResult(action, coord,
            verb: 'double-tapped', extraWarnings: _hittableWarnings(coord));

      case Swipe():
        final fromCoord = await _resolveOrThrow(scene, action.from);
        final toCoord = await _resolveOrThrow(scene, action.to);
        await backend.swipe(
          physicalX1: fromCoord.physicalCenter.x,
          physicalY1: fromCoord.physicalCenter.y,
          physicalX2: toCoord.physicalCenter.x,
          physicalY2: toCoord.physicalCenter.y,
          durationMs: action.durationMs,
        );
        return ActionResult(
          action: action,
          ok: true,
          summary: 'swiped (${fromCoord.physicalCenter.x},'
              '${fromCoord.physicalCenter.y}) -> '
              '(${toCoord.physicalCenter.x},${toCoord.physicalCenter.y})',
          physicalCenter: toCoord.physicalCenter,
          devicePixelRatio: toCoord.devicePixelRatio,
          painted: toCoord.painted,
          hittable: toCoord.hittable,
        );

      case TypeText():
        await backend.typeText(action.text);
        return ActionResult(
          action: action,
          ok: true,
          summary: action.label,
        );

      case PressHardwareButton():
        await backend.pressHardwareButton(action.button);
        return ActionResult(
          action: action,
          ok: true,
          summary: action.label,
        );
    }
  }

  Future<ResolvedCoord> _resolveOrThrow(Scene scene, Target t) async {
    switch (t) {
      case SymbolicTarget():
        if (scene.findByGlintId(t.glintId) == null) {
          throw UnresolvedTarget('no node with glintId "${t.glintId}" in scene');
        }
        return resolver.resolve(scene, t.glintId);
      case CoordinateTarget():
        // Coordinate targets bypass Module B. We synthesise a minimal
        // ResolvedCoord so downstream code can treat both target kinds
        // uniformly. painted/hittable are unknown by definition.
        return ResolvedCoord(
          glintId: '<coord>',
          logicalCenter: (x: t.x, y: t.y),
          logicalBounds: (x: 0, y: 0, w: 0, h: 0),
          devicePixelRatio: 1,
          logicalViewSize: (w: 0, h: 0),
          nearestAncestorOpacity: 1,
          nearestAncestorVisible: true,
          hittable: true,
        );
    }
  }

  void _gateHittable(ResolvedCoord coord) {
    if (refuseNotHittable && coord.hittable == false) {
      throw NotHittableRefused(
        message: 'refusing action: target is not hittable '
            '(painted=${coord.painted}, hittable=false)',
        physicalCenter: coord.physicalCenter,
        devicePixelRatio: coord.devicePixelRatio,
        painted: coord.painted,
      );
    }
  }

  List<String> _hittableWarnings(ResolvedCoord coord) {
    final w = <String>[];
    if (coord.painted == false) {
      w.add('target is not painted (zero bounds, off-viewport, '
          'or hidden by ancestor opacity / visibility)');
    }
    if (coord.hittable == false) {
      w.add('target is not hittable — an absorber, overlay, or modal '
          'likely sits above; the OS-level tap landed but the framework '
          'hit test would not route it to your target');
    }
    return w;
  }

  ActionResult _okResult(
    Action action,
    ResolvedCoord coord, {
    required String verb,
    List<String> extraWarnings = const [],
  }) {
    final summary = '$verb ${_targetLabel(action)} at '
        '(${coord.physicalCenter.x}, ${coord.physicalCenter.y}) px';
    return ActionResult(
      action: action,
      ok: true,
      summary: summary,
      physicalCenter: coord.physicalCenter,
      devicePixelRatio: coord.devicePixelRatio,
      painted: coord.painted,
      hittable: coord.hittable,
      warnings: extraWarnings,
    );
  }

  String _targetLabel(Action action) {
    if (action is Tap) return action.target.toString();
    if (action is LongPress) return action.target.toString();
    if (action is DoubleTap) return action.target.toString();
    if (action is Swipe) return '${action.from} -> ${action.to}';
    return action.label;
  }
}

class UnresolvedTarget implements Exception {
  UnresolvedTarget(this.message);
  final String message;
  @override
  String toString() => 'UnresolvedTarget: $message';
}

class NotHittableRefused implements Exception {
  NotHittableRefused({
    required this.message,
    this.physicalCenter,
    this.devicePixelRatio,
    this.painted,
  });
  final String message;
  final ({int x, int y})? physicalCenter;
  final double? devicePixelRatio;
  final bool? painted;
}
