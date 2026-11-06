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
const _retryDelay = Duration(seconds: 10);
const _callKey = #glintExploreCall;

/// Failures about the session or the arguments, not about the screen, so the map does not keep them.
const _unrecordedFailures = {
  'sessionNotAttached',
  'unknownApp',
  'invalidArgument',
  'flutterModeRequired',
  'connectionLost',
  'deviceGone',
  'deviceClaimed',
  'notOwned',
};

class _Pending {
  _Pending(this.key, this.deviceId, this.platform, this.before, this.after);

  final String key;
  final String deviceId;
  final String platform;
  final SceneSketch before;
  final SceneSketch after;
}

/// One tool call's own slot for the screens it saw; calls never share it, so overlapping calls cannot swap edges.
class ExploreCall {
  _Pending? _pending;
  String? _resolvedId;

  /// Runs [body] so that the post-action read inside it is noted on this call.
  Future<T> run<T>(Future<T> Function() body) => runZoned(body, zoneValues: {_callKey: this});
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
  final Set<String> _blocked = {};
  final Map<String, List<String>> _notes = {};
  Timer? _timer;
  bool _closed = false;

  /// The id an app's graph is stored under: bundle id or package, else its name.
  static String keyOf(AppSession app) => app.bundleId ?? app.package ?? app.displayName ?? app.label;

  String _file(String key) => '$_dir/${key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.json';

  ExploreGraph graphFor(String key) => _graphs.putIfAbsent(key, () => _load(key));

  /// What to tell the agent once about [key]'s saved map, such as a file set aside or left alone.
  List<String> takeNotes(String key) => _notes.remove(key) ?? const [];

  void _note(String key, String text) => _notes.putIfAbsent(key, () => []).add(text);

  ExploreGraph _load(String key) {
    try {
      return _readDisk(key) ?? ExploreGraph(key);
    } on FileSystemException {
      return ExploreGraph(key);
    }
  }

