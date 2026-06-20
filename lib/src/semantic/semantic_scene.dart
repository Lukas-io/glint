import '../../perception.dart';
import 'semantic_node.dart';

/// Module C output. The Interactor still uses [sourceScene] for the
/// raw hit-test geometry, so callers own its `dispose()`.
class SemanticScene {
  SemanticScene({
    required this.root,
    required this.sourceScene,
    this.routeStack = const [],
    this.overlayLayers = const [],
  });

  final SemanticNode root;
  final Scene sourceScene;

  /// Topmost-first. v0 surfaces only the topmost route; deeper-stack
  /// enumeration is deferred.
  List<RouteFrame> routeStack;

  /// Active overlay layers (dialogs, bottom sheets) above the base screen.
  /// Topmost-first. Empty when no overlay is present.
  List<SemanticOverlayLayer> overlayLayers;

  SemanticNode? findByGlintId(String glintId) {
    for (final n in root.walk()) {
      if (n.glintId == glintId) return n;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        // Overlays first — mirrors the text renderer (topmost = most
        // interactive) and keeps dialog ids addressable in JSON mode.
        if (overlayLayers.isNotEmpty)
          'overlayLayers': overlayLayers.map((l) => l.toJson()).toList(),
        'root': root.toJson(),
        if (routeStack.isNotEmpty)
          'routeStack': routeStack.map((r) => r.toJson()).toList(),
      };
}

class RouteFrame {
  RouteFrame({required this.name, this.isModal = false, this.depth = 1});

  final String name;
  final bool isModal;
  /// Navigator page count — how many routes are in the stack (GoRouter fills
  /// this via the pages API). 1 = at root, >1 = pushed screens above root.
  final int depth;

  Map<String, Object?> toJson() => {
        'name': name,
        if (isModal) 'isModal': true,
        if (depth > 1) 'depth': depth,
      };
}

/// One overlay layer (dialog, bottom sheet, or other modal entry) sitting
/// above the base screen. [isBarriered] is true when a [ModalBarrier] sits
/// between this layer and what is below it — the layer below is painted but
/// not hittable.
class SemanticOverlayLayer {
  SemanticOverlayLayer({
    required this.nodes,
    this.isBarriered = false,
    this.kind = 'dialog',
  });

  final List<SemanticNode> nodes;
  final bool isBarriered;
  final String kind; // 'dialog' | 'bottomSheet' | 'unknown'

  Map<String, Object?> toJson() => {
        'kind': kind,
        if (isBarriered) 'isBarriered': true,
        'nodes': nodes.map((n) => n.toJson()).toList(),
      };
}
