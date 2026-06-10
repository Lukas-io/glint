import 'inspector_client.dart';
import 'scene_node.dart';
import 'stable_id.dart';

/// Module B's top-level read.
///
/// One call: connect → read → assign stable ids → return the SceneNode tree.
/// Callers own the inspector group's lifetime via [Scene.dispose].
class SceneReader {
  SceneReader(this._inspector);

  final InspectorClient _inspector;
  final StableIdGenerator _ids = StableIdGenerator();

  /// Reads the user-code-only summary tree, assigns stable ids, returns
  /// the tree handle. The caller is responsible for calling `dispose` on
  /// the returned [Scene] when done so the inspector's id table can be
  /// released — keeping it alive too long is harmless but wastes memory
  /// in the target VM.
  Future<Scene> readSummary() async {
    final groupName = _inspector.nextReadGroup();
    final root = await _inspector.readSummaryTree(groupName: groupName);
    _ids.assignIds(root);
    return Scene._(root: root, groupName: groupName, inspector: _inspector);
  }

  /// Reads the full element tree. Same shape as [readSummary] but includes
  /// every framework node — useful for hit-test reasoning and ancestor
  /// walks that need framework chrome (Overlay, RenderView, etc.). Not
  /// what the agent reads.
  Future<Scene> readFull() async {
    final groupName = _inspector.nextReadGroup();
    final root = await _inspector.readFullTree(groupName: groupName);
    _ids.assignIds(root);
    return Scene._(root: root, groupName: groupName, inspector: _inspector);
  }
}

/// Owns one inspector group and the SceneNode tree built from it.
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

  /// Look up a node by its stable id. O(n).
  SceneNode? findByGlintId(String glintId) {
    for (final n in root.walk()) {
      if (n.glintId == glintId) return n;
    }
    return null;
  }

  /// Drops the inspector's id table for this read. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _inspector.disposeGroup(groupName);
  }
}
