import '../../perception.dart';
import 'classifier.dart';
import 'compactor.dart';
import 'semantic_node.dart';
import 'semantic_scene.dart';

/// Module C entry — bottom-up classify + compact + hoist page to root.
class Semanticizer {
  Semanticizer({
    ClassifierRegistry? registry,
    SceneCompactor compactor = const SceneCompactor(),
  })  : _registry = registry ?? ClassifierRegistry.defaults(),
        _compactor = compactor;

  final ClassifierRegistry _registry;
  final SceneCompactor _compactor;

  SemanticScene semanticize(Scene scene) {
    final classified = _classify(scene.root);
    final root = _selectActivePage(classified, scene);
    return SemanticScene(root: root, sourceScene: scene);
  }

  /// Picks the active page among multiple [SemanticPage]s (GoRouter / IndexedStack):
  /// the one whose subtree holds the first addressable node. Since that probe skips
  /// offstage nodes, walking UP to its outermost [SemanticPage] ancestor gives the
  /// active route. Falls back to [SceneCompactor.hoistPage] when no probe exists.
  SemanticNode _selectActivePage(SemanticNode classified, Scene source) {
    final probeId = source.firstAddressableId();
    if (probeId == null) return _compactor.hoistPage(classified);

    final parents = <SemanticNode, SemanticNode>{};
    void link(SemanticNode n) {
      for (final c in n.children) {
        parents[c] = n;
        link(c);
      }
    }
    link(classified);

    SemanticNode? probe;
    for (final n in classified.walk()) {
      if (n.glintId == probeId) { probe = n; break; }
    }
    if (probe == null) return _compactor.hoistPage(classified);

    // Take the OUTERMOST SemanticPage ancestor, not the nearest: in GoRouter +
    // PageView apps the probe leaf sits in an inner tab page while the active
    // route page is higher up — the outermost is the route, not the tab.
    SemanticNode? outermost;
    var cur = probe;
    while (parents.containsKey(cur)) {
      cur = parents[cur]!;
      if (cur is SemanticPage) outermost = cur;
    }
    if (outermost != null) return outermost;
    return _compactor.hoistPage(classified); // no SemanticPage ancestor
  }

  /// Classify a subtree without hoisting to a page root. Used by
  /// [OverlayEnricher] to classify dialog/overlay content that has no
  /// [Scaffold] ancestor.
  SemanticNode classifyNode(SceneNode root) {
    return _classify(root);
  }

  SemanticNode _classify(SceneNode node) {
    final children = node.children
        .map(_classify)
        .expand(_compactor.expandChild)
        .toList(growable: false);
    final classifier = _registry.classifierFor(node);
    return classifier.build(node, children);
  }
}
