import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'device.dart';

/// Raised when a launch can't complete. [logTail] carries the last lines of
/// `flutter run` output so the caller can surface the real reason.
class LaunchError implements Exception {
  LaunchError(this.message, {this.logTail});
  final String message;
  final String? logTail;
  @override
  String toString() => 'LaunchError: $message';
}

/// Boots devices and starts Flutter apps so `attach` can recover from a cold
/// machine. Process work is best-effort; failures surface as [LaunchError]
/// with the build log.
class AppLauncher {
  const AppLauncher({this.flutterPath = 'flutter'});

  final String flutterPath;

  /// Ensure the simulator/emulator is up. iOS boots via `simctl` (idempotent —
  /// already-booted is success) and opens the Simulator UI. Returns null on
  /// success, or an error string. Android emulator boot needs the AVD name
  /// (a serial only exists once running), so it's deferred — an absent device
  /// surfaces later as a clear `flutter run` failure.
  Future<String?> ensureBooted(DevicePlatform platform, String deviceId) async {
    if (platform != DevicePlatform.ios) return null;
    final ProcessResult boot;
    try {
      boot = await Process.run('xcrun', ['simctl', 'boot', deviceId]);
    } on Object catch (e) {
      return 'could not run simctl boot: $e';
    }
    final stderr = (boot.stderr as String?) ?? '';
    final alreadyBooted = stderr.contains('Booted'); // "current state: Booted"
    if (boot.exitCode != 0 && !alreadyBooted) {
      return 'simctl boot failed: ${stderr.trim()}';
    }
    // Surface the Simulator window and block until the device is fully booted.
    await Process.run('open', ['-a', 'Simulator']);
    try {
      await Process.run('xcrun', ['simctl', 'bootstatus', deviceId, '-b']);
    } on Object {
      // bootstatus is a convenience wait; proceed even if it's unavailable.
    }
    return null;
  }

  /// `flutter run -d [deviceId]` in [projectDir], polling its output for the VM
  /// service URI up to [timeout]. The process is detached so the app outlives
  /// the tool call. Returns the URI, or throws [LaunchError] on build failure
  /// or timeout.
  Future<Uri> launchApp({
    required String projectDir,
    required String deviceId,
    Duration timeout = const Duration(seconds: 180),
    Duration poll = const Duration(seconds: 2),
  }) async {
    final Process proc;
    try {
      proc = await Process.start(
        flutterPath,
        ['run', '-d', deviceId],
        workingDirectory: projectDir,
        mode: ProcessStartMode.detachedWithStdio,
      );
    } on Object catch (e) {
      throw LaunchError('could not start `$flutterPath run`: $e');
    }

    final out = StringBuffer();
    proc.stdout.transform(utf8.decoder).listen(out.write);
    proc.stderr.transform(utf8.decoder).listen(out.write);

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(poll);
      final text = out.toString();
      final uri = _vmUriPattern.firstMatch(text)?.group(0);
      if (uri != null) {
        final parsed = Uri.tryParse(uri);
        if (parsed != null) return parsed;
      }
      if (_looksFailed(text)) {
        throw LaunchError('flutter run failed', logTail: _tail(text));
      }
    }
    throw LaunchError(
      'timed out after ${timeout.inSeconds}s waiting for the VM service',
      logTail: _tail(out.toString()),
    );
  }

  static final _vmUriPattern = RegExp(
    r'http://(?:127\.0\.0\.1|localhost):\d+/[A-Za-z0-9_=+\-/]*',
  );

  static bool _looksFailed(String text) =>
      text.contains('Error launching application') ||
      text.contains('No supported devices connected') ||
      text.contains('Unable to find a target device') ||
      (text.contains('Gradle task') && text.contains('failed')) ||
      text.contains('the Dart compiler exited unexpectedly') ||
      text.contains('Error: No pubspec.yaml file found');

  static String _tail(String text, {int lines = 12}) {
    final all = text.trimRight().split('\n');
    return all.length <= lines ? all.join('\n') : all.sublist(all.length - lines).join('\n');
  }
}
