import 'graph.dart';
import 'screen_sketch.dart';

const _mapScreenCap = 25;
const _mapEdgeCap = 40;
const _frontierCap = 15;

String ago(DateTime then, DateTime now) {
  final d = now.difference(then);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 48) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

String screenName(ExploreScreen s) {
  if (s.isOverlay) return '${s.id} ${s.label}';
  final route = s.route.isEmpty ? '' : '${s.route} ';
  return s.label == s.route || s.label == '(unnamed)' ? '${s.id} ${route.trim()}'.trim() : '${s.id} $route"${s.label}"';
}

/// The call that does [a] on its screen.
String callFor(StoredAffordance a) => switch (a.kind) {
      AffordanceKind.tap => 'tap glintId:"${a.sample}"',
      AffordanceKind.type => 'type focus:"${a.sample}" text:"…"',
      AffordanceKind.scroll => 'scroll direction:"down"',
    };

class MapView {
  MapView(this.text, this.data);

  final String text;
  final Map<String, Object?> data;
}

MapView renderMap(ExploreGraph g, ExploreScreen? here, DateTime now) {
  final platforms = {for (final s in g.screens.values) ...s.byPlatform.keys};
  final screens = g.screens.values.toList()..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
  final shown = screens.take(_mapScreenCap).toList();
  final edges = g.edges.values.where((e) => !e.isSelf).toList()
    ..sort((a, b) {
      final c = b.count.compareTo(a.count);
      return c != 0 ? c : b.lastSeen.compareTo(a.lastSeen);
    });
  final shownIds = {for (final s in shown) s.id};
  final visibleEdges = edges.where((e) => shownIds.contains(e.from) && shownIds.contains(e.to)).toList();
  final shownEdges = visibleEdges.take(_mapEdgeCap).toList();
  final failed = g.edges.values.where((e) => e.errorKind != null && e.isSelf).toList();

  final buf = StringBuffer()
    ..writeln('${g.app} · ${g.screens.length} screens, ${g.edges.length} edges'
        '${here == null ? '' : ' · you are on ${here.id}'}'
        '${platforms.length > 1 ? ' · ${platforms.join(' + ')}' : ''}')
    ..writeln('screens');
  for (final s in shown) {
    final total = s.affordances.length;
    final done = total - g.untried(s).length;
    buf.writeln(' ${screenName(s)}${s.isOverlay ? ' (over ${s.parentId})' : ''} ×${s.visits} ${ago(s.lastSeen, now)}'
        ' · $done/$total tried${s.stale ? ' · stale' : ''}'
        '${s.states.contains('error') ? ' · saw error' : ''}'
        '${platforms.length > 1 ? ' · ${s.byPlatform.entries.map((e) => '${e.key} ${e.value}').join(' ')}' : ''}');
  }
  if (screens.length > shown.length) {
    buf.writeln(' +${screens.length - shown.length} older screens (explore op:frontier or op:path to:"<id>")');
  }
  if (shownEdges.isNotEmpty) buf.writeln('edges');
  for (final e in shownEdges) {
    buf.writeln(' ${e.from} --${e.verb}--> ${e.to}'
        '${e.count > 1 ? ' ×${e.count}' : ''}'
        '${e.errorKind != null ? ' ${e.errorKind}' : e.changeCategory != null && e.changeCategory != 'routeChanged' ? ' ${e.changeCategory}' : ''}');
  }
  if (visibleEdges.length > shownEdges.length) buf.writeln(' +${visibleEdges.length - shownEdges.length} more edges');
  if (failed.isNotEmpty) {
    buf.writeln('failed');
    for (final e in failed.take(8)) {
      buf.writeln(' ${e.from} --${e.verb}--> ${e.errorKind} ×${e.count}');
    }
  }

  final data = <String, Object?>{
    'app': g.app,
    if (here != null) 'current': here.id,
    'screenCount': g.screens.length,
    'edgeCount': g.edges.length,
    'screens': [
      for (final s in shown)
        {
          'id': s.id,
          'route': s.route,
          'label': s.label,
          if (s.isOverlay) 'overlay': s.overlayKind,
          if (s.parentId != null) 'parent': s.parentId,
          'visits': s.visits,
          'lastSeen': s.lastSeen.toUtc().toIso8601String(),
          if (s.stale) 'stale': true,
          'tried': s.affordances.length - g.untried(s).length,
          'affordances': s.affordances.length,
          if (platforms.length > 1) 'platforms': s.byPlatform,
        }
    ],
    'edges': [for (final e in shownEdges) _edgeData(e)],
  };
  return MapView(buf.toString().trimRight(), data);
}

