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
    // Build parent map for active-route detection before hoistPage discards siblings.
    final root = _selectActivePage(classified, scene);
    return SemanticScene(root: root, sourceScene: scene);
  }

  /// Selects the correct active page when multiple [SemanticPage]s are
  /// present (GoRouter / IndexedStack apps). The active page is the one
  /// whose subtree contains the first addressable node in the scene —
  /// since [firstAddressableId] already skips offstage nodes, walking UP
  /// from that node to the first [SemanticPage] ancestor gives us the
  /// active route.
  ///
  /// Falls back to [SceneCompactor.hoistPage] (first page found) when no
  /// first-addressable node is available (empty scene, etc.).
  SemanticNode _selectActivePage(SemanticNode classified, Scene source) {
    final probeId = source.firstAddressableId();
    if (probeId == null) return _compactor.hoistPage(classified);

    // Build parent map over the classified tree.
    final parents = <SemanticNode, SemanticNode>{};
    void link(SemanticNode n) {
      for (final c in n.children) {
        parents[c] = n;
        link(c);
      }
    }
    link(classified);

    // Find the classified node whose glintId matches the probe node.
    SemanticNode? probe;
    for (final n in classified.walk()) {
      if (n.glintId == probeId) { probe = n; break; }
    }
    if (probe == null) return _compactor.hoistPage(classified);

    // Walk up the parent chain to find the OUTERMOST SemanticPage ancestor
    // (not the first/nearest). For GoRouter + PageView apps, the probe leaf
    // is inside an inner tab page (e.g. PickupScreen); the outer route page
    // (HomeWidget) is higher. Taking the outermost gives the active GoRouter
    // route page rather than the active tab within it.
    SemanticNode? outermost;
    var cur = probe;
    while (parents.containsKey(cur)) {
      cur = parents[cur]!;
      if (cur is SemanticPage) outermost = cur;
    }
    if (outermost != null) return outermost;

    // No SemanticPage ancestor found — fall back.
    return _compactor.hoistPage(classified);
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
