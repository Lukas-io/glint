import '../../interaction.dart';
import 'envelope.dart';
import 'post_action.dart';
import 'session.dart';

// Backend-direct coordinate actions, shared by tap / long_press / swipe / drag.
//
// The net injected ratio is coord / referenceSize: the backend divides physical
// pixels by dpr, so passing coord * dpr cancels out. Device mode uses dpr=1 over
// screenshot pixels; Flutter mode uses the real dpr over logical points.

Map<String, Object?> _ok(GlintSession session, Map<String, Object?> extra, InputReport? input) =>
    {'ok': true, ...extra, if (session.isDeviceMode) 'mode': 'device', if (input != null) 'input': input.toJson()};

String _via(InputReport? input) => input == null ? '' : ' · ${input.label}';

String _unit(GlintSession session) => session.isDeviceMode ? 'px' : 'pt';

/// Runs a raw-coordinate [action] and, in Flutter mode with [returnScene], adds
/// the changed-signal via pre/post snapshots — so a raw x,y tap answers "did
/// anything happen?" the same way a glintId tap does. Device mode has no Flutter
/// scene to compare, so it returns the bare action result unchanged.
Future<StructuredResponse> withCoordinateChange(
  GlintSession session,
  Future<StructuredResponse> Function() action, {
  bool returnScene = true,
  bool fetchScene = false,
}) async {
  if (session.isDeviceMode || !returnScene) return action();
  final pre = await snapshotPreAction(session);
  final response = await action();
  if (response.isError) return response;
  final post = await readPostActionState(session, pre, includeSceneText: fetchScene);
  return post == null ? response : response.mergeData(post.toData()).addWarnings([if (post.note != null) post.note!]);
}

/// Taps logical point [x], [y]; [label] names a native item the point was resolved from.
Future<StructuredResponse> coordinateTap(GlintSession session, double x, double y, {String? label}) async {
  final dpr = session.device.devicePixelRatio;
  try {
    await session.backend.tap(physicalX: (x * dpr).round(), physicalY: (y * dpr).round());
  } on Object catch (e) {
    return _failed('coordinate tap', '($x, $y)', e);
  }
  final input = session.backend.takeInput();
  return StructuredResponse(
    summary:
        '${label == null ? 'tapped' : 'tapped "$label" at'} (${pointText(x)}, ${pointText(y)}) ${_unit(session)}${_via(input)}',
    data: _ok(session, {'x': x, 'y': y, if (label != null) 'native': label}, input),
  );
}

Future<StructuredResponse> coordinateLongPress(GlintSession session, double x, double y, int durationMs,
    {String? label}) async {
  final dpr = session.device.devicePixelRatio;
  try {
    await session.backend.longPress(
      physicalX: (x * dpr).round(),
      physicalY: (y * dpr).round(),
      durationMs: durationMs,
    );
  } on Object catch (e) {
    return _failed('coordinate long-press', '($x, $y)', e);
  }
  final input = session.backend.takeInput();
  return StructuredResponse(
    summary:
        '${label == null ? 'long-pressed' : 'long-pressed "$label" at'} (${pointText(x)}, ${pointText(y)}) ${_unit(session)} for ${durationMs}ms${_via(input)}',
    data: _ok(session, {'x': x, 'y': y, if (label != null) 'native': label}, input),
  );
}

/// Pinches around logical [x], [y] to [scale]; [label] names what the center was resolved from.
Future<StructuredResponse> coordinatePinch(GlintSession session, double x, double y, double scale, int durationMs,
    {String? label}) async {
  final dpr = session.device.devicePixelRatio;
  try {
    await session.backend
        .pinch(physicalX: (x * dpr).round(), physicalY: (y * dpr).round(), scale: scale, durationMs: durationMs);
  } on Object catch (e) {
    return _failed('pinch', '(${pointText(x)}, ${pointText(y)})', e);
  }
  final input = session.backend.takeInput();
  return StructuredResponse(
    summary:
        '${scale > 1 ? 'spread' : 'pinched'} ${label == null ? '' : '$label '}at (${pointText(x)}, ${pointText(y)}) ${_unit(session)} to ${scale}x${_via(input)}',
    data: _ok(session, {'x': x, 'y': y, 'scale': scale}, input),
  );
}

