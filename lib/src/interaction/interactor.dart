import '../perception/geometry.dart';
import '../perception/scene_reader.dart';
import 'action.dart';
import 'backend.dart';
import 'result.dart';
import 'target.dart';

/// Resolves symbolic targets, gates hittable, dispatches to the backend,
/// and wraps everything in an [ActionResult].
class Interactor {
  Interactor({required this.backend, required this.resolver});

  final InteractionBackend backend;
  final CoordinateResolver resolver;

  /// When true, non-hittable targets cause [ActionFailureKind.notHittable]
  /// instead of a warning. §3 keeps the default permissive: agent decides.
  bool refuseNotHittable = false;

  Future<ActionResult> run(Scene scene, Action action) async {
    try {
      return await _dispatch(scene, action);
    } on UnsupportedBackendAction catch (e) {
      return ActionResult.failure(
        action: action,
        summary: 'backend rejected ${action.label}: ${e.detail}',
        error: e.detail,
        errorKind: ActionFailureKind.unsupportedBackendAction,
      );
    } on BackendToolError catch (e) {
      return ActionResult.failure(
        action: action,
        summary: '${backend.label} failed ${action.label}',
        error: 'exit=${e.exitCode} ${e.stderr}',
        errorKind: ActionFailureKind.backendToolError,
      );
    } on UnresolvedTarget catch (e) {
      return ActionResult.failure(
        action: action,
        summary: e.message,
        error: e.message,
        errorKind: ActionFailureKind.unresolvedTarget,
        nextSteps: const [
          'read the scene with get_scene to see current glintIds',
          'use CoordinateTarget if the target genuinely isn\'t in the tree',
        ],
      );
    } on NotHittableRefused catch (e) {
      return ActionResult.failure(
        action: action,
        summary: e.message,
        error: e.message,
        errorKind: ActionFailureKind.notHittable,
        physicalCenter: e.physicalCenter,
        devicePixelRatio: e.devicePixelRatio,
        painted: e.painted,
        hittable: false,
        nextSteps: const [
          'check what\'s on top with the scene read — a modal or absorber probably covers the target',
        ],
      );
    } on GeometryResolveError catch (e) {
      return ActionResult.failure(
        action: action,
        summary: 'resolve failed for ${action.label}',
        error: e.message,
        errorKind: ActionFailureKind.geometryResolveError,
      );
    }
  }

  Future<ActionResult> _dispatch(Scene scene, Action action) async {
    switch (action) {
      case Tap():
        final c = await _resolveOrThrow(scene, action.target);
        _gateHittable(c);
        await backend.tap(physicalX: c.physicalCenter.x, physicalY: c.physicalCenter.y);
        return _coordinateResult(action, c, verb: 'tapped');

      case LongPress():
        final c = await _resolveOrThrow(scene, action.target);
        _gateHittable(c);
        await backend.longPress(
          physicalX: c.physicalCenter.x,
          physicalY: c.physicalCenter.y,
          durationMs: action.durationMs,
        );
        return _coordinateResult(action, c, verb: 'long-pressed');

      case DoubleTap():
        final c = await _resolveOrThrow(scene, action.target);
        _gateHittable(c);
        await backend.tap(physicalX: c.physicalCenter.x, physicalY: c.physicalCenter.y);
        await Future<void>.delayed(Duration(milliseconds: action.gapMs));
        await backend.tap(physicalX: c.physicalCenter.x, physicalY: c.physicalCenter.y);
        return _coordinateResult(action, c, verb: 'double-tapped');

      case Swipe():
        final from = await _resolveOrThrow(scene, action.from);
        final to = await _resolveOrThrow(scene, action.to);
        await backend.swipe(
          physicalX1: from.physicalCenter.x,
          physicalY1: from.physicalCenter.y,
          physicalX2: to.physicalCenter.x,
          physicalY2: to.physicalCenter.y,
          durationMs: action.durationMs,
        );
        return ActionResult.success(
          action: action,
          summary: 'swiped (${from.physicalCenter.x},${from.physicalCenter.y})'
              ' -> (${to.physicalCenter.x},${to.physicalCenter.y})',
          physicalCenter: to.physicalCenter,
          devicePixelRatio: to.devicePixelRatio,
          painted: to.painted,
          hittable: to.hittable,
        );

      case TypeText():
        await backend.typeText(action.text);
        return ActionResult.success(action: action, summary: action.label);

      case PressHardwareButton():
        await backend.pressHardwareButton(action.button);
        return ActionResult.success(action: action, summary: action.label);
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

  ActionResult _coordinateResult(Action action, ResolvedCoord c,
      {required String verb}) {
    return ActionResult.success(
      action: action,
      summary: '$verb ${action.targetSummary} at '
          '(${c.physicalCenter.x}, ${c.physicalCenter.y}) px',
      physicalCenter: c.physicalCenter,
      devicePixelRatio: c.devicePixelRatio,
      painted: c.painted,
      hittable: c.hittable,
      warnings: c.warnings,
    );
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
