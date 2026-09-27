import '../../perception.dart';
import 'action.dart';
import 'backend.dart';
import 'ios_toolchain.dart';
import 'result.dart';
import 'target.dart';

/// Resolves symbolic targets, gates hittable, dispatches to the backend,
/// and wraps everything in an [ActionResult].
class Interactor {
  Interactor({required this.backend, required this.resolver});

  final InteractionBackend backend;
  final CoordinateResolver resolver;

  /// True refuses any non-hittable target, false never refuses; null (default) refuses only when Flutter's real hit test missed.
  bool? refuseNotHittable;

  Future<ActionResult> run(Scene scene, Action action) async {
    try {
      return await _dispatch(scene, action);
    } on IosToolchainBlocked catch (e) {
      return ActionResult.failure(
        action: action,
        summary: 'refused ${action.label}: ${e.detail}',
        error: e.detail,
        errorKind: GlintErrorKind.unsupportedToolchain,
        nextSteps: e.nextSteps,
      );
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
        nextSteps: [
          if (e.underKeyboard)
            'close the on-screen keyboard (hardware_button back on Android, or tap outside the field), then retry'
          else
            'bring it on-screen with '
                'scroll_to_find targetGlintId:"${_glintIdOf(action) ?? "<glintId>"}", '
                'then retry',
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
        nextSteps: e.hitBy != null
            ? [
                'something covers the target: scroll it into view with scroll_to_find targetGlintId:"${_glintIdOf(action) ?? "<glintId>"}", or dismiss what is on top, then retry',
                'pass refuseNotHittable:false to tap anyway',
              ]
            : const [
                'check what\'s on top with get_scene: a modal or absorber probably covers the target',
              ],
      );
    } on GeometryResolveError catch (e) {
      return ActionResult.failure(
        action: action,
        summary: 'resolve failed for ${action.label}',
        error: e.message,
        errorKind: GlintErrorKind.geometryResolveError,
        nextSteps: const [
          'retry once: the app may have been mid-rebuild',
          'if it repeats, call get_scene and target a fresh glintId',
        ],
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
        await backend.typeText(action.text, keyDelayMs: action.keyDelayMs);
        return ActionResult.success(action: action, summary: action.label);

      case PressKey():
        await backend.pressKey(action.key,
            count: action.count, modifiers: action.modifiers);
        return ActionResult.success(action: action, summary: action.label);

      case ClearField():
        await backend.selectAll();
        await backend.pressKey(KeyName.backspace);
        return ActionResult.success(
            action: action, summary: 'select-all + backspace');

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
    final at = '(${c.x.toStringAsFixed(1)}, ${c.y.toStringAsFixed(1)}) logical';
    final String why;
    if (coord.centerUnderKeyboard) {
      why = 'under the on-screen keyboard';
    } else if (!coord.centerInClip) {
      why = 'outside the visible part of its scroll view (clipped)';
    } else {
      why = 'outside the ${coord.logicalViewSize.w.toStringAsFixed(0)}x'
          '${coord.logicalViewSize.h.toStringAsFixed(0)} viewport '
          '(scrolled out or not laid out on-screen)';
    }
    throw OffViewportRefused(
      message: 'refusing action: ${coord.glintId} resolved to $at, $why',
      physicalCenter: coord.physicalCenter,
      devicePixelRatio: coord.devicePixelRatio,
      underKeyboard: coord.centerUnderKeyboard,
    );
  }

  void _gateHittable(ResolvedCoord coord) {
    if (coord.hittable) return;
    if (!(refuseNotHittable ?? coord.hitTestReal)) return;
    throw NotHittableRefused(
      message: coord.hitTestReal
          ? 'refusing action: a tap at the centre of ${coord.glintId} would land on '
              '${coord.hitBy ?? 'another widget'}, not on it'
          : 'refusing action: target is not hittable '
              '(painted=${coord.painted}, hittable=false)',
      physicalCenter: coord.physicalCenter,
      devicePixelRatio: coord.devicePixelRatio,
      painted: coord.painted,
      hitBy: coord.hitBy,
    );
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
    this.underKeyboard = false,
  });
  final String message;
  final ({int x, int y})? physicalCenter;
  final double? devicePixelRatio;
  final bool underKeyboard;
}

class NotHittableRefused implements Exception {
  NotHittableRefused({
    required this.message,
    this.physicalCenter,
    this.devicePixelRatio,
    this.painted,
    this.hitBy,
  });
  final String message;
  final ({int x, int y})? physicalCenter;
  final double? devicePixelRatio;
  final bool? painted;
  final String? hitBy;
}

/// The glintId an action aims at, when it targets one node symbolically.
String? _glintIdOf(Action action) {
  final target = switch (action) {
    Tap(:final target) || LongPress(:final target) || DoubleTap(:final target) =>
      target,
    _ => null,
  };
  return target is SymbolicTarget ? target.glintId : null;
}
