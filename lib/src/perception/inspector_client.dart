import 'package:vm_service/vm_service.dart';

import '../vm/vm_client.dart';
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

/// Talks to `ext.flutter.inspector.*` and returns typed [SceneNode] trees.
/// Walks happen server-side; no in-VM evaluate.
class InspectorClient {
  InspectorClient(this._vm);

  final VmClient _vm;
  int _seq = 0;

  String nextReadGroup() => '${InspectorGroup.read.prefix}${_seq++}';
  String nextResolveGroup() => '${InspectorGroup.resolve.prefix}${_seq++}';

  Future<SceneNode> readSummaryTree({String? groupName}) => _readTree(
        groupName: groupName ?? nextReadGroup(),
        isSummaryTree: true,
        withPreviews: true,
        fullDetails: false,
      );

  // fullDetails=false: omits per-node DiagnosticsProperty serialisation,
  // which blows the JSON up ~10× without anything Module B uses today.
  Future<SceneNode> readFullTree({String? groupName}) => _readTree(
        groupName: groupName ?? nextReadGroup(),
        isSummaryTree: false,
        withPreviews: true,
        fullDetails: false,
      );

  /// Returns the raw DiagnosticsNode subtree rooted at [inspectorId],
  /// including each node's properties. Used for selective per-node
  /// detail reads (e.g. extracting an input's `controller.text`).
  Future<Map<String, Object?>> getDetailsSubtree({
    required String inspectorId,
    required String groupName,
    int subtreeDepth = 5,
  }) async {
    final Response resp;
    try {
      resp = await _vm.service.callServiceExtension(
        'ext.flutter.inspector.getDetailsSubtree',
        isolateId: _vm.flutterIsolateId,
        args: {
          'arg': inspectorId,
          'objectGroup': groupName,
          'subtreeDepth': subtreeDepth.toString(),
        },
      );
    } on RPCError catch (e) {
      throw InspectorReadError(
        'getDetailsSubtree($inspectorId) failed (${e.code}): '
        '${e.details ?? e.message}',
        cause: e,
      );
    }
    final result = (resp.json?['result'] as Map?)?.cast<String, Object?>();
    if (result == null) {
      throw InspectorReadError(
        'getDetailsSubtree returned a response without a `result` map: '
        '${resp.json}',
      );
    }
    return result;
  }

  /// Drops the group's inspector id table. Best-effort cleanup.
  Future<void> disposeGroup(String groupName) async {
    try {
      await _vm.service.callServiceExtension(
        'ext.flutter.inspector.disposeGroup',
        isolateId: _vm.flutterIsolateId,
        args: {'groupName': groupName},
      );
    } on Object {
      // ignore — dispose is best effort
    }
  }

  Future<SceneNode> _readTree({
    required String groupName,
    required bool isSummaryTree,
    required bool withPreviews,
    required bool fullDetails,
  }) async {
    // §10 pin: getRootWidgetTree is primary on Flutter 3.44+.
    final Response resp;
    try {
      resp = await _vm.service.callServiceExtension(
        'ext.flutter.inspector.getRootWidgetTree',
        isolateId: _vm.flutterIsolateId,
        args: {
          'groupName': groupName,
          'isSummaryTree': isSummaryTree.toString(),
          'withPreviews': withPreviews.toString(),
          'fullDetails': fullDetails.toString(),
        },
      );
    } on RPCError catch (e) {
      throw InspectorReadError(
        'getRootWidgetTree RPC failed (${e.code}): ${e.details ?? e.message}',
        cause: e,
      );
    }
    final root = (resp.json?['result'] as Map?)?.cast<String, Object?>();
    if (root == null) {
      throw InspectorReadError(
        'getRootWidgetTree returned a response without a `result` map: '
        '${resp.json}',
      );
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
  InspectorReadError(this.message, {this.cause});
  final String message;
  final Object? cause;
  @override
  String toString() => 'InspectorReadError: $message';
}
