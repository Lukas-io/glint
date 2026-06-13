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

  // Hardware buttons: see source-of-truth §13 "Xcode 26 open work".
  // Bridge has dispatch wired (IndigoHIDMessageForButton), but the
  // per-device button-code mapping + IndigoHIDTargetForScreen integration
  // isn't complete. Lock works (code 1), Home on Face ID needs the gesture
  // path, others need the per-screen target.
  @override
  BackendCapabilities get capabilities => const BackendCapabilities(
        hardwareButtons: <HardwareButton>{},
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
    throw UnsupportedBackendAction(
      label,
      'pressHardwareButton: per-device IndigoHIDButton mapping incomplete — '
          'see source-of-truth §13 compat matrix',
    );
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
  type('type');

  const _BridgeCommand(this.cliName);
  final String cliName;
}
