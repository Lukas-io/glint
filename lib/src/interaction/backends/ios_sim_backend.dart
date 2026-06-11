import 'dart:io';

import '../action.dart';
import '../backend.dart';

/// iOS Simulator backend that shells out to the `glint-iossim` Swift
/// helper (native/ios_sim_bridge/) for HID injection.
///
/// The Swift bridge takes LOGICAL device coordinates (points), not
/// physical pixels — it does its own ratio-to-screen math internally
/// using the device's logical size that we pass in. So this backend
/// undoes the physical→logical conversion that the [Interactor] applied
/// for adb's sake. Worth the conversion churn — it keeps the Interactor
/// path uniform across backends.
class IosSimBackend implements InteractionBackend {
  IosSimBackend({
    required this.udid,
    required this.deviceLogicalWidth,
    required this.deviceLogicalHeight,
    required this.devicePixelRatio,
    required this.binaryPath,
  });

  /// Booted simulator UDID. e.g. `E223E4B6-14EB-4331-A4E9-C1031EE08261`.
  final String udid;

  /// Logical width (points) of the device. Used to compute the 0..1
  /// ratio the HID message expects.
  final double deviceLogicalWidth;
  final double deviceLogicalHeight;

  /// DPR at boot. Used to translate the Interactor's physical-pixel
  /// arguments back to logical points before handing them to the bridge.
  final double devicePixelRatio;

  /// Path to the compiled `glint-iossim` binary. Defaults to the SwiftPM
  /// `.build/debug/glint-iossim` next to the project root when not
  /// overridden.
  final String binaryPath;

  @override
  String get label => 'ios-sim(${_short(udid)})';

  @override
  BackendCapabilities get capabilities => const BackendCapabilities(
        tap: true,
        longPress: false,    // not yet exposed by the Swift bridge — P2.2
        doubleTap: true,     // composed by the Interactor from two taps
        swipe: false,        // not yet exposed by the Swift bridge — P2.2
        typeText: false,     // hardware keyboard / NSEvent path — P2.2
        // No hardware-button entries yet — depends on
        // IndigoHIDMessageForButton support in the Swift bridge.
        hardwareButtons: <HardwareButton>{},
      );

  @override
  Future<void> tap({required int physicalX, required int physicalY}) {
    final lx = physicalX / devicePixelRatio;
    final ly = physicalY / devicePixelRatio;
    return _run([
      'tap',
      udid,
      '$deviceLogicalWidth',
      '$deviceLogicalHeight',
      '$lx',
      '$ly',
    ]);
  }

  @override
  Future<void> longPress({
    required int physicalX,
    required int physicalY,
    required int durationMs,
  }) async {
    throw UnsupportedBackendAction(
      label,
      'long-press is not yet exposed by glint-iossim (P2.2)',
    );
  }

  @override
  Future<void> swipe({
    required int physicalX1,
    required int physicalY1,
    required int physicalX2,
    required int physicalY2,
    required int durationMs,
  }) async {
    final lx1 = physicalX1 / devicePixelRatio;
    final ly1 = physicalY1 / devicePixelRatio;
    final lx2 = physicalX2 / devicePixelRatio;
    final ly2 = physicalY2 / devicePixelRatio;
    return _run([
      'swipe',
      udid,
      '$deviceLogicalWidth',
      '$deviceLogicalHeight',
      '$lx1', '$ly1',
      '$lx2', '$ly2',
      '$durationMs',
    ]);
  }

  @override
  Future<void> typeText(String text) async {
    throw UnsupportedBackendAction(
      label,
      'typing is not yet exposed by glint-iossim (P2.2)',
    );
  }

  @override
  Future<void> pressHardwareButton(HardwareButton button) async {
    throw UnsupportedBackendAction(
      label,
      'hardware buttons are not yet exposed by glint-iossim (P2.2)',
    );
  }

  Future<void> _run(List<String> args) async {
    final result = await Process.run(binaryPath, args);
    if (result.exitCode != 0) {
      throw BackendToolError(
        backend: label,
        command: '${_short(binaryPath)} ${args.join(' ')}',
        exitCode: result.exitCode,
        stderr: ((result.stderr as String?) ?? '').trim(),
      );
    }
  }

  static String _short(String s) {
    final last = s.split('/').last;
    if (last.length <= 16) return last;
    return '${last.substring(0, 8)}…';
  }
}
