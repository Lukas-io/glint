import 'dart:convert';

import 'package:glint_core/glint_core.dart' show instanceText;

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
    this.clip,
    this.keyboardInset = 0,
    this.hitTestReal = false,
    this.hitBy,
  });

  final String glintId;
  final ({double x, double y}) logicalCenter;
  final ({double x, double y, double w, double h}) logicalBounds;
  final double devicePixelRatio;
  final ({double w, double h}) logicalViewSize;

  /// Every ancestor opacity multiplied (Opacity, AnimatedOpacity, FadeTransition); 0 means the node paints nothing.
  final double nearestAncestorOpacity;
  final bool nearestAncestorVisible;
  final bool hittable;

  /// Global rect of the nearest scroll viewport; content outside it is clipped away.
  final ({double x, double y, double w, double h})? clip;

  /// Logical height the on-screen keyboard covers at the bottom of the view.
  final double keyboardInset;

  /// True when [hittable] comes from Flutter's own hit test rather than the ancestor approximation.
  final bool hitTestReal;

  /// What a tap at the centre would reach instead, when the real hit test misses the target.
  final String? hitBy;

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
    final c = clip;
    if (c == null) return true;
    return globalRight > c.x && globalBottom > c.y && globalLeft < c.x + c.w && globalTop < c.y + c.h;
  }

  /// True when the centre sits inside the nearest scroll viewport (or there is none).
  bool get centerInClip {
    final c = clip;
    if (c == null) return true;
    return logicalCenter.x >= c.x &&
        logicalCenter.y >= c.y &&
        logicalCenter.x < c.x + c.w &&
        logicalCenter.y < c.y + c.h;
  }

  /// True when the on-screen keyboard covers the centre.
  bool get centerUnderKeyboard => keyboardInset > 0 && logicalCenter.y >= logicalViewSize.h - keyboardInset;

  bool get painted => hasNonZeroBounds && intersectsViewport && nearestAncestorOpacity > 0 && nearestAncestorVisible;

  /// True when the resolved center lies inside the viewport — a gesture can
  /// land there. Center goes through localToGlobal, so this is transform-safe.
  bool get centerOnViewport =>
      logicalViewSize.w > 0 &&
      logicalViewSize.h > 0 &&
      logicalCenter.x >= 0 &&
      logicalCenter.y >= 0 &&
      logicalCenter.x < logicalViewSize.w &&
      logicalCenter.y < logicalViewSize.h &&
      centerInClip &&
      !centerUnderKeyboard;

  /// Non-fatal observations for [ActionResult.warnings].
  List<String> get warnings {
    final out = <String>[];
    if (!painted) {
      out.add('target is not painted (zero bounds, off-viewport, '
          'or hidden by ancestor opacity / visibility)');
    }
    if (!hittable) {
      out.add(hitTestReal
          ? 'a tap at the centre would land on ${hitBy ?? 'another widget'}, not on the target'
          : 'target may not be hittable: an absorber, overlay or modal '
              'likely sits above it (approximate check)');
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
        'hitTest': hitTestReal ? 'real' : 'approximate',
        if (hitBy != null) 'hitBy': hitBy,
        if (clip != null) 'clip': {'x': clip!.x, 'y': clip!.y, 'w': clip!.w, 'h': clip!.h},
        if (keyboardInset > 0) 'keyboardInset': keyboardInset,
      };
}

/// The scrollable that moves content along one axis: its global [rect] and whether it [paged] (PageView, TabBarView).
typedef AxisScrollable = ({({double x, double y, double w, double h}) rect, bool paged});

