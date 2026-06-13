import 'dart:convert';

import 'semantic_node.dart';
import 'semantic_scene.dart';

/// Strategy for serialising a [SemanticScene] for a downstream consumer.
///
/// Two implementations ship:
///
///   - [PlainTextSceneRenderer] — the agent's reading surface. Indented
///     bullet list, leading affordance marker, role + glintId + label.
///   - [JsonSceneRenderer] — structured payload for MCP tool returns.
///
/// Consumers can subclass [SceneRenderer] to plug in app-specific
/// surfaces (Markdown table for a doc tool, YAML for tests, etc.).
abstract class SceneRenderer {
  const SceneRenderer();
  String render(SemanticScene scene);
}

/// Compact indented format tuned for token-efficient agent prompts.
///
/// Format per line: `<indent><marker> <role> <glintId> <label>` with
/// brackets dropped and runs of identical-shape siblings collapsed into
/// a single summary line. Examples:
///
///     - page scaffold
///       <> list single_child_scroll_view
///         - column column_in_single_child_scroll_view
///           - text text_in_single_child_scroll_view#tso5 "..."
///           - text text_in_single_child_scroll_view#* (30 more rows)
///       * button floating_action_button
///
/// The marker mirrors [Affordance]: `*` tappable, `>` typeable, `<>`
/// scrollable, `-` static. Runs trigger when [groupThreshold]+ siblings
/// share the same role and a non-trivial glintId prefix.
class PlainTextSceneRenderer extends SceneRenderer {
  const PlainTextSceneRenderer({this.indent = 2, this.groupThreshold = 5});

  final int indent;
  final int groupThreshold;

  @override
  String render(SemanticScene scene) {
    final buf = StringBuffer();
    _write(buf, scene.root, depth: 0);
    if (scene.routeStack.isNotEmpty) {
      buf.writeln('route stack:');
      for (final r in scene.routeStack) {
        buf.writeln('  - ${r.name}${r.isModal ? ' (modal)' : ''}');
      }
    }
    return buf.toString();
  }

  void _write(StringBuffer buf, SemanticNode node, {required int depth}) {
    _writeNodeLine(buf, node, depth: depth);
    _writeChildren(buf, node.children, depth: depth + 1);
  }

  void _writeChildren(
    StringBuffer buf,
    List<SemanticNode> children, {
    required int depth,
  }) {
    var i = 0;
    while (i < children.length) {
      final run = _detectRun(children, i);
      if (run != null) {
        _writeRun(buf, children, i, run, depth: depth);
        i += run.length;
      } else {
        _write(buf, children[i], depth: depth);
        i += 1;
      }
    }
  }

  void _writeNodeLine(StringBuffer buf, SemanticNode node,
      {required int depth}) {
    buf
      ..write(' ' * (depth * indent))
      ..write(_affordanceMarker(node.affordances))
      ..write(' ')
      ..write(node.role.name);
    if (node.glintId != null) {
      buf
        ..write(' ')
        ..write(node.glintId);
    }
    final label = node.displayLabel;
    if (label.isNotEmpty && label != node.role.name) {
      buf
        ..write(' ')
        ..write(label);
    }
    buf.writeln();
  }

  void _writeRun(StringBuffer buf, List<SemanticNode> all, int start,
      _SiblingRun run,
      {required int depth}) {
    // Emit the first item normally so the agent sees one concrete example
    // (full id + label), then a single collapsed summary line.
    _write(buf, all[start], depth: depth);
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
    return ' $label';
  }

  /// Detects a run of identical-role children at [start] sharing a
  /// non-trivial glintId prefix. Returns null when the run is shorter
  /// than [groupThreshold] or no prefix is shared.
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

  /// glintIds look like `<base>#<hash>` for disambiguated siblings; the
  /// run-detector keys off the `<base>` portion.
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
