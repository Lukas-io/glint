import 'dart:io';

import '../action.dart';
import '../backend.dart';

/// iOS Simulator backend. Shells out to the `glint-iossim` Swift helper
/// (`native/ios_sim_bridge/`) which speaks LOGICAL device points, so we
/// undo the [Interactor]'s physical→logical conversion here.
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

  // Lock: raw IndigoHIDMessageForButton code 1 (verified Xcode 26).
  // Home: Face ID gesture — bottom-edge swipe up; the iOS Sim interprets
  //   any swipe starting within the home-indicator strip as a home press.
  // Others still gated; see source-of-truth §13.
  @override
  BackendCapabilities get capabilities => const BackendCapabilities(
        hardwareButtons: {HardwareButton.lock, HardwareButton.home},
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
  Future<void> pressHardwareButton(HardwareButton button) {
    switch (button) {
      case HardwareButton.lock:
        // The Swift bridge's SimButton.home enum case happens to map to
        // raw code 1, which on Face ID devices actually fires Lock /
        // Apple Pay overlay (the bridge's enum naming pre-dates the
        // §13 reverse engineering). probe-button takes the raw int and
        // dodges the misleading name.
        return _run(_BridgeCommand.probeButton, [udid, '1']);
      case HardwareButton.home:
        // Face ID gesture: bottom-edge swipe up. Start within the
        // home-indicator strip and travel ~half the viewport.
        final centerX = deviceLogicalWidth / 2;
        return _run(_BridgeCommand.swipe, [
          udid,
          '$deviceLogicalWidth',
          '$deviceLogicalHeight',
          '$centerX', '${deviceLogicalHeight - 1}',
          '$centerX', '${deviceLogicalHeight / 2}',
          '200',
        ]);
      case HardwareButton.back:
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
