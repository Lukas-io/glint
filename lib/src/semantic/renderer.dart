import 'dart:convert';

import 'semantic_node.dart';
import 'semantic_scene.dart';

abstract class SceneRenderer {
  const SceneRenderer();
  String render(SemanticScene scene);
}

/// Compact indented form for agent prompts. Markers: `*` tappable, `>` typeable,
/// `<>` scrollable, `-` static. Runs of [groupThreshold]+ siblings sharing role
/// and glintId prefix collapse into one summary line.
class PlainTextSceneRenderer extends SceneRenderer {
  const PlainTextSceneRenderer({this.indent = 2, this.groupThreshold = 5});

  final int indent;
  final int groupThreshold;

  @override
  String render(SemanticScene scene) {
    final buf = StringBuffer();

    // Overlay layers render FIRST — topmost = most interactive.
    if (scene.overlayLayers.isNotEmpty) {
      for (final layer in scene.overlayLayers) {
        buf.writeln('--- ${layer.kind} ---');
        for (final node in layer.nodes) {
          _write(buf, node, depth: 0);
        }
      }
      // Annotate base screen.
      final blocked = scene.overlayLayers.any((l) => l.isBarriered);
      buf.writeln(blocked
          ? '--- screen (blocked by modal — not interactive) ---'
          : '--- screen ---');
    }

    _write(buf, scene.root, depth: 0);
    if (scene.routeStack.isNotEmpty) {
      buf.writeln('route stack:');
      for (final r in scene.routeStack) {
        buf.writeln('  - ${r.name}${r.isModal ? ' (modal)' : ''}');
      }
    }
    return buf.toString();
  }

  // Maximum nesting depth before content is suppressed (keeps scenes compact).
  static const _maxDepth = 8;

  /// One subtree only — no overlays, no route stack. [maxDepth] counts from
  /// [node] (0 = just its line).
  String renderSubtree(SemanticNode node, {int? maxDepth}) {
    final buf = StringBuffer();
    _write(buf, node, depth: 0, maxDepth: maxDepth ?? _maxDepth);
    return buf.toString();
  }

  void _write(StringBuffer buf, SemanticNode node,
      {required int depth, bool inList = false, int maxDepth = _maxDepth}) {
    if (depth > maxDepth) return;
    _writeNodeLine(buf, node, depth: depth);
    // A nested page inside a PageView/IndexedStack (SemanticList) is an
    // alternate tab/route — summarise it; the agent navigates to it and
    // re-reads. But an app-shell that nests the real content Scaffold (a
    // page directly under a container) IS the current screen — expand it, or
    // its whole form stays invisible in text mode.
    if (node is SemanticPage && depth > 0 && inList) return;
    _writeChildren(buf, node.children,
        depth: depth + 1, inList: node is SemanticList, maxDepth: maxDepth);
  }

  void _writeChildren(
    StringBuffer buf,
    List<SemanticNode> children, {
    required int depth,
    bool inList = false,
    int maxDepth = _maxDepth,
  }) {
    var i = 0;
    while (i < children.length) {
      final run = _detectRun(children, i);
      if (run != null) {
        _writeRun(buf, children, i, run, depth: depth, maxDepth: maxDepth);
        i += run.length;
      } else {
        _write(buf, children[i],
            depth: depth, inList: inList, maxDepth: maxDepth);
        i += 1;
      }
    }
  }

  // Labels longer than this are truncated to keep scene text compact.
  static const _maxLabelChars = 40;

  void _writeNodeLine(StringBuffer buf, SemanticNode node,
      {required int depth}) {
    buf
      ..write(' ' * (depth * indent))
      ..write(_affordanceMarker(node.affordances))
      ..write(' ')
      ..write(node.role.name);
    // Show glintId only when it adds information beyond the role name.
    final id = node.glintId;
    if (id != null && id != node.role.name) {
      buf
        ..write(' ')
        ..write(id);
    }
    final label = node.displayLabel;
    if (label.isNotEmpty && label != node.role.name) {
      buf
        ..write(' ')
        ..write(_truncate(label));
    }
    buf.writeln();
  }

  /// Multiline labels would break the line-per-node contract — collapse all
  /// whitespace runs to a single space before truncating.
  static String _truncate(String s) {
    final flat = s.replaceAll(RegExp(r'\s+'), ' ');
    return flat.length <= _maxLabelChars
        ? flat
        : '${flat.substring(0, _maxLabelChars - 1)}…';
  }

  void _writeRun(StringBuffer buf, List<SemanticNode> all, int start,
      _SiblingRun run,
      {required int depth, int maxDepth = _maxDepth}) {
    // First item full, rest collapsed: agent gets one concrete example.
    _write(buf, all[start], depth: depth, maxDepth: maxDepth);
    final hidden = run.length - 1;
    if (hidden == 0) return;
    final last = all[start + run.length - 1];
    buf
      ..write(' ' * (depth * indent))
      ..write(_affordanceMarker(last.affordances))
      ..write(' ')
      ..write(last.role.name)
      ..write(' ')
      ..write(run.prefix)
      ..write('#* (')
      ..write(hidden)
      ..write(' more, last: ')
      ..write(last.glintId ?? '')
      ..write(_lastLabelSuffix(last))
      ..writeln(')');
  }

  String _lastLabelSuffix(SemanticNode last) {
    final label = last.displayLabel;
    if (label.isEmpty || label == last.role.name) return '';
    return ' ${_truncate(label)}';
  }

  /// Null when shorter than [groupThreshold] or no shared prefix.
  _SiblingRun? _detectRun(List<SemanticNode> children, int start) {
    final head = children[start];
    if (head.glintId == null) return null;
    if (head.children.isNotEmpty) return null; // only fold leaves
    final prefix = _prefixOf(head.glintId!);
    if (prefix.isEmpty) return null;

    var end = start + 1;
    while (end < children.length) {
      final n = children[end];
      if (n.role != head.role) break;
      if (n.glintId == null) break;
      if (n.children.isNotEmpty) break;
      if (_prefixOf(n.glintId!) != prefix) break;
      end++;
    }
    final length = end - start;
    if (length < groupThreshold) return null;
    return _SiblingRun(prefix: prefix, length: length);
  }

  /// glintIds are `<base>#<hash>` for disambiguated siblings; key on `<base>`.
  String _prefixOf(String id) {
    final hashIdx = id.indexOf('#');
    return hashIdx < 0 ? id : id.substring(0, hashIdx);
  }

  String _affordanceMarker(Set<Affordance> affs) {
    if (affs.contains(Affordance.typeable)) return '>';
    if (affs.contains(Affordance.tappable)) return '*';
    if (affs.contains(Affordance.scrollable)) return '<>';
    return '-';
  }
}

class _SiblingRun {
  const _SiblingRun({required this.prefix, required this.length});
  final String prefix;
  final int length;
}

class JsonSceneRenderer extends SceneRenderer {
  const JsonSceneRenderer({this.pretty = true});

  final bool pretty;

  @override
  String render(SemanticScene scene) {
    final encoder = pretty
        ? const JsonEncoder.withIndent('  ')
        : const JsonEncoder();
    return encoder.convert(scene.toJson());
  }
}
