import 'dart:convert';

import 'package:vm_service/vm_service.dart';

import '../vm/vm_client.dart';
import 'scene_node.dart';
import 'scene_reader.dart';

/// A single node's geometry resolved against the live render tree.
///
/// All coordinates are global (relative to the FlutterView origin).
/// `logicalCenter` is in Flutter logical pixels — what RenderObject APIs
/// speak. `physicalCenter` is `logicalCenter * devicePixelRatio`, which
/// is what Module A's interaction layer (`adb input tap`, the iOS Swift
/// bridge in P2) actually consumes.
///
/// `painted` follows the §9 v1 rule: non-empty bounds, bounds intersect
/// viewport, no ancestor Opacity with opacity==0 or Visibility with
/// visible==false.
///
/// `hittable` is computed via a real Flutter `hitTestInView` call at this
/// node's centre — §3 "lean on the framework" honoured. The check is
/// "is our RenderObject anywhere in the hit-test result's path?". An
/// `AbsorbPointer` / opaque `GestureDetector` between root and our node
/// will prevent our render object from appearing in the path, so we
/// correctly read as not-hittable.
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

  /// Opacity of the nearest `Opacity` ancestor (1.0 if there is none).
  final double nearestAncestorOpacity;

  /// `visible` of the nearest `Visibility` ancestor (true if there is none).
  final bool nearestAncestorVisible;

  /// Result of a live `hitTestInView` at [logicalCenter] — true when this
  /// node's render object would receive the tap.
  final bool hittable;

  /// §9 v1 painted: non-empty bounds AND bounds intersect viewport AND no
  /// ancestor Opacity(opacity:0) AND no ancestor Visibility(visible:false).
  bool get painted =>
      hasNonZeroBounds &&
      intersectsViewport &&
      nearestAncestorOpacity > 0 &&
      nearestAncestorVisible;

  ({int x, int y}) get physicalCenter => (
        x: (logicalCenter.x * devicePixelRatio).round(),
        y: (logicalCenter.y * devicePixelRatio).round(),
      );

  /// Empty bounds = nothing to paint.
  bool get hasNonZeroBounds => logicalBounds.w > 0 && logicalBounds.h > 0;

  /// `logicalBounds` is given in node-local coordinates. To check viewport
  /// intersection we translate it into global coords via `localToGlobal`
  /// of the origin — which is `logicalCenter - bounds.center`. For axis-
  /// aligned non-transformed boxes this is exact.
  bool get intersectsViewport {
    final globalLeft =
        logicalCenter.x - (logicalBounds.x + logicalBounds.w / 2);
    final globalTop =
        logicalCenter.y - (logicalBounds.y + logicalBounds.h / 2);
    final globalRight = globalLeft + logicalBounds.w;
    final globalBottom = globalTop + logicalBounds.h;
    if (globalRight <= 0 || globalBottom <= 0) return false;
    if (globalLeft >= logicalViewSize.w) return false;
    if (globalTop >= logicalViewSize.h) return false;
    return true;
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

/// Server-side coordinate resolver.
///
/// Strategy: set the inspector's selection to the target node via
/// `setSelectionById`, then evaluate a single Dart expression that pulls
/// the rendered geometry off the selected RenderObject. No statement-block
/// IIFE — the expression is a chain of getters and constructors built as
/// a JSON string the server parses.
///
/// "Lazy" per §3 of the source-of-truth: resolution happens at the moment
/// of action, never cached. Two consecutive calls always re-query the live
/// VM. If the agent acts on a stale coordinate it's still safe — the
/// resolver re-reads on the next call.
class CoordinateResolver {
  CoordinateResolver(this._vm);

  final VmClient _vm;

  /// Resolve geometry for the node with [glintId] in [scene]. Throws
  /// [GeometryResolveError] when the node is unknown, missing a render
  /// object (off-screen / virtualised list item), or when the live VM
  /// rejects the expression.
  Future<ResolvedCoord> resolve(Scene scene, String glintId) async {
    final node = scene.findByGlintId(glintId);
    if (node == null) {
      throw GeometryResolveError('unknown glintId: $glintId');
    }
    return _resolveNode(scene, node);
  }

  Future<ResolvedCoord> _resolveNode(Scene scene, SceneNode node) async {
    // Step 1: set the inspector's selection to this object. The inspector
    // looks the id up in its own group table, which is still alive because
    // we haven't disposed the Scene yet.
    final svc = _vm.service;
    final isolateId = _vm.flutterIsolateId;
    try {
      await svc.callServiceExtension(
        'ext.flutter.inspector.setSelectionById',
        isolateId: isolateId,
        args: {'arg': node.inspectorId, 'objectGroup': scene.groupName},
      );
    } on RPCError catch (e) {
      throw GeometryResolveError(
        'setSelectionById(${node.inspectorId}) failed: ${e.details ?? e.message}',
      );
    }

    // Step 2: pull geometry through one evaluate. We render the answer as
    // a JSON string in the expression so we don't have to fight Dart 3's
    // record-vs-record-literal ambiguity in the response shape.
    //
    // Two real fragility risks here:
    //   - `selection.current` is RenderObject?. We `!` unwrap — the catch
    //     below maps the resulting StateError into a typed exception.
    //   - `View.of(currentElement)` needs an Element that's in a tree with
    //     a FlutterView ancestor. All paint-visible nodes are, but the
    //     RootWidget itself may not be. Resolving the root node is meaningless,
    //     so we don't bother.
    // Single-line: the CFE expression evaluator treats raw newlines as
    // end-of-input. Long but readable when wrapped at sight.
    final expr = _buildGeometryExpr();

    final rootLib = _vm.flutterIsolate.rootLib?.id;
    if (rootLib == null) {
      throw GeometryResolveError('flutter isolate has no rootLib');
    }
    final Object? raw;
    try {
      raw = await svc.evaluate(isolateId, rootLib, expr);
    } on RPCError catch (e) {
      throw GeometryResolveError(
        'evaluate(geometry) failed: ${e.details ?? e.message}',
      );
    }
    if (raw is! InstanceRef || raw.valueAsString == null) {
      throw GeometryResolveError(
        'evaluate(geometry) returned ${raw.runtimeType}, expected String',
      );
    }
    // `valueAsString` is a preview — VM service truncates at ~128 chars.
    // Our JSON blob can exceed that on devices whose viewport prints with
    // many fractional digits (e.g. Pixel 8: 411.42857142857144). When the
    // preview reports truncated, refetch the full Instance.
    String jsonString = raw.valueAsString!;
    if (raw.valueAsStringIsTruncated == true) {
      final full = await svc.getObject(isolateId, raw.id!);
      if (full is Instance && full.valueAsString != null) {
        jsonString = full.valueAsString!;
      } else {
        throw GeometryResolveError(
          'geometry JSON was truncated and getObject returned '
          '${full.runtimeType} (expected Instance with valueAsString)',
        );
      }
    }
    final decoded =
        jsonDecode(jsonString) as Map<String, Object?>; // synchronous; small
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

/// Builds the single-line evaluate expression that reads geometry off the
/// inspector's currently-selected RenderObject / Element. Kept separate so
/// the (necessarily long) string doesn't drown the algorithm above.
///
/// Pulls in one shot:
///   - global centre (gx, gy)
///   - local paint bounds (bx, by, bw, bh)
///   - device pixel ratio (dpr)
///   - view logical size (vw, vh)
///   - nearest ancestor Opacity.opacity (op; 1.0 when none)
///   - nearest ancestor Visibility.visible (vis; true when none)
///   - hit-test result (hit; true iff our RO is on the hit-test path at our centre)
///
/// The hit-test uses a single-expression IIFE-like pattern: a lambda binds
/// `r` (a fresh `HitTestResult`) and `c` (the global centre), the body is a
/// record literal whose first element side-effects `hitTestInView` via a
/// cascade on `WidgetsBinding.instance`, and whose second element reads
/// `r.path` — Dart record evaluation order (left-to-right) guarantees the
/// hit test runs before the read.
String _buildGeometryExpr() {
  const ro = 'WidgetInspectorService.instance.selection.current!';
  const el = 'WidgetInspectorService.instance.selection.currentElement!';
  const view = 'View.of($el)';
  const ancOpacity =
      '($el.findAncestorWidgetOfExactType<Opacity>()?.opacity ?? 1.0)';
  const ancVisible =
      '($el.findAncestorWidgetOfExactType<Visibility>()?.visible ?? true)';
  // Hit-test sub-expression. `c` is the global centre Offset bound by the
  // outer lambda; `r` is the fresh HitTestResult also bound there.
  const hitTest =
      '((WidgetsBinding.instance..hitTestInView(r, c, $view.viewId)), '
      'r.path.any((e) => identical(e.target, $ro))).\$2';
  // Inner string-concat builds the JSON payload. `c.dx` / `c.dy` come from
  // the lambda binding, so we don't recompute localToGlobal twice.
  final body = [
    "'{\"gx\":'",
    'c.dx.toString()',
    "',\"gy\":'",
    'c.dy.toString()',
    "',\"bx\":'",
    '$ro.paintBounds.left.toString()',
    "',\"by\":'",
    '$ro.paintBounds.top.toString()',
    "',\"bw\":'",
    '$ro.paintBounds.width.toString()',
    "',\"bh\":'",
    '$ro.paintBounds.height.toString()',
    "',\"dpr\":'",
    '$view.devicePixelRatio.toString()',
    "',\"vw\":'",
    '($view.physicalSize.width / $view.devicePixelRatio).toString()',
    "',\"vh\":'",
    '($view.physicalSize.height / $view.devicePixelRatio).toString()',
    "',\"op\":'",
    '$ancOpacity.toString()',
    "',\"vis\":'",
    '$ancVisible.toString()',
    "',\"hit\":'",
    '$hitTest.toString()',
    "'}'",
  ].join(' + ');
  return '((Offset c, HitTestResult r) => $body)'
      '($ro.localToGlobal($ro.paintBounds.center), HitTestResult())';
}
