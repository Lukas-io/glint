import 'dart:io';

import '../action.dart';
import '../backend.dart';
import '../image_size.dart';
import '../ios_toolchain.dart';
import '../key_codes.dart';
import '../screen_recording.dart';

/// iOS Simulator backend over the `glint-iossim` Swift helper (`native/ios_sim_bridge/`),
/// which speaks LOGICAL device points — so we undo the physical→logical conversion here.
class IosSimBackend implements InteractionBackend {
  IosSimBackend({
    required this.udid,
    required this.deviceLogicalWidth,
    required this.deviceLogicalHeight,
    required this.devicePixelRatio,
    required this.binaryPath,
    this.toolchain,
    this.run = Process.run,
  });

  final ProcessRunner run;
  final String udid;
  final double deviceLogicalWidth;
  final double deviceLogicalHeight;
  final double devicePixelRatio;
  final String binaryPath;

  /// Attach's toolchain check; when it names a blocker, bridge commands are refused.
  final IosToolchain? toolchain;

  @override
  String get label => 'ios-sim(${_shortPath(udid)})';

  // Lock:   IndigoHIDMessageForButton code 1 (verified Xcode 26).
  // Home:   IndigoHID button code 0 (verified iOS 26.5); a bottom-edge swipe reaches the app as a scroll instead.
  // Unlock: Darwin notification `com.apple.BiometricKit_Sim.pearl.match` (Face ID auth) then a bottom-edge swipe past the authenticated-lock-screen state.
  //         From the Simulator.app binary: Pearl = Face ID, Oyster = Touch ID; default Pearl since modern test targets are Face ID.
  // Back:   left-edge swipe, the iOS back gesture (there is no back button on iPhone).
  // Others still gated; see source-of-truth §13.
  @override
  BackendCapabilities get capabilities => const BackendCapabilities(
        keys: true,
        record: true,
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
  Future<void> tapSequence(List<({int x, int y})> points,
      {required int intervalMs}) {
    return _run(_BridgeCommand.taps, [
      udid,
      '$deviceLogicalWidth',
      '$deviceLogicalHeight',
      '$intervalMs',
      for (final pt in points) ...() {
        final p = _logical(pt.x, pt.y);
        return ['${p.x}', '${p.y}'];
      }(),
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
    int holdMs = 0,
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
      if (holdMs > 0) '$holdMs',
    ]);
  }

  @override
  Future<void> typeText(String text, {int? keyDelayMs}) => _run(
      _BridgeCommand.type, [udid, text, if (keyDelayMs != null) '$keyDelayMs']);

  @override
  Future<void> pressKey(KeyName key,
          {int count = 1, Set<KeyModifier> modifiers = const {}}) =>
      _run(_BridgeCommand.key,
          [udid, '${key.hidUsage}', '$count', '${hidModifierMask(modifiers)}']);

  @override
  Future<void> selectAll() =>
      _run(_BridgeCommand.key, [udid, '4', '1', '8']); // usage 0x04=a, mask 8=cmd
  @override
  Future<ScreenRecording> startRecording(String path) =>
      SimctlRecording.start(udid: udid, path: path);

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
        return _run(_BridgeCommand.probeButton, [udid, '0']);
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

  /// Raw IndigoHID code 1 is Lock on Face ID devices (probe-button takes the raw int, dodging the bridge's older SimButton naming); waits for SpringBoard to report the lock and the dark display.
  Future<void> _lock() async {
    await _run(_BridgeCommand.probeButton, [udid, '1']);
    await _awaitLockState(true);
    // Settle into display-off so unlock knows to wake it; the flag trails the display.
    await _awaitSpringboardFlag('hasBlankedScreen', true,
        within: const Duration(seconds: 6));
  }

  /// Face ID match Darwin notification authenticates; after about a second the bottom-edge swipe moves past the authenticated lock screen. Each round re-reads lock and display state, waking a dark display first, since matching behind a dark display unlocks without lighting it.
  Future<void> _unlockFaceID() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final locked = await lockState();
      final blanked = await _displayBlanked();
      if (locked == false && blanked == false) {
        if (attempt > 0) await Future<void>.delayed(unlockSettle);
        return;
      }
      if (locked == false && blanked == null) return;
      if (locked == false) {
        // Unlocked behind a dark display: a side press only flashes it, so lock it cleanly and unlock from there.
        await _lock();
        continue;
      }
      if (blanked == true) {
        await _run(_BridgeCommand.probeButton, [udid, '1']);
        await _awaitSpringboardFlag('hasBlankedScreen', false);
        // A just-woken lock screen ignores a Face ID match for about a second.
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      await _postFaceIdMatch();
      await Future<void>.delayed(const Duration(seconds: 1));
      await _bottomEdgeSwipeUp();
      await _awaitLockState(false);
    }
    await Future<void>.delayed(unlockSettle);
  }

  /// SpringBoard reports unlocked while the lock screen is still sliding away; a touch in that window strands it half-dismissed.
  static const unlockSettle = Duration(milliseconds: 700);

  /// SpringBoard's `com.apple.springboard.hasBlankedScreen`: true while the display is off. It trails the display by a second or more.
  Future<bool?> _displayBlanked() => _springboardFlag('hasBlankedScreen');

  /// Polls a SpringBoard flag until it reads [value] or [within] passes.
  Future<void> _awaitSpringboardFlag(String name, bool value,
      {Duration within = const Duration(seconds: 2)}) async {
    final deadline = DateTime.now().add(within);
    while (DateTime.now().isBefore(deadline)) {
      if (await _springboardFlag(name) == value) return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
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
  Future<bool?> lockState() => _springboardFlag('lockstate');

  /// Reads `com.apple.springboard.<name>` inside the simulator: true when non-zero, null when unreadable.
  Future<bool?> _springboardFlag(String name) async {
    final result = await Process.run('xcrun', [
      'simctl', 'spawn', udid, 'notifyutil', '-g', 'com.apple.springboard.$name',
    ]);
    if (result.exitCode != 0) return null;
    final m = RegExp('$name\\s+(\\d+)').firstMatch((result.stdout as String?) ?? '');
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
    final blocker = toolchain?.blocker;
    if (blocker != null) {
      throw IosToolchainBlocked(label, blocker, toolchain!.nextSteps);
    }
    final argv = [cmd.cliName, ...args];
    final result = await run(binaryPath, argv);
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
  taps('taps'),
  longPress('long-press'),
  swipe('swipe'),
  type('type'),
  key('key'),
  probeButton('probe-button');

  const _BridgeCommand(this.cliName);
  final String cliName;
}
