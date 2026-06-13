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
