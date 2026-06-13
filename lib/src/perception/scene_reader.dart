import 'inspector_client.dart';
import 'scene_node.dart';
import 'stable_id.dart';

/// Reads the inspector tree, assigns stable ids, returns a [Scene] the
/// caller disposes when done.
class SceneReader {
  SceneReader(this._inspector);

  final InspectorClient _inspector;
  final StableIdGenerator _ids = StableIdGenerator();

  /// User-code-only tree — the agent's reading surface.
  Future<Scene> readSummary() => _read(TreeDepth.summary);

  /// Every framework element. Server-internal only.
  Future<Scene> readFull() => _read(TreeDepth.full);

  Future<Scene> _read(TreeDepth depth) async {
    final groupName = _inspector.nextReadGroup();
    final root = switch (depth) {
      TreeDepth.summary =>
        await _inspector.readSummaryTree(groupName: groupName),
      TreeDepth.full =>
        await _inspector.readFullTree(groupName: groupName),
    };
    _ids.assignIds(root);
    return Scene._(root: root, groupName: groupName, inspector: _inspector);
  }
}

enum TreeDepth { summary, full }

/// One inspector group + its SceneNode tree. Dispose releases the VM-side id table.
class Scene {
  Scene._(
      {required this.root,
      required this.groupName,
      required InspectorClient inspector})
      : _inspector = inspector;

  final SceneNode root;
  final String groupName;
  final InspectorClient _inspector;
  bool _disposed = false;

  SceneNode? findByGlintId(String glintId) {
    for (final n in root.walk()) {
      if (n.glintId == glintId) return n;
    }
    return null;
  }

  /// Pick a node that's safe to probe geometry against. Skips the root
  /// (often a StatelessWidget with no RenderObject) and prefers a leaf —
  /// leaves are guaranteed to have a RenderObject hit-test can resolve.
  String? firstAddressableId() {
    SceneNode? best;
    for (final n in root.walk().skip(1)) {
      if (n.glintId == null || n.glintId!.isEmpty) continue;
      if (n.children.isEmpty) return n.glintId;
      best ??= n;
    }
    return best?.glintId;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _inspector.disposeGroup(groupName);
  }
}
