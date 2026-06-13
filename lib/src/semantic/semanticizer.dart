import '../perception/scene_node.dart';
import '../perception/scene_reader.dart';
import 'classifier.dart';
import 'compactor.dart';
import 'semantic_node.dart';
import 'semantic_scene.dart';

/// Module C entry point. Turns a Module B [Scene] into a
/// [SemanticScene] the agent can read.
///
/// The pipeline is intentionally small:
///   1. Bottom-up walk; each [SceneNode] is handed to the
///      [ClassifierRegistry] which picks the first matching provider.
///   2. Children fold through [SceneCompactor.expandChild] so noisy
///      pass-throughs (anonymous containers, identity-less unknowns)
///      don't pollute the parent's child list.
///   3. After the root is classified, [SceneCompactor.hoistPage]
///      surfaces the [SemanticPage] above any framework / app-shell
///      wrappers.
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
    final root = _compactor.hoistPage(classified);
    return SemanticScene(root: root, sourceScene: scene);
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
