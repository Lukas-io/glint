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
    final root = selectActivePage(classified);
    return SemanticScene(root: root, sourceScene: scene);
  }

  /// Picks the active page among multiple [SemanticPage]s. Candidates are the
  /// MAXIMAL onstage pages — a page nested inside another (PageView tab, shell
  /// branch) is never a route. Offstage scaffolds already classified as
  /// [SemanticUnknown], so siblings that remain are stacked navigator routes
  /// in overlay order: the LAST is the top of the stack, the screen the user
  /// sees. Falls back to [SceneCompactor.hoistPage] when no page exists.
  SemanticNode selectActivePage(SemanticNode classified) {
    final candidates = <SemanticPage>[];
    void collect(SemanticNode n) {
      if (n is SemanticPage) {
        candidates.add(n);
        return;
      }
      n.children.forEach(collect);
    }

    collect(classified);
    if (candidates.isNotEmpty) return candidates.last;
    return _compactor.hoistPage(classified);
  }

  /// Classify a subtree without hoisting to a page root. Used by
  /// [OverlayEnricher] to classify dialog/overlay content that has no
  /// [Scaffold] ancestor.
  SemanticNode classifyNode(SceneNode root) {
    return _classify(root);
  }

  SemanticNode _classify(SceneNode node) {
    // Offstage subtrees (hidden IndexedStack children, shell branches) must
    // not surface content — the user cannot see or touch them.
    if (node.isOffstage) {
      return SemanticUnknown(glintId: null, label: 'offstage', children: const []);
    }
    final children = node.children
        .map(_classify)
        .expand(_compactor.expandChild)
        .toList(growable: false);
    final classifier = _registry.classifierFor(node);
    return classifier.build(node, children);
  }
}
