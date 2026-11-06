import 'dart:collection';

import '../../semantic/fold.dart' show glintIdBase;
import 'screen_sketch.dart';

const _maxScreens = 150;
const _maxEdges = 500;
const _maxAffordances = 60;

/// Gestures whose edge can be replayed from a screen without more input than the edge itself.
const replayableTools = {'tap', 'long_press', 'hardware_button'};

class StoredAffordance {
  StoredAffordance({required this.id, required this.sample, required this.kind, this.label});

  factory StoredAffordance.fromJson(Map<String, Object?> j) => StoredAffordance(
        id: j['id']! as String,
        sample: (j['sample'] as String?) ?? j['id']! as String,
        kind: AffordanceKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => AffordanceKind.tap),
        label: j['label'] as String?,
      );

  final String id;
  String sample;
  final AffordanceKind kind;
  String? label;

  bool get isRow => sample != id;

  Map<String, Object?> toJson() => {
        'id': id,
        if (isRow) 'sample': sample,
        'kind': kind.name,
        if (label != null) 'label': label,
      };
}

class ExploreScreen {
  ExploreScreen({
    required this.id,
    required this.route,
    required this.overlayKind,
    required this.parentId,
    required this.fingerprint,
    required this.label,
    required this.firstSeen,
    required this.lastSeen,
  });

  factory ExploreScreen.fromJson(Map<String, Object?> j) => ExploreScreen(
        id: j['id']! as String,
        route: (j['route'] as String?) ?? '',
        overlayKind: j['overlay'] as String?,
        parentId: j['parent'] as String?,
        fingerprint: j['fp']! as String,
        label: (j['label'] as String?) ?? '',
        firstSeen: DateTime.parse(j['first']! as String),
        lastSeen: DateTime.parse(j['last']! as String),
      )
        ..visits = (j['visits'] as num?)?.toInt() ?? 0
        ..stale = j['stale'] == true
        ..states.addAll(((j['states'] as List?) ?? const []).cast<String>())
        ..byPlatform
            .addAll(((j['platforms'] as Map?) ?? const {}).cast<String, num>().map((k, v) => MapEntry(k, v.toInt())))
        ..affordances
            .addAll(((j['affs'] as List?) ?? const []).map((a) => StoredAffordance.fromJson((a as Map).cast())));

  final String id;
  final String route;
  final String? overlayKind;
  final String? parentId;
  final String fingerprint;
  String label;
  final DateTime firstSeen;
  DateTime lastSeen;
  int visits = 0;
  bool stale = false;
  final Set<String> states = {};
  final Map<String, int> byPlatform = {};
  final List<StoredAffordance> affordances = [];

  bool get isOverlay => overlayKind != null;

  String get groupKey => '$route|${overlayKind ?? ''}|${parentId ?? ''}';

  void mergeAffordances(Iterable<SketchAffordance> seen) {
    for (final a in seen) {
      final known = affordances.where((s) => s.id == a.id && s.kind == a.kind).firstOrNull;
      if (known != null) {
        known.sample = a.sample;
        if (a.label != null) known.label = a.label;
      } else if (affordances.length < _maxAffordances) {
        affordances.add(StoredAffordance(id: a.id, sample: a.sample, kind: a.kind, label: a.label));
      }
    }
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'route': route,
        if (overlayKind != null) 'overlay': overlayKind,
        if (parentId != null) 'parent': parentId,
        'fp': fingerprint,
        'label': label,
        'visits': visits,
        'first': firstSeen.toIso8601String(),
        'last': lastSeen.toIso8601String(),
        if (stale) 'stale': true,
        if (states.isNotEmpty) 'states': states.toList()..sort(),
        if (byPlatform.isNotEmpty) 'platforms': byPlatform,
        'affs': [for (final a in affordances) a.toJson()],
      };
}

class ExploreEdge {
  ExploreEdge({
    required this.from,
    required this.to,
    required this.tool,
    this.glintId,
    this.text,
    this.arg,
    required this.lastSeen,
  });

