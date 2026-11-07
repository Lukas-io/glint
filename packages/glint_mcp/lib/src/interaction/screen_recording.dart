import 'dart:async';
import 'dart:io';

import 'backend.dart';
import 'bounded_process.dart';

/// A running display recording; [stop] finalises it and returns the local video path.
abstract class ScreenRecording {
  DateTime get startedAt;
  Future<String> stop();
}

/// Records an iOS simulator display via `xcrun simctl io <udid> recordVideo`.
class SimctlRecording implements ScreenRecording {
  SimctlRecording._(this._process, this.path, this.startedAt, this._label);

  final Process _process;
  final String path;
  @override
  final DateTime startedAt;
  final String _label;

  /// Starts recording and returns once simctl reports the first frame ("Recording started" on stderr), or throws [BackendToolError] on early exit or timeout.
  static Future<SimctlRecording> start({
    required String udid,
    required String path,
    Duration startTimeout = const Duration(seconds: 5),
  }) async {
    final proc = await startManaged('xcrun', [
      'simctl',
      'io',
      udid,
      'recordVideo',
      '--codec=h264',
      '--force',
      path,
    ]);
    final started = Completer<DateTime>();
    final err = StringBuffer();
    proc.stderr.transform(const SystemEncoding().decoder).listen((chunk) {
      err.write(chunk);
      if (!started.isCompleted && chunk.contains('Recording started')) {
        started.complete(DateTime.now());
      }
    });
    unawaited(proc.exitCode.then((code) {
      if (!started.isCompleted) {
        started.completeError(BackendToolError(
          backend: 'ios-sim($udid)',
          command: 'simctl io recordVideo',
          exitCode: code,
          stderr: err.toString().trim(),
        ));
      }
    }));
    final DateTime t0;
    try {
      t0 = await started.future.timeout(startTimeout);
    } on TimeoutException {
      proc.kill(ProcessSignal.sigkill);
      throw BackendToolError(
        backend: 'ios-sim($udid)',
        command: 'simctl io recordVideo',
        exitCode: -1,
        stderr: 'recorder did not report "Recording started" within '
            '${startTimeout.inSeconds}s: ${err.toString().trim()}',
      );
    }
    return SimctlRecording._(proc, path, t0, 'ios-sim($udid)');
  }

  @override
  Future<String> stop() async {
    _process.kill(ProcessSignal.sigint);
    try {
      await _process.exitCode.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
    }
    if (!File(path).existsSync()) {
      throw BackendToolError(
        backend: _label,
        command: 'simctl io recordVideo (stop)',
        exitCode: -1,
        stderr: 'no video file written to $path',
      );
    }
    return path;
  }
}

/// Records an Android device via `adb shell screenrecord`, pulled to the local path on stop.
class AdbRecording implements ScreenRecording {
  AdbRecording._(this._process, this._adbPath, this._serial, this.path, this.startedAt);

  static const remotePath = '/sdcard/glint-rec.mp4';

  final Process _process;
  final String _adbPath;
  final String _serial;
  final String path;
  @override
  final DateTime startedAt;

  static List<String> startArgs(String serial) => [
        '-s', serial, 'shell', 'screenrecord', //
        '--time-limit', '30', remotePath,
      ];
  static List<String> existsArgs(String serial) => ['-s', serial, 'shell', 'ls', remotePath];
  static List<String> stopArgs(String serial) => ['-s', serial, 'shell', 'pkill', '-l', 'INT', 'screenrecord'];
  static List<String> pullArgs(String serial, String local) => ['-s', serial, 'pull', remotePath, local];
  static List<String> removeArgs(String serial) => ['-s', serial, 'shell', 'rm', '-f', remotePath];

  static Future<AdbRecording> start({
    required String adbPath,
    required String serial,
    required String localPath,
    Duration startTimeout = const Duration(seconds: 5),
  }) async {
    await runBounded(adbPath, removeArgs(serial),
        timeout: const Duration(seconds: 10), phase: 'adb clearing the old recording');
    final proc = await startManaged(adbPath, startArgs(serial), label: 'adb screenrecord');
    final deadline = DateTime.now().add(startTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if ((await proc.exitCode.timeout(const Duration(milliseconds: 1), onTimeout: () => -999)) != -999) {
        throw BackendToolError(
          backend: 'adb($serial)',
          command: 'adb shell screenrecord',
          exitCode: 1,
          stderr: 'screenrecord exited before recording started',
        );
      }
      final ls = await runBounded(adbPath, existsArgs(serial),
          timeout: const Duration(seconds: 5), phase: 'adb checking the recording started');
      if (ls.exitCode == 0 && !(ls.stdout as String).contains('No such file')) {
        return AdbRecording._(proc, adbPath, serial, localPath, DateTime.now());
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    proc.kill(ProcessSignal.sigkill);
    throw BackendToolError(
      backend: 'adb($serial)',
      command: 'adb shell screenrecord',
      exitCode: -1,
      stderr: 'screenrecord did not create $remotePath within '
          '${startTimeout.inSeconds}s',
    );
  }

  @override
  Future<String> stop() async {
    await runBounded(_adbPath, stopArgs(_serial),
        timeout: const Duration(seconds: 10), phase: 'adb stopping screenrecord');
    try {
      await _process.exitCode.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
    }
    final pull = await runBounded(_adbPath, pullArgs(_serial, path),
        timeout: const Duration(seconds: 60), phase: 'adb pulling the recording');
    await runBounded(_adbPath, removeArgs(_serial),
        timeout: const Duration(seconds: 10), phase: 'adb removing the recording');
    if (pull.exitCode != 0 || !File(path).existsSync()) {
      throw BackendToolError(
        backend: 'adb($_serial)',
        command: 'adb pull',
        exitCode: pull.exitCode,
        stderr: (pull.stderr as String?)?.trim() ?? 'pull failed',
      );
    }
    return path;
  }
}