Map<String, Object?> _edgeData(ExploreEdge e) => {
      'from': e.from,
      'to': e.to,
      'call': e.call,
      'count': e.count,
      if (e.changeCategory != null) 'changeCategory': e.changeCategory,
      if (e.errorKind != null) 'errorKind': e.errorKind,
      'lastSeen': e.lastSeen.toUtc().toIso8601String(),
      'platforms': e.byPlatform,
    };

class FrontierItem {
  FrontierItem(this.screen, this.affordance, this.hops);

  final ExploreScreen screen;
  final StoredAffordance affordance;
  final int? hops;
}

class FrontierView {
  FrontierView(this.text, this.data, this.total);

  final String text;
  final Map<String, Object?> data;
  final int total;
}

FrontierView renderFrontier(ExploreGraph g, ExploreScreen? here, DateTime now) {
  final reach = here == null ? <String, List<ExploreEdge>>{} : g.paths(here.id);
  int? hops(ExploreScreen s) => reach[s.id]?.length;
  int rank(int? h) => h ?? 1 << 20;

  final items = <FrontierItem>[
    for (final s in g.screens.values)
      if (!s.stale)
        for (final a in g.untried(s)) FrontierItem(s, a, hops(s)),
  ]..sort((a, b) {
      final c = rank(a.hops).compareTo(rank(b.hops));
      return c != 0 ? c : b.screen.lastSeen.compareTo(a.screen.lastSeen);
    });
  final stale = [
    for (final s in g.screens.values)
      if (s.stale) s
  ]..sort((a, b) => rank(hops(a)).compareTo(rank(hops(b))));

  final shown = items.take(_frontierCap).toList();
  final buf = StringBuffer()
    ..writeln('frontier on ${g.app}${here == null ? '' : ' from ${screenName(here)}'}'
        ' · ${items.length} untried on ${items.map((i) => i.screen.id).toSet().length} screens'
        '${stale.isEmpty ? '' : ' · ${stale.length} stale'}');
  String? lastScreen;
  for (final i in shown) {
    if (i.screen.id != lastScreen) {
      lastScreen = i.screen.id;
      final h = i.hops;
      buf.writeln(h == 0
          ? 'here ${screenName(i.screen)}'
          : '${screenName(i.screen)} · ${h == null ? 'no known path' : '$h hop${h == 1 ? '' : 's'}: explore op:path to:"${i.screen.id}"'}');
    }
    buf.writeln(' ${callFor(i.affordance)}${i.affordance.label == null ? '' : '   ${i.affordance.label}'}'
        '${i.affordance.isRow ? '   (a row of its list)' : ''}');
  }
  if (items.length > shown.length) {
    buf.writeln('+${items.length - shown.length} more untried (nearest ${shown.length} shown)');
  }
  if (stale.isNotEmpty) {
    buf.writeln('stale, not seen since their structure changed');
    for (final s in stale.take(6)) {
      final h = hops(s);
      buf.writeln(' ${screenName(s)} · last seen ${ago(s.lastSeen, now)}'
          '${h == null ? '' : ' · $h hop${h == 1 ? '' : 's'}: explore op:path to:"${s.id}"'}');
    }
  }
  if (items.isEmpty && stale.isEmpty) buf.writeln('nothing untried on the ${g.screens.length} known screens');

  final data = <String, Object?>{
    'app': g.app,
    if (here != null) 'current': here.id,
    'untried': items.length,
    'items': [
      for (final i in shown)
        {
          'screen': i.screen.id,
          'call': callFor(i.affordance),
          'glintId': i.affordance.sample,
          'kind': i.affordance.kind.name,
          if (i.affordance.label != null) 'label': i.affordance.label,
          if (i.hops != null) 'hops': i.hops,
        }
    ],
    'stale': [
      for (final s in stale.take(6))
        {
          'screen': s.id,
          'label': s.label,
          'lastSeen': s.lastSeen.toUtc().toIso8601String(),
          if (hops(s) != null) 'hops': hops(s)
        }
    ],
  };
  return FrontierView(buf.toString().trimRight(), data, items.length);
}
