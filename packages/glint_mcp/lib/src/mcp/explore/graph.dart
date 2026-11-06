import 'dart:collection';
import 'dart:math' as math;

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
  DateTime firstSeen;
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

  void absorb(ExploreScreen other) {
    if (other.lastSeen.isAfter(lastSeen)) {
      lastSeen = other.lastSeen;
      label = other.label;
    }
    if (other.firstSeen.isBefore(firstSeen)) firstSeen = other.firstSeen;
    visits = math.max(visits, other.visits);
    states.addAll(other.states);
    other.byPlatform.forEach((k, v) => byPlatform[k] = math.max(byPlatform[k] ?? 0, v));
    for (final a in other.affordances) {
      final known = affordances.where((s) => s.id == a.id && s.kind == a.kind).firstOrNull;
      if (known == null && affordances.length < _maxAffordances) {
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

/// Stands in for typed text in a recorded `type` edge; the real text is never stored.
const typedTextPlaceholder = '<text>';

/// Error kinds where the gesture still reached the app, so the control counts as tried.
const firedErrorKinds = {'inputPartial', 'modalNotDismissible'};

const _idArgs = {'glintId', 'focus', 'fromGlintId', 'toGlintId'};

class ExploreEdge {
  ExploreEdge({
    required this.from,
    required this.to,
    required this.tool,
    required this.args,
    this.errorKind,
    required this.lastSeen,
  });

  factory ExploreEdge.fromJson(Map<String, Object?> j) => ExploreEdge(
        from: j['from']! as String,
        to: j['to']! as String,
        tool: j['tool']! as String,
        args: ((j['args'] as Map?) ?? const {}).map((k, v) => MapEntry(k as String, v as String)),
        errorKind: j['err'] as String?,
        lastSeen: DateTime.parse(j['last']! as String),
      )
        ..count = (j['count'] as num?)?.toInt() ?? 1
        ..changeCategory = j['cat'] as String?
        ..byPlatform
            .addAll(((j['platforms'] as Map?) ?? const {}).cast<String, num>().map((k, v) => MapEntry(k, v.toInt())));

  final String from;
  final String to;
  final String tool;

  /// The arguments the tool really takes, with typed text replaced by [typedTextPlaceholder].
  Map<String, String> args;

  /// Set on a failed attempt; a failure is its own edge, never mixed with a success of the same gesture.
  final String? errorKind;
  DateTime lastSeen;
  int count = 0;
  String? changeCategory;
  final Map<String, int> byPlatform = {};

  String get key => edgeKey(from, to, tool, args, errorKind);

  String? get targetId => args['glintId'] ?? args['focus'] ?? args['fromGlintId'];

  String get targetBase => targetId == null ? '' : glintIdBase(targetId!);

  /// The text a tap or long press was aimed at when no glintId was given.
  String? get targetText =>
      args.containsKey('glintId') || (tool != 'tap' && tool != 'long_press') ? null : args['text'];

  bool get isSelf => from == to;

  /// Whether the gesture reached the app, so what it targeted counts as tried.
  bool get fired => errorKind == null || firedErrorKinds.contains(errorKind);

  bool get replayable => replayableTools.contains(tool) && errorKind == null;

  String get verb {
    if (tool == 'hardware_button') return args['button'] ?? 'button';
    final shown = [
      for (final e in args.entries)
        if (!(tool == 'type' && e.key == 'text')) e.key == 'text' ? '"${e.value}"' : e.value,
    ];
    return [tool, ...shown].join(' ');
  }

  Map<String, Object?> get stepArgs => Map<String, Object?>.from(args);

  /// The exact call to repeat this edge.
  String get call {
    final text = args.entries.map((e) => '${e.key}:"${e.value}"').join(' ');
    return text.isEmpty ? tool : '$tool $text';
  }

  void absorb(ExploreEdge other) {
    count = math.max(count, other.count);
    other.byPlatform.forEach((k, v) => byPlatform[k] = math.max(byPlatform[k] ?? 0, v));
    if (other.lastSeen.isAfter(lastSeen)) {
      lastSeen = other.lastSeen;
      changeCategory = other.changeCategory ?? changeCategory;
      args = Map.of(other.args);
    }
  }

  Map<String, Object?> toJson() => {
        'from': from,
        'to': to,
        'tool': tool,
        'args': args,
        'count': count,
        if (changeCategory != null) 'cat': changeCategory,
        if (errorKind != null) 'err': errorKind,
        'last': lastSeen.toIso8601String(),
        if (byPlatform.isNotEmpty) 'platforms': byPlatform,
      };
}

String edgeKey(String from, String to, String tool, Map<String, String> args, String? errorKind) {
  final names = args.keys.toList()..sort();
  final shown = [for (final k in names) '$k=${_idArgs.contains(k) ? glintIdBase(args[k]!) : args[k]}'];
  return '$from|$to|$tool|${shown.join(',')}|${errorKind ?? ''}';
}

/// What was done on each screen, indexed once so asking about every control stays linear.
class TriedIndex {
  TriedIndex(Iterable<ExploreEdge> edges) {
    for (final e in edges) {
      if (!e.fired) continue;
      final seen = _byScreen.putIfAbsent(e.from, _Tried.new);
      if (e.targetBase.isNotEmpty) seen.bases.add(e.targetBase);
      if (e.tool.startsWith('scroll') && e.targetId == null) seen.scrolled = true;
      if (e.targetText != null) seen.labels.add(e.targetText!.toLowerCase());
    }
  }

  final Map<String, _Tried> _byScreen = {};

  /// Whether something was done to [a] on [screen], by id or by its label as tap text.
  bool has(ExploreScreen screen, StoredAffordance a) {
    final seen = _byScreen[screen.id];
    if (seen == null) return false;
    return seen.bases.contains(a.id) ||
        (a.kind == AffordanceKind.scroll && seen.scrolled) ||
        (a.label != null && seen.labels.contains(a.label!.toLowerCase()));
  }
}

class _Tried {
  final Set<String> bases = {};
  final Set<String> labels = {};
  bool scrolled = false;
}

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
    final screen =
        _find(sketch.fingerprint, sketch.route, sketch.overlayKind, parentId) ?? _create(sketch, parentId, now);
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

  ExploreScreen? _find(String fingerprint, String route, String? overlayKind, String? parentId) => screens.values
      .where((s) =>
          s.fingerprint == fingerprint && s.route == route && s.overlayKind == overlayKind && s.parentId == parentId)
      .firstOrNull;

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
    required Map<String, String> args,
    String? changeCategory,
    String? errorKind,
    required String platform,
    required DateTime now,
  }) {
    final key = edgeKey(from.id, to.id, tool, args, errorKind);
    final edge = edges[key] ??= ExploreEdge(
      from: from.id,
      to: to.id,
      tool: tool,
      args: args,
      errorKind: errorKind,
      lastSeen: now,
    );
    edge
      ..args = args
      ..count += 1
      ..changeCategory = changeCategory ?? edge.changeCategory
      ..lastSeen = now;
    edge.byPlatform[platform] = (edge.byPlatform[platform] ?? 0) + 1;
    _trimEdges();
    return edge;
  }

  /// The controls of each screen (by screen id) that nothing was done to yet.
  Map<String, List<StoredAffordance>> untriedByScreen() {
    final index = TriedIndex(edges.values);
    return {
      for (final s in screens.values)
        s.id: [
          for (final a in s.affordances)
            if (!index.has(s, a)) a
        ],
    };
  }

  /// Folds another save of this app ([disk]) into this graph, matching screens by what they are rather than by id.
  void mergeFrom(ExploreGraph disk) {
    final idMap = <String, String>{};
    final theirs = disk.screens.values.toList()
      ..sort((a, b) => (a.parentId == null ? 0 : 1).compareTo(b.parentId == null ? 0 : 1));
    for (final other in theirs) {
      final parent = other.parentId == null ? null : idMap[other.parentId];
      if (other.parentId != null && parent == null) continue;
      final mine = _find(other.fingerprint, other.route, other.overlayKind, parent) ?? _adopt(other, parent);
      mine.absorb(other);
      idMap[other.id] = mine.id;
    }
    for (final other in disk.edges.values) {
      final from = idMap[other.from];
      final to = idMap[other.to];
      if (from == null || to == null) continue;
      final copy = ExploreEdge(
        from: from,
        to: to,
        tool: other.tool,
        args: Map.of(other.args),
        errorKind: other.errorKind,
        lastSeen: other.lastSeen,
      )
        ..count = other.count
        ..changeCategory = other.changeCategory
        ..byPlatform.addAll(other.byPlatform);
      final known = edges[copy.key];
      if (known == null) {
        edges[copy.key] = copy;
      } else {
        known.absorb(copy);
      }
    }
    _refreshStale();
    _trim(keep: null);
    _trimEdges();
  }

  ExploreScreen _adopt(ExploreScreen other, String? parentId) {
    while (screens.containsKey('s$nextId')) {
      nextId++;
    }
    final id = 's${nextId++}';
    return screens[id] = ExploreScreen(
      id: id,
      route: other.route,
      overlayKind: other.overlayKind,
      parentId: parentId,
      fingerprint: other.fingerprint,
      label: other.label,
      firstSeen: other.firstSeen,
      lastSeen: other.lastSeen,
    );
  }

  /// In each route group only the most recently seen screen is current; the rest are stale.
  void _refreshStale() {
    final latest = <String, ExploreScreen>{};
    for (final s in screens.values) {
      final known = latest[s.groupKey];
      if (known == null || s.lastSeen.isAfter(known.lastSeen)) latest[s.groupKey] = s;
    }
    for (final s in screens.values) {
      s.stale = s.route.isNotEmpty && !identical(latest[s.groupKey], s);
    }
  }

  void _trimEdges() {
    if (edges.length <= _maxEdges) return;
    final drop = edges.values.toList()..sort((a, b) => a.lastSeen.compareTo(b.lastSeen));
    for (final e in drop.take(edges.length - _maxEdges)) {
      edges.remove(e.key);
    }
  }

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

  void _trim({required String? keep}) {
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
