import '../runtime/flutter_runtime.dart';
import 'enricher.dart';
import 'semantic_node.dart';
import 'semantic_scene.dart';

/// Reads what each Google map shows: markers, routes and areas from the widget, and the live camera and marker screen points from its controller.
class MapEnricher implements SemanticEnricher {
  MapEnricher({required this.runtime, this.maxMarkers = 20, this.wait = const Duration(milliseconds: 1500)});

  final FlutterRuntime runtime;
  final int maxMarkers;

  /// How long to wait for the controller's camera and screen points, which the platform answers asynchronously.
  final Duration wait;

  static const _library = 'google_maps_flutter/google_maps_flutter.dart';
  static const _sep = '\u001f';

  /// Starts collecting into a list the second eval reads: sync lines from the widget now, camera lines as the controller answers, then a D line per map.
  static String _start(List<String> ids, int maxMarkers) => '(() { final box = <String>[]; '
      "final ids = <String>[${ids.map((i) => "'$i'").join(',')}]; "
      r'String f(double v) => v.toStringAsFixed(5); '
      r"String ll(LatLng p) => f(p.latitude) + ', ' + f(p.longitude); "
      r'for (var i = 0; i < ids.length; i++) { '
      r'final e = WidgetInspectorService.instance.toObject(ids[i]) as Element; '
      r'final w = e.widget as GoogleMap; '
      r'final ro = e.findRenderObject() as RenderBox?; '
      r'final o = ro == null || !ro.hasSize ? Offset.zero : ro.localToGlobal(Offset.zero); '
      r'final size = ro == null || !ro.hasSize ? Size.zero : ro.size; '
      r'final dpr = View.of(e).devicePixelRatio; '
      r'final android = defaultTargetPlatform == TargetPlatform.android; '
      'final shown = w.markers.take($maxMarkers).toList(); '
      r"for (final m in shown) box.add('M\u001f$i\u001f${m.markerId.value}\u001f${m.infoWindow.title ?? ''}\u001f${ll(m.position)}'); "
      r"if (w.markers.length > shown.length) box.add('X\u001f$i\u001f${w.markers.length - shown.length}'); "
      r"for (final r in w.polylines) box.add('R\u001f$i\u001f${r.polylineId.value}\u001f${r.points.length}\u001f${r.points.isEmpty ? '' : ll(r.points.first)}\u001f${r.points.isEmpty ? '' : ll(r.points.last)}'); "
      r"for (final a in w.polygons) box.add('A\u001f$i\u001f${a.polygonId.value}\u001fpolygon of ${a.points.length} points\u001f${a.points.isEmpty ? '' : ll(a.points.first)}'); "
      r"for (final c in w.circles) box.add('A\u001f$i\u001f${c.circleId.value}\u001fcircle ${c.radius.round()} m around\u001f${ll(c.center)}'); "
      r'final s = (e as StatefulElement).state as _GoogleMapState; '
      r"if (!s._controller.isCompleted) box.add('N\u001f$i\u001fnot ready yet'); "
      r's._controller.future.then((c) async { try { '
      r'final r = await c.getVisibleRegion(); final z = await c.getZoomLevel(); '
      r'final mid = LatLng((r.northeast.latitude + r.southwest.latitude) / 2, (r.northeast.longitude + r.southwest.longitude) / 2); '
      r"box.add('C\u001f$i\u001f${ll(mid)}\u001f$z\u001f${f(r.southwest.latitude)}..${f(r.northeast.latitude)}, ${f(r.southwest.longitude)}..${f(r.northeast.longitude)}'); "
      r'} catch (_) {} '
      r'for (final m in shown) { try { final p = await c.getScreenCoordinate(m.position); '
      r'final x = android ? p.x / dpr : p.x.toDouble(); final y = android ? p.y / dpr : p.y.toDouble(); '
      r'final on = x >= 0 && y >= 0 && x <= size.width && y <= size.height; '
      r"box.add('P\u001f$i\u001f${m.markerId.value}\u001f${(o.dx + x).round()},${(o.dy + y).round()}\u001f$on'); } catch (_) {} } "
      r"box.add('D\u001f$i'); }); } return box; })()";

