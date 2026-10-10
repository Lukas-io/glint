import 'dart:io';

import '../action.dart';
import '../backend.dart';
import '../image_size.dart';

/// A paired physical iPhone: screenshots through `devicectl`; glint has no input path to it yet, so every gesture is refused with the point to ask the user to tap.
class IosDeviceBackend extends InteractionBackend {
  IosDeviceBackend({required this.udid, required this.devicePixelRatio, this.run = Process.run});

  final String udid;
  final double devicePixelRatio;
  final ProcessRunner run;

  @override
  String get label => 'ios-device($udid)';

  @override
  BackendCapabilities get capabilities => const BackendCapabilities(
        tap: false,
        longPress: false,
        doubleTap: false,
        swipe: false,
        typeText: false,
      );

  String _point(int x, int y) =>
      '(${(x / devicePixelRatio).round()}, ${(y / devicePixelRatio).round()}) in points';

  Never _refuse(String what, String ask) => throw UnsupportedBackendAction(
        label,
        '$what: glint cannot send input to a physical iPhone yet',
        nextSteps: [ask, 'then call get_scene to read the result'],
      );

  @override
  Future<void> tap({required int physicalX, required int physicalY}) async =>
      _refuse('tap', 'ask the user to tap the phone at ${_point(physicalX, physicalY)}');

  @override
  Future<void> longPress({required int physicalX, required int physicalY, required int durationMs}) async =>
      _refuse('long press', 'ask the user to press and hold the phone at ${_point(physicalX, physicalY)}');

  @override
  Future<void> swipe({
    required int physicalX1,
    required int physicalY1,
    required int physicalX2,
    required int physicalY2,
    required int durationMs,
    int holdMs = 0,
  }) async =>
      _refuse('swipe', 'ask the user to swipe from ${_point(physicalX1, physicalY1)} to ${_point(physicalX2, physicalY2)}');

  @override
  Future<void> tapSequence(List<({int x, int y})> points, {required int intervalMs}) async =>
      _refuse('tap', 'ask the user to tap ${points.map((p) => _point(p.x, p.y)).join(', then ')}');

  @override
  Future<void> typeText(String text, {int? keyDelayMs}) async =>
      _refuse('type', 'ask the user to type the text into the focused field (${text.length} chars)');

  @override
  Future<void> pressHardwareButton(HardwareButton button) async =>
      _refuse('hardware_button ${button.name}', 'ask the user to press ${button.name} on the phone');

  @override
  Future<ScreenshotResult> screenshot(String path) async {
    final ProcessResult r;
    try {
      r = await run('xcrun', ['devicectl', 'device', 'capture', 'screenshot', '--device', udid, '--destination', path, '-q']);
    } on Object catch (e) {
      return ScreenshotResult(error: 'could not run devicectl: $e');
    }
    final file = File(path);
    if (r.exitCode != 0 || !file.existsSync()) {
      return ScreenshotResult(error: 'devicectl could not capture the screen: ${'${r.stderr}'.trim()}');
    }
    final size = pngSize(path);
    return ScreenshotResult(path: path, width: size?.$1, height: size?.$2);
  }
}
