import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'device.dart';

/// Raised when a launch can't complete; [logTail] holds the last `flutter run` lines.
class LaunchError implements Exception {
  LaunchError(this.message, {this.logTail});
  final String message;
  final String? logTail;
  @override
  String toString() => 'LaunchError: $message';
}

/// Why [dir] is not a Flutter app `flutter run` can start, or null when it is.
String? flutterAppProblem(String dir) {
  final pubspec = File('$dir/pubspec.yaml');
  if (!pubspec.existsSync()) return 'no pubspec.yaml in $dir';
  final declaresFlutter = RegExp(r'^\s+flutter:\s*\n\s+sdk:\s*flutter', multiLine: true)
      .hasMatch(pubspec.readAsStringSync());
  if (!declaresFlutter) return '$dir/pubspec.yaml does not depend on the flutter SDK';
  if (!File('$dir/lib/main.dart').existsSync()) return 'no lib/main.dart in $dir';
  return null;
}

/// Boots devices and starts/stops Flutter apps so `attach` can recover from cold.
class AppLauncher {
  const AppLauncher({this.flutterPath = 'flutter'});

  final String flutterPath;

  /// Boot the iOS sim (idempotent) and open Simulator; returns null on success else an error.
  Future<String?> ensureBooted(DevicePlatform platform, String deviceId) async {
    if (platform != DevicePlatform.ios) return null; // android boot deferred
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
    await Process.run('open', ['-a', 'Simulator']);
    try {
      await Process.run('xcrun', ['simctl', 'bootstatus', deviceId, '-b']);
    } on Object {
      // bootstatus just waits; proceed if unavailable.
    }
    return null;
  }

  /// `flutter run` [projectDir] on [deviceId], or with [attachTo] `flutter attach` to the app already serving that VM URI; returns the tool's VM URI + live process, throws [LaunchError] on failure/timeout.
  Future<({Uri uri, Process process})> launchApp({
    required String projectDir,
    required String deviceId,
    Uri? attachTo,
    Duration timeout = const Duration(seconds: 180),
    Duration poll = const Duration(seconds: 2),
    Duration progressEvery = const Duration(seconds: 15),
    void Function(int elapsedSec, String? phase)? onProgress,
  }) async {
    final verb = attachTo == null ? 'run' : 'attach';
    final Process proc;
    try {
      proc = await Process.start(
        flutterPath,
        [verb, '-d', deviceId, if (attachTo != null) ...['--debug-url', '$attachTo']],
        workingDirectory: projectDir,
      );
    } on Object catch (e) {
      throw LaunchError('could not start `$flutterPath $verb`: $e');
    }
    var exited = false;
    unawaited(proc.exitCode.then((_) => exited = true));

    // Bounded — the listeners keep draining for the app's whole life (the
    // process outlives this call for kill_app), so accumulate only the tail.
    final out = _BoundedLog();
    proc.stdout.transform(utf8.decoder).listen(out.add);
    proc.stderr.transform(utf8.decoder).listen(out.add);

    final start = DateTime.now();
    final deadline = start.add(timeout);
    var nextUpdate = start.add(progressEvery);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(poll);
      final text = out.text;
      final uri = vmUriPattern.firstMatch(text)?.group(0);
      if (uri != null) {
        final parsed = Uri.tryParse(uri);
        if (parsed != null) return (uri: parsed, process: proc);
      }
      if (exited || _looksFailed(text)) {
        proc.kill();
        throw LaunchError('flutter $verb failed', logTail: _tail(text));
      }
      final now = DateTime.now();
      if (onProgress != null && now.isAfter(nextUpdate)) {
        onProgress(now.difference(start).inSeconds, _phase(text));
        nextUpdate = now.add(progressEvery);
      }
    }
    proc.kill();
    final phase = _phase(out.text);
    throw LaunchError(
      'timed out after ${timeout.inSeconds}s waiting for the VM service'
      '${phase == null ? "" : " (last: $phase)"}',
      logTail: _tail(out.text),
    );
  }

  /// Current `flutter run` phase — the last build/launch-phase line, else the last line.
  static String? _phase(String text) {
    final lines = text
        .split(RegExp(r'[\r\n]'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;
    for (final l in lines.reversed) {
      if (_phaseHints.any(l.contains)) return l;
    }
    return lines.last;
  }

  static const _phaseHints = [
    'Launching', 'Running Xcode', 'Xcode build', 'Building', 'Syncing',
    'Installing', 'Compiling', 'Resolving', 'Waiting for',
  ];

  /// Terminate an app: `simctl terminate` (iOS) / `am force-stop` (Android); null on success.
  Future<String?> terminateApp(
      DevicePlatform platform, String deviceId, String appId,
      {String adbPath = 'adb'}) async {
    try {
      final r = platform == DevicePlatform.ios
          ? await Process.run('xcrun', ['simctl', 'terminate', deviceId, appId])
          : await Process.run(
              adbPath, ['-s', deviceId, 'shell', 'am', 'force-stop', appId]);
      if (r.exitCode != 0) {
        final err = ((r.stderr as String?) ?? '').trim();
        return err.isEmpty ? 'exit ${r.exitCode}' : err;
      }
      return null;
    } on Object catch (e) {
      return '$e';
    }
  }

  /// Shut down a device: `simctl shutdown` (iOS) / `adb emu kill` (Android); null on success.
  Future<String?> shutdown(DevicePlatform platform, String deviceId,
      {String adbPath = 'adb'}) async {
    try {
      final r = platform == DevicePlatform.ios
          ? await Process.run('xcrun', ['simctl', 'shutdown', deviceId])
          : await Process.run(adbPath, ['-s', deviceId, 'emu', 'kill']);
      if (r.exitCode != 0) {
        final err = ((r.stderr as String?) ?? '').trim();
        if (err.contains('current state: Shutdown')) return null; // already off
        return err.isEmpty ? 'exit ${r.exitCode}' : err;
      }
      return null;
    } on Object catch (e) {
      return '$e';
    }
  }

  static final vmUriPattern = RegExp(
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

/// Append-only log that keeps only the last [_cap] chars, so draining a
/// long-lived process's output never grows unbounded.
class _BoundedLog {
  static const _cap = 16384;
  String text = '';
  void add(String s) {
    text += s;
    if (text.length > _cap) text = text.substring(text.length - _cap);
  }
}
