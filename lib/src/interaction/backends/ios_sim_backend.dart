import 'dart:io';

import '../action.dart';
import '../backend.dart';
import '../image_size.dart';

/// iOS Simulator backend over the `glint-iossim` Swift helper (`native/ios_sim_bridge/`),
/// which speaks LOGICAL device points — so we undo the physical→logical conversion here.
class IosSimBackend implements InteractionBackend {
  IosSimBackend({
    required this.udid,
    required this.deviceLogicalWidth,
    required this.deviceLogicalHeight,
    required this.devicePixelRatio,
    required this.binaryPath,
  });

  final String udid;
  final double deviceLogicalWidth;
  final double deviceLogicalHeight;
  final double devicePixelRatio;
  final String binaryPath;

  @override
  String get label => 'ios-sim(${_shortPath(udid)})';

  // Lock:   IndigoHIDMessageForButton code 1 (verified Xcode 26).
  // Home:   bottom-edge swipe up; the sim reads any swipe starting in the home-indicator strip as a home press.
  // Unlock: Darwin notification `com.apple.BiometricKit_Sim.pearl.match` (Face ID auth) then a bottom-edge swipe past the authenticated-lock-screen state.
  //         From the Simulator.app binary: Pearl = Face ID, Oyster = Touch ID; default Pearl since modern test targets are Face ID.
  // Back:   left-edge swipe, the iOS back gesture (there is no back button on iPhone).
  // Others still gated; see source-of-truth §13.
  @override
  BackendCapabilities get capabilities => const BackendCapabilities(
        hardwareButtons: {
          HardwareButton.lock,
          HardwareButton.unlock,
          HardwareButton.home,
          HardwareButton.back,
        },
      );

  @override
  Future<void> tap({required int physicalX, required int physicalY}) {
    final p = _logical(physicalX, physicalY);
    return _run(_BridgeCommand.tap, [
      udid,
      '$deviceLogicalWidth',
      '$deviceLogicalHeight',
      '${p.x}',
      '${p.y}',
    ]);
  }

  @override
  Future<void> longPress({
    required int physicalX,
    required int physicalY,
    required int durationMs,
  }) {
    final p = _logical(physicalX, physicalY);
    return _run(_BridgeCommand.longPress, [
      udid,
      '$deviceLogicalWidth',
      '$deviceLogicalHeight',
      '${p.x}',
      '${p.y}',
      '$durationMs',
    ]);
  }

  @override
  Future<void> swipe({
    required int physicalX1,
    required int physicalY1,
    required int physicalX2,
    required int physicalY2,
    required int durationMs,
  }) {
    final from = _logical(physicalX1, physicalY1);
    final to = _logical(physicalX2, physicalY2);
    return _run(_BridgeCommand.swipe, [
      udid,
      '$deviceLogicalWidth',
      '$deviceLogicalHeight',
      '${from.x}', '${from.y}',
      '${to.x}', '${to.y}',
      '$durationMs',
    ]);
  }

  @override
  Future<void> typeText(String text) =>
      _run(_BridgeCommand.type, [udid, text]);

  @override
  Future<ScreenshotResult> screenshot(String path) async {
    final res = await Process.run(
      'xcrun',
      ['simctl', 'io', udid, 'screenshot', path],
    );
    if (res.exitCode != 0) {
      return ScreenshotResult(
        error: ((res.stderr as String?) ?? '').trim().isEmpty
            ? 'simctl screenshot exited ${res.exitCode}'
            : (res.stderr as String).trim(),
      );
    }
    final size = pngSize(path);
    return ScreenshotResult(path: path, width: size?.$1, height: size?.$2);
  }

  @override
  Future<void> pressHardwareButton(HardwareButton button) {
    switch (button) {
      case HardwareButton.lock:
        return _lock();
      case HardwareButton.home:
        return _bottomEdgeSwipeUp();
      case HardwareButton.unlock:
        return _unlockFaceID();
      case HardwareButton.back:
        return _leftEdgeSwipeBack();
      case HardwareButton.volumeUp:
      case HardwareButton.volumeDown:
      case HardwareButton.appSwitcher:
        throw UnsupportedBackendAction(
          label,
          'pressHardwareButton(${button.name}): not wired on Xcode 26 yet — '
              'see source-of-truth §13',
        );
    }
  }

