import '../../perception.dart';
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

  /// When true, non-hittable targets fail with [GlintErrorKind.notHittable] instead of warning. Default permissive (§3): agent decides.
  bool refuseNotHittable = false;

  Future<ActionResult> run(Scene scene, Action action) async {
    try {
      return await _dispatch(scene, action);
    } on UnsupportedBackendAction catch (e) {
      return ActionResult.failure(
        action: action,
        summary: 'backend rejected ${action.label}: ${e.detail}',
        error: e.detail,
        errorKind: GlintErrorKind.unsupportedBackendAction,
      );
    } on BackendToolError catch (e) {
      return ActionResult.failure(
        action: action,
        summary: '${backend.label} failed ${action.label}',
        error: 'exit=${e.exitCode} ${e.stderr}',
        errorKind: GlintErrorKind.backendToolError,
      );
    } on UnresolvedTarget catch (e) {
      return ActionResult.failure(
        action: action,
        summary: e.message,
        error: e.message,
        errorKind: GlintErrorKind.unresolvedTarget,
        nextSteps: const [
          'read the scene with get_scene to see current glintIds',
          'use CoordinateTarget if the target genuinely isn\'t in the tree',
        ],
      );
    } on OffViewportRefused catch (e) {
      return ActionResult.failure(
        action: action,
        summary: e.message,
        error: e.message,
        errorKind: GlintErrorKind.offViewport,
        physicalCenter: e.physicalCenter,
        devicePixelRatio: e.devicePixelRatio,
        painted: false,
        hittable: false,
        nextSteps: const [
          'the target is scrolled out of the viewport — use scroll_to_find '
              'with its glintId to bring it on-screen first',
        ],
      );
    } on NotHittableRefused catch (e) {
      return ActionResult.failure(
        action: action,
        summary: e.message,
        error: e.message,
        errorKind: GlintErrorKind.notHittable,
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
        errorKind: GlintErrorKind.geometryResolveError,
      );
    }
  }

  Future<ActionResult> _dispatch(Scene scene, Action action) async {
    switch (action) {
      case Tap():
        final c = await _resolveOrThrow(scene, action.target);
        _gateOnScreen(c);
        _gateHittable(c);
        await backend.tap(physicalX: c.physicalCenter.x, physicalY: c.physicalCenter.y);
        return _coordinateResult(action, c, verb: 'tapped');

      case LongPress():
        final c = await _resolveOrThrow(scene, action.target);
        _gateOnScreen(c);
        _gateHittable(c);
        await backend.longPress(
          physicalX: c.physicalCenter.x,
          physicalY: c.physicalCenter.y,
          durationMs: action.durationMs,
        );
        return _coordinateResult(action, c, verb: 'long-pressed');

      case DoubleTap():
        final c = await _resolveOrThrow(scene, action.target);
        _gateOnScreen(c);
        _gateHittable(c);
        await backend.tap(physicalX: c.physicalCenter.x, physicalY: c.physicalCenter.y);
        await Future<void>.delayed(Duration(milliseconds: action.gapMs));
        await backend.tap(physicalX: c.physicalCenter.x, physicalY: c.physicalCenter.y);
        return _coordinateResult(action, c, verb: 'double-tapped');

      case Swipe():
        final from = await _resolveOrThrow(scene, action.from);
        final to = await _resolveOrThrow(scene, action.to);
        // Only the from endpoint must be on-screen: the finger starts there.
        // A to endpoint past the edge is a legitimate long fling.
        _gateOnScreen(from);
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

  /// A symbolic target whose resolved center is outside the viewport can never
  /// receive the gesture — firing would tap a void or system UI. Coordinate
  /// targets skip this (caller owns raw coords; their sentinel viewport is 0×0).
  void _gateOnScreen(ResolvedCoord coord) {
    if (coord.glintId == '<coord>') return;
    if (coord.logicalViewSize.w <= 0 || coord.logicalViewSize.h <= 0) return;
    if (coord.centerOnViewport) return;
    final c = coord.logicalCenter;
    throw OffViewportRefused(
      message: 'refusing action: ${coord.glintId} resolved to '
          '(${c.x.toStringAsFixed(1)}, ${c.y.toStringAsFixed(1)}) logical — '
          'outside the ${coord.logicalViewSize.w.toStringAsFixed(0)}x'
          '${coord.logicalViewSize.h.toStringAsFixed(0)} viewport '
          '(scrolled out or not laid out on-screen)',
      physicalCenter: coord.physicalCenter,
      devicePixelRatio: coord.devicePixelRatio,
    );
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

class OffViewportRefused implements Exception {
  OffViewportRefused({
    required this.message,
    this.physicalCenter,
    this.devicePixelRatio,
  });
  final String message;
  final ({int x, int y})? physicalCenter;
  final double? devicePixelRatio;
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
