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

  /// True when the resolved center lies inside the viewport — a gesture can
  /// land there. Center goes through localToGlobal, so this is transform-safe.
  bool get centerOnViewport =>
      logicalViewSize.w > 0 &&
      logicalViewSize.h > 0 &&
      logicalCenter.x >= 0 &&
      logicalCenter.y >= 0 &&
      logicalCenter.x < logicalViewSize.w &&
      logicalCenter.y < logicalViewSize.h;

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

  /// Viewport dimensions straight from the implicit view — no selected node,
  /// so it works before the first addressable widget renders (issue #13).
  Future<({double dpr, double w, double h})> resolveViewportNodeFree() async {
    final String? json;
    try {
      json = await _runtime.evaluateString(GeometryExpr.buildImplicitViewProbe());
    } on RuntimeEvalError catch (e) {
      throw GeometryResolveError('evaluate(implicitView) failed: ${e.message}');
    }
    if (json == null) {
      throw GeometryResolveError('evaluate(implicitView) returned non-string');
    }
    final decoded = _decode(json, 'implicitView');
    return (
      dpr: (decoded['dpr'] as num).toDouble(),
      w: (decoded['vw'] as num).toDouble(),
      h: (decoded['vh'] as num).toDouble(),
    );
  }

  /// Viewport dimensions without a hit-test. Safe on Dart 3.12 / iOS 26 where
  /// [HitTestResult] is inaccessible in the CFE eval scope; use over [resolve].
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
      json = await _runtime.evaluateString(GeometryExpr.buildViewProbe());
    } on RuntimeEvalError catch (e) {
      throw GeometryResolveError('evaluate(viewProbe) failed: ${e.message}');
    }
    if (json == null) {
      throw GeometryResolveError('evaluate(viewProbe) returned non-string');
    }
    final decoded = _decode(json, 'viewProbe');
    return (
      dpr: (decoded['dpr'] as num).toDouble(),
      w: (decoded['vw'] as num).toDouble(),
      h: (decoded['vh'] as num).toDouble(),
    );
  }

  Future<ResolvedCoord> _resolveNode(Scene scene, SceneNode node) async {
    // Overlay nodes have inspectorIds from the full-tree group (not summary).
    // Use fullGroupName for those so the inspector can resolve the reference.
    final groupName = (node.glintId != null && scene.isInOverlay(node.glintId!))
        ? (scene.fullGroupName ?? scene.groupName)
        : scene.groupName;
    try {
      await _runtime.setInspectorSelection(
        inspectorId: node.inspectorId,
        groupName: groupName,
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
    final decoded = _decode(json, 'geometry');
    if (decoded['gx'] == null || decoded['gy'] == null) {
      throw GeometryResolveError(
          '${node.glintId} is not laid out — offstage or an inactive tab '
          'page; bring it on screen first');
    }
    // A ModalBarrier blocks the base screen through its own hit-testing, not an
    // AbsorbPointer/IgnorePointer ancestor — so the eval reports base nodes as
    // hittable while a modal actually covers them. Fold in the barrier the
    // scene already detected: a base-tree node under a barrier is not hittable.
    final evalHittable = decoded['hit'] as bool;
    final id = node.glintId;
    final blockedByBarrier = scene.hasBarrierOverlay &&
        id != null &&
        !scene.isInOverlay(id);
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
      hittable: evalHittable && !blockedByBarrier,
    );
  }
}

/// An eval can come back as prose (`Instance of…`, a Sentinel, an error text)
/// instead of the JSON blob; surface that as a typed failure, never a crash.
/// Dart prints unlaid-out geometry as `NaN`, which is not JSON: it becomes
/// null so callers can name the condition.
Map<String, Object?> _decode(String json, String what) {
  try {
    final decoded =
        jsonDecode(json.replaceAll(RegExp(r'-?(?:NaN|Infinity)'), 'null'));
    if (decoded is Map<String, Object?>) return decoded;
  } on FormatException {
    // fall through
  }
  final head = json.length > 120 ? '${json.substring(0, 120)}…' : json;
  throw GeometryResolveError('evaluate($what) returned non-JSON: $head');
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
  // A true hit-test is unreachable here: the eval runs in the app's root
  // library, where `HitTestResult`/`GestureBinding` don't resolve (RPCError 113,
  // confirmed empirically — they're only re-exported, not declared, by the
  // imported libraries). So hittability is approximated in two layers: this
  // ancestor walk (nearest AbsorbPointer / IgnorePointer), plus a scene-level
  // ModalBarrier check in CoordinateResolver (a barrier blocks via its own hit
  // test, not an absorber ancestor). Residual gap: a plain opaque sibling drawn
  // on top in the same layer, with no barrier, can still read as hittable —
  // only a real hit-test would catch that.
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
    return '((Offset c) => $body)($_ro.localToGlobal($_ro.paintBounds.center))';
  }

  static const _implicitView =
      'WidgetsBinding.instance.platformDispatcher.implicitView!';

  /// dpr/vw/vh from the implicit view — needs no inspector selection, so it
  /// works on any root widget and before the first addressable node renders.
  static String buildImplicitViewProbe() {
    final body = [
      "'{\"dpr\":'",
      '$_implicitView.devicePixelRatio.toString()',
      "',\"vw\":'",
      '($_implicitView.physicalSize.width / $_implicitView.devicePixelRatio).toString()',
      "',\"vh\":'",
      '($_implicitView.physicalSize.height / $_implicitView.devicePixelRatio).toString()',
      "'}'",
    ].join(' + ');
    return body;
  }

  /// Returns only dpr/vw/vh — skips the hit-test half of [build] because the
  /// CFE rejects `HitTestResult` in synthetic eval scopes on Dart 3.12+.
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