  /// The iOS back gesture: a swipe that starts at the left screen edge and travels past the middle.
  Future<void> _leftEdgeSwipeBack() {
    final midY = deviceLogicalHeight / 2;
    return _run(_BridgeCommand.swipe, [
      udid,
      '$deviceLogicalWidth',
      '$deviceLogicalHeight',
      '8', '$midY',
      '${deviceLogicalWidth * 0.8}', '$midY',
      '350',
    ]);
  }

  Future<void> _bottomEdgeSwipeUp() {
    final centerX = deviceLogicalWidth / 2;
    return _run(_BridgeCommand.swipe, [
      udid,
      '$deviceLogicalWidth',
      '$deviceLogicalHeight',
      '$centerX', '${deviceLogicalHeight - 1}',
      '$centerX', '${deviceLogicalHeight / 2}',
      '200',
    ]);
  }

  /// Raw IndigoHID code 1 is Lock on Face ID devices (probe-button takes the raw int, dodging the bridge's older SimButton naming); waits for SpringBoard to report the lock.
  Future<void> _lock() async {
    await _run(_BridgeCommand.probeButton, [udid, '1']);
    await _awaitLockState(true);
  }

  /// Face ID match Darwin notification authenticates; after about a second the bottom-edge swipe moves past the authenticated lock screen. Retried once when SpringBoard still reports locked.
  Future<void> _unlockFaceID() async {
    for (var attempt = 0; attempt < 2; attempt++) {
      await _postFaceIdMatch();
      await Future<void>.delayed(Duration(milliseconds: attempt == 0 ? 1000 : 1500));
      await _bottomEdgeSwipeUp();
      if (await _awaitLockState(false) != true) return;
    }
  }

  Future<void> _postFaceIdMatch() async {
    final result = await Process.run(
      'notifyutil',
      ['-p', 'com.apple.BiometricKit_Sim.pearl.match'],
    );
    if (result.exitCode != 0) {
      throw BackendToolError(
        backend: label,
        command: 'notifyutil -p com.apple.BiometricKit_Sim.pearl.match',
        exitCode: result.exitCode,
        stderr: ((result.stderr as String?) ?? '').trim(),
      );
    }
  }

  /// SpringBoard's `com.apple.springboard.lockstate` inside the simulator: 1 locked, 0 unlocked.
  @override
  Future<bool?> lockState() async {
    final result = await Process.run('xcrun', [
      'simctl', 'spawn', udid, 'notifyutil', '-g', 'com.apple.springboard.lockstate',
    ]);
    if (result.exitCode != 0) return null;
    final m = RegExp(r'lockstate\s+(\d+)').firstMatch((result.stdout as String?) ?? '');
    return m == null ? null : m.group(1) != '0';
  }

  /// Polls [lockState] until it reads [locked], the read fails, or two seconds pass; returns the last read.
  Future<bool?> _awaitLockState(bool locked) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    bool? last;
    while (DateTime.now().isBefore(deadline)) {
      last = await lockState();
      if (last == null || last == locked) return last;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return last;
  }

  ({double x, double y}) _logical(int physicalX, int physicalY) => (
        x: physicalX / devicePixelRatio,
        y: physicalY / devicePixelRatio,
      );

  Future<void> _run(_BridgeCommand cmd, List<String> args) async {
    final argv = [cmd.cliName, ...args];
    final result = await Process.run(binaryPath, argv);
    if (result.exitCode != 0) {
      throw BackendToolError(
        backend: label,
        command: '${_shortPath(binaryPath)} ${argv.join(' ')}',
        exitCode: result.exitCode,
        stderr: ((result.stderr as String?) ?? '').trim(),
      );
    }
  }

  static String _shortPath(String s) {
    final last = s.split('/').last;
    return last.length <= 16 ? last : '${last.substring(0, 8)}…';
  }
}

/// Subcommands exposed by the `glint-iossim` Swift binary.
enum _BridgeCommand {
  tap('tap'),
  longPress('long-press'),
  swipe('swipe'),
  type('type'),
  probeButton('probe-button');

  const _BridgeCommand(this.cliName);
  final String cliName;
}
