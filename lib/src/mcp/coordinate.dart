import '../../interaction.dart';
import 'envelope.dart';
import 'session.dart';

// Backend-direct coordinate actions, shared by tap / long_press / swipe / drag.
//
// The net injected ratio is coord / referenceSize: the backend divides physical
// pixels by dpr, so passing coord * dpr cancels out. Device mode uses dpr=1 over
// screenshot pixels; Flutter mode uses the real dpr over logical points.

Map<String, Object?> _ok(GlintSession session, Map<String, Object?> extra) =>
    {'ok': true, ...extra, if (session.isDeviceMode) 'mode': 'device'};

Future<StructuredResponse> coordinateTap(
    GlintSession session, double x, double y) async {
  final dpr = session.device.devicePixelRatio;
  try {
    await session.backend
        .tap(physicalX: (x * dpr).round(), physicalY: (y * dpr).round());
  } on Object catch (e) {
    return _failed('coordinate tap', '($x, $y)', e);
  }
  return StructuredResponse(
    summary: 'tapped ($x, $y)',
    data: _ok(session, {'x': x, 'y': y}),
  );
}

Future<StructuredResponse> coordinateLongPress(
    GlintSession session, double x, double y, int durationMs) async {
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
  return StructuredResponse(
    summary: 'long-pressed ($x, $y) for ${durationMs}ms',
    data: _ok(session, {'x': x, 'y': y}),
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
}) async {
  final dpr = session.device.devicePixelRatio;
  try {
    await session.backend.swipe(
      physicalX1: (x1 * dpr).round(),
      physicalY1: (y1 * dpr).round(),
      physicalX2: (x2 * dpr).round(),
      physicalY2: (y2 * dpr).round(),
      durationMs: durationMs,
    );
  } on Object catch (e) {
    return _failed(verb, '($x1,$y1)->($x2,$y2)', e);
  }
  return StructuredResponse(
    summary: '$verb ($x1,$y1) -> ($x2,$y2)',
    data: _ok(session, const {}),
  );
}

StructuredResponse _failed(String what, String where, Object e) =>
    StructuredResponse.error(
      summary: '$what failed at $where',
      errorKind: GlintErrorKind.backendToolError,
      detail: '$e',
    );
