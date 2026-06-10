import 'package:vm_service/vm_service.dart';

import '../vm/vm_client.dart';
import 'scene_node.dart';

/// Talks to `ext.flutter.inspector.*` service extensions and returns
/// typed [SceneNode] trees. No in-VM evaluate; the walk is server-side.
///
/// Two depths supported:
/// - [readSummaryTree] — the user-code-only tree. Compact (10–100 nodes for
///   a typical screen). What the agent-facing semantic layer (P3) reads.
/// - [readFullTree] — every framework element. Large (thousands of nodes).
///   What Module B uses internally for hit-test / containment / occlusion
///   reasoning. Never shipped to the agent verbatim.
///
/// Inspector "group" lifetime: every read uses a fresh group name so the
/// inspector's id table can be disposed cleanly between reads. Geometry
/// resolution (P1 step 5) and hit testing (P1 step 6) use a separate,
/// longer-lived group because they need the inspectorIds to still resolve.
class InspectorClient {
  InspectorClient(this._vm);

  final VmClient _vm;

  static const String _kReadGroupPrefix = 'glint-read-';
  static const String _kResolveGroupPrefix = 'glint-resolve-';

  int _seq = 0;

  String nextReadGroup() => '$_kReadGroupPrefix${_seq++}';
  String nextResolveGroup() => '$_kResolveGroupPrefix${_seq++}';

  /// Reads the summary tree (user-created widgets only) with text previews.
  /// `groupName` keeps the inspector's id table alive for follow-up
  /// resolution; caller is responsible for [disposeGroup] when done.
  Future<SceneNode> readSummaryTree({String? groupName}) {
    return _readTree(
      groupName: groupName ?? nextReadGroup(),
      isSummaryTree: true,
      withPreviews: true,
      fullDetails: false,
    );
  }

  /// Reads the full element tree (every framework node) with text previews.
  /// Caller owns the group.
  Future<SceneNode> readFullTree({String? groupName}) {
    return _readTree(
      groupName: groupName ?? nextReadGroup(),
      isSummaryTree: false,
      withPreviews: true,
      // fullDetails=false keeps the payload at the structural level —
      // properties (constraint, color, …) blow the JSON up by 10x and we
      // don't use them in P1.
      fullDetails: false,
    );
  }

  /// Disposes a group's inspector id table. Cheap RPC; safe even if the
  /// group was never created.
  Future<void> disposeGroup(String groupName) async {
    try {
      await _vm.service.callServiceExtension(
        'ext.flutter.inspector.disposeGroup',
        isolateId: _vm.flutterIsolateId,
        args: {'groupName': groupName},
      );
    } on Object {
      // disposeGroup is best-effort cleanup.
    }
  }

  Future<SceneNode> _readTree({
    required String groupName,
    required bool isSummaryTree,
    required bool withPreviews,
    required bool fullDetails,
  }) async {
    // §10 access-path pin: getRootWidgetTree is primary on Flutter 3.44+.
    // Two fallback methods exist (getRootWidgetSummaryTreeWithPreviews,
    // getRootWidgetSummaryTree) but only matter for summary reads on older
    // releases. P0 confirmed the primary exists on the supported floor.
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
    return _buildSceneNode(root, depth: 0, indexInParent: -1);
  }

  SceneNode _buildSceneNode(
    Map<String, Object?> json, {
    required int depth,
    required int indexInParent,
  }) {
    final children = <SceneNode>[];
    final rawChildren = json['children'];
    if (rawChildren is List) {
      for (var i = 0; i < rawChildren.length; i++) {
        final raw = rawChildren[i];
        if (raw is Map) {
          children.add(_buildSceneNode(
            raw.cast<String, Object?>(),
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
      creationLocation: _parseCreationLocation(json['creationLocation']),
      widgetRuntimeType: json['widgetRuntimeType'] as String?,
      textPreview: json['textPreview'] as String?,
      createdByLocalProject: json['createdByLocalProject'] == true,
      stateful: json['stateful'] == true,
      hasChildren: json['hasChildren'] == true,
      children: children,
    );
  }

  CreationLocation? _parseCreationLocation(Object? raw) {
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
