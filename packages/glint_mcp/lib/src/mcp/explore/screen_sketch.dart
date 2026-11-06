import '../../semantic/fold.dart' show detectFoldRun, glintIdBase;
import '../../semantic/semantic_node.dart';
import '../../semantic/semantic_scene.dart';

enum AffordanceKind {
  tap('*'),
  type('>'),
  scroll('<>');

  const AffordanceKind(this.marker);

  final String marker;
}

/// One actionable node of a screen; a list row shares its [key] with the rows folded like it, any other control has its own.
class SketchAffordance {
  SketchAffordance({required this.key, required this.sample, required this.kind, this.label, this.isRow = false});

  /// What makes this control the same one on the next read: the glintId base for a row, else base plus its label (full id with no label).
  final String key;

  /// The full glintId last seen for [key], the one to pass to a tool.
  final String sample;
  final AffordanceKind kind;
  final String? label;
  final bool isRow;
}

/// What one scene read says about one screen: where it is, its structural fingerprint and what can be acted on.
class ScreenSketch {
  ScreenSketch({
    required this.route,
    required this.overlayKind,
    required this.fingerprint,
    required this.label,
    required this.affordances,
    this.keyById = const {},
    this.state = 'loaded',
  });

  /// The normalized route name, empty when the route is unnamed.
  final String route;

  /// `dialog` or `bottomSheet` for an overlay screen, null for a base screen.
  final String? overlayKind;

  /// A hash of the screen's tappable, typeable and scrollable controls (list rows once, text ignored).
  final String fingerprint;
  final String label;
  final List<SketchAffordance> affordances;

  /// The affordance key of every actionable glintId seen, even past the affordance cap.
  final Map<String, String> keyById;
  final String state;

  bool get isOverlay => overlayKind != null;

  bool offers(String glintId) => keyById.containsKey(glintId);

  String? keyFor(String glintId) => keyById[glintId];
}

/// The base screen of a scene plus the dialog or sheet covering it, if any.
class SceneSketch {
  SceneSketch({required this.base, this.overlay});

  final ScreenSketch base;
  final ScreenSketch? overlay;

  ScreenSketch get top => overlay ?? base;
}

const _maxAffordances = 60;
const _maxLabelChars = 28;
const _blockingKinds = {'dialog', 'bottomSheet'};

/// Sketches [scene]; null when it has nothing to fingerprint.
SceneSketch? sketchScene(SemanticScene scene, {String state = 'loaded'}) {
  final route = normalizeRoute(scene.routeStack.isEmpty ? '' : scene.routeStack.first.name);
  if (scene.root.walk().every((n) => n.glintId == null)) return null;
  final base = _sketch([scene.root], route: route, overlayKind: null, state: state);
  final layer = scene.overlayLayers.where((l) => _blockingKinds.contains(l.kind)).firstOrNull;
  if (layer == null) return SceneSketch(base: base);
  if (layer.nodes.every((r) => r.walk().every((n) => n.glintId == null))) return SceneSketch(base: base);
  return SceneSketch(base: base, overlay: _sketch(layer.nodes, route: route, overlayKind: layer.kind, state: state));
}

ScreenSketch _sketch(List<SemanticNode> roots, {required String route, String? overlayKind, required String state}) {
  final nodes = _collect(roots);
  final affordances = _affordancesOf(nodes);
  return ScreenSketch(
    route: route,
    overlayKind: overlayKind,
    fingerprint: fnv1a(_structure(nodes).join('\n')),
    label: _labelOf([for (final n in nodes) n.node], route, overlayKind),
    affordances: affordances.list,
    keyById: affordances.keyById,
    state: state,
  );
}

class _Collected {
  _Collected(this.node, this.inRow);

  final SemanticNode node;
  final bool inRow;
}

/// Every node under [roots], marking those inside a run get_scene folds (4+ siblings of one shape) as list rows.
List<_Collected> _collect(List<SemanticNode> roots) {
  final out = <_Collected>[];
  void visit(SemanticNode n, bool inRow) {
    out.add(_Collected(n, inRow));
    var i = 0;
    while (i < n.children.length) {
      final run = detectFoldRun(n.children, i);
      if (run == null) {
        visit(n.children[i], inRow);
        i++;
        continue;
      }
      for (var j = run.start; j < run.end; j++) {
        visit(n.children[j], true);
      }
      i = run.end;
    }
  }

  for (final r in roots) {
    visit(r, false);
  }
  return out;
}

/// The actionable shape of a screen: each distinct control once, list rows once per kind and id base, text ignored.
List<String> _structure(List<_Collected> nodes) {
  final rows = <String>{};
  final singles = <String>[];
  for (final c in nodes) {
    final n = c.node;
    if (n.glintId == null || n.role == SemanticRole.marker || n.inert == Inert.hidden) continue;
    final kind = _kindOf(n);
    if (kind == null) continue;
    final entry = '${kind.name}:${glintIdBase(n.glintId!)}';
    if (c.inRow) {
      rows.add(entry);
    } else {
      singles.add(entry);
    }
  }
  return [...rows, ...singles]..sort();
}

({List<SketchAffordance> list, Map<String, String> keyById}) _affordancesOf(List<_Collected> nodes) {
  final byKey = <String, SketchAffordance>{};
  final keyById = <String, String>{};
  for (final c in nodes) {
    final n = c.node;
    final id = n.glintId;
    if (id == null || n.inert == Inert.hidden) continue;
    final kind = _kindOf(n);
    if (kind == null) continue;
    final key = c.inRow ? glintIdBase(id) : _controlKey(n, id);
    keyById[id] = key;
    final slot = '${kind.name}:$key';
    if (byKey.length >= _maxAffordances && !byKey.containsKey(slot)) continue;
    final label = c.inRow || n is SemanticInput ? null : _shorten(n.displayLabel);
    byKey[slot] = SketchAffordance(
      key: key,
      sample: id,
      kind: kind,
      label: label == null || label.isEmpty || label == key ? null : label,
      isRow: c.inRow,
    );
  }
  return (list: byKey.values.toList(), keyById: keyById);
}

/// Base id plus normalized visible label, since the `#hash` of a lone control may change between reads.
String _controlKey(SemanticNode n, String id) {
  final label = _identityLabel(n);
  return label == null ? id : '${glintIdBase(id)}|$label';
}

String? _identityLabel(SemanticNode n) {
  final raw = switch (n) {
    SemanticButton b => b.label,
    SemanticInput i => i.hint,
    SemanticText t => t.content,
    _ => n.displayLabel,
  };
  final flat = _shorten((raw ?? '').toLowerCase());
  return flat.isEmpty ? null : flat;
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
