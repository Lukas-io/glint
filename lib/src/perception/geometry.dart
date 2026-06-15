import 'dart:convert';

import '../runtime/flutter_runtime.dart';
import 'scene_node.dart';
import 'scene_reader.dart';

/// One node's live geometry. Global coords in logical pixels.
/// `painted` and `hittable` are independent (see §3, §9).
class ResolvedCoord {
  ResolvedCoord({
    required this.glintId,
    required this.logicalCenter,
    required this.logicalBounds,
    required this.devicePixelRatio,
    required this.logicalViewSize,
    required this.nearestAncestorOpacity,
    required this.nearestAncestorVisible,
    required this.hittable,
  });

  final String glintId;
  final ({double x, double y}) logicalCenter;
  final ({double x, double y, double w, double h}) logicalBounds;
  final double devicePixelRatio;
  final ({double w, double h}) logicalViewSize;
  final double nearestAncestorOpacity;
  final bool nearestAncestorVisible;
  final bool hittable;

  ({int x, int y}) get physicalCenter => (
        x: (logicalCenter.x * devicePixelRatio).round(),
        y: (logicalCenter.y * devicePixelRatio).round(),
      );

  bool get hasNonZeroBounds => logicalBounds.w > 0 && logicalBounds.h > 0;

  bool get intersectsViewport {
    // logicalBounds is node-local. Translate to global via the relationship
    // globalOrigin = logicalCenter - bounds.center. Exact for axis-aligned
    // non-transformed boxes.
    final globalLeft = logicalCenter.x - (logicalBounds.x + logicalBounds.w / 2);
    final globalTop = logicalCenter.y - (logicalBounds.y + logicalBounds.h / 2);
    final globalRight = globalLeft + logicalBounds.w;
    final globalBottom = globalTop + logicalBounds.h;
    if (globalRight <= 0 || globalBottom <= 0) return false;
    if (globalLeft >= logicalViewSize.w) return false;
    if (globalTop >= logicalViewSize.h) return false;
    return true;
  }

  bool get painted =>
      hasNonZeroBounds &&
      intersectsViewport &&
      nearestAncestorOpacity > 0 &&
      nearestAncestorVisible;

  /// Non-fatal observations for [ActionResult.warnings].
  List<String> get warnings {
    final out = <String>[];
    if (!painted) {
      out.add('target is not painted (zero bounds, off-viewport, '
          'or hidden by ancestor opacity / visibility)');
    }
    if (!hittable) {
      out.add('target is not hittable — an absorber, overlay, or modal '
          'likely sits above; the OS-level tap landed but the framework '
          'hit test would not route it to your target');
    }
    return out;
  }

  Map<String, Object?> toJson() => {
        'glintId': glintId,
        'logicalCenter': {'x': logicalCenter.x, 'y': logicalCenter.y},
        'logicalBounds': {
          'x': logicalBounds.x,
          'y': logicalBounds.y,
          'w': logicalBounds.w,
          'h': logicalBounds.h,
        },
        'devicePixelRatio': devicePixelRatio,
        'logicalViewSize': {
          'w': logicalViewSize.w,
          'h': logicalViewSize.h,
        },
        'physicalCenter': {'x': physicalCenter.x, 'y': physicalCenter.y},
        'nearestAncestorOpacity': nearestAncestorOpacity,
        'nearestAncestorVisible': nearestAncestorVisible,
        'painted': painted,
        'hittable': hittable,
      };
}

/// Resolves nodes to live geometry. Lazy — re-queries every call.
class CoordinateResolver {
  CoordinateResolver(this._runtime);

  final FlutterRuntime _runtime;

  Future<ResolvedCoord> resolve(Scene scene, String glintId) async {
    final node = scene.findByGlintId(glintId);
    if (node == null) {
      throw GeometryResolveError('unknown glintId: $glintId');
    }
    return _resolveNode(scene, node);
  }

  /// Returns viewport dimensions without performing a hit-test.
  ///
  /// Safe on Dart 3.12 / iOS 26 where [HitTestResult] is not accessible in
  /// the CFE eval scope. Use this from [AttachTool] instead of [resolve].
  Future<({double dpr, double w, double h})> resolveViewport(
      Scene scene, String glintId) async {
    final node = scene.findByGlintId(glintId);
    if (node == null) {
      throw GeometryResolveError('unknown glintId: $glintId');
    }
    try {
      await _runtime.setInspectorSelection(
        inspectorId: node.inspectorId,
        groupName: scene.groupName,
      );
    } on Object catch (e) {
      throw GeometryResolveError(
        'setSelectionById(${node.inspectorId}) failed: $e',
      );
    }
    final String? json;
    try {
      json = await _runtime.evaluateString(_GeometryExpr.buildViewProbe());
    } on RuntimeEvalError catch (e) {
      throw GeometryResolveError('evaluate(viewProbe) failed: ${e.message}');
    }
    if (json == null) {
      throw GeometryResolveError('evaluate(viewProbe) returned non-string');
    }
    final decoded = jsonDecode(json) as Map<String, Object?>;
    return (
      dpr: (decoded['dpr'] as num).toDouble(),
      w: (decoded['vw'] as num).toDouble(),
      h: (decoded['vh'] as num).toDouble(),
    );
  }