Future<StructuredResponse> coordinateSwipe(
  GlintSession session,
  double x1,
  double y1,
  double x2,
  double y2,
  int durationMs, {
  String verb = 'swiped',
  int holdMs = 0,
}) async {
  final dpr = session.device.devicePixelRatio;
  try {
    await session.backend.swipe(
      physicalX1: (x1 * dpr).round(),
      physicalY1: (y1 * dpr).round(),
      physicalX2: (x2 * dpr).round(),
      physicalY2: (y2 * dpr).round(),
      durationMs: durationMs,
      holdMs: holdMs,
    );
  } on Object catch (e) {
    return _failed(verb, '($x1,$y1)->($x2,$y2)', e);
  }
  final input = session.backend.takeInput();
  return StructuredResponse(
    summary:
        '$verb (${pointText(x1)}, ${pointText(y1)}) -> (${pointText(x2)}, ${pointText(y2)}) ${_unit(session)}${_via(input)}',
    data: _ok(session, {'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2}, input),
  );
}

/// One named coordinate to range-check; [horizontal] picks the screen width over the height.
typedef NamedCoordinate = ({String name, double value, bool horizontal});

/// A point's two coordinates, named after the args they came from.
List<NamedCoordinate> pointCoordinates(double x, double y, {String xName = 'x', String yName = 'y'}) => [
      (name: xName, value: x, horizontal: true),
      (name: yName, value: y, horizontal: false),
    ];

/// A swipe's four coordinates, named after the args they came from.
List<NamedCoordinate> segmentCoordinates(({double x1, double y1, double x2, double y2}) s) => [
      ...pointCoordinates(s.x1, s.y1, xName: 'x1', yName: 'y1'),
      ...pointCoordinates(s.x2, s.y2, xName: 'x2', yName: 'y2'),
    ];

/// The screen a raw coordinate must land on: screen pixels in device mode, logical points in Flutter mode; null when its size is unknown or the app does not answer quickly.
Future<({double w, double h, double dpr, String unit})?> _coordinateSpace(GlintSession session) async {
  final device = session.device;
  final fixed = device.screenSize;
  if (session.isDeviceMode) {
    return fixed == null ? null : (w: fixed.w, h: fixed.h, dpr: 1.0, unit: 'px');
  }
  if (fixed != null && device.platform == DevicePlatform.ios) {
    final side = fixed.w > fixed.h ? fixed.w : fixed.h;
    return (w: side, h: side, dpr: device.devicePixelRatio, unit: 'pt');
  }
  try {
    final v = await session.resolver.resolveViewportNodeFree().timeout(const Duration(milliseconds: 1500));
    return (w: v.w, h: v.h, dpr: v.dpr, unit: 'pt');
  } on Object {
    return null;
  }
}

/// An invalidArgument reply naming every [coords] entry that lies off the screen, or null when all land on it.
Future<StructuredResponse?> rejectOffScreen(GlintSession session, String tool, List<NamedCoordinate> coords) async {
  final space = await _coordinateSpace(session);
  if (space == null) return null;
  final off = [
    for (final c in coords)
      if (c.value < 0 || c.value > (c.horizontal ? space.w : space.h)) c,
  ];
  if (off.isEmpty) return null;
  final unit = space.unit;
  String edge(NamedCoordinate c) => pointText(c.horizontal ? space.w : space.h);
  final problems = [
    for (final c in off) '${c.name}=${pointText(c.value)} is outside the ${edge(c)}-$unit screen',
  ];
  final device = session.isDeviceMode;
  final units = device
      ? 'coordinates here are screen pixels (device mode), the same pixels as the screenshot'
      : 'did you pass px? Coordinates are logical points (dpr ${pointText(space.dpr)})';
  final fits = [
    for (final c in off)
      if (!device && space.dpr > 1 && c.value / space.dpr <= (c.horizontal ? space.w : space.h))
        '${c.name}=${pointText(c.value / space.dpr)}',
  ];
  return StructuredResponse.error(
    summary: '$tool not sent: ${problems.first}${problems.length > 1 ? ' (+${problems.length - 1} more)' : ''}',
    errorKind: GlintErrorKind.invalidArgument,
    detail: '${problems.join('; ')}; $units',
    nextSteps: [
      if (fits.isNotEmpty) 'if those were device pixels, pass logical points instead: ${fits.join(', ')}',
      if (device)
        'read coordinates off a `device op:screenshot` of this screen'
      else ...[
        'pass logical points: resolve glintId:"<id>" returns logicalCenter and logicalBounds',
        'or target by glintId (fromGlintId / toGlintId, glintId) and skip coordinates',
      ],
    ],
  ).mergeData({
    'screen': {'w': space.w, 'h': space.h, 'unit': unit},
    if (!device) 'devicePixelRatio': space.dpr,
  });
}

StructuredResponse _failed(String what, String where, Object e) =>
    StructuredResponse.backendError('$what at $where was not delivered', e);
