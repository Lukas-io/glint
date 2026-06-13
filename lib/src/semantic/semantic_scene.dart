import '../../perception.dart';
import 'semantic_node.dart';

/// Module C output. The Interactor still uses [sourceScene] for the
/// raw hit-test geometry, so callers own its `dispose()`.
class SemanticScene {
  SemanticScene({
    required this.root,
    required this.sourceScene,
    this.routeStack = const [],
  });

  final SemanticNode root;
  final Scene sourceScene;

  /// Topmost-first. Empty until overlay reading lands.
  final List<RouteFrame> routeStack;

  SemanticNode? findByGlintId(String glintId) {
    for (final n in root.walk()) {
      if (n.glintId == glintId) return n;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        'root': root.toJson(),
        if (routeStack.isNotEmpty)
          'routeStack': routeStack.map((r) => r.toJson()).toList(),
      };
}

class RouteFrame {
  RouteFrame({required this.name, this.isModal = false});

  final String name;
  final bool isModal;

  Map<String, Object?> toJson() => {
        'name': name,
        if (isModal) 'isModal': true,
      };
}
