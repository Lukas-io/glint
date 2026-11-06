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

  Future<AppProcessVerdict> check(DeviceTarget device, {required String? appId}) async {
    switch (device) {
      case IosSimulator():
        return _simulator(device.udid, appId);
      case AndroidDevice():
        return _android(device, appId);
      case IosDevice():
        return const AppProcessVerdict(running: null, reason: 'a physical iPhone cannot be asked whether the app runs');
    }
  }

  Future<AppProcessVerdict> _simulator(String udid, String? appId) async {
    final state = await sim.state(udid);
    if (state != null && state != 'Booted') {
      return AppProcessVerdict(running: false, reason: 'the simulator is $state');
    }
    if (appId == null) return const AppProcessVerdict(running: null, reason: 'the app id is not known');
    final running = await sim.isAppRunning(udid, appId);
    if (running == null) return const AppProcessVerdict(running: null, reason: 'the simulator did not answer');
    if (running) return const AppProcessVerdict(running: true);
    final hostLine = await _simulatorLog(udid, appId);
    final reason = hostLine == null ? null : _hostReason.firstMatch(hostLine)?.group(1)?.trim();
    return AppProcessVerdict(
      running: false,
      reason: reason ?? hostLine,
      exitStatus: hostLine == null ? null : _exitStatus.firstMatch(hostLine)?.group(1),
    );
  }

  Future<String?> _simulatorLog(String udid, String appId) async {
    final predicate = 'eventMessage CONTAINS "$appId" AND '
        '(eventMessage CONTAINS[c] "terminat" OR eventMessage CONTAINS[c] "jetsam" OR eventMessage CONTAINS[c] "exited")';
    try {
      final r = await run('xcrun', [
        'simctl',
        'spawn',
        udid,
        'log',
        'show',
        '--last',
        '2m',
        '--style',
        'compact',
        '--predicate',
        predicate,
      ]).timeout(const Duration(seconds: 8));
      if (r.exitCode != 0) return null;
      final lines = [
        for (final l in r.stdout.toString().split('\n'))
          if (l.trim().isNotEmpty && !l.startsWith('Timestamp') && !l.startsWith('Filtering')) l.trim(),
      ];
      if (lines.isEmpty) return null;
      final last = lines.last;
      return last.length > 240 ? '${last.substring(0, 239)}…' : last;
    } on Object {
      return null;
    }
  }

  Future<AppProcessVerdict> _android(AndroidDevice device, String? appId) async {
    if (appId == null) return const AppProcessVerdict(running: null, reason: 'the app package is not known');
    try {
      final r =
          await run(device.adbPath, ['-s', device.serial, 'shell', 'pidof', appId]).timeout(const Duration(seconds: 6));
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
