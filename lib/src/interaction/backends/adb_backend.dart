import 'dart:io';

import '../action.dart';
import '../backend.dart';
import '../image_size.dart';
import '../key_codes.dart';
import '../screen_recording.dart';

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
  AdbBackend({
    required this.deviceSerial,
    this.adbPath = 'adb',
    this.run = Process.run,
  });

  final String deviceSerial;
  final String adbPath;
  final ProcessRunner run;

  @override
  String get label => 'adb($deviceSerial)';

  @override
  BackendCapabilities get capabilities => const BackendCapabilities(
        keys: true,
        record: true,
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
    int holdMs = 0,
  }) =>
      // `input swipe` cannot rest at the end; spreading the hold over the move lowers the lift velocity instead.
      _shell([
        'input',
        'swipe',
        '$physicalX1',
        '$physicalY1',
        '$physicalX2',
        '$physicalY2',
        '${durationMs + holdMs}',
      ]);

  @override
  Future<void> tapSequence(List<({int x, int y})> points,
          {required int intervalMs}) =>
      tapEachInTurn(this, points, intervalMs);

  /// Latin only; non-ASCII would need an IME via `am broadcast`.
  @override
  Future<void> typeText(String text, {int? keyDelayMs}) async {
    if (keyDelayMs == null || text.length < 2) return _inputText(text);
    final chars = text.split('');
    for (var i = 0; i < chars.length; i++) {
      await _inputText(chars[i]);
      if (i < chars.length - 1) {
        await Future<void>.delayed(Duration(milliseconds: keyDelayMs));
      }
    }
  }

  Future<void> _inputText(String text) async {
    for (final chunk in splitLiteralPercentS(text)) {
      await _shell(
          ['input', 'text', quoteForDeviceShell(chunk.replaceAll(' ', '%s'))]);
    }
  }

  @override
  Future<ScreenRecording> startRecording(String path) => AdbRecording.start(
      adbPath: adbPath, serial: deviceSerial, localPath: path);

  /// Not read on Android yet; callers fall back to the app lifecycle.
  @override
  Future<bool?> lockState() async => null;

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
  Future<void> pressKey(KeyName key,
      {int count = 1, Set<KeyModifier> modifiers = const {}}) async {
    final code = key.androidKeyCode;
    if (modifiers.isEmpty) {
      await _shell(['input', 'keyevent', ...List.filled(count, '$code')]);
      return;
    }
    final combo = [
      ...modifiers.map((m) => '${m.androidKeyCode}'),
      '$code',
    ];
    for (var i = 0; i < count; i++) {
      await _shell(['input', 'keycombination', ...combo]);
    }
  }

  @override
  Future<void> selectAll() =>
      _shell(['input', 'keycombination', '113', '29']); // CTRL_LEFT + A

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
    final result = await run(
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

/// adb joins shell arguments into one command line for the device's `sh`, so text is single-quoted to arrive as one literal argument.
String quoteForDeviceShell(String arg) => "'${arg.replaceAll("'", "'\\''")}'";

/// `input text` turns `%s` into a space, so text is split between `%` and `s` to keep a literal `%s`.
List<String> splitLiteralPercentS(String text) {
  final chunks = <String>[];
  var start = 0;
  for (var i = 0; i < text.length - 1; i++) {
    if (text[i] == '%' && text[i + 1] == 's') {
      chunks.add(text.substring(start, i + 1));
      start = i + 1;
    }
  }
  chunks.add(text.substring(start));
  return chunks.where((c) => c.isNotEmpty).toList();
}
