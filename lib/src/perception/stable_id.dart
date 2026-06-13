import 'dart:convert';

import 'scene_node.dart';

/// Assigns symbolic glintIds — see §9 of source-of-truth for the algorithm.
/// Same widget at the same source location + tree path → same id every read.
class StableIdGenerator {
  void assignIds(SceneNode root) {
    final pass = _IdPass(root);
    pass.computeBaseNames();
    pass.assignWithDisambiguation();
  }
}

class _IdPass {
  _IdPass(this.root) {
    nodes = root.walk().toList();
    _linkParents(root);
  }

  final SceneNode root;
  late final List<SceneNode> nodes;
  final Map<SceneNode, String> baseName = {};
  final Map<String, int> baseCount = {};
  final Map<SceneNode, SceneNode> parentOf = {};

  void _linkParents(SceneNode n) {
    for (final c in n.children) {
      parentOf[c] = n;
      _linkParents(c);
    }
  }

  void computeBaseNames() {
    for (final n in nodes) {
      final name = _Snake.case_(n.label);
      baseName[n] = name;
      baseCount.update(name, (v) => v + 1, ifAbsent: () => 1);
    }
  }

  void assignWithDisambiguation() {
    final proposed = <SceneNode, String>{};
    for (final n in nodes) {
      final name = baseName[n]!;
      if (baseCount[name] == 1) {
        proposed[n] = name;
        continue;
      }
      final scope = _findUniqueAncestorScope(n);
      proposed[n] = scope == null ? name : '${name}_in_$scope';
    }

    final proposedCount = <String, int>{};
    for (final v in proposed.values) {
      proposedCount.update(v, (k) => k + 1, ifAbsent: () => 1);
    }
    for (final n in nodes) {
      final id = proposed[n]!;
      n.glintId = (proposedCount[id] == 1) ? id : '$id#${_shortHash(n)}';
    }
  }

  String? _findUniqueAncestorScope(SceneNode n) {
    var p = parentOf[n];
    while (p != null) {
      final name = baseName[p]!;
      if (baseCount[name] == 1) return name;
      p = parentOf[p];
    }
    return null;
  }

  String _shortHash(SceneNode node) {
    final seed = '${node.locationId ?? ''}:${_indexPath(node).join(',')}';
    return _Hash.fnvBase32(seed, length: 4);
  }

  List<int> _indexPath(SceneNode node) {
    final path = <int>[];
    var cur = node;
    while (parentOf.containsKey(cur)) {
      path.insert(0, cur.indexInParent);
      cur = parentOf[cur]!;
    }
    return path;
  }
}

class _Snake {
  // PascalCase → snake_case. Strips leading `_`, splits at upper-to-lower
  // boundaries and (run-of-uppers) → next-is-lower transitions.
  //
  // FloatingActionButton → floating_action_button
  // _ElementTreeNode     → element_tree_node
  // HTTPSConnection      → https_connection
  // Sliver2DPanel        → sliver2_d_panel (acceptable v1 quirk)
  static String case_(String input) {
    if (input.isEmpty) return '_unknown';
    var s = input;
    while (s.startsWith('_') && s.length > 1) {
      s = s.substring(1);
    }
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      final isUpper = c.toUpperCase() == c && c.toLowerCase() != c;
      if (isUpper) {
        final prevLower = i > 0 &&
            s[i - 1].toLowerCase() == s[i - 1] &&
            s[i - 1] != '_';
        final nextLower = i + 1 < s.length &&
            s[i + 1].toLowerCase() == s[i + 1] &&
            s[i + 1] != '_';
        final prevUpper = i > 0 &&
            s[i - 1].toUpperCase() == s[i - 1] &&
            s[i - 1].toLowerCase() != s[i - 1];
        if (out.isNotEmpty && (prevLower || (prevUpper && nextLower))) {
          out.write('_');
        }
        out.write(c.toLowerCase());
      } else {
        out.write(c);
      }
    }
    var result = out.toString();
    result = result.replaceAll(RegExp('[^a-z0-9_]'), '_');
    result = result.replaceAll(RegExp('_+'), '_');
    if (result.startsWith('_')) result = result.substring(1);
    if (result.endsWith('_')) result = result.substring(0, result.length - 1);
    return result.isEmpty ? '_unknown' : result;
  }
}

class _Hash {
  static const _base32 = 'abcdefghijklmnopqrstuvwxyz234567';

  static String fnvBase32(String seed, {required int length}) {
    var hash = 0x811C9DC5;
    for (final b in utf8.encode(seed)) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    final buf = StringBuffer();
    var v = hash;
    for (var i = 0; i < length; i++) {
      buf.write(_base32[v & 31]);
      v >>= 5;
    }
    return buf.toString();
  }
}