  /// The saved graph of [key], null when there is none; an unreadable file is set aside, a newer one blocks saving.
  ExploreGraph? _readDisk(String key) {
    final file = File(_file(key));
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map) throw const FormatException('not an object');
      final version = json['v'];
      if (version is int && version > ExploreGraph.version) {
        _blocked.add(key);
        _note(key,
            'the saved map of $key was written by a newer glint (v$version), so this session keeps its map in memory and leaves the file alone');
        return null;
      }
      if (version != ExploreGraph.version) throw FormatException('version $version');
      return ExploreGraph.fromJson(key, json.cast());
    } on FileSystemException {
      rethrow;
    } on Object {
      _setAside(key, file);
      return null;
    }
  }

  void _setAside(String key, File file) {
    final aside = '${file.path}.bad-${_clock().millisecondsSinceEpoch}';
    try {
      file.renameSync(aside);
      _note(key, 'the saved map of $key was unreadable and was moved to $aside; a fresh one started');
    } on Object {
      _note(key, 'the saved map of $key was unreadable and could not be moved aside');
    }
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

  /// The pre-action and post-action sketches of the gesture now finishing, kept on the call running it.
  void noteAction(AppSession? app, SceneSketch? before, SceneSketch? after) {
    final call = Zone.current[_callKey] as ExploreCall?;
    if (call == null) return;
    call._pending = null;
    if (app == null || app.deviceMode || before == null || after == null || after.top.state == 'loading') return;
    call._pending = _Pending(keyOf(app), app.id, app.platform.name, before, after);
  }

  /// Notes the glintId a call resolved from visible text, so its edge is keyed by the control it really hit.
  void noteTarget(String glintId) {
    final call = Zone.current[_callKey] as ExploreCall?;
    call?._resolvedId = glintId;
  }

  /// Called when a tool call ends: records the edge its gesture made, or its failure, on [app]'s graph.
  void completeCall(
    AppSession? app,
    ExploreCall? call,
    String tool,
    Map<String, Object?>? args,
    StructuredResponse response,
  ) {
    final pending = call?._pending;
    final resolvedId = call?._resolvedId;
    call?._pending = null;
    call?._resolvedId = null;
    if (!_edgeTools.contains(tool)) return;
    try {
      final gesture = gestureArgs(tool, args ?? const {});
      if (gesture == null) return;
      final errorKind = response.isError ? (response.data?['errorKind'] as String?) ?? 'internal' : null;
      if (errorKind != null) {
        if (app != null && !_unrecordedFailures.contains(errorKind)) _recordFailure(app, tool, gesture, errorKind);
        return;
      }
      if (pending == null) return;
      final graph = graphFor(pending.key);
      final platform = pending.platform;
      final now = _clock();
      if (pending.before.top.state == 'loading') {
        _Arrival(graph, pending.key, pending.deviceId, platform, now, _cursor).arrive(pending.after);
        _markDirty(pending.key);
        return;
      }
      final before = _Arrival(graph, pending.key, pending.deviceId, platform, now, _cursor)..arrive(pending.before);
      final targetId = gesture['glintId'] ?? gesture['focus'] ?? gesture['fromGlintId'] ?? resolvedId;
      final fromSketch = _sourceSketch(pending.before, targetId);
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
        args: gesture,
        target: targetId == null ? null : fromSketch.keyFor(targetId) ?? targetId,
        changeCategory: response.data?['changeCategory'] as String?,
        platform: platform,
        now: now,
      );
      _markDirty(pending.key);
    } on Object {
      return;
    }
  }

  void _recordFailure(AppSession app, String tool, Map<String, String> gesture, String errorKind) {
    final screen = current(app);
    if (screen == null) return;
    final key = keyOf(app);
    graphFor(key).recordEdge(
      from: screen,
      to: screen,
      tool: tool,
      args: gesture,
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

  /// Forgets [app]'s graph in memory and on disk (a file from a newer glint is kept); returns what it held.
  ({int screens, int edges, bool fileKept}) reset(AppSession app) {
    final key = keyOf(app);
    final graph = graphFor(key);
    final keep = _blocked.contains(key);
    final dropped = (screens: graph.screens.length, edges: graph.edges.length, fileKept: keep);
    _graphs[key] = ExploreGraph(key);
    _cursor.removeWhere((k, _) => k.startsWith('$key@'));
    _dirty.remove(key);
    _notes.remove(key);
    if (keep) return dropped;
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
    _timer?.cancel();
    _timer = Timer(debounce, flush);
  }

  /// Writes every changed graph to disk now, merged with whatever another glint saved there meanwhile.
  void flush() {
    _timer?.cancel();
    _timer = null;
    for (final key in _dirty.toList()) {
      final graph = _graphs[key];
      if (graph == null || _blocked.contains(key)) {
        _dirty.remove(key);
        continue;
      }
      try {
        final saved = _readDisk(key);
        if (_blocked.contains(key)) {
          _dirty.remove(key);
          continue;
        }
        if (saved != null) graph.mergeFrom(saved);
        final file = File(_file(key));
        file.parent.createSync(recursive: true);
        final tmp = File('${file.path}.tmp$pid')..writeAsStringSync(jsonEncode(graph.toJson()));
        tmp.renameSync(file.path);
        _dirty.remove(key);
      } on Object {
        continue;
      }
    }
    if (_dirty.isNotEmpty && !_closed) _timer = Timer(_retryDelay, flush);
  }

  /// Saves what is pending and stops the retry timer, for server shutdown.
  void close() {
    _closed = true;
    flush();
  }
}

/// The arguments [tool] takes to repeat a gesture, with typed text swapped for a placeholder; null when it cannot be repeated.
Map<String, String>? gestureArgs(String tool, Map<String, Object?> args) {
  String? str(String k) {
    final v = args[k];
    return v is String && v.isNotEmpty ? v : null;
  }

  switch (tool) {
    case 'tap':
    case 'long_press':
      if (args['sequence'] != null) return null;
      final id = str('glintId');
      if (id != null) return {'glintId': id};
      final text = str('text');
      return text == null ? null : {'text': text};
    case 'pinch':
      final id = str('glintId');
      return id == null ? null : {'glintId': id};
    case 'type':
      final id = str('focus') ?? str('glintId');
      return id == null ? null : {'focus': id, 'text': typedTextPlaceholder};
    case 'swipe':
    case 'drag':
      final from = str('fromGlintId');
      final to = str('toGlintId');
      final edge = tool == 'swipe' ? str('edge') : null;
      if (from != null) return {'fromGlintId': from, if (to != null) 'toGlintId': to};
      return edge == null ? null : {'edge': edge};
    case 'key':
      final key = str('key');
      return key == null ? null : {'key': key};
    case 'scroll':
      final direction = str('direction');
      if (direction == null) return null;
      final id = str('glintId');
      return {'direction': direction, if (id != null) 'glintId': id};
    case 'hardware_button':
      final button = str('button');
      return button == null ? null : {'button': button};
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
    final covered = sketch.overlay == null ? null : _coveredBase(previous, sketch.base.route);
    final b = base = covered ?? graph.upsert(sketch.base, platform: platform, now: now);
    var t = b;
    if (sketch.overlay != null) t = graph.upsert(sketch.overlay!, parentId: b.id, platform: platform, now: now);
    top = t;
    final stayedOnBase = previous != null && (previous.id == b.id || previous.parentId == b.id);
    if (!stayedOnBase) graph.countVisit(b, platform);
    if (t != b && previous?.id != t.id) graph.countVisit(t, platform);
    cursor[cursorKey] = t.id;
  }

  /// The screen a dialog or sheet sits on: the one the cursor was on, else the latest known one of the route, never a new one made from the blocked read.
  ExploreScreen? _coveredBase(ExploreScreen? previous, String route) {
    final from = previous == null || !previous.isOverlay ? previous : graph.screens[previous.parentId];
    if (from != null && !from.isOverlay && from.route == route) return from;
    if (route.isEmpty) return null;
    final known = graph.screens.values.where((s) => !s.isOverlay && !s.stale && s.route == route).toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return known.firstOrNull;
  }
}
