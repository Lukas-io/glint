import 'dart:io';

import '../action.dart';
import '../backend.dart';

/// Android emulator / device backend over `adb shell input`.
///
/// Notes carried forward from the P0 smoke harness:
///   - `adb` lives at `~/Library/Android/sdk/platform-tools/adb` on dev
///     machines that installed Android Studio, but isn't always on PATH.
///     We accept an explicit [adbPath]; defaults to bare `"adb"`.
///   - On Android, OS-level taps go to whichever app is foreground. If
///     the target app is alive but backgrounded, the Flutter view has a
///     zero-size surface and Module B's geometry is garbage. The
///     [foregroundPackage] hint is exposed so callers (or the MCP
///     server in P4) can bring the target up before tapping; this
///     backend itself stays focused on input delivery.
class AdbBackend implements InteractionBackend {
  AdbBackend({
    required this.deviceSerial,
    this.adbPath = 'adb',
  });

  /// `-s <serial>` argument. e.g. `emulator-5554`.
  final String deviceSerial;

  /// Path to the `adb` binary. Defaults to whatever's on PATH.
  final String adbPath;

  @override
  String get label => 'adb($deviceSerial)';

  @override
  BackendCapabilities get capabilities => const BackendCapabilities(
        tap: true,
        longPress: true,
        doubleTap: true,
        swipe: true,
        typeText: true,
        hardwareButtons: {
          HardwareButton.home,
          HardwareButton.back,
          HardwareButton.lock,
          HardwareButton.volumeUp,
          HardwareButton.volumeDown,
          HardwareButton.appSwitcher,
        },
      );

  @override
  Future<void> tap({required int physicalX, required int physicalY}) {
    return _run(['input', 'tap', '$physicalX', '$physicalY']);
  }

  @override
  Future<void> longPress({
    required int physicalX,
    required int physicalY,
    required int durationMs,
  }) {
    // `input swipe x y x y duration` with zero displacement is the
    // canonical adb long-press pattern.
    return _run([
      'input',
      'swipe',
      '$physicalX',
      '$physicalY',
      '$physicalX',
      '$physicalY',
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
    return _run([
      'input',
      'swipe',
      '$physicalX1',
      '$physicalY1',
      '$physicalX2',
      '$physicalY2',
      '$durationMs',
    ]);
  }

  @override
  Future<void> typeText(String text) {
    // `input text` interprets `%s` as space and chokes on quotes/specials.
    // Encode each character — Latin charset only for v1; non-ASCII text
    // input requires `am broadcast` to an IME, which is out of v1 scope.
    final escaped = text
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('`', '\\`')
        .replaceAll(' ', '%s');
    return _run(['input', 'text', escaped]);
  }

  @override
  Future<void> pressHardwareButton(HardwareButton button) {
    final code = switch (button) {
      HardwareButton.home => 3,         // KEYCODE_HOME
      HardwareButton.back => 4,         // KEYCODE_BACK
      HardwareButton.lock => 26,        // KEYCODE_POWER (lock toggle)
      HardwareButton.volumeUp => 24,    // KEYCODE_VOLUME_UP
      HardwareButton.volumeDown => 25,  // KEYCODE_VOLUME_DOWN
      HardwareButton.appSwitcher => 187, // KEYCODE_APP_SWITCH
    };
    return _run(['input', 'keyevent', '$code']);
  }

  /// Shell-on-device wrapper. `adb -s <serial> shell <args>`.
  Future<void> _run(List<String> shellArgs) async {
    final result = await Process.run(
      adbPath,
      ['-s', deviceSerial, 'shell', ...shellArgs],
    );
    if (result.exitCode != 0) {
      throw BackendToolError(
        backend: label,
        command: 'adb shell ${shellArgs.join(' ')}',
        exitCode: result.exitCode,
        stderr: (result.stderr as String).trim(),
      );
    }
  }
}
