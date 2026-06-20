import 'semantic_node.dart';

/// Strips framework noise: [expandChild] spills nameless pass-throughs into the
/// parent's child list; [hoistPage] surfaces a [SemanticPage] past app-shell wrappers.
class SceneCompactor {
  const SceneCompactor();

  Iterable<SemanticNode> expandChild(SemanticNode node) {
    if (_isNoisyPassThrough(node)) return node.children;
    return [node];
  }

  SemanticNode hoistPage(SemanticNode root) {
    final page = _findPage(root);
    return page ?? root;
  }

  /// glintId means "addressable", not "worth surfacing" — stable-id names every
  /// node, so we fold on shape: hintless containers and child-bearing unknowns.
  bool _isNoisyPassThrough(SemanticNode node) {
    if (node is SemanticContainer && node.hint == null) return true;
    if (node is SemanticUnknown && node.children.isNotEmpty) return true;
    return false;
  }

  SemanticPage? _findPage(SemanticNode node) {
    if (node is SemanticPage) return node;
    for (final c in node.children) {
      final p = _findPage(c);
      if (p != null) return p;
    }
    return null;
  }
}
