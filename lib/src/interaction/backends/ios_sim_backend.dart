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
        longPress: true,
        doubleTap: true,     // composed by the Interactor from two taps
        swipe: true,         // proven on Xcode 26 (2-payload + `field1=2` move marker)
        // Typing + hardware buttons are gated on the per-Xcode mapping
        // research described in source-of-truth §13. The Swift bridge has
        // the dispatch code wired (see `IndigoHIDMessageForKeyboardArbitrary`
        // and `IndigoHIDMessageForButton`); the gap is empirical: keymaps
        // and button enum case → integer codes shift per Xcode major.
        typeText: false,
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
  }) {
    final lx = physicalX / devicePixelRatio;
    final ly = physicalY / devicePixelRatio;
    return _run([
      'long-press',
      udid,
      '$deviceLogicalWidth',
      '$deviceLogicalHeight',
      '$lx',
      '$ly',
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
    // The Swift bridge has the `type` command wired through
    // IndigoHIDMessageForKeyboardArbitrary with a printable-ASCII HID
    // usage table (`native/ios_sim_bridge/Sources/glint-iossim/HidKeymap.swift`).
    // Whether the simulator's input pipeline actually consumes those
    // messages on Xcode 26 is the unverified bit — until source-of-truth
    // §13 lands a green checkmark, we refuse and steer the agent at the
    // adb path.
    throw UnsupportedBackendAction(
      label,
      'typeText: Swift dispatch wired but Xcode 26 mapping is not yet '
          'verified end-to-end — see source-of-truth §13 compat matrix',
    );
  }

  @override
  Future<void> pressHardwareButton(HardwareButton button) async {
    // The Swift bridge has the `button` command wired through
    // IndigoHIDMessageForButton (see SimBridge.swift's `pressButton`),
    // but the button-code → physical-button mapping for iPhone 17 Pro /
    // iOS 26.5 is empirically only `code=1 ⇒ Apple Pay (Face ID prompt)`.
    // The richer mapping needs `IndigoHIDTargetForScreen` (now identified
    // as the right target source) plus a per-device codes table — see
    // source-of-truth §13.
    throw UnsupportedBackendAction(
      label,
      'pressHardwareButton: Swift dispatch wired but Xcode 26 button '
          'codes + IndigoHIDTargetForScreen integration is incomplete — '
          'see source-of-truth §13 compat matrix',
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
