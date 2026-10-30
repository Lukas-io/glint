import '../../perception.dart' show CoordinateResolver, Scene, SceneNode;

/// Widget types that take the tap for an input hidden behind them.
const _tappableParents = {'Stack', 'GestureDetector', 'InkWell', 'InkResponse'};

const _inputWidgets = {'TextField', 'TextFormField', 'EditableText', 'CupertinoTextField', 'CupertinoTextFormFieldRow'};

const _maxAncestors = 8;

/// Whether the node with [glintId] is a text input.
bool isInputNode(Scene scene, String glintId) {
  final node = scene.findByGlintId(glintId);
  return node != null && _inputWidgets.contains(node.baseLabel);
}

/// The ancestors of [glintId], nearest first; empty when it is not in the tree.
List<SceneNode> ancestorsOf(Scene scene, String glintId) {
  List<SceneNode>? path;
  void walk(SceneNode n, List<SceneNode> above) {
    if (path != null) return;
    if (n.glintId == glintId && !n.isOffstage) {
      path = above;
      return;
    }
    for (final c in n.children) {
      walk(c, [n, ...above]);
    }
  }

  walk(scene.root, const []);
  return path ?? const [];
}

/// The nearest painted, hittable Stack / GestureDetector / InkWell around the input [glintId] that a person would tap instead, or null when it is not an input or no such ancestor shows.
Future<String?> findVisibleParent(Scene scene, CoordinateResolver resolver, String glintId) async {
  if (!isInputNode(scene, glintId)) return null;
  for (final a in ancestorsOf(scene, glintId).take(_maxAncestors)) {
    final id = a.glintId;
    if (id == null || !_tappableParents.contains(a.baseLabel)) continue;
    if (await _shows(scene, resolver, id)) return id;
    if (a.baseLabel == 'Stack') break;
  }
  return null;
}

Future<bool> _shows(Scene scene, CoordinateResolver resolver, String id) async {
  try {
    final c = await resolver.resolve(scene, id);
    return c.painted && c.hittable && c.centerOnViewport;
  } on Object {
    return false;
  }
}
