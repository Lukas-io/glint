import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../observability.dart' show StateObserver, resolveDataDir;
import '../../semantic/semantic_scene.dart';
import '../app_session.dart';
import '../envelope.dart';
import 'graph.dart';
import 'screen_sketch.dart';

const _edgeTools = {'tap', 'long_press', 'swipe', 'drag', 'pinch', 'type', 'key', 'scroll', 'hardware_button'};
const _scrollTools = {'scroll'};

class _Pending {
  _Pending(this.key, this.deviceId, this.platform, this.before, this.after);

  final String key;
  final String deviceId;
  final String platform;
  final SceneSketch before;
  final SceneSketch after;
}

/// Keeps one persistent [ExploreGraph] per app, fed by the scenes and action replies glint already produces.
class ExploreRecorder {
  ExploreRecorder({String? dir, this.debounce = const Duration(seconds: 2), DateTime Function()? clock})
      : _dir = dir ?? '${resolveDataDir()}/explore',
        _clock = clock ?? DateTime.now;

  final String _dir;
  final Duration debounce;
  final DateTime Function() _clock;
  final Map<String, ExploreGraph> _graphs = {};
  final Map<String, String> _cursor = {};
  final Set<String> _dirty = {};
  Timer? _timer;
  _Pending? _pending;

  /// The id an app's graph is stored under: bundle id or package, else its name.
  static String keyOf(AppSession app) => app.bundleId ?? app.package ?? app.displayName ?? app.label;

  String _file(String key) => '$_dir/${key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.json';

  ExploreGraph graphFor(String key) => _graphs.putIfAbsent(key, () => _load(key));

  ExploreGraph _load(String key) {
    final file = File(_file(key));
    try {
      if (file.existsSync()) {
        final json = jsonDecode(file.readAsStringSync());
        if (json is Map && json['v'] == ExploreGraph.version) return ExploreGraph.fromJson(key, json.cast());
      }
    } on Object {
      return ExploreGraph(key);
    }
    return ExploreGraph(key);
  }

  /// The screen [app]'s device is on according to the latest read or action, if any.
  ExploreScreen? current(AppSession app) {
    final key = keyOf(app);
    final id = _cursor['$key@${app.id}'];
    return id == null ? null : graphFor(key).screens[id];
  }

  /// A full-screen scene read: counts a visit when it shows a different screen than the last one.
  void noteScene(AppSession app, SemanticScene scene) {
    if (app.deviceMode) return;
    try {
      final state = const StateObserver().observe(scene).name;
      if (state == 'loading') return;
      final sketch = sketchScene(scene, state: state);
      if (sketch == null) return;
      _arrive(graphFor(keyOf(app)), keyOf(app), app, sketch);
      _markDirty(keyOf(app));
    } on Object {
      return;
    }
  }

  /// The pre-action and post-action sketches of the gesture now finishing; [completeCall] turns them into an edge.
  void noteAction(AppSession? app, SceneSketch? before, SceneSketch? after) {
    _pending = null;
    if (app == null || app.deviceMode || before == null || after == null || after.top.state == 'loading') return;
    _pending = _Pending(keyOf(app), app.id, app.platform.name, before, after);
  }

  /// Called when a tool call ends: records the edge its gesture made, or its failure, on the graph.
  void completeCall(AppSession? app, String tool, Map<String, Object?>? args, StructuredResponse response) {
    final pending = _pending;
    _pending = null;
    if (!_edgeTools.contains(tool)) return;
    try {
      final target = _targetOf(tool, args ?? const {});
      if (target == null) return;
      final errorKind = response.isError ? (response.data?['errorKind'] as String?) : null;
      final category = response.data?['changeCategory'] as String?;
      if (pending == null) {
        if (errorKind != null && app != null) _recordFailure(app, tool, target, errorKind);
        return;
      }
      final graph = graphFor(pending.key);
      final platform = pending.platform;
      final now = _clock();
      final before = _Arrival(graph, pending.key, pending.deviceId, platform, now, _cursor)..arrive(pending.before);
      final fromSketch = _sourceSketch(pending.before, target.glintId);
      final from = fromSketch.isOverlay ? before.top! : before.base!;
      final sameScreen = _scrollTools.contains(tool) &&
          pending.after.base.route == pending.before.base.route &&
          pending.after.overlay?.overlayKind == pending.before.overlay?.overlayKind;
      final ExploreScreen to;
      if (sameScreen) {
        from.mergeAffordances(pending.after.top.affordances);
        to = from;
      } else {
        final after = _Arrival(graph, pending.key, pending.deviceId, platform, now, _cursor)..arrive(pending.after);
        to = after.top!;
      }
      graph.recordEdge(
        from: from,
        to: to,
        tool: tool,
        glintId: target.glintId,
        text: target.text,
        arg: target.arg,
        changeCategory: category,
        errorKind: errorKind,
        platform: platform,
        now: now,
      );
      _markDirty(pending.key);
    } on Object {
      return;
    }
  }

