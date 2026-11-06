import '../../semantic/fold.dart' show glintIdBase;
import '../../semantic/semantic_node.dart';
import '../../semantic/semantic_scene.dart';

enum AffordanceKind {
  tap('*'),
  type('>'),
  scroll('<>');

  const AffordanceKind(this.marker);

  final String marker;
}

/// One actionable node of a screen; list rows share a [id] (the glintId without its `#hash`) and collapse to one.
class SketchAffordance {
  SketchAffordance({required this.id, required this.sample, required this.kind, this.label});

  final String id;

  /// The full glintId last seen for [id], the one to pass to a tool.
  final String sample;
  final AffordanceKind kind;
  final String? label;

  bool get isRow => sample != id;
}

/// What one scene read says about one screen: where it is, its structural fingerprint and what can be acted on.
class ScreenSketch {
  ScreenSketch({
    required this.route,
    required this.overlayKind,
    required this.fingerprint,
    required this.label,
    required this.affordances,
    this.state = 'loaded',
  });

  /// The normalized route name, empty when the route is unnamed.
  final String route;

  /// `dialog` or `bottomSheet` for an overlay screen, null for a base screen.
  final String? overlayKind;
  final String fingerprint;
  final String label;
  final List<SketchAffordance> affordances;
  final String state;

  bool get isOverlay => overlayKind != null;

  bool offers(String glintId) => affordances.any((a) => a.id == glintIdBase(glintId));
}

/// The base screen of a scene plus the dialog or sheet covering it, if any.
class SceneSketch {
  SceneSketch({required this.base, this.overlay});

  final ScreenSketch base;
  final ScreenSketch? overlay;

  ScreenSketch get top => overlay ?? base;

  SceneSketch withState(String state) => SceneSketch(
        base: base.copyWith(state: state),
        overlay: overlay?.copyWith(state: state),
      );
}

extension on ScreenSketch {
  ScreenSketch copyWith({String? state}) => ScreenSketch(
        route: route,
        overlayKind: overlayKind,
        fingerprint: fingerprint,
        label: label,
        affordances: affordances,
        state: state ?? this.state,
      );
}

const _maxAffordances = 60;
const _maxLabelChars = 28;
const _blockingKinds = {'dialog', 'bottomSheet'};

/// Sketches [scene]; null when it has nothing to fingerprint.
SceneSketch? sketchScene(SemanticScene scene, {String state = 'loaded'}) {
  final route = normalizeRoute(scene.routeStack.isEmpty ? '' : scene.routeStack.first.name);
  final baseNodes = scene.root.walk().toList();
  if (baseNodes.every((n) => n.glintId == null)) return null;
  final base = _sketch(baseNodes, route: route, overlayKind: null, state: state);
  final layer = scene.overlayLayers.where((l) => _blockingKinds.contains(l.kind)).firstOrNull;
  if (layer == null) return SceneSketch(base: base);
  final overlayNodes = [for (final n in layer.nodes) ...n.walk()];
  if (overlayNodes.every((n) => n.glintId == null)) return SceneSketch(base: base);
  return SceneSketch(base: base, overlay: _sketch(overlayNodes, route: route, overlayKind: layer.kind, state: state));
}

ScreenSketch _sketch(List<SemanticNode> nodes, {required String route, String? overlayKind, required String state}) {
  final ids = <String>{
    for (final n in nodes)
      if (n.glintId != null && n.role != SemanticRole.marker) glintIdBase(n.glintId!),
  }.toList()
    ..sort();
  return ScreenSketch(
    route: route,
    overlayKind: overlayKind,
    fingerprint: fnv1a(ids.join('\n')),
    label: _labelOf(nodes, route, overlayKind),
    affordances: _affordancesOf(nodes),
    state: state,
  );
}

List<SketchAffordance> _affordancesOf(List<SemanticNode> nodes) {
  final byKey = <String, SketchAffordance>{};
  for (final n in nodes) {
    final id = n.glintId;
    if (id == null || n.inert == Inert.hidden) continue;
    final kind = _kindOf(n);
    if (kind == null) continue;
    final base = glintIdBase(id);
    final key = '${kind.name}:$base';
    if (byKey.length >= _maxAffordances && !byKey.containsKey(key)) continue;
    final label = id == base && n is! SemanticInput ? _shorten(n.displayLabel) : null;
    byKey[key] = SketchAffordance(id: base, sample: id, kind: kind, label: label == base ? null : label);
  }
  return byKey.values.toList();
}

AffordanceKind? _kindOf(SemanticNode n) {
  if (n.affordances.contains(Affordance.typeable)) return AffordanceKind.type;
  if (n.affordances.contains(Affordance.tappable)) return AffordanceKind.tap;
  if (n.affordances.contains(Affordance.scrollable)) return AffordanceKind.scroll;
  return null;
}

String _labelOf(List<SemanticNode> nodes, String route, String? overlayKind) {
  for (final n in nodes) {
    if (n is SemanticAppBar && (n.title ?? '').trim().isNotEmpty) return _shorten(n.title!);
  }
  for (final n in nodes) {
    if (n is SemanticPage && (n.title ?? '').trim().isNotEmpty) return _shorten(n.title!);
  }
  if (overlayKind != null) {
    for (final n in nodes) {
      if (n is SemanticText && n.content.trim().isNotEmpty) return '$overlayKind "${_shorten(n.content)}"';
    }
    return overlayKind;
  }
  return route.isEmpty ? '(unnamed)' : route;
}

String _shorten(String s) {
  final flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= _maxLabelChars ? flat : '${flat.substring(0, _maxLabelChars - 1)}…';
}

final _idSegment = RegExp(r'^(\d+|[0-9a-fA-F]{8,}(-[0-9a-fA-F]{4,})*)$');

/// The route without its query or fragment, and with numeric or uuid segments replaced by `:id`, so one screen is not split by its arguments.
String normalizeRoute(String route) {
  final path = route.split('?').first.split('#').first;
  if (path.isEmpty) return '';
  return path.split('/').map((s) => _idSegment.hasMatch(s) ? ':id' : s).join('/');
}

/// A stable 32-bit FNV-1a hash of [text] as 8 hex digits (String.hashCode changes between runs).
String fnv1a(String text) {
  var h = 0x811c9dc5;
  for (final c in text.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}
