import '../../interaction.dart';
import 'envelope.dart';
import 'session.dart';

/// Backend-direct coordinate actions, shared by tap / long_press / swipe / drag.
///
/// The net ratio handed to the platform backend is `coord / referenceSize`
/// because the backend divides physical pixels by dpr before injecting:
///   • device mode  → dpr = 1 over screenshot pixels  → ratio = pixel / shot
///   • flutter mode → dpr over logical points         → ratio = logical / view
/// So the agent passes screenshot pixels in device mode and logical points in
/// flutter mode, and the same code is correct for both.
double _scale(GlintSession session) {
  final device = session.device;
  return device is IosSimulator ? device.devicePixelRatio : 1.0;
}

Map<String, Object?> _okData(GlintSession session, Map<String, Object?> extra) =>
    {'ok': true, ...extra, if (session.isDeviceMode) 'mode': 'device'};

Future<StructuredResponse> coordinateTap(
    GlintSession session, double x, double y) async {
  final dpr = _scale(session);
  try {
    await session.backend
        .tap(physicalX: (x * dpr).round(), physicalY: (y * dpr).round());
  } on Object catch (e) {
    return StructuredResponse.error(
      summary: 'coordinate tap failed at ($x, $y)',
      errorKind: GlintErrorKind.backendToolError,
      detail: '$e',
    );
  }
  return StructuredResponse(
    summary: 'tapped ($x, $y)',
    data: _okData(session, {'x': x, 'y': y}),
  );
}

Future<StructuredResponse> coordinateLongPress(
    GlintSession session, double x, double y, int durationMs) async {
  final dpr = _scale(session);
  try {
    await session.backend.longPress(
      physicalX: (x * dpr).round(),
      physicalY: (y * dpr).round(),
      durationMs: durationMs,
    );
  } on Object catch (e) {
    return StructuredResponse.error(
      summary: 'coordinate long-press failed at ($x, $y)',
      errorKind: GlintErrorKind.backendToolError,
      detail: '$e',
    );
  }
  return StructuredResponse(
    summary: 'long-pressed ($x, $y) for ${durationMs}ms',
    data: _okData(session, {'x': x, 'y': y}),
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
  final dpr = _scale(session);
  try {
    await session.backend.swipe(
      physicalX1: (x1 * dpr).round(),
      physicalY1: (y1 * dpr).round(),
      physicalX2: (x2 * dpr).round(),
      physicalY2: (y2 * dpr).round(),
      durationMs: durationMs,
    );
  } on Object catch (e) {
    return StructuredResponse.error(
      summary: '$verb (coordinate) failed ($x1,$y1)->($x2,$y2)',
      errorKind: GlintErrorKind.backendToolError,
      detail: '$e',
    );
  }
  return StructuredResponse(
    summary: '$verb ($x1,$y1) -> ($x2,$y2)',
    data: _okData(session, const {}),
  );
}
