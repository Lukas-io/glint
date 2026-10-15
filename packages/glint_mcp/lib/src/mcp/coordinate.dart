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

String _n(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

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
  final post =
      await readPostActionState(session, pre, includeSceneText: fetchScene);
  return post == null
      ? response
      : response.mergeData(post.toData()).addWarnings([if (post.note != null) post.note!]);
}

/// Taps logical point [x], [y]; [label] names a native item the point was resolved from.
Future<StructuredResponse> coordinateTap(
    GlintSession session, double x, double y, {String? label}) async {
  final dpr = session.device.devicePixelRatio;
  try {
    await session.backend
        .tap(physicalX: (x * dpr).round(), physicalY: (y * dpr).round());
  } on Object catch (e) {
    return _failed('coordinate tap', '($x, $y)', e);
  }
  final input = session.backend.takeInput();
  return StructuredResponse(
    summary: '${label == null ? 'tapped' : 'tapped "$label" at'} (${_n(x)}, ${_n(y)})${_via(input)}',
    data: _ok(session, {'x': x, 'y': y, if (label != null) 'native': label}, input),
  );
}

Future<StructuredResponse> coordinateLongPress(
    GlintSession session, double x, double y, int durationMs, {String? label}) async {
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
    summary: '${label == null ? 'long-pressed' : 'long-pressed "$label" at'} (${_n(x)}, ${_n(y)}) for ${durationMs}ms${_via(input)}',
    data: _ok(session, {'x': x, 'y': y, if (label != null) 'native': label}, input),
  );
}

/// Pinches around logical [x], [y] to [scale]; [label] names what the center was resolved from.
Future<StructuredResponse> coordinatePinch(GlintSession session, double x, double y, double scale, int durationMs, {String? label}) async {
  final dpr = session.device.devicePixelRatio;
  try {
    await session.backend.pinch(physicalX: (x * dpr).round(), physicalY: (y * dpr).round(), scale: scale, durationMs: durationMs);
  } on Object catch (e) {
    return _failed('pinch', '(${_n(x)}, ${_n(y)})', e);
  }
  final input = session.backend.takeInput();
  return StructuredResponse(
    summary: '${scale > 1 ? 'spread' : 'pinched'} ${label == null ? '' : '$label '}at (${_n(x)}, ${_n(y)}) to ${scale}x${_via(input)}',
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
    summary: '$verb ($x1,$y1) -> ($x2,$y2)${_via(input)}',
    data: _ok(session, const {}, input),
  );
}

StructuredResponse _failed(String what, String where, Object e) =>
    StructuredResponse.backendError('$what at $where was not delivered', e);
