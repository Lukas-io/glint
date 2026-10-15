import 'dart:io';

import 'package:dart_mcp/server.dart';

import '../../interaction.dart';
import '../interaction/image_size.dart';
import '../../perception.dart';
import 'envelope.dart';
import 'session.dart';
import 'tool.dart';
import 'tool_args.dart';
import 'tools/wait_for_tool.dart';

/// A part of the screen in fractions (0-1) of its width and height.
typedef ScreenRegion = ({double top, double bottom, double left, double right});

/// Logical points of margin around a `glintId` crop.
const _cropPadding = 8.0;

/// One app's capture, cropped when asked: the PNG, its size, and the logical rect it covers (null for the whole screen).
typedef _Shot = ({
  String path,
  int width,
  int height,
  ({double x, double y, double w, double h})? logical,
  AppSession app
});

/// `device op:screenshot` on attached apps: optional wait, crop to a widget or region, and several apps side by side.
Future<StructuredResponse> attachedScreenshot(
    GlintSession session, Map<String, Object?> args, CallToolRequest request) async {
  final glintId = args['glintId'] as String?;
  final regionResult = _readRegion(args['region']);
  if (regionResult.error != null) return regionResult.error!;
  final region = regionResult.region;
  final names = (args['apps'] as List?)?.cast<Object?>().map((a) => '$a').toList();
  final afterMs = argInt(args, 'afterMs') ?? 0;
  final waitFor = args['waitFor'] as String?;
  final shaped = glintId != null || region != null || names != null;
  final inline = argBool(args, 'inline') ?? shaped;
  final maxSize = argInt(args, 'maxSize') ?? (shaped ? 720 : session.config.screenshotMaxSize);
  if (glintId != null && region != null) {
    return _bad('pass glintId or region, not both');
  }
  if (afterMs < 0 || afterMs > 30000) return _bad('afterMs must be between 0 and 30000');

  final targets = <AppSession>[];
  for (final name in names ?? const <String>[]) {
    final matches = session.matchApps(name);
    if (matches.length != 1) return GlintTool.unknownAppResponse(session, name, matches);
    targets.add(matches.single);
  }
  if (targets.isEmpty) targets.add(session.active!);

  if (waitFor != null) {
    final waited = await session.withApp(
      targets.first,
      () async => await const WaitForTool()
          .handle(session, CallToolRequest(name: 'wait_for', arguments: {'text': waitFor}, meta: request.meta)),
    );
    if (waited.isError) return waited;
  }
  if (afterMs > 0) await Future<void>.delayed(Duration(milliseconds: afterMs));

  final shots = <_Shot>[];
  for (final app in targets) {
    final shot = await session.withApp(app, () => _capture(session, app, glintId: glintId, region: region));
    if (shot.error != null) return shot.error!;
    shots.add(shot.shot!);
  }

  if (shots.length == 1) return _single(session, shots.single, inline: inline, maxSize: maxSize);
  return _composite(shots, maxSize: maxSize);
}

