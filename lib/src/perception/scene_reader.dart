import 'inspector_client.dart';
import 'scene_node.dart';
import 'stable_id.dart';

/// Module B's top-level read: connect → fetch tree → assign stable ids
/// → return a [Scene]. Caller owns the Scene's lifetime via [Scene.dispose].
class SceneReader {
  SceneReader(this._inspector);

  final InspectorClient _inspector;
  final StableIdGenerator _ids = StableIdGenerator();

  /// User-code-only summary tree. The agent's read surface (Module C / P3).
  Future<Scene> readSummary() => _read(TreeDepth.summary);

  /// Every framework element. Server-internal use only (hit-test,
  /// containment, ancestor walks). Never shipped to the agent verbatim.
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

/// Owns one inspector group plus its SceneNode tree. Disposing releases the
/// inspector's id table in the target VM.
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

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _inspector.disposeGroup(groupName);
  }
}