  factory ExploreEdge.fromJson(Map<String, Object?> j) => ExploreEdge(
        from: j['from']! as String,
        to: j['to']! as String,
        tool: j['tool']! as String,
        glintId: j['glintId'] as String?,
        text: j['text'] as String?,
        arg: j['arg'] as String?,
        lastSeen: DateTime.parse(j['last']! as String),
      )
        ..count = (j['count'] as num?)?.toInt() ?? 1
        ..changeCategory = j['cat'] as String?
        ..errorKind = j['err'] as String?
        ..byPlatform
            .addAll(((j['platforms'] as Map?) ?? const {}).cast<String, num>().map((k, v) => MapEntry(k, v.toInt())));

  final String from;
  final String to;
  final String tool;
  String? glintId;
  final String? text;
  final String? arg;
  DateTime lastSeen;
  int count = 0;
  String? changeCategory;
  String? errorKind;
  final Map<String, int> byPlatform = {};

  String get key => edgeKey(from, to, tool, glintId, text, arg);

  String get targetBase => glintId == null ? '' : glintIdBase(glintId!);

  bool get isSelf => from == to;

  bool get replayable => replayableTools.contains(tool) && errorKind == null;

  String get verb => switch (tool) {
        'hardware_button' => arg ?? 'button',
        _ => [tool, if (glintId != null) glintId else if (text != null) '"$text"' else if (arg != null) arg].join(' '),
      };

  Map<String, Object?> get stepArgs => {
        if (glintId != null) 'glintId': glintId,
        if (glintId == null && text != null) 'text': text,
        if (tool == 'hardware_button') 'button': arg,
      };

  /// The exact call to repeat this edge.
  String get call {
    final args = stepArgs.entries.map((e) => '${e.key}:"${e.value}"').join(' ');
    return args.isEmpty ? tool : '$tool $args';
  }

  Map<String, Object?> toJson() => {
        'from': from,
        'to': to,
        'tool': tool,
        if (glintId != null) 'glintId': glintId,
        if (text != null) 'text': text,
        if (arg != null) 'arg': arg,
        'count': count,
        if (changeCategory != null) 'cat': changeCategory,
        if (errorKind != null) 'err': errorKind,
        'last': lastSeen.toIso8601String(),
        if (byPlatform.isNotEmpty) 'platforms': byPlatform,
      };
}

String edgeKey(String from, String to, String tool, String? glintId, String? text, String? arg) =>
    '$from|$to|$tool|${glintId == null ? '' : glintIdBase(glintId)}|${text ?? ''}|${arg ?? ''}';

/// The persistent map of one app: screens by id, and what happened when something was done on them.
class ExploreGraph {
  ExploreGraph(this.app);

  factory ExploreGraph.fromJson(String app, Map<String, Object?> j) {
    final g = ExploreGraph(app);
    for (final s in (j['screens'] as List?) ?? const []) {
      final screen = ExploreScreen.fromJson((s as Map).cast());
      g.screens[screen.id] = screen;
    }
    for (final e in (j['edges'] as List?) ?? const []) {
      final edge = ExploreEdge.fromJson((e as Map).cast());
      if (g.screens.containsKey(edge.from) && g.screens.containsKey(edge.to)) g.edges[edge.key] = edge;
    }
    g.nextId = (j['next'] as num?)?.toInt() ?? g.screens.length + 1;
    return g;
  }

  static const version = 1;

  final String app;
  final Map<String, ExploreScreen> screens = {};
  final Map<String, ExploreEdge> edges = {};
  int nextId = 1;

  bool get isEmpty => screens.isEmpty;

  /// The screen for [sketch] under [parentId], created on first sight. Marks the other fingerprints of its route stale.
  ExploreScreen upsert(ScreenSketch sketch, {String? parentId, required String platform, required DateTime now}) {
    final existing = screens.values
        .where((s) =>
            s.fingerprint == sketch.fingerprint &&
            s.route == sketch.route &&
            s.overlayKind == sketch.overlayKind &&
            s.parentId == parentId)
        .firstOrNull;
    final screen = existing ?? _create(sketch, parentId, now);
    screen
      ..label = sketch.label
      ..lastSeen = now
      ..stale = false
      ..states.add(sketch.state)
      ..mergeAffordances(sketch.affordances);
    if (screen.route.isNotEmpty) {
      for (final other in screens.values) {
        if (!identical(other, screen) && other.groupKey == screen.groupKey) other.stale = true;
      }
    }
    _trim(keep: screen.id);
    return screen;
  }