Future<({_Shot? shot, StructuredResponse? error})> _capture(GlintSession session, AppSession app,
    {String? glintId, ScreenRegion? region}) async {
  final capture = await app.captureNow('explicit');
  final size = capture == null ? null : pngSize(capture.path);
  if (capture == null || size == null) {
    return (
      shot: null,
      error: StructuredResponse.error(
        summary: 'screenshot of ${app.label} failed',
        errorKind: GlintErrorKind.backendToolError,
        nextSteps: const ['check the device is booted and unlocked, then retry'],
      ),
    );
  }
  final (w, h) = size;
  if (glintId == null && region == null) {
    return (shot: (path: capture.path, width: w, height: h, logical: null, app: app), error: null);
  }

  final ({double x, double y, double w, double h}) logical;
  final double scale;
  if (glintId != null) {
    final bounds = await _bounds(session, app, glintId);
    if (bounds.error != null) return (shot: null, error: bounds.error);
    final b = bounds.rect!;
    scale = w / bounds.viewWidth!;
    final viewH = h / scale;
    final x0 = (b.x - _cropPadding).clamp(0.0, bounds.viewWidth!);
    final y0 = (b.y - _cropPadding).clamp(0.0, viewH);
    final x1 = (b.x + b.w + _cropPadding).clamp(0.0, bounds.viewWidth!);
    final y1 = (b.y + b.h + _cropPadding).clamp(0.0, viewH);
    logical = (x: x0, y: y0, w: x1 - x0, h: y1 - y0);
  } else {
    final r = region!;
    final dpr = app.deviceMode ? 1.0 : app.device.devicePixelRatio;
    scale = dpr;
    final viewW = w / scale, viewH = h / scale;
    logical = (x: r.left * viewW, y: r.top * viewH, w: (r.right - r.left) * viewW, h: (r.bottom - r.top) * viewH);
  }
  final px = (logical.x * scale).round(), py = (logical.y * scale).round();
  final pw = (logical.w * scale).round().clamp(1, w - px), ph = (logical.h * scale).round().clamp(1, h - py);
  if (pw < 2 || ph < 2) {
    return (
      shot: null,
      error: StructuredResponse.error(
        summary: '${glintId ?? 'region'} covers no visible part of the screen',
        errorKind: GlintErrorKind.offViewport,
        nextSteps: [if (glintId != null) 'scroll_to_find glintId:"$glintId" first, then capture'],
      ),
    );
  }
  final cropped = await cropImage(capture.path, x: px, y: py, w: pw, h: ph);
  if (cropped == null) {
    return (
      shot: null,
      error: StructuredResponse.error(
        summary: 'could not crop the screenshot',
        errorKind: GlintErrorKind.backendToolError,
        detail: Platform.isMacOS
            ? 'sips failed on ${capture.path}'
            : 'ImageMagick `convert` is needed to crop on this host',
        nextSteps: [if (!Platform.isMacOS) 'install ImageMagick, or take the whole screen without glintId/region'],
      ),
    );
  }
  return (shot: (path: cropped, width: pw, height: ph, logical: logical, app: app), error: null);
}

/// The widget's on-screen rect in logical points (its bounds are node-local, its center global) and the view width, read on the active app.
Future<({({double x, double y, double w, double h})? rect, double? viewWidth, StructuredResponse? error})> _bounds(
    GlintSession session, AppSession app, String glintId) async {
  if (app.deviceMode) {
    return (
      rect: null,
      viewWidth: null,
      error: StructuredResponse.error(
        summary: 'glintId crops need a Flutter app; ${app.label} is in device mode',
        errorKind: GlintErrorKind.flutterModeRequired,
        nextSteps: const ['crop with region:{top,bottom} instead'],
      ),
    );
  }
  final scene = await session.reader.readSummary();
  try {
    if (scene.findByGlintId(glintId) == null) {
      return (
        rect: null,
        viewWidth: null,
        error: StructuredResponse.error(
          summary: 'no node with glintId "$glintId" on ${app.label}',
          errorKind: GlintErrorKind.unresolvedTarget,
          nextSteps: [
            if (didYouMean(suggestIds(scene.glintIds, glintId)) case final h?) h,
            'get_scene app:"${app.label}" to read its ids',
          ],
        ),
      );
    }
    final c = await session.resolver.resolve(scene, glintId);
    final b = c.logicalBounds;
    final global = (x: c.logicalCenter.x - b.w / 2, y: c.logicalCenter.y - b.h / 2, w: b.w, h: b.h);
    return (rect: global, viewWidth: c.logicalViewSize.w, error: null);
  } finally {
    await scene.dispose();
  }
}