  Future<ResolvedCoord> _resolveNode(Scene scene, SceneNode node) async {
    try {
      await _runtime.setInspectorSelection(
        inspectorId: node.inspectorId,
        groupName: scene.groupName,
      );
    } on Object catch (e) {
      throw GeometryResolveError(
        'setSelectionById(${node.inspectorId}) failed: $e',
      );
    }

    final String? json;
    try {
      json = await _runtime.evaluateString(GeometryExpr.build());
    } on RuntimeEvalError catch (e) {
      throw GeometryResolveError('evaluate(geometry) failed: ${e.message}');
    }
    if (json == null) {
      throw GeometryResolveError('evaluate(geometry) returned non-string');
    }
    final decoded = jsonDecode(json) as Map<String, Object?>;
    return ResolvedCoord(
      glintId: node.glintId!,
      logicalCenter: (
        x: (decoded['gx'] as num).toDouble(),
        y: (decoded['gy'] as num).toDouble(),
      ),
      logicalBounds: (
        x: (decoded['bx'] as num).toDouble(),
        y: (decoded['by'] as num).toDouble(),
        w: (decoded['bw'] as num).toDouble(),
        h: (decoded['bh'] as num).toDouble(),
      ),
      devicePixelRatio: (decoded['dpr'] as num).toDouble(),
      logicalViewSize: (
        w: (decoded['vw'] as num).toDouble(),
        h: (decoded['vh'] as num).toDouble(),
      ),
      nearestAncestorOpacity: (decoded['op'] as num).toDouble(),
      nearestAncestorVisible: decoded['vis'] as bool,
      hittable: decoded['hit'] as bool,
    );
  }
}

class GeometryResolveError implements Exception {
  GeometryResolveError(this.message);
  final String message;
  @override
  String toString() => 'GeometryResolveError: $message';
}

// Single-line Dart expression sent via `evaluate`. CFE rejects newlines and
// statement-block lambdas, so fields are string-concatenated into a JSON blob.
class GeometryExpr {
  static const _ro = 'WidgetInspectorService.instance.selection.current!';
  static const _el =
      'WidgetInspectorService.instance.selection.currentElement!';
  static const _view = 'View.of($_el)';
  static const _ancOpacity =
      '($_el.findAncestorWidgetOfExactType<Opacity>()?.opacity ?? 1.0)';
  static const _ancVisible =
      '($_el.findAncestorWidgetOfExactType<Visibility>()?.visible ?? true)';
  // On Dart 3.12 the CFE rejects `HitTestResult` in synthetic eval scopes even
  // though the type is re-exported via package:flutter/widgets.dart. Same root
  // cause as the attach probe (fixed separately). We replace the full hit-test
  // with a widget-tree ancestor walk: nearest AbsorbPointer / IgnorePointer.
  // Trade-off: overlay-based coverings (e.g. opaque GestureDetector in a modal)
  // are not detected, but the common cases are covered and no type is named.
  static const _hittable =
      '(!($_el.findAncestorWidgetOfExactType<AbsorbPointer>()?.absorbing ?? false) && '
      '!($_el.findAncestorWidgetOfExactType<IgnorePointer>()?.ignoring ?? false))';

  static String build() {
    final body = [
      "'{\"gx\":'",
      'c.dx.toString()',
      "',\"gy\":'",
      'c.dy.toString()',
      "',\"bx\":'",
      '$_ro.paintBounds.left.toString()',
      "',\"by\":'",
      '$_ro.paintBounds.top.toString()',
      "',\"bw\":'",
      '$_ro.paintBounds.width.toString()',
      "',\"bh\":'",
      '$_ro.paintBounds.height.toString()',
      "',\"dpr\":'",
      '$_view.devicePixelRatio.toString()',
      "',\"vw\":'",
      '($_view.physicalSize.width / $_view.devicePixelRatio).toString()',
      "',\"vh\":'",
      '($_view.physicalSize.height / $_view.devicePixelRatio).toString()',
      "',\"op\":'",
      '$_ancOpacity.toString()',
      "',\"vis\":'",
      '$_ancVisible.toString()',
      "',\"hit\":'",
      '$_hittable.toString()',
      "'}'",
    ].join(' + ');
    // HitTestResult r dropped — lambda only needs Offset c now.
    return '((Offset c) => $body)($_ro.localToGlobal($_ro.paintBounds.center))';
  }

  /// Probe expression that returns only dpr/vw/vh — no [HitTestResult].
  ///
  /// On Dart 3.12+ the CFE rejects `HitTestResult` in synthetic eval scopes
  /// even though the type is exported from `package:flutter/widgets.dart`.
  /// [_probeIosTarget] only needs viewport dimensions so we skip the hit-test
  /// half of [build] entirely.
  static String buildViewProbe() {
    final body = [
      "'{\"dpr\":'",
      '$_view.devicePixelRatio.toString()',
      "',\"vw\":'",
      '($_view.physicalSize.width / $_view.devicePixelRatio).toString()',
      "',\"vh\":'",
      '($_view.physicalSize.height / $_view.devicePixelRatio).toString()',
      "'}'",
    ].join(' + ');
    return body;
  }
}
