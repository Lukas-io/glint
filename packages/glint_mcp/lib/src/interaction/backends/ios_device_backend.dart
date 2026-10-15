import 'dart:io';

import '../action.dart';
import '../backend.dart';
import '../device_hid.dart';
import '../image_size.dart';

/// A paired physical iPhone driven like a hand would: real touches, keys and buttons through Xcode's Device Hub service, screenshots through `devicectl`.
class IosDeviceBackend extends InteractionBackend {
  IosDeviceBackend({
    required this.udid,
    required this.devicePixelRatio,
    required this.pixelWidth,
    required this.pixelHeight,
    DeviceHid? hid,
    this.run = Process.run,
  }) : hid = hid ?? DeviceHid(udid: udid);

  final String udid;
  final double devicePixelRatio;
  final double pixelWidth;
  final double pixelHeight;
  final DeviceHid hid;
  final ProcessRunner run;

  static const _frameMs = 16;

  @override
  String get label => 'ios-device($udid)';

  @override
  BackendCapabilities get capabilities => const BackendCapabilities(
        keys: true,
        hardwareButtons: {HardwareButton.home, HardwareButton.lock, HardwareButton.volumeUp, HardwareButton.volumeDown},
      );

  List<int> _point(int x, int y, int ms) => [
        (x.clamp(0, pixelWidth) / pixelWidth * 65535).round(),
        (y.clamp(0, pixelHeight) / pixelHeight * 65535).round(),
        ms,
      ];

  Future<void> _call(Map<String, Object?> request, {int extraMs = 0}) async {
    try {
      await hid.call(request, timeout: Duration(milliseconds: 20000 + extraMs));
    } on DeviceHidError catch (e) {
      throw UnsupportedBackendAction(label, '${request['cmd']} on the iPhone failed (${e.kind}): ${e.detail}', nextSteps: e.nextSteps);
    }
  }

  Future<void> _touch(List<List<int>> points) => _call({'cmd': 'touch', 'points': points}, extraMs: points.last[2]);

  @override
  Future<void> tap({required int physicalX, required int physicalY}) =>
      _touch([_point(physicalX, physicalY, 0), _point(physicalX, physicalY, 50)]);

  @override
  Future<void> longPress({required int physicalX, required int physicalY, required int durationMs}) =>
      _touch([_point(physicalX, physicalY, 0), _point(physicalX, physicalY, durationMs)]);

  @override
  Future<void> swipe({
    required int physicalX1,
    required int physicalY1,
    required int physicalX2,
    required int physicalY2,
    required int durationMs,
    int holdMs = 0,
  }) {
    final steps = (durationMs / _frameMs).ceil().clamp(2, 400);
    return _touch([
      _point(physicalX1, physicalY1, 0),
      if (holdMs > 0) _point(physicalX1, physicalY1, holdMs),
      for (var i = 1; i <= steps; i++)
        _point(
          (physicalX1 + (physicalX2 - physicalX1) * i / steps).round(),
          (physicalY1 + (physicalY2 - physicalY1) * i / steps).round(),
          holdMs + (durationMs * i / steps).round(),
        ),
    ]);
  }

  @override
  Future<void> tapSequence(List<({int x, int y})> points, {required int intervalMs}) =>
      tapEachInTurn(this, points, intervalMs);

  @override
  Future<void> typeText(String text, {int? keyDelayMs}) =>
      _call({'cmd': 'type', 'text': text, if (keyDelayMs != null) 'keyDelayMs': keyDelayMs}, extraMs: text.length * ((keyDelayMs ?? 12) + 20));

  @override
  Future<void> pressKey(KeyName key, {int count = 1, Set<KeyModifier> modifiers = const {}}) => _call({
        'cmd': 'key',
        'key': key.name,
        'count': count,
        'modifiers': [for (final m in modifiers) m.name],
      }, extraMs: count * 40);

  @override
  Future<void> selectAll() => _call({'cmd': 'key', 'key': 'a', 'modifiers': ['cmd']});

  @override
  Future<void> pressHardwareButton(HardwareButton button) => switch (button) {
        HardwareButton.home ||
        HardwareButton.lock ||
        HardwareButton.volumeUp ||
        HardwareButton.volumeDown =>
          _call({'cmd': 'button', 'name': button.name}),
        HardwareButton.unlock => throw UnsupportedBackendAction(label, 'unlock: a physical iPhone unlocks with its own Face ID or passcode',
            nextSteps: const ['press hardware_button lock to wake the screen, then swipe up from the bottom edge']),
        HardwareButton.back => throw UnsupportedBackendAction(label, 'back: iOS has no back button',
            nextSteps: const ["tap the app's back button, or swipe right from the left edge"]),
        HardwareButton.appSwitcher => throw UnsupportedBackendAction(label, 'appSwitcher: iOS has no switcher button',
            nextSteps: const ['swipe up from the bottom edge to the middle and hold (swipe holdMs:600)']),
      };

  @override
  Future<void> close() => hid.stop();

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