Future<StructuredResponse> _single(GlintSession session, _Shot shot,
    {required bool inline, required int maxSize}) async {
  final l = shot.logical;
  ModelImage? sent;
  String? coordinates;
  if (inline && l == null) {
    final full = await session.withApp(shot.app, () => session.modelImage(shot.path, maxSize: maxSize));
    sent = full.image;
    coordinates = full.coordinates;
  } else if (inline) {
    sent = await prepareModelImage(shot.path,
        width: shot.width,
        height: shot.height,
        maxSize: maxSize,
        format: session.config.screenshotFormat,
        quality: session.config.screenshotQuality);
    coordinates =
        'image is ${sent.width}x${sent.height} covering logical ${_n(l!.x)},${_n(l.y)} ${_n(l.w)}x${_n(l.h)}; '
        'tap x = ${_n(l.x)} + image x × ${(l.w / sent.width).toStringAsFixed(3)}, '
        'y = ${_n(l.y)} + image y × ${(l.h / sent.height).toStringAsFixed(3)}';
  }
  return StructuredResponse(
    summary:
        '${l == null ? 'screenshot' : 'cropped screenshot'} of ${shot.app.label} saved: ${shot.path} (${shot.width}x${shot.height} px)',
    nextSteps: [if (sent == null) 'read the image at ${shot.path} to see the screen'],
    data: {
      'ok': true,
      'path': shot.path,
      'width': shot.width,
      'height': shot.height,
      if (l != null) 'logicalRect': {'x': l.x, 'y': l.y, 'w': l.w, 'h': l.h},
      if (coordinates != null) 'coordinates': coordinates,
      if (sent != null) 'sent': {'width': sent.width, 'height': sent.height, 'mimeType': sent.mimeType},
    },
    imagePaths: [if (sent != null) sent.path],
  );
}

Future<StructuredResponse> _composite(List<_Shot> shots, {required int maxSize}) async {
  final dir = Directory('${Directory.systemTemp.path}/glint-captures');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final dst = '${dir.path}/side-by-side-${DateTime.now().millisecondsSinceEpoch}.png';
  final height = maxSize > 0 ? maxSize : shots.map((s) => s.height).reduce((a, b) => a > b ? a : b);
  final composed = await composeSideBySide([for (final s in shots) s.path], dst, height: height);
  final legend = 'left to right: ${shots.map((s) => '${s.app.label} (${s.app.deviceName ?? s.app.id})').join(', ')}';
  if (composed == null) {
    return StructuredResponse(
      summary: 'captured ${shots.length} apps but could not join them; $legend',
      warnings: [
        Platform.isMacOS
            ? 'sips could not join the images'
            : 'ImageMagick `convert` is needed to join images on this host'
      ],
      data: {
        'ok': true,
        'paths': [for (final s in shots) s.path]
      },
      nextSteps: const ['read each image path instead'],
    );
  }
  final size = pngSize(composed);
  final sent = size == null
      ? null
      : await prepareModelImage(composed,
          width: size.$1, height: size.$2, maxSize: maxSize * 2, format: 'jpeg', quality: 75);
  return StructuredResponse(
    summary: '${shots.length} apps side by side, $legend',
    data: {
      'ok': true,
      'path': composed,
      'apps': [
        for (final s in shots) {'app': s.app.label, 'device': s.app.deviceName ?? s.app.id, 'path': s.path}
      ],
      if (size != null) 'width': size.$1,
      if (size != null) 'height': size.$2,
    },
    imagePaths: [if (sent != null) sent.path],
    nextSteps: const ['for tap coordinates, take one app at a time; a side-by-side image has none'],
  );
}

({ScreenRegion? region, StructuredResponse? error}) _readRegion(Object? raw) {
  if (raw == null) return (region: null, error: null);
  if (raw is! Map) return (region: null, error: _bad('region is {top, bottom, left, right} fractions of the screen'));
  double? f(String k) => switch (raw[k]) { num n => n.toDouble(), String s => double.tryParse(s), _ => null };
  final r = (top: f('top') ?? 0, bottom: f('bottom') ?? 1, left: f('left') ?? 0, right: f('right') ?? 1);
  final ok = [r.top, r.bottom, r.left, r.right].every((v) => v >= 0 && v <= 1) && r.top < r.bottom && r.left < r.right;
  if (!ok) return (region: null, error: _bad('region fractions must be 0-1 with top < bottom and left < right'));
  return (region: r, error: null);
}

StructuredResponse _bad(String summary) =>
    StructuredResponse.error(summary: summary, errorKind: GlintErrorKind.invalidArgument);

String _n(double v) => v.toStringAsFixed(0);
