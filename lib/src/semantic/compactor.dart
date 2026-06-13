import 'semantic_node.dart';

/// Compaction pass that strips the framework noise the classifiers
/// produce wholesale (anonymous [SemanticContainer]s, identity-less
/// [SemanticUnknown] wrappers). Runs in two places:
///
///   - [expandChild]: called while the [Semanticizer] is folding a
///     parent's children list. Nameless pass-throughs spill their own
///     children up so the parent's child list stays flat.
///   - [hoistPage]: a final pass on the top-level node. The agent's
///     reading surface starts at a [SemanticPage]; any
///     framework/app-shell wrappers above it (MaterialApp, CupertinoApp,
///     custom App widgets) get unwrapped.
class SceneCompactor {
  const SceneCompactor();

  /// Bottom-up expansion used by the semanticizer's children fold.
  /// Returns the node itself for "keep as a single child", or its
  /// children for "splice me out".
  Iterable<SemanticNode> expandChild(SemanticNode node) {
    if (_isNoisyPassThrough(node)) return node.children;
    return [node];
  }

  /// Walks down through framework wrappers to surface a [SemanticPage]
  /// as the tree root. Falls back to [root] when no page exists yet
  /// (e.g. splash, single-widget tests).
  SemanticNode hoistPage(SemanticNode root) {
    final page = _findPage(root);
    return page ?? root;
  }

  bool _isNoisyPassThrough(SemanticNode node) {
    // A glintId from Module B says "addressable", not "worth surfacing":
    // stable-id assigns every meaningful node, so leaning on glintId would
    // keep the SizedBox/Center/Padding scaffolding the agent never targets.
    // We fold on shape instead: containers without a hint, and unknown
    // wrappers that have children to spill.
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
