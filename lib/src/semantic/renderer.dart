import 'dart:convert';

import 'fold.dart';
import 'semantic_node.dart';
import 'semantic_scene.dart';

abstract class SceneRenderer {
  const SceneRenderer();
  String render(SemanticScene scene);
}

/// A rendered scene plus what the renderer left out, so a caller can write an
/// honest trailer without re-parsing the text.
class RenderResult {
  const RenderResult({
    required this.text,
    required this.runs,
    required this.depthUsed,
  });

  final String text;

  /// Every folded run, in document order.
  final List<FoldedRun> runs;

  /// The depth cap the render used.
  final int depthUsed;

  int get lineCount => text.isEmpty ? 0 : text.trimRight().split('\n').length;
  int get foldedItems =>
      runs.fold(0, (s, r) => s + (r.count - 1));
}

/// Compact indented form for agent prompts. Markers: `*` tappable, `>` typeable,
/// `<>` scrollable, `-` static. Runs of [foldThreshold]+ siblings with the same
/// structure render as the first item in full plus one digest line naming the
/// rest, so a 40-row list costs a few lines, not a few hundred.
class PlainTextSceneRenderer extends SceneRenderer {
  const PlainTextSceneRenderer({this.indent = 2, this.foldThreshold = 4});

  final int indent;
  final int foldThreshold;

  /// Maximum nesting depth before content is suppressed (keeps scenes compact).
  static const int defaultMaxDepth = 8;

  @override
  String render(SemanticScene scene) => renderDetailed(scene).text;

  /// Full render with fold bookkeeping. [fold] off = every sibling in full.
  RenderResult renderDetailed(SemanticScene scene,
      {int? maxDepth, bool fold = true}) {
    final w = _Writer(this, maxDepth ?? defaultMaxDepth, fold);

    // Overlay layers render FIRST — topmost = most interactive.
    if (scene.overlayLayers.isNotEmpty) {
      for (final layer in scene.overlayLayers) {
        w.buf.writeln('--- ${layer.kind} ---');
        for (final node in layer.nodes) {
          w.write(node, depth: 0);
        }
      }
      final blocked = scene.overlayLayers.any((l) => l.isBarriered);
      w.buf.writeln(blocked
          ? '--- screen (blocked by modal — not interactive) ---'
          : '--- screen ---');
    }

    w.write(scene.root, depth: 0);
    if (scene.routeStack.isNotEmpty) {
      w.buf.writeln('route stack:');
      for (final r in scene.routeStack) {
        w.buf.writeln('  - ${r.name}${r.isModal ? ' (modal)' : ''}');
      }
    }
    return RenderResult(text: w.buf.toString(), runs: w.runs, depthUsed: w.maxDepth);
  }

  /// One subtree only — no overlays, no route stack, no folding (an explicit
  /// drill-down means "show me"). [maxDepth] counts from [node] (0 = its line).
  String renderSubtree(SemanticNode node, {int? maxDepth, bool fold = false}) {
    final w = _Writer(this, maxDepth ?? defaultMaxDepth, fold);
    w.write(node, depth: 0);
    return w.buf.toString();
  }
}

class _Writer {
  _Writer(this.r, this.maxDepth, this.fold);

  final PlainTextSceneRenderer r;
  final int maxDepth;
  final bool fold;
  final buf = StringBuffer();
  final runs = <FoldedRun>[];
  final _listStack = <String?>[];

  void write(SemanticNode node, {required int depth, bool inList = false}) {
    if (depth > maxDepth) return;
    _nodeLine(node, depth);
    // A nested page inside a PageView/IndexedStack (SemanticList) is an
    // alternate tab/route — summarise it; the agent navigates to it and
    // re-reads. But an app-shell that nests the real content Scaffold (a
    // page directly under a container) IS the current screen — expand it, or
    // its whole form stays invisible in text mode.
    if (node is SemanticPage && depth > 0 && inList) return;
    final isList = node is SemanticList;
    if (isList) _listStack.add(node.glintId);
    _children(node.children, depth: depth + 1, inList: isList);
    if (isList) _listStack.removeLast();
  }

  void _children(List<SemanticNode> children,
      {required int depth, bool inList = false}) {
    var i = 0;
    while (i < children.length) {
      final run = fold ? detectFoldRun(children, i, threshold: r.foldThreshold) : null;
      if (run == null) {
        write(children[i], depth: depth, inList: inList);
        i++;
        continue;
      }
      final items = children.sublist(run.start, run.end);
      write(items.first, depth: depth, inList: inList);
      _digest(items, depth);
      i = run.end;
    }
  }

