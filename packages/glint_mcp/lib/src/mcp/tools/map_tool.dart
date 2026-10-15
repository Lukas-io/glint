import 'dart:math';

import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../semantic.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

const _ops = ['read', 'tap', 'pan', 'zoom'];

/// `map` reads a Google map and moves it the way a finger does: tap a marker, pan, zoom.
class MapTool extends GlintTool {
  const MapTool();

  @override
  Tool get definition => Tool(
        name: 'map',
        description:
            'A Google map in the attached app, driven like a finger. op: read (camera and markers with their screen points), '
            'tap (marker: its id), pan (dx, dy in logical points, or to: "lat,lng" or marker: id to center it), zoom (direction: in | out, one finger). '
            'Each reply gives the camera before and after. errorKind: sessionNotAttached, targetNotFound, invalidArgument.',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(description: _ops.join(' | ')),
            'marker': Schema.string(description: 'tap: the marker id to tap. pan: the marker to center.'),
            'to': Schema.string(description: 'pan: "lat,lng" to center.'),
            'dx': Schema.num(description: 'pan: move the map content this many logical points right (negative: left).'),
            'dy': Schema.num(description: 'pan: move the map content this many logical points down (negative: up).'),
            'direction': Schema.string(description: 'zoom: in | out.'),
            'index': Schema.int(description: 'Which map when the screen has several, 0 = first. Default 0.'),
          },
          required: ['op'],
        ),
      );

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final op = args['op'] as String?;
    if (!_ops.contains(op)) return _bad('op must be ${_ops.join(', ')}; got ${op ?? 'nothing'}');
    if (!session.isAttached || session.active?.deviceMode == true) {
      return StructuredResponse.error(
        summary: 'attach a Flutter app first: map reads the map through the app',
        errorKind: GlintErrorKind.sessionNotAttached,
        nextSteps: const ['attach'],
      );
    }
    final before = await _read(session, argInt(args, 'index') ?? 0);
    if (before == null) {
      return StructuredResponse.error(
        summary: 'no Google map on screen',
        errorKind: GlintErrorKind.targetNotFound,
        detail: 'map reads google_maps_flutter maps; other map packages are not read yet',
        nextSteps: const ['get_scene to see the screen'],
      );
    }
    if (before.center == null) {
      return StructuredResponse.error(
        summary: 'the map has not answered with its camera (${before.note ?? 'not ready'})',
        errorKind: GlintErrorKind.targetNeverReady,
        nextSteps: const ['wait a moment for the map to load, then retry'],
      );
    }
    return switch (op) {
      'read' => _reply(session, 'map', before, before),
      'tap' => await _tap(session, args, before),
      'pan' => await _pan(session, request, args, before),
      _ => await _zoom(session, args, before),
    };
  }

  StructuredResponse _bad(String summary, {List<String> nextSteps = const []}) =>
      StructuredResponse.error(summary: summary, errorKind: GlintErrorKind.invalidArgument, nextSteps: nextSteps);

  Future<SemanticMap?> _read(GlintSession session, int index) => session.withScene((scene) async {
        final maps = scene.allNodes().whereType<SemanticMap>().toList();
        return index < maps.length ? maps[index] : null;
      });

  String _camera(SemanticMap m) => '${m.center} zoom ${m.zoom?.toStringAsFixed(1)}';

  StructuredResponse _reply(GlintSession session, String did, SemanticMap before, SemanticMap after,
      {List<String> warnings = const []}) {
    final moved = _camera(before) != _camera(after);
    return StructuredResponse(
      summary: did == 'map'
          ? 'map camera ${_camera(after)} · shows ${after.shows}'
          : '$did; camera ${moved ? '${_camera(before)} -> ${_camera(after)}' : 'unchanged at ${_camera(after)}'}',
      warnings: warnings,
      nextSteps: const ['get_scene to see how the app reacted'],
      data: {
        'center': after.center,
        'zoom': after.zoom,
        'shows': after.shows,
        'markers': [
          for (final m in after.markers)
            {
              'id': m.id,
              if (m.title.isNotEmpty) 'title': m.title,
              'at': m.at,
              if (m.screen != null) 'screen': '${m.screen!.x},${m.screen!.y}'
            },
        ],
        if (did != 'map') 'cameraMoved': moved,
      },
    );
  }

  Future<void> _tapAt(GlintSession session, double x, double y) {
    final dpr = session.device.devicePixelRatio;
    return session.backend.tap(physicalX: (x * dpr).round(), physicalY: (y * dpr).round());
  }

  /// A slow drag, so the map does not fling on release and overshoot.
  Future<void> _drag(GlintSession session, ({double x, double y}) from, ({double x, double y}) to) {
    final dpr = session.device.devicePixelRatio;
    return session.backend.swipe(
      physicalX1: (from.x * dpr).round(),
      physicalY1: (from.y * dpr).round(),
      physicalX2: (to.x * dpr).round(),
      physicalY2: (to.y * dpr).round(),
      durationMs: 1200,
    );
  }

  Future<void> _dragBy(GlintSession session, ({double x, double y, double w, double h}) rect, double dx, double dy) {
    final cx = rect.x + rect.w / 2, cy = rect.y + rect.h / 2;
    return _drag(session, (x: cx - dx / 2, y: cy - dy / 2), (x: cx + dx / 2, y: cy + dy / 2));
  }

  Future<SemanticMap> _settled(GlintSession session, SemanticMap fallback, int index) async {
    await Future<void>.delayed(const Duration(milliseconds: 900));
    return await _read(session, index) ?? fallback;
  }

  Future<StructuredResponse> _tap(GlintSession session, Map<String, Object?> args, SemanticMap before) async {
    final id = args['marker'] as String?;
    if (id == null) {
      return _bad('tap needs marker: the marker id',
          nextSteps: ['markers here: ${before.markers.map((m) => m.id).join(', ')}']);
    }
    final marker = before.markers.where((m) => m.id == id).firstOrNull;
    if (marker == null) {
      return StructuredResponse.error(
        summary: 'no marker "$id" on the map',
        errorKind: GlintErrorKind.targetNotFound,
        detail: 'markers: ${before.markers.map((m) => m.id).join(', ')}',
      );
    }
    if (marker.screen == null) {
      return StructuredResponse.error(
        summary: 'marker "$id" is off screen',
        errorKind: GlintErrorKind.offViewport,
        nextSteps: ['map op:pan marker:"$id" centers it, then tap'],
      );
    }
    await _tapAt(session, marker.screen!.x.toDouble(), marker.screen!.y.toDouble());
    final after = await _settled(session, before, argInt(args, 'index') ?? 0);
    return _reply(
        session,
        'tapped marker $id${marker.title.isEmpty ? '' : ' "${marker.title}"'} at ${marker.screen!.x},${marker.screen!.y}',
        before,
        after);
  }

  /// Logical points the map content must move so [target] lands on the camera center, from Web Mercator at the current zoom (256 points per tile).
  ({double dx, double dy})? _offsetTo(SemanticMap map, ({double lat, double lng}) target) {
    final c = map.center?.split(',').map((v) => double.tryParse(v.trim())).toList();
    final zoom = map.zoom;
    if (c == null || c.length != 2 || c.contains(null) || zoom == null) return null;
    final world = 256 * pow(2, zoom);
    double mercY(double lat) => log(tan(pi / 4 + lat * pi / 360));
    final dx = (target.lng - c[1]!) / 360 * world;
    final dy = (mercY(c[0]!) - mercY(target.lat)) / (2 * pi) * world;
    return (dx: -dx, dy: -dy);
  }

  void Function(int, String)? _progressSink(GlintSession session, CallToolRequest request) {
    final token = request.meta?.progressToken;
    final notifier = session.progressNotifier;
    if (token == null || notifier == null) return null;
    return (sec, phase) =>
        notifier(ProgressNotification(progressToken: token, progress: sec, message: '$phase (${sec}s)'));
  }

  Future<StructuredResponse> _pan(
      GlintSession session, CallToolRequest request, Map<String, Object?> args, SemanticMap before) async {
    final rect = before.rect;
    if (rect == null || rect.w <= 0 || rect.h <= 0) return _bad('the map has no size on screen yet');
    final index = argInt(args, 'index') ?? 0;
    final markerId = args['marker'] as String?;
    final toRaw = args['to'] as String?;
    final maxX = rect.w * 0.8, maxY = rect.h * 0.8;
    if (markerId == null && toRaw == null) {
      final dx = argNum(args, 'dx') ?? 0, dy = argNum(args, 'dy') ?? 0;
      if (dx == 0 && dy == 0) return _bad('pan needs dx and dy, to:"lat,lng" or marker');
      var restX = dx, restY = dy, steps = 0;
      while ((restX.abs() > 2 || restY.abs() > 2) && steps < 12) {
        final sx = restX.clamp(-maxX, maxX).toDouble(), sy = restY.clamp(-maxY, maxY).toDouble();
        await _dragBy(session, rect, sx, sy);
        restX -= sx;
        restY -= sy;
        steps++;
      }
      return _reply(session, 'panned by ${dx.round()},${dy.round()} in $steps drag${steps == 1 ? '' : 's'}', before,
          await _settled(session, before, index));
    }
    final at = markerId != null ? before.markers.where((m) => m.id == markerId).firstOrNull?.at : toRaw;
    if (at == null) {
      return _bad('no marker "$markerId" on the map',
          nextSteps: ['markers: ${before.markers.map((m) => m.id).join(', ')}']);
    }
    final parts = at.split(',').map((v) => double.tryParse(v.trim())).toList();
    if (parts.length != 2 || parts.contains(null)) return _bad('to must be "lat,lng"; got $at');
    final target = (lat: parts[0]!, lng: parts[1]!);
    final sink = _progressSink(session, request);
    final clock = Stopwatch()..start();
    var lastReport = Duration.zero;
    var now = before;
    var steps = 0;
    var stuck = 0;
    ({double dx, double dy})? left = _offsetTo(now, target);
    while (left != null && (left.dx.abs() > 25 || left.dy.abs() > 25) && steps < 30 && stuck < 2) {
      await _dragBy(session, rect, left.dx.clamp(-maxX, maxX).toDouble(), left.dy.clamp(-maxY, maxY).toDouble());
      steps++;
      final previous = now;
      now = await _settled(session, now, index);
      stuck = _camera(now) == _camera(previous) ? stuck + 1 : 0;
      left = _offsetTo(now, target);
      if (clock.elapsed - lastReport >= const Duration(seconds: 15)) {
        lastReport = clock.elapsed;
        sink?.call(clock.elapsed.inSeconds,
            'panning to ${markerId ?? at}: $steps drags, ${left == null ? '?' : '${left.dx.round()},${left.dy.round()}'} points to go');
      }
    }
    if (stuck >= 2) {
      return StructuredResponse.error(
        summary: 'the map does not move under drags (camera stayed at ${_camera(now)})',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail:
            'two drags in a row left the camera where it was: the map may have scroll gestures off, or not be drawn (an Android map without a valid API key draws nothing and ignores touches)',
        nextSteps: const ['get_scene, then device op:screenshot to see the map'],
      );
    }
    final there = left != null && left.dx.abs() <= 25 && left.dy.abs() <= 25;
    return _reply(session, 'panned to ${markerId ?? at} in $steps drag${steps == 1 ? '' : 's'}', before, now,
        warnings: [
          if (!there)
            'stopped ${left == null ? 'without a camera to check' : '${left.dx.round()},${left.dy.round()} points short'} after $steps drags; far targets take many drags at this zoom',
        ]);
  }

  Future<StructuredResponse> _zoom(GlintSession session, Map<String, Object?> args, SemanticMap before) async {
    final direction = args['direction'] as String?;
    if (direction != 'in' && direction != 'out') return _bad('zoom needs direction: in | out');
    final rect = before.rect;
    if (rect == null) return _bad('the map has no size on screen yet');
    final cx = rect.x + rect.w / 2, cy = rect.y + rect.h / 2;
    final dpr = session.device.devicePixelRatio;
    if (direction == 'in') {
      await session.backend.tapSequence(
          [(x: (cx * dpr).round(), y: (cy * dpr).round()), (x: (cx * dpr).round(), y: (cy * dpr).round())],
          intervalMs: 120);
    } else {
      await _tapAt(session, cx, cy);
      await _drag(session, (x: cx, y: cy), (x: cx, y: cy - rect.h * 0.25));
    }
    final after = await _settled(session, before, argInt(args, 'index') ?? 0);
    final zoomed = (after.zoom ?? 0) - (before.zoom ?? 0);
    final worked = direction == 'in' ? zoomed > 0.05 : zoomed < -0.05;
    if (!worked) {
      return StructuredResponse.error(
        summary: 'the map did not zoom $direction (still ${_camera(after)})',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail: direction == 'in'
            ? 'a double tap on the map center changed nothing: the map may have zoom gestures off'
            : 'glint has one finger; zooming out takes two, or a double-tap-and-drag whose second touch must follow the tap faster than this device takes input',
        nextSteps: [
          if (direction == 'out') 'tap the app\'s own zoom out control if it has one (get_scene)',
          'or `map op:pan` to move without zooming',
        ],
      );
    }
    return _reply(session, 'zoomed $direction', before, after);
  }
}
