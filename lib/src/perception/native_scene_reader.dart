import 'dart:convert';
import 'dart:io';

import 'scene_node.dart';
import 'scene_reader.dart';

/// Reads native surface content via glint-iossim `ax-snapshot`. Returns a
/// parsed scene when the Simulator exposes an AX tree (needs macOS a11y
/// permission), else a sentinel scene flagging an unreadable native surface.
class NativeSceneReader {
  NativeSceneReader({required this.udid, required this.bridgePath});

  final String udid;
  final String bridgePath;

  /// Read the native surface. Always returns a non-null [Scene]; uses a
  /// sentinel scene when the AX tree is unavailable.
  Future<Scene> readSnapshot() async {
    try {
      final result = await Process.run(bridgePath, ['ax-snapshot', udid]);
      if (result.exitCode != 0) return _nativeSentinel();
      final jsonStr = (result.stdout as String).trim();
      if (jsonStr.isEmpty || jsonStr.startsWith('ax-snapshot:')) {
        return _nativeSentinel();
      }
      final elements = jsonDecode(jsonStr) as List<dynamic>;
      return _buildScene(elements);
    } on Object {
      return _nativeSentinel();
    }
  }

  // ── internals ─────────────────────────────────────────────────────────────

  Scene _nativeSentinel() {
    // Placeholder scene signalling a native surface is up so the agent can
    // wait, dismiss it, or tap by physical coordinates.
    final root = SceneNode(
      depth: 0,
      indexInParent: -1,
      description: '_NativeSurface',
      type: 'native',
      inspectorId: '',
      createdByLocalProject: false,
    );
    root.glintId = '_native_surface';
    return Scene.native(root: root);
  }

  Scene _buildScene(List<dynamic> elements) {
    final root = SceneNode(
      depth: 0,
      indexInParent: -1,
      description: '_NativeRoot',
      type: 'native',
      inspectorId: '',
      createdByLocalProject: false,
    );
    root.glintId = '_native_root';
    root.children = elements
        .whereType<Map<String, Object?>>()
        .map((e) => _parseElement(e, depth: 1))
        .toList();
    return Scene.native(root: root);
  }

  SceneNode _parseElement(Map<String, Object?> e, {required int depth}) {
    final role = e['role'] as String? ?? 'AXUnknown';
    final label = e['label'] as String? ?? '';
    final value = e['value'] as String? ?? '';
    final ident = e['ident'] as String? ?? '';
    final enabled = e['enabled'] as bool? ?? false;
    final frame = e['frame'] as Map<String, Object?>?;

    // Stable glintId: prefer ident, fall back to role+label slug.
    final baseId = ident.isNotEmpty
        ? _slug(ident)
        : _slug('${role}_$label'.toLowerCase().replaceAll(' ', '_'));

    final node = SceneNode(
      depth: depth,
      indexInParent: 0,
      description: role,
      type: 'native',
      inspectorId: '',
      widgetRuntimeType: role,
      textPreview: value.isNotEmpty ? value : (label.isNotEmpty ? label : null),
      createdByLocalProject: true, // treat as addressable
    );
    node.glintId = baseId;

    // Stash the AX frame for geometry resolution.
    if (frame != null) {
      node.axFrame = (
        x: (frame['x'] as num?)?.toDouble() ?? 0,
        y: (frame['y'] as num?)?.toDouble() ?? 0,
        w: (frame['w'] as num?)?.toDouble() ?? 0,
        h: (frame['h'] as num?)?.toDouble() ?? 0,
      );
      node.isNativeEnabled = enabled;
    }

    final kids = e['children'];
    if (kids is List) {
      node.children = kids
          .whereType<Map<String, Object?>>()
          .map((c) => _parseElement(c, depth: depth + 1))
          .toList();
    }
    return node;
  }

  String _slug(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');

  /// Compact text representation of the native scene for agent consumption.
  /// Enabled elements are marked `*`, disabled elements are marked `-`.
  static String renderAsText(Scene scene) {
    final buf = StringBuffer();
    _renderNode(buf, scene.root, depth: 0);
    return buf.toString();
  }

  static void _renderNode(StringBuffer buf, SceneNode node, {required int depth}) {
    if (depth > 6) return;
    final id = node.glintId ?? '';
    if (id.isNotEmpty && !id.startsWith('_native')) {
      final label = node.textPreview ?? node.label;
      final marker = (node.isNativeEnabled ?? false) ? '*' : '-';
      buf
        ..write('  ' * depth)
        ..writeln('$marker native $id $label');
    }
    for (final child in node.children) {
      _renderNode(buf, child, depth: depth + 1);
    }
  }
}
