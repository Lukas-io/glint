import '../runtime/flutter_runtime.dart';
import 'scene_node.dart';

/// Inspector group identity used by [InspectorClient].
enum InspectorGroup {
  /// Used for tree reads. Disposed by [Scene.dispose] when the read is done.
  read('glint-read-'),

  /// Used by geometry/hit-test resolution where inspectorIds must outlive
  /// the read that produced them.
  resolve('glint-resolve-');

  const InspectorGroup(this.prefix);
  final String prefix;
}

/// Parses inspector trees into typed [SceneNode]s. Talks to the running
/// app via [FlutterRuntime] only — no direct RPC calls. Walks happen
/// server-side.
class InspectorClient {
  InspectorClient(this._runtime);

  final FlutterRuntime _runtime;
  int _seq = 0;

  String nextReadGroup() => '${InspectorGroup.read.prefix}${_seq++}';
  String nextResolveGroup() => '${InspectorGroup.resolve.prefix}${_seq++}';

  Future<SceneNode> readSummaryTree({String? groupName}) => _readTree(
        groupName: groupName ?? nextReadGroup(),
        isSummaryTree: true,
      );

  Future<SceneNode> readFullTree({String? groupName}) => _readTree(
        groupName: groupName ?? nextReadGroup(),
        isSummaryTree: false,
      );

  /// Raw DiagnosticsNode subtree rooted at [inspectorId], including each
  /// node's properties. Used for selective per-node detail reads (input
  /// `controller.text`, icon codepoint, …).
  Future<Map<String, Object?>> getDetailsSubtree({
    required String inspectorId,
    required String groupName,
    int subtreeDepth = 5,
  }) async {
    try {
      return await _runtime.readDetailsSubtree(
        inspectorId: inspectorId,
        groupName: groupName,
        subtreeDepth: subtreeDepth,
      );
    } on Object catch (e) {
      throw InspectorReadError('getDetailsSubtree($inspectorId): $e');
    }
  }

  Future<void> disposeGroup(String groupName) =>
      _runtime.disposeInspectorGroup(groupName);

  Future<SceneNode> _readTree({
    required String groupName,
    required bool isSummaryTree,
  }) async {
    final Map<String, Object?> root;
    try {
      root = await _runtime.readWidgetTree(
        groupName: groupName,
        isSummaryTree: isSummaryTree,
      );
    } on Object catch (e) {
      throw InspectorReadError('readWidgetTree failed: $e');
    }
    return _SceneNodeParser().parse(root);
  }
}

class _SceneNodeParser {
  SceneNode parse(Map<String, Object?> json) =>
      _node(json, depth: 0, indexInParent: -1);

  SceneNode _node(
    Map<String, Object?> json, {
    required int depth,
    required int indexInParent,
  }) {
    final children = <SceneNode>[];
    final raw = json['children'];
    if (raw is List) {
      for (var i = 0; i < raw.length; i++) {
        final c = raw[i];
        if (c is Map) {
          children.add(_node(
            c.cast<String, Object?>(),
            depth: depth + 1,
            indexInParent: i,
          ));
        }
      }
    }
    return SceneNode(
      depth: depth,
      indexInParent: indexInParent,
      description: (json['description'] as String?) ?? '',
      type: (json['type'] as String?) ?? '',
      inspectorId: (json['valueId'] as String?) ?? '',
      locationId: json['locationId'] is int ? json['locationId'] as int : null,
      creationLocation: _creationLocation(json['creationLocation']),
      widgetRuntimeType: json['widgetRuntimeType'] as String?,
      textPreview: json['textPreview'] as String?,
      createdByLocalProject: json['createdByLocalProject'] == true,
      stateful: json['stateful'] == true,
      hasChildren: json['hasChildren'] == true,
      children: children,
    );
  }

  CreationLocation? _creationLocation(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<String, Object?>();
    final file = m['file'] as String?;
    final line = m['line'];
    final column = m['column'];
    if (file == null || line is! int || column is! int) return null;
    return CreationLocation(
      file: file,
      line: line,
      column: column,
      name: m['name'] as String?,
    );
  }
}

class InspectorReadError implements Exception {
  InspectorReadError(this.message);
  final String message;
  @override
  String toString() => 'InspectorReadError: $message';
}
