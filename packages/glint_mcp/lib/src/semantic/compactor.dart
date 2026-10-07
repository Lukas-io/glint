import '../../perception.dart';
import 'semantic_node.dart';

/// Strips framework noise: [expandChild] spills nameless pass-throughs into the
/// parent's child list; [hoistPage] surfaces a [SemanticPage] past app-shell wrappers.
class SceneCompactor {
  const SceneCompactor();

  /// With [imageCandidate], a dissolved node leaves a pending [SemanticImage] ahead of its children for [ImageEnricher] to confirm or drop.
  Iterable<SemanticNode> expandChild(SemanticNode node,
      {bool imageCandidate = false}) {
    if (!_isNoisyPassThrough(node)) return [node];
    if (!imageCandidate) return node.children;
    return [
      SemanticImage(
        glintId: node.glintId,
        isBackground: node.children.isNotEmpty,
        candidate: true,
      ),
      ...node.children,
    ];
  }

  /// Widgets whose `decoration` can paint an image, which dissolving would hide.
  bool paintsDecorationImage(SceneNode node) =>
      _decorationLabels.contains(node.baseLabel);

  static const _decorationLabels = {
    'Container',
    'DecoratedBox',
    'Ink',
    'AnimatedContainer',
  };

  SemanticNode hoistPage(SemanticNode root) {
    final page = _findPage(root);
    return page ?? root;
  }

  /// glintId means "addressable", not "worth surfacing" — stable-id names every
  /// node, so we fold on shape: hintless containers and child-bearing unknowns.
  bool _isNoisyPassThrough(SemanticNode node) {
    if (node is SemanticContainer && node.hint == null) return true;
    if (node is SemanticUnknown && node.children.isNotEmpty) return true;
    if (node is SemanticUnknown && _plumbingLabels.contains(node.label)) {
      return true;
    }
    return false;
  }

  /// Leaf framework plumbing — spacing, semantics, focus — pure noise to agents.
  static const _plumbingLabels = {
    'offstage',
    'Gap',
    'SliverGap',
    '_RawGap',
    'Spacer',
    'SizedBox.expand',
    'SizedBox.shrink',
    'Semantics',
    'ExcludeSemantics',
    'MergeSemantics',
    'BlockSemantics',
    'IndexedSemantics',
    'KeyedSubtree',
    'Focus',
    'FocusScope',
    'MouseRegion',
  };

  SemanticPage? _findPage(SemanticNode node) {
    if (node is SemanticPage) return node;
    for (final c in node.children) {
      final p = _findPage(c);
      if (p != null) return p;
    }
    return null;
  }
}
