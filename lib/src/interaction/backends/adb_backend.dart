import 'dart:io';

import '../action.dart';
import '../backend.dart';
import '../image_size.dart';

/// Android KEYCODE_* values for glint's [HardwareButton]. `unlock` is null —
/// no stock biometric-match equivalent and per-OEM lock-screen behaviour; surfaced as [UnsupportedBackendAction] until v1.
extension AndroidKeyCode on HardwareButton {
  int? get androidKeyCode => switch (this) {
        HardwareButton.home => 3,
        HardwareButton.back => 4,
        HardwareButton.lock => 26, // KEYCODE_POWER (toggle)
        HardwareButton.volumeUp => 24,
        HardwareButton.volumeDown => 25,
        HardwareButton.appSwitcher => 187,
        HardwareButton.unlock => null,
      };
}

/// Android emulator / device backend over `adb shell input`.
class AdbBackend implements InteractionBackend {
  AdbBackend({required this.deviceSerial, this.adbPath = 'adb'});

  final String deviceSerial;
  final String adbPath;

  @override
  String get label => 'adb($deviceSerial)';

  @override
  BackendCapabilities get capabilities => const BackendCapabilities(
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
  Future<void> tap({required int physicalX, required int physicalY}) =>
      _shell(['input', 'tap', '$physicalX', '$physicalY']);

  // adb has no dedicated long-press; `input swipe x y x y duration` with
  // zero displacement is the canonical workaround.
  @override
  Future<void> longPress({
    required int physicalX,
    required int physicalY,
    required int durationMs,
  }) =>
      _shell([
        'input',
        'swipe',
        '$physicalX',
        '$physicalY',
        '$physicalX',
        '$physicalY',
        '$durationMs',
      ]);

  @override
  Future<void> swipe({
    required int physicalX1,
    required int physicalY1,
    required int physicalX2,
    required int physicalY2,
    required int durationMs,
  }) =>
      _shell([
        'input',
        'swipe',
        '$physicalX1',
        '$physicalY1',
        '$physicalX2',
        '$physicalY2',
        '$durationMs',
      ]);

  // `input text` treats `%s` as space and chokes on quote / backtick.
  // Latin only — non-ASCII would need an IME via `am broadcast` (v2).
  @override
  Future<void> typeText(String text) {
    final escaped = text
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('`', '\\`')
        .replaceAll(' ', '%s');
    return _shell(['input', 'text', escaped]);
  }

  @override
  Future<void> pressHardwareButton(HardwareButton button) {
    final code = button.androidKeyCode;
    if (code == null) {
      throw UnsupportedBackendAction(
        label,
        'pressHardwareButton(${button.name}): no Android keyevent equivalent',
      );
    }
    return _shell(['input', 'keyevent', '$code']);
  }

  @override
  Future<ScreenshotResult> screenshot(String path) async {
    // `exec-out screencap -p` streams raw PNG bytes to stdout.
    final ProcessResult res;
    try {
      res = await Process.run(
        adbPath,
        ['-s', deviceSerial, 'exec-out', 'screencap', '-p'],
        stdoutEncoding: null, // keep stdout as raw bytes
      );
    } on Object catch (e) {
      return ScreenshotResult(error: 'adb screencap failed: $e');
    }
    if (res.exitCode != 0) {
      return ScreenshotResult(
        error: (res.stderr as String?)?.trim().isNotEmpty == true
            ? (res.stderr as String).trim()
            : 'adb screencap exited ${res.exitCode}',
      );
    }
    try {
      File(path).writeAsBytesSync(res.stdout as List<int>);
    } on Object catch (e) {
      return ScreenshotResult(error: 'could not write screenshot: $e');
    }
    final size = pngSize(path);
    return ScreenshotResult(path: path, width: size?.$1, height: size?.$2);
  }

  Future<void> _shell(List<String> shellArgs) async {
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
