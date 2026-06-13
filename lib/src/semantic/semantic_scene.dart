import '../perception/scene_reader.dart';
import 'semantic_node.dart';

/// The Module C output: a [SemanticNode] tree plus pointers back to the
/// raw perception [Scene] for callers that need both surfaces (e.g. the
/// Interactor still uses the raw Scene for hit-testing geometry).
///
/// Navigation-stack awareness is deferred — [routeStack] is a placeholder
/// the perception layer will populate once Module C wires up overlay
/// reading. Kept on the model now so callers don't have to break their
/// API later.
class SemanticScene {
  SemanticScene({
    required this.root,
    required this.sourceScene,
    this.routeStack = const [],
  });

  /// Top of the semantic tree — usually a [SemanticPage] but the
  /// classifier registry's floor guarantees *some* node is always
  /// produced.
  final SemanticNode root;

  /// Underlying perception scene. Callers must still `await
  /// sourceScene.dispose()` when finished — the semantic layer does not
  /// own the inspector group's lifetime.
  final Scene sourceScene;

  /// Topmost-first navigation stack. Empty until Module C overlay
  /// awareness lands.
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

/// One frame in the Overlay-anchored navigation stack — placeholder for
/// the deferred overlay-reading work.
class RouteFrame {
  RouteFrame({required this.name, this.isModal = false});

  final String name;
  final bool isModal;

  Map<String, Object?> toJson() => {
        'name': name,
        if (isModal) 'isModal': true,
      };
}