  void _digest(List<SemanticNode> items, int depth) {
    final firstId = items.first.glintId;
    final base = firstId == null ? null : glintIdBase(firstId);
    final rest = items.sublist(1);
    final digest = foldDigest(rest, base);
    if (depth <= maxDepth) {
      buf
        ..write(' ' * (depth * r.indent))
        ..write('… ${rest.length} more like it')
        ..write(digest.isEmpty ? '' : ': $digest')
        ..writeln();
    }
    runs.add(FoldedRun(
      base: base ?? items.first.role.name,
      count: items.length,
      listId: _listStack.isEmpty ? null : _listStack.last,
      firstItemId: firstId,
      lastItemId: items.last.glintId,
    ));
  }

  // Labels longer than this are truncated to keep scene text compact.
  static const _maxLabelChars = 40;

  void _nodeLine(SemanticNode node, int depth) {
    buf
      ..write(' ' * (depth * r.indent))
      ..write(_marker(node.affordances))
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

  static String _marker(Set<Affordance> affs) {
    if (affs.contains(Affordance.typeable)) return '>';
    if (affs.contains(Affordance.tappable)) return '*';
    if (affs.contains(Affordance.scrollable)) return '<>';
    return '-';
  }
}

/// JSON form of a scene with the same folding rule as the text renderer: a
/// run's tail becomes one `{"folded": {count, base, items}}` entry.
class JsonSceneRenderer extends SceneRenderer {
  const JsonSceneRenderer({this.pretty = true, this.foldThreshold = 4});

  final bool pretty;
  final int foldThreshold;

  @override
  String render(SemanticScene scene) => encode(toMap(scene));

  String encode(Map<String, Object?> map) => (pretty
          ? const JsonEncoder.withIndent('  ')
          : const JsonEncoder())
      .convert(map);

  /// The scene as a map; [fold] off = plain `toJson`. [maxDepth] drops
  /// `children` below that many levels (a `childCount` stands in).
  Map<String, Object?> toMap(SemanticScene scene,
      {bool fold = true, int? maxDepth}) {
    Map<String, Object?> node(SemanticNode n, int depth) =>
        nodeMap(n, fold: fold, maxDepth: maxDepth, depth: depth);
    return {
      if (scene.overlayLayers.isNotEmpty)
        'overlayLayers': [
          for (final l in scene.overlayLayers)
            {
              'kind': l.kind,
              if (l.isBarriered) 'isBarriered': true,
              'nodes': [for (final n in l.nodes) node(n, 0)],
            }
        ],
      'root': node(scene.root, 0),
      if (scene.routeStack.isNotEmpty)
        'routeStack': scene.routeStack.map((r) => r.toJson()).toList(),
    };
  }

  /// One node as a map, folding runs among its children.
  Map<String, Object?> nodeMap(SemanticNode n,
      {bool fold = true, int? maxDepth, int depth = 0}) {
    final own = n.toJson()..remove('children');
    if (n.children.isEmpty) return own;
    if (maxDepth != null && depth >= maxDepth) {
      return {...own, 'childCount': n.children.length};
    }
    final kids = <Object?>[];
    var i = 0;
    while (i < n.children.length) {
      final run = fold ? detectFoldRun(n.children, i, threshold: foldThreshold) : null;
      if (run == null) {
        kids.add(nodeMap(n.children[i], fold: fold, maxDepth: maxDepth, depth: depth + 1));
        i++;
        continue;
      }
      final items = n.children.sublist(run.start, run.end);
      kids.add(nodeMap(items.first, fold: fold, maxDepth: maxDepth, depth: depth + 1));
      final firstId = items.first.glintId;
      final base = firstId == null ? null : glintIdBase(firstId);
      kids.add({
        'folded': {
          'count': items.length - 1,
          if (base != null) 'base': base,
          'items': [
            for (final item in items.sublist(1))
              {
                if (item.glintId != null) 'glintId': item.glintId,
                if (foldItemLabel(item) != null) 'label': foldItemLabel(item),
              }
          ],
        }
      });
      i = run.end;
    }
    return {...own, 'children': kids};
  }
}