  ExploreScreen _create(ScreenSketch sketch, String? parentId, DateTime now) {
    final id = 's${nextId++}';
    return screens[id] = ExploreScreen(
      id: id,
      route: sketch.route,
      overlayKind: sketch.overlayKind,
      parentId: parentId,
      fingerprint: sketch.fingerprint,
      label: sketch.label,
      firstSeen: now,
      lastSeen: now,
    );
  }

  void countVisit(ExploreScreen screen, String platform) {
    screen.visits++;
    screen.byPlatform[platform] = (screen.byPlatform[platform] ?? 0) + 1;
  }

  ExploreEdge recordEdge({
    required ExploreScreen from,
    required ExploreScreen to,
    required String tool,
    String? glintId,
    String? text,
    String? arg,
    String? changeCategory,
    String? errorKind,
    required String platform,
    required DateTime now,
  }) {
    final key = edgeKey(from.id, to.id, tool, glintId, text, arg);
    final edge = edges[key] ??= ExploreEdge(
      from: from.id,
      to: to.id,
      tool: tool,
      glintId: glintId,
      text: text,
      arg: arg,
      lastSeen: now,
    );
    edge
      ..glintId = glintId ?? edge.glintId
      ..count += 1
      ..changeCategory = changeCategory ?? edge.changeCategory
      ..errorKind = errorKind
      ..lastSeen = now;
    edge.byPlatform[platform] = (edge.byPlatform[platform] ?? 0) + 1;
    if (edges.length > _maxEdges) {
      final drop = edges.values.toList()..sort((a, b) => a.lastSeen.compareTo(b.lastSeen));
      for (final e in drop.take(edges.length - _maxEdges)) {
        edges.remove(e.key);
      }
    }
    return edge;
  }

  /// Whether something was done to [a] on [screen], by id or by its label as tap text.
  bool tried(ExploreScreen screen, StoredAffordance a) {
    for (final e in edges.values) {
      if (e.from != screen.id) continue;
      if (e.targetBase == a.id) return true;
      if (a.kind == AffordanceKind.scroll && e.tool.startsWith('scroll') && e.glintId == null) return true;
      if (e.glintId == null && e.text != null && a.label != null && e.text!.toLowerCase() == a.label!.toLowerCase()) {
        return true;
      }
    }
    return false;
  }

  List<StoredAffordance> untried(ExploreScreen screen) => [
        for (final a in screen.affordances)
          if (!tried(screen, a)) a,
      ];

  List<ExploreEdge> outgoing(String screenId) => [
        for (final e in edges.values)
          if (e.from == screenId && !e.isSelf) e,
      ];

  /// Hops from [start] to every reachable screen over replayable edges, with the edge that led there.
  Map<String, List<ExploreEdge>> paths(String start) {
    final found = <String, List<ExploreEdge>>{start: const []};
    final queue = Queue<String>()..add(start);
    final byFrom = <String, List<ExploreEdge>>{};
    for (final e in edges.values) {
      if (e.replayable && !e.isSelf) byFrom.putIfAbsent(e.from, () => []).add(e);
    }
    for (final list in byFrom.values) {
      list.sort((a, b) => b.count.compareTo(a.count));
    }
    while (queue.isNotEmpty) {
      final at = queue.removeFirst();
      for (final e in byFrom[at] ?? const <ExploreEdge>[]) {
        if (found.containsKey(e.to)) continue;
        found[e.to] = [...found[at]!, e];
        queue.add(e.to);
      }
    }
    return found;
  }

  void _trim({required String keep}) {
    if (screens.length <= _maxScreens) return;
    final order = screens.values.where((s) => s.id != keep).toList()
      ..sort((a, b) {
        if (a.stale != b.stale) return a.stale ? -1 : 1;
        return a.lastSeen.compareTo(b.lastSeen);
      });
    for (final s in order.take(screens.length - _maxScreens)) {
      screens.remove(s.id);
      edges.removeWhere((_, e) => e.from == s.id || e.to == s.id);
    }
  }

  Map<String, Object?> toJson() => {
        'v': version,
        'app': app,
        'next': nextId,
        'screens': [for (final s in screens.values) s.toJson()],
        'edges': [for (final e in edges.values) e.toJson()],
      };
}