  void _recordFailure(AppSession app, String tool, _Target target, String errorKind) {
    final screen = current(app);
    if (screen == null) return;
    final key = keyOf(app);
    graphFor(key).recordEdge(
      from: screen,
      to: screen,
      tool: tool,
      glintId: target.glintId,
      text: target.text,
      arg: target.arg,
      errorKind: errorKind,
      platform: app.platform.name,
      now: _clock(),
    );
    _markDirty(key);
  }

  ScreenSketch _sourceSketch(SceneSketch before, String? glintId) {
    final overlay = before.overlay;
    if (glintId == null) return before.top;
    if (overlay != null && overlay.offers(glintId)) return overlay;
    if (before.base.offers(glintId)) return before.base;
    return before.top;
  }

  void _arrive(ExploreGraph graph, String key, AppSession app, SceneSketch sketch) {
    _Arrival(graph, key, app.id, app.platform.name, _clock(), _cursor).arrive(sketch);
  }

  /// Forgets [app]'s graph in memory and on disk; returns what it held.
  ({int screens, int edges}) reset(AppSession app) {
    final key = keyOf(app);
    final graph = graphFor(key);
    final dropped = (screens: graph.screens.length, edges: graph.edges.length);
    _graphs[key] = ExploreGraph(key);
    _cursor.removeWhere((k, _) => k.startsWith('$key@'));
    _dirty.remove(key);
    try {
      final file = File(_file(key));
      if (file.existsSync()) file.deleteSync();
    } on Object {
      return dropped;
    }
    return dropped;
  }

  void _markDirty(String key) {
    _dirty.add(key);
    _timer ??= Timer(debounce, flush);
  }

  /// Writes every changed graph to disk now.
  void flush() {
    _timer?.cancel();
    _timer = null;
    for (final key in _dirty.toList()) {
      final graph = _graphs[key];
      if (graph == null) continue;
      try {
        final file = File(_file(key));
        file.parent.createSync(recursive: true);
        final tmp = File('${file.path}.tmp')..writeAsStringSync(jsonEncode(graph.toJson()));
        tmp.renameSync(file.path);
      } on Object {
        continue;
      }
    }
    _dirty.clear();
  }

  String path(AppSession app) => _file(keyOf(app));
}

class _Target {
  _Target({this.glintId, this.text, this.arg});

  final String? glintId;
  final String? text;
  final String? arg;
}

_Target? _targetOf(String tool, Map<String, Object?> args) {
  String? str(String k) {
    final v = args[k];
    return v is String && v.isNotEmpty ? v : null;
  }

  switch (tool) {
    case 'tap':
    case 'long_press':
      if (args['sequence'] != null) return null;
      final id = str('glintId');
      final text = str('text');
      return id == null && text == null ? null : _Target(glintId: id, text: id == null ? text : null);
    case 'pinch':
      final id = str('glintId');
      return id == null ? null : _Target(glintId: id);
    case 'type':
      final id = str('focus');
      return id == null ? null : _Target(glintId: id);
    case 'swipe':
    case 'drag':
      final id = str('fromGlintId');
      return id == null ? null : _Target(glintId: id);
    case 'key':
      final key = str('key');
      return key == null ? null : _Target(arg: key);
    case 'scroll':
      return _Target(arg: str('direction'));
    case 'hardware_button':
      final button = str('button');
      return button == null ? null : _Target(arg: button);
  }
  return null;
}

class _Arrival {
  _Arrival(this.graph, this.key, this.deviceId, this.platform, this.now, this.cursor);

  final ExploreGraph graph;
  final String key;
  final String deviceId;
  final String platform;
  final DateTime now;
  final Map<String, String> cursor;
  ExploreScreen? base;
  ExploreScreen? top;

  void arrive(SceneSketch sketch) {
    final cursorKey = '$key@$deviceId';
    final previous = graph.screens[cursor[cursorKey]];
    final b = base = graph.upsert(sketch.base, platform: platform, now: now);
    var t = b;
    if (sketch.overlay != null) t = graph.upsert(sketch.overlay!, parentId: b.id, platform: platform, now: now);
    top = t;
    final stayedOnBase = previous != null && (previous.id == b.id || previous.parentId == b.id);
    if (!stayedOnBase) graph.countVisit(b, platform);
    if (t != b && previous?.id != t.id) graph.countVisit(t, platform);
    cursor[cursorKey] = t.id;
  }
}
