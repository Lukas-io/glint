import 'dart:convert';

import 'scene_node.dart';

/// Generates the stable, unique, agent-facing symbolic id per §9 of the
/// source-of-truth.
///
/// Rules in order of preference:
/// 1. **Base name.** snake_case of the node's label (`FloatingActionButton`
///    → `floating_action_button`). All ids start as base names.
/// 2. **Descriptive disambiguation.** If two or more nodes share a base
///    name, suffix each with the nearest ancestor whose own base name is
///    unique across the tree. `text` + `text` becomes `text_in_app_bar` +
///    `text_in_column`.
/// 3. **Hash fallback.** If descriptive disambiguation still leaves a
///    collision (e.g. three `text` nodes in the same `Column`), append a
///    short deterministic hash of `(locationId, index path)` — both of
///    which are stable across reads. `text#a3f1`.
///
/// Stability guarantee: same widget at the same source location with the
/// same tree path → same id, every read. No timestamps, no randomness, no
/// inspector-id leakage (inspector ids renumber across reads; we never
/// derive a glint id from them).
class StableIdGenerator {
  /// Walks `root`, assigns `glintId` to every node in the subtree.
  void assignIds(SceneNode root) {
    final all = root.walk().toList();

    // Pass 1: compute base names.
    final base = <SceneNode, String>{};
    for (final n in all) {
      base[n] = _snake(n.label);
    }

    // Pass 2: count base-name collisions to find which names are unique.
    final baseCount = <String, int>{};
    for (final name in base.values) {
      baseCount.update(name, (v) => v + 1, ifAbsent: () => 1);
    }

    // Parent index for walking up.
    final parentOf = <SceneNode, SceneNode>{};
    void link(SceneNode n) {
      for (final c in n.children) {
        parentOf[c] = n;
        link(c);
      }
    }
    link(root);

    // Pass 3: provisional ids with descriptive disambiguation.
    final proposed = <SceneNode, String>{};
    for (final n in all) {
      final name = base[n]!;
      if (baseCount[name] == 1) {
        proposed[n] = name;
        continue;
      }
      // Walk ancestors looking for one whose base name is unique tree-wide.
      // That ancestor becomes our scope tag.
      String? scope;
      var p = parentOf[n];
      while (p != null) {
        final pName = base[p]!;
        if (baseCount[pName] == 1) {
          scope = pName;
          break;
        }
        p = parentOf[p];
      }
      proposed[n] = scope == null ? name : '${name}_in_$scope';
    }

    // Pass 4: detect still-ambiguous ids and add hash suffixes.
    final proposedCount = <String, int>{};
    for (final v in proposed.values) {
      proposedCount.update(v, (k) => k + 1, ifAbsent: () => 1);
    }
    for (final n in all) {
      final id = proposed[n]!;
      if (proposedCount[id] == 1) {
        n.glintId = id;
        continue;
      }
      n.glintId = '$id#${_shortHash(n, root)}';
    }
  }

  /// Path of `indexInParent` from `root` to `node`, root excluded.
  /// Stable across reads.
  List<int> _indexPath(SceneNode node, SceneNode root) {
    final path = <int>[];
    // Rebuild parent map locally so this helper stays usable standalone.
    final parents = <SceneNode, SceneNode>{};
    void rec(SceneNode n) {
      for (final c in n.children) {
        parents[c] = n;
        rec(c);
      }
    }
    rec(root);
    var cur = node;
    while (parents.containsKey(cur)) {
      path.insert(0, cur.indexInParent);
      cur = parents[cur]!;
    }
    return path;
  }

  /// Hashes (locationId, indexPath) into a 4-char base32 suffix. Empty
  /// locationId is fine — the index path alone is enough to keep stability.
  String _shortHash(SceneNode node, SceneNode root) {
    final seed = '${node.locationId ?? ''}:${_indexPath(node, root).join(',')}';
    final bytes = utf8.encode(seed);
    // FNV-1a 32-bit.
    var hash = 0x811C9DC5;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    // Base32, lowercase, padded — keeps suffix human-readable.
    const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
    final buf = StringBuffer();
    var v = hash;
    for (var i = 0; i < 4; i++) {
      buf.write(alphabet[v & 31]);
      v >>= 5;
    }
    return buf.toString();
  }

  /// CamelCase / PascalCase → snake_case. Strips leading underscores,
  /// collapses runs of upper-case (`HTTPSConnection` → `https_connection`),
  /// preserves digits.
  ///
  /// Examples:
  ///   FloatingActionButton → floating_action_button
  ///   Text                 → text
  ///   _ElementTreeNode     → element_tree_node
  ///   MaterialApp          → material_app
  ///   Sliver2DPanel        → sliver2_d_panel  (acceptable v1 quirk)
  static String _snake(String input) {
    if (input.isEmpty) return '_unknown';
    var s = input;
    // Strip leading underscores.
    while (s.startsWith('_') && s.length > 1) {
      s = s.substring(1);
    }
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      final isUpper = c.toUpperCase() == c && c.toLowerCase() != c;
      if (isUpper) {
        // Avoid leading underscore.
        final prevLower = i > 0 && s[i - 1].toLowerCase() == s[i - 1] &&
            s[i - 1] != '_';
        // Run of uppers: split before the last upper when the next char is lower.
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
    // Sanitize: only [a-z0-9_], runs of `_` collapsed.
    result = result.replaceAll(RegExp('[^a-z0-9_]'), '_');
    result = result.replaceAll(RegExp('_+'), '_');
    if (result.startsWith('_')) result = result.substring(1);
    if (result.endsWith('_')) result = result.substring(0, result.length - 1);
    return result.isEmpty ? '_unknown' : result;
  }
}