/// The nearest scrollable around [node] that scrolls along the [horizontal] or vertical axis, skipping nearer ones on the other axis; null when there is none or the eval fails.
Future<AxisScrollable?> scrollableAround(
  FlutterRuntime runtime,
  Scene scene,
  SceneNode node, {
  required bool horizontal,
}) async {
  final groupName = (node.glintId != null && scene.isInOverlay(node.glintId!))
      ? (scene.fullGroupName ?? scene.groupName)
      : scene.groupName;
  final raw = await runtime.evaluateWithSelection(
    expression: GeometryExpr.axisScrollable(horizontal: horizontal),
    inspectorId: node.inspectorId,
    groupName: groupName,
  );
  final parts = raw?.split(',').map(double.tryParse).toList();
  if (parts == null || parts.length != 5 || parts.contains(null)) return null;
  return (rect: (x: parts[0]!, y: parts[1]!, w: parts[2]!, h: parts[3]!), paged: parts[4] == 1);
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
      json = await _runtime.evaluateString(GeometryExpr.buildImplicitViewProbe(), rethrowErrors: true);
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
  Future<({double dpr, double w, double h})> resolveViewport(Scene scene, String glintId) async {
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
      json = await _runtime.evaluateString(GeometryExpr.buildViewProbe(), rethrowErrors: true);
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

    String? json;
    for (var attempt = 0;; attempt++) {
      try {
        json = await _runtime.evaluateString(GeometryExpr.build(), rethrowErrors: true);
        break;
      } on RuntimeEvalError catch (e) {
        if (attempt > 0) {
          throw GeometryResolveError('evaluate(geometry) failed: ${e.message}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    if (json == null) {
      throw GeometryResolveError('evaluate(geometry) returned non-string');
    }
    final decoded = _decode(json, 'geometry');
    if (decoded['gx'] == null || decoded['gy'] == null) {
      throw GeometryResolveError('${node.glintId} is not laid out — offstage or an inactive tab '
          'page; bring it on screen first');
    }
    // A ModalBarrier blocks the base screen through its own hit-testing, not an
    // AbsorbPointer/IgnorePointer ancestor — so the eval reports base nodes as
    // hittable while a modal actually covers them. Fold in the barrier the
    // scene already detected: a base-tree node under a barrier is not hittable.
    final evalHittable = decoded['hit'] as bool;
    final id = node.glintId;
    final blockedByBarrier = scene.hasBarrierOverlay && id != null && !scene.isInOverlay(id);
    final clip = await _clipRect();
    final gx = (decoded['gx'] as num).toDouble(), gy = (decoded['gy'] as num).toDouble();
    final onScreen = gx >= 0 && gy >= 0 && gx < (decoded['vw'] as num) && gy < (decoded['vh'] as num);
    final probed = await _hitTest(scene, groupName, (decoded['vid'] as num?)?.toInt() ?? 0);
    final hit = probed == null || onScreen ? probed : (hit: false, hitBy: null);
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
      hittable: hit?.hit ?? (evalHittable && !blockedByBarrier),
      clip: clip,
      keyboardInset: (decoded['kb'] as num?)?.toDouble() ?? 0,
      hitTestReal: hit != null,
      hitBy: hit?.hitBy,
    );
  }

  /// The selected node's nearest scroll viewport as a global rect, minus the strip pinned headers cover; null when there is none or the eval fails.
  Future<({double x, double y, double w, double h})?> _clipRect() async {
    final ({double x, double y, double w, double h}) rect;
    try {
      final raw = await _runtime.evaluateString(GeometryExpr.clip, rethrowErrors: true);
      final parts = raw?.split(',').map(double.tryParse).toList();
      if (parts == null || parts.length != 4 || parts.contains(null)) return null;
      rect = (x: parts[0]!, y: parts[1]!, w: parts[2]!, h: parts[3]!);
    } on Object {
      return null;
    }
    return _withoutLeadingCover(rect, await _leadingCover());
  }

  /// How far earlier pinned slivers cover the selected node's sliver, with the sliver's axis and growth direction indexes and its painted box; null when unknown.
  Future<({double overlap, int axis, int growth, double x, double y, double extent})?> _leadingCover() async {
    try {
      final raw = await _runtime.evaluateString(GeometryExpr.leadingCover, rethrowErrors: true);
      final parts = raw?.split(',').map(double.tryParse).toList();
      if (parts == null || parts.length != 6 || parts.contains(null)) return null;
      return (
        overlap: parts[0]!,
        axis: parts[1]!.toInt(),
        growth: parts[2]!.toInt(),
        x: parts[3]!,
        y: parts[4]!,
        extent: parts[5]!
      );
    } on Object {
      return null;
    }
  }

  /// Flutter's own hit test at the selected node's centre; null when it cannot run, so callers fall back to the approximation.
  Future<({bool hit, String? hitBy})?> _hitTest(Scene scene, String groupName, int viewId) async {
    try {
      final pair = await _runtime.evaluateIn(GeometryExpr.hitInputs);
      final pairId = pair.id;
      if (pairId == null) return null;
      final path = await _runtime
          .evaluateIn(GeometryExpr.hitPath(viewId), librarySuffix: GeometryExpr.gesturesLibrary, scope: {'x': pairId});
      final pathId = path.id;
      if (pathId == null) return null;
      final verdict = await _runtime.evaluateIn(GeometryExpr.hitVerdict(groupName), scope: {'h': pathId});
      final text = verdict.valueAsStringIsTruncated == true
          ? await instanceText(_runtime.rawService, _runtime.flutterIsolateId, verdict)
          : verdict.valueAsString;
      if (text == null) return null;
      if (text == 'hit') return (hit: true, hitBy: null);
      return (hit: false, hitBy: _describeWinner(scene, text));
    } on Object {
      return null;
    }
  }

  /// Names the nearest scene node on the winner's ancestor chain, else the winner's widget type.
  String _describeWinner(Scene scene, String verdict) {
    final parts = verdict.split('|');
    final ids = parts.length > 1 ? parts[1].split(',') : const <String>[];
    final byId = {
      for (final n in scene.root.walk())
        if (n.glintId != null) n.inspectorId: n,
    };
    for (final id in ids) {
      final n = byId[id];
      if (n == null) continue;
      final label = n.walk().map((d) => d.textPreview).firstWhere((t) => t != null && t.isNotEmpty, orElse: () => null);
      return label == null ? n.glintId! : '${n.glintId} "$label"';
    }
    return parts.first.replaceFirst('miss:', '').trim().isEmpty
        ? 'another widget'
        : parts.first.replaceFirst('miss:', '').trim();
  }
}

/// [rect] with the strip pinned slivers paint over the start of the node's own sliver cut off; [cover] indexes follow Flutter's AxisDirection (up, right, down, left) and GrowthDirection (forward, reverse).
({double x, double y, double w, double h}) _withoutLeadingCover(
  ({double x, double y, double w, double h}) rect,
  ({double overlap, int axis, int growth, double x, double y, double extent})? cover,
) {
  if (cover == null || !cover.overlap.isFinite || cover.overlap <= 0.5) return rect;
  final paintAxis = cover.growth == 0 ? cover.axis : (cover.axis + 2) % 4;
  final o = cover.overlap;
  final right = rect.x + rect.w;
  final bottom = rect.y + rect.h;
  switch (paintAxis) {
    case 2:
      final top = (cover.y + o).clamp(rect.y, bottom);
      return (x: rect.x, y: top, w: rect.w, h: bottom - top);
    case 0:
      final end = (cover.y + cover.extent - o).clamp(rect.y, bottom);
      return (x: rect.x, y: rect.y, w: rect.w, h: end - rect.y);
    case 1:
      final left = (cover.x + o).clamp(rect.x, right);
      return (x: left, y: rect.y, w: right - left, h: rect.h);
    default:
      final end = (cover.x + cover.extent - o).clamp(rect.x, right);
      return (x: rect.x, y: rect.y, w: end - rect.x, h: rect.h);
  }
}

/// An eval can come back as prose (`Instance of…`, a Sentinel, an error text)
/// instead of the JSON blob; surface that as a typed failure, never a crash.
/// Dart prints unlaid-out geometry as `NaN`, which is not JSON: it becomes
/// null so callers can name the condition.
/// Measuring the modal on top of the app: what back needs to close a sheet or dialog.
extension ModalGeometry on CoordinateResolver {
  /// Global rect and view size of [node] (an inspector node needs no glintId), or null when it cannot be measured.
  Future<({double x, double y, double w, double h, double vw, double vh})?> boundsOf(
      Scene scene, SceneNode node) async {
    try {
      await _runtime.setInspectorSelection(
        inspectorId: node.inspectorId,
        groupName: scene.fullGroupName ?? scene.groupName,
      );
      final json = await _runtime.evaluateString(GeometryExpr.build(), rethrowErrors: true);
      if (json == null) return null;
      final d = _decode(json, 'bounds');
      if (d['gx'] == null || d['gy'] == null) return null;
      final w = (d['bw'] as num).toDouble(), h = (d['bh'] as num).toDouble();
      return (
        x: (d['gx'] as num).toDouble() - w / 2,
        y: (d['gy'] as num).toDouble() - h / 2,
        w: w,
        h: h,
        vw: (d['vw'] as num).toDouble(),
        vh: (d['vh'] as num).toDouble(),
      );
    } on Object {
      return null;
    }
  }

  /// Whether the top modal barrier closes its route when tapped; null when there is no barrier or the app would not say.
  Future<bool?> barrierDismissible(Scene scene) async {
    final entry = scene.topBarrier;
    if (entry == null) return null;
    final nodes = entry.walk().toList();
    final barrier = nodes.where((n) => n.baseLabel == 'ModalBarrier').firstOrNull ??
        nodes.where((n) => n.baseLabel == 'AnimatedModalBarrier').firstOrNull;
    if (barrier == null) return null;
    try {
      await _runtime.setInspectorSelection(
        inspectorId: barrier.inspectorId,
        groupName: scene.fullGroupName ?? scene.groupName,
      );
      return switch (await _runtime.evaluateString(GeometryExpr.barrierDismissible, rethrowErrors: true)) {
        'true' => true,
        'false' => false,
        _ => null,
      };
    } on Object {
      return null;
    }
  }
}

Map<String, Object?> _decode(String json, String what) {
  try {
    final decoded = jsonDecode(json.replaceAll(RegExp(r'-?(?:NaN|Infinity)'), 'null'));
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

// Single-line Dart expression sent via `evaluate`. CFE rejects newlines, so
// fields are string-concatenated into a JSON blob.
class GeometryExpr {
  static const _ro = 'WidgetInspectorService.instance.selection.current!';
  static const _el = 'WidgetInspectorService.instance.selection.currentElement!';
  static const _view = 'View.of($_el)';
  static const _ancOpacity = '$opacityOf($_ro)';

  /// How opaque a render object really paints: every Opacity, AnimatedOpacity and FadeTransition (box or sliver) above it, multiplied; type names are compared as strings so it compiles in any eval library.
  static const opacityOf = '((dynamic r) { var o = 1.0; while (r != null) { final t = r.runtimeType.toString(); '
      "if (t == 'RenderOpacity' || t == 'RenderSliverOpacity') { o = o * r.opacity; } "
      "else if (t == 'RenderAnimatedOpacity' || t == 'RenderSliverAnimatedOpacity') { o = o * r.opacity.value; } "
      'r = r.parent; } return o; })';
  static const _ancVisible = '($_el.findAncestorWidgetOfExactType<Visibility>()?.visible ?? true)';

  /// Fallback when the real hit test ([hitPath]) cannot run: nearest AbsorbPointer / IgnorePointer only.
  static const _hittable = '(!($_el.findAncestorWidgetOfExactType<AbsorbPointer>()?.absorbing ?? false) && '
      '!($_el.findAncestorWidgetOfExactType<IgnorePointer>()?.ignoring ?? false))';

  /// The selected ModalBarrier's `dismissible` flag as a string.
  static const barrierDismissible = '((dynamic w) => w.dismissible.toString())($_el.widget)';

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
      "',\"vid\":'",
      '$_view.viewId.toString()',
      "',\"kb\":'",
      '($_view.viewInsets.bottom / $_view.devicePixelRatio).toString()',
      "'}'",
    ].join(' + ');
    return '((Offset c) => $body)($_ro.localToGlobal($_ro.paintBounds.center))';
  }

  /// The nearest scroll viewport's global rect as `x,y,w,h`, or empty when the node is not in one.
  static const clip = "((RenderAbstractViewport? v) => v == null ? '' : ((RenderBox b) => "
      "b.localToGlobal(Offset.zero).dx.toString() + ',' + b.localToGlobal(Offset.zero).dy.toString() + ',' + "
      "b.size.width.toString() + ',' + b.size.height.toString())(v as RenderBox))"
      '(RenderAbstractViewport.maybeOf($_ro))';

  /// The nearest scrollable around the selected node along one axis as `x,y,w,h,paged`, or empty when there is none; each step up asks the scrollable's own context, so scrollables on the other axis are skipped.
  static String axisScrollable({required bool horizontal}) => '((Element e) { dynamic s = Scrollable.maybeOf(e); '
      'while (s != null && s.axisDirection.index % 2 != ${horizontal ? 1 : 0}) { s = Scrollable.maybeOf(s.context); } '
      "if (s == null) { return ''; } final b = s.context.findRenderObject() as RenderBox; final o = b.localToGlobal(Offset.zero); "
      "return o.dx.toString() + ',' + o.dy.toString() + ',' + b.size.width.toString() + ',' + b.size.height.toString() + ',' + "
      "(s.position.runtimeType.toString().contains('PagePosition') ? '1' : '0'); })"
      '($_el)';

  /// The nearest sliver around the selected node: `overlap,axisDirection,growthDirection,x,y,paintExtent`, where overlap is how much pinned slivers before it paint over its start and x,y is its global origin; empty when it is in no sliver.
  static const leadingCover = '((dynamic r) { while (r != null && r is! RenderSliver) { r = r.parent; } '
      "if (r == null) { return ''; } final c = (r as RenderSliver).constraints; final t = r.getTransformTo(null).getTranslation(); "
      "return c.overlap.toString() + ',' + c.axisDirection.index.toString() + ',' + c.growthDirection.index.toString() + ',' + "
      "t.x.toString() + ',' + t.y.toString() + ',' + (r as RenderSliver).geometry!.paintExtent.toString(); })"
      '($_ro)';

  /// Library that declares `GestureBinding` and imports `HitTestResult` directly, so a real hit test compiles there.
  static const gesturesLibrary = 'flutter/src/gestures/binding.dart';

  /// The selected render object and its global centre, handed to [hitPath] through eval scope.
  static const hitInputs = '<Object>[$_ro, $_ro.localToGlobal($_ro.paintBounds.center)]';

  /// Runs Flutter's hit test at the centre; yields `[targetOnPath, deepestTarget]`.
  static String hitPath(int viewId) =>
      '((HitTestResult r) => [GestureBinding.instance..hitTestInView(r, x[1] as dynamic, $viewId)].isEmpty '
      '? null : <Object?>[r.path.any((e) => identical(e.target, x[0])), '
      'r.path.isEmpty ? null : r.path.first.target])(HitTestResult())';

  /// `hit`, or `miss:<creator>|<inspector ids up the winner's element chain>` in [groupName].
  static String hitVerdict(String groupName) =>
      "(h[0] as bool) ? 'hit' : ((h[1] as RenderObject?)?.debugCreator is DebugCreator "
      "? 'miss:' + ((h[1] as RenderObject).debugCreator as DebugCreator).element.widget.runtimeType.toString() "
      "+ '|' + ((h[1] as RenderObject).debugCreator as DebugCreator).element.debugGetDiagnosticChain()"
      ".take(120).map((e) => WidgetInspectorService.instance.toId(e, '$groupName')).join(',') "
      ": 'miss:')";

  static const _implicitView = 'WidgetsBinding.instance.platformDispatcher.implicitView!';

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