  @override
  Future<void> enrich(SemanticScene scene) async {
    final maps = <(SemanticMap, String)>[];
    for (final m in scene.allNodes().whereType<SemanticMap>()) {
      final id = m.glintId;
      final source = id == null ? null : scene.sourceFor(id);
      if (source != null && source.inspectorId.isNotEmpty) maps.add((m, source.inspectorId));
    }
    if (maps.isEmpty) return;
    final String? boxId;
    try {
      boxId = (await runtime.evaluateIn(_start([for (final m in maps) m.$2], maxMarkers), librarySuffix: _library)).id;
    } on Object {
      for (final (m, _) in maps) {
        m.note = 'glint could not read it';
      }
      return;
    }
    if (boxId == null) return;
    final clock = Stopwatch()..start();
    while (clock.elapsed < wait) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final done = await _read("box.where((l) => l.startsWith('D')).length", boxId);
      if (done == null || (int.tryParse(done) ?? 0) >= maps.length) break;
    }
    final raw = await _readLong(boxId);
    final lines = [for (final l in (raw ?? '').split('\n')) if (l.isNotEmpty) l.split(_sep)];
    for (final (i, (map, _)) in maps.indexed) {
      _fill(map, [for (final l in lines) if (l.length > 1 && l[1] == '$i') l]);
    }
  }

  Future<String?> _read(String expression, String boxId) async {
    try {
      return (await runtime.evaluateIn(expression, librarySuffix: _library, scope: {'box': boxId})).valueAsString;
    } on Object {
      return null;
    }
  }

  /// The collected lines, read in slices under the VM's 128-character preview, since the scope-taking eval returns only the preview.
  Future<String?> _readLong(String boxId) async {
    const all = r"box.join('\n')";
    final length = int.tryParse(await _read('$all.length', boxId) ?? '');
    if (length == null) return null;
    final out = StringBuffer();
    for (var at = 0; at < length; at += 120) {
      final piece = await _read('$all.substring($at, ${at + 120 < length ? at + 120 : length})', boxId);
      if (piece == null) return out.toString();
      out.write(piece);
    }
    return out.toString();
  }

  void _fill(SemanticMap map, List<List<String>> lines) {
    final points = {for (final l in lines) if (l.first == 'P' && l.length >= 5) l[2]: (at: l[3], onScreen: l[4] == 'true')};
    final children = map.children;
    for (final l in lines) {
      switch (l.first) {
        case 'C' when l.length >= 5:
          map.center = l[2];
          map.zoom = double.tryParse(l[3]);
          map.shows = l[4];
          map.note = null;
        case 'N' when map.center == null:
          map.note = 'camera ${l[2]}';
        case 'M' when l.length >= 5:
          final p = points[l[2]];
          final where = p == null ? '' : (p.onScreen ? ' @ ${p.at}' : ' (off screen)');
          children.add(SemanticMapItem(role: SemanticRole.marker, label: '${l[2]}${l[3].isEmpty ? '' : ' "${l[3]}"'} at ${l[4]}$where'));
        case 'X':
          children.add(SemanticMapItem(role: SemanticRole.marker, label: '… ${l[2]} more markers'));
        case 'R' when l.length >= 6:
          children.add(SemanticMapItem(role: SemanticRole.route, label: '${l[2]}: ${l[3]} points, ${l[4]} to ${l[5]}'));
        case 'A' when l.length >= 5:
          children.add(SemanticMapItem(role: SemanticRole.area, label: '${l[2]}: ${l[3]} ${l[4]}'));
      }
    }
    if (map.center == null) map.note ??= 'camera not answered in time';
  }
}
