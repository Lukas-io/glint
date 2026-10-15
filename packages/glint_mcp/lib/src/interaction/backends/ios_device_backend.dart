import 'dart:io';

import '../action.dart';
import '../backend.dart';
import 'flutter_input_backend.dart';
import '../device_hid.dart';
import '../image_size.dart';
import '../phone_status.dart';
import '../result.dart';
import '../screen_recording.dart';

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
        record: true,
        hardwareButtons: {
          HardwareButton.home,
          HardwareButton.lock,
          HardwareButton.unlock,
          HardwareButton.back,
          HardwareButton.appSwitcher,
          HardwareButton.volumeUp,
          HardwareButton.volumeDown,
        },
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
      throw BackendFailure(e.failure.errorKind, '${request['cmd']} on the iPhone failed: ${e.detail}',
          nextSteps: e.nextSteps, data: {'deviceInput': e.failure.name});
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
  Future<void> tapSequence(List<({int x, int y})> points, {required int intervalMs}) => _call({
        'cmd': 'taps',
        'points': [for (final p in points) _point(p.x, p.y, 0).sublist(0, 2)],
        'intervalMs': intervalMs,
      }, extraMs: points.length * (intervalMs + 80));

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

  /// A real drag between two fractions of the screen, [ms] long; a back swipe from x = 0 registers, a drag from the bottom edge does not.
  Future<void> _edgeDrag(double fx1, double fy1, double fx2, double fy2, {int ms = 300}) {
    final steps = (ms / _frameMs).ceil();
    return _touch([
      for (var i = 0; i <= steps; i++)
        _point(((fx1 + (fx2 - fx1) * i / steps) * pixelWidth).round(), ((fy1 + (fy2 - fy1) * i / steps) * pixelHeight).round(), ms * i ~/ steps),
    ]);
  }

  @override
  Future<void> pressHardwareButton(HardwareButton button) async {
    switch (button) {
      case HardwareButton.home || HardwareButton.lock || HardwareButton.volumeUp || HardwareButton.volumeDown:
        await _call({'cmd': 'button', 'name': button.name});
      case HardwareButton.back:
        await _edgeDrag(0, 0.5, 0.62, 0.5);
      case HardwareButton.appSwitcher:
        await _call({'cmd': 'button', 'name': 'home'});
        await _call({'cmd': 'button', 'name': 'home'});
      case HardwareButton.unlock:
        final status = await phoneStatus(udid);
        if (status?['passcodeRequired'] == true) {
          throw BackendFailure(GlintErrorKind.notOnThisDevice, 'the iPhone has a passcode, which only its owner can enter',
              nextSteps: const ['ask the user to unlock the phone, then retry'], data: const {'ability': 'unlock'});
        }
        await _call({'cmd': 'button', 'name': 'lock'});
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await _edgeDrag(0.5, 0.92, 0.5, 0.3, ms: 300);
    }
  }

  @override
  Future<ScreenRecording> startRecording(String path) async {
    final raw = '$path.h265';
    try {
      await hid.call({'cmd': 'recordStart', 'path': raw});
    } on DeviceHidError catch (e) {
      throw BackendFailure(e.failure.errorKind, 'recording the iPhone could not start: ${e.detail}', nextSteps: e.nextSteps);
    }
    return _DeviceHubRecording(hid, raw, path, run);
  }

  @override
  Future<void> close() => hid.stop();

  @override
  Future<void> warm() async {
    try {
      await hid.start();
    } on DeviceHidError {
      // reported on the first input that needs the helper
    }
  }

  @override
  Future<ScreenshotResult> screenshot(String path) async {
    try {
      await hid.call({'cmd': 'screenshot', 'path': path}, timeout: const Duration(seconds: 10));
      final size = pngSize(path);
      if (size != null) return ScreenshotResult(path: path, width: size.$1, height: size.$2);
    } on DeviceHidError {
      // devicectl below still works without the helper
    }
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

/// A Device Hub recording: the display's HEVC written by the helper, wrapped as mp4 without re-encoding when it stops.
class _DeviceHubRecording implements ScreenRecording {
  _DeviceHubRecording(this.hid, this.raw, this.path, this.run);

  final DeviceHid hid;
  final String raw;
  final String path;
  final ProcessRunner run;

  @override
  final DateTime startedAt = DateTime.now();

  @override
  Future<String> stop() async {
    final r = await hid.call({'cmd': 'recordStop'});
    final frames = (r['frames'] as num?)?.toInt() ?? 0;
    final seconds = (r['seconds'] as num?)?.toDouble() ?? 0;
    final fps = seconds <= 0 || frames == 0 ? 30.0 : (frames / seconds).clamp(1, 120).toDouble();
    final mux = await run('ffmpeg', ['-v', 'error', '-y', '-r', fps.toStringAsFixed(2), '-i', raw, '-c', 'copy', '-tag:v', 'hvc1', path]);
    if (mux.exitCode != 0) return raw;
    try {
      File(raw).deleteSync();
    } on Object {
      // the raw stream only takes space
    }
    return path;
  }
}

/// The Device Hub helper behind [backend], when it drives a physical iPhone.
DeviceHid? phoneHid(InteractionBackend backend) => switch (backend) {
      FlutterInputBackend(:final native) => phoneHid(native),
      IosDeviceBackend(:final hid) => hid,
      _ => null,
    };
