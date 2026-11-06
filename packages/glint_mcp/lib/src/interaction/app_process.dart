import 'dart:async';
import 'dart:io';

import 'backend.dart' show ProcessRunner;
import 'device.dart';
import 'native_crashes.dart';
import 'sim_control.dart';

/// What is known about an app's process after its VM connection dropped.
class AppProcessVerdict {
  const AppProcessVerdict({required this.running, this.reason, this.exitStatus, this.crash});

  /// True while the process lives, false once it is gone, null when the device cannot be asked.
  final bool? running;

  /// Why the process is gone or the device cannot be asked, when known.
  final String? reason;

  /// The exit status the host logged for the process, as logged (for example `0xfbfbfbfb`).
  final String? exitStatus;
  final NativeCrash? crash;
}

/// Finds out whether an app's process still runs and why it ended, from the host's side of the device.
class AppProcessProbe {
  const AppProcessProbe({this.run = Process.run, this.sim = const SimControl()});

  final ProcessRunner run;
  final SimControl sim;

  /// The simulator host's own reason, such as `Termination requested by simulator host`.
  static final _hostReason =
      RegExp(r'(Termination requested by[^\n]*|jetsam[^\n]*|terminated due to[^\n]*)', caseSensitive: false);
  static final _exitStatus =
      RegExp(r'(?:exit(?:ed)?(?: with)?(?: code| status)?[: =]+|status[: =]+)(0x[0-9a-fA-F]+|-?\d+)');

  static const limit = Duration(seconds: 10);

  /// The verdict for [appId]; [since] and [pid] keep a simulator's host log to this process's own lines. Unknown when the device is slower than [limit].
  Future<AppProcessVerdict> check(DeviceTarget device, {required String? appId, DateTime? since, int? pid}) async {
    try {
      return await _check(device, appId, since, pid).timeout(limit);
    } on TimeoutException {
      return const AppProcessVerdict(running: null, reason: 'the device did not answer in time');
    }
  }

  Future<AppProcessVerdict> _check(DeviceTarget device, String? appId, DateTime? since, int? pid) async {
    switch (device) {
      case IosSimulator():
        return _simulator(device.udid, appId, since, pid);
      case AndroidDevice():
        return _android(device, appId);
      case IosDevice():
        return const AppProcessVerdict(running: null, reason: 'a physical iPhone cannot be asked whether the app runs');
    }
  }

  Future<AppProcessVerdict> _simulator(String udid, String? appId, DateTime? since, int? pid) async {
    final state = await sim.state(udid);
    if (state != null && state != 'Booted') {
      return AppProcessVerdict(running: false, reason: 'the simulator is $state');
    }
    if (appId == null) return const AppProcessVerdict(running: null, reason: 'the app id is not known');
    final running = await sim.isAppRunning(udid, appId);
    if (running == null) return const AppProcessVerdict(running: null, reason: 'the simulator did not answer');
    if (running) return const AppProcessVerdict(running: true);
    final hostLine = await _simulatorLog(udid, appId, since, pid);
    return AppProcessVerdict(
      running: false,
      reason: hostLine == null ? null : readableReason(hostLine),
      exitStatus: hostLine == null ? null : _exitStatus.firstMatch(hostLine)?.group(1),
    );
  }

  static final _exitCode = RegExp(r'code:([A-Za-z][\w-]*)\(0x[0-9a-fA-F]+\)');
  static const _exitCodeNames = {
    'force-quit': 'force-quit (the app was swiped away or killed from outside)',
    'crash': 'crashed',
    'jetsam': 'killed by jetsam (out of memory)',
  };

  /// A short reason out of a SpringBoard exit line (`code:force-quit(0x..)`), a host line or a runningboardd line.
  static String readableReason(String line) {
    final code = _exitCode.firstMatch(line)?.group(1);
    if (code != null) return _exitCodeNames[code] ?? code;
    final host = _hostReason.firstMatch(line)?.group(1)?.trim();
    if (host != null) return host;
    if (RegExp(r'Removing assertions for terminated process', caseSensitive: false).hasMatch(line)) {
      return 'the process was terminated';
    }
    return line.length > 240 ? '${line.substring(0, 239)}…' : line;
  }

  static int _lineRank(String line) {
    if (_exitCode.hasMatch(line) ||
        RegExp(r'Process exited|jetsam|Termination requested', caseSensitive: false).hasMatch(line)) {
      return 3;
    }
    if (line.contains('SpringBoard[') || line.contains('runningboardd[')) return 2;
    return 1;
  }

  static String _logTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Future<String?> _simulatorLog(String udid, String appId, DateTime? since, int? pid) async {
    if (since == null) return null;
    final predicate = 'process != "log" AND eventMessage CONTAINS "$appId" AND '
        '(eventMessage CONTAINS[c] "terminat" OR eventMessage CONTAINS[c] "jetsam" OR eventMessage CONTAINS[c] "exited")';
    try {
      final r = await run('xcrun', [
        'simctl',
        'spawn',
        udid,
        'log',
        'show',
        '--start',
        _logTime(since.toLocal()),
        '--style',
        'compact',
        '--predicate',
        predicate,
      ]).timeout(const Duration(seconds: 3));
      if (r.exitCode != 0) return null;
      final own = pid == null ? null : RegExp('\\b$pid\\b');
      final lines = [
        for (final l in r.stdout.toString().split('\n'))
          if (l.trim().isNotEmpty &&
              !l.startsWith('Timestamp') &&
              !l.startsWith('Filtering') &&
              !l.contains("'log' 'show'") &&
              !l.contains('log run noninteractively'))
            l.trim(),
      ];
      if (lines.isEmpty) return null;
      var best = lines.last;
      var bestScore = -1;
      for (final l in lines) {
        final score = _lineRank(l) * 2 + (own != null && own.hasMatch(l) ? 1 : 0);
        if (score >= bestScore) {
          best = l;
          bestScore = score;
        }
      }
      return best;
    } on Object {
      return null;
    }
  }

  Future<AppProcessVerdict> _android(AndroidDevice device, String? appId) async {
    if (appId == null) return const AppProcessVerdict(running: null, reason: 'the app package is not known');
    try {
      final r =
          await run(device.adbPath, ['-s', device.serial, 'shell', 'pidof', appId]).timeout(const Duration(seconds: 4));
      final out = r.stdout.toString().trim();
      if (r.exitCode == 0 && out.isNotEmpty) return const AppProcessVerdict(running: true);
      final err = r.stderr.toString().trim();
      if (err.contains('offline') || err.contains('not found') || err.contains('no devices')) {
        return AppProcessVerdict(running: null, reason: 'adb cannot reach ${device.serial}: ${err.split('\n').first}');
      }
      return const AppProcessVerdict(running: false);
    } on Object catch (e) {
      return AppProcessVerdict(running: null, reason: 'adb failed: $e');
    }
  }
}
