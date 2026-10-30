import 'dart:async';
import 'dart:io';

import 'adb_versions.dart';
import 'emulator_control.dart';
import 'result.dart';

/// Booting an AVD failed; [detail] holds the emulator's last log lines when it left any, [errorKind] and [nextSteps] replace the generic ones when set.
class AvdBootError implements Exception {
  AvdBootError(this.summary, {this.detail, this.errorKind, this.nextSteps = const []});
  final String summary;
  final String? detail;
  final GlintErrorKind? errorKind;
  final List<String> nextSteps;

  @override
  String toString() => 'AvdBootError: $summary';
}

/// The Android virtual devices on this host: which exist, which one runs where, and booting one from glint's own process.
class Avds {
  Avds({required this.adbPath, Map<String, String>? env}) : _env = env ?? Platform.environment;

  final String adbPath;
  final Map<String, String> _env;

  /// The SDK's `emulator` binary, found next to adb or under ANDROID_HOME, ANDROID_SDK_ROOT or the default SDK folder.
  String? get emulatorPath {
    final adb = File(adbPath);
    final roots = [
      if (adb.isAbsolute) adb.parent.parent.path,
      _env['ANDROID_HOME'],
      _env['ANDROID_SDK_ROOT'],
      '${_env['HOME']}/Library/Android/sdk',
      '${_env['HOME']}/Android/Sdk',
    ];
    for (final root in roots.whereType<String>()) {
      final exe = File('$root/emulator/emulator');
      if (exe.existsSync()) return exe.path;
    }
    return null;
  }

  Future<List<String>> list() async {
    final exe = emulatorPath;
    if (exe == null) return const [];
    try {
      final r = await Process.run(exe, ['-list-avds']).timeout(const Duration(seconds: 20));
      return [
        for (final line in '${r.stdout}'.split('\n'))
          if (line.trim().isNotEmpty && !line.contains('|')) line.trim(),
      ];
    } on Object {
      return const [];
    }
  }

  Future<List<String>> runningSerials() async {
    try {
      final r = await Process.run(adbPath, ['devices']).timeout(const Duration(seconds: 10));
      return [
        for (final line in '${r.stdout}'.split('\n'))
          if (RegExp(r'^emulator-\d+\s').hasMatch(line)) line.split(RegExp(r'\s+')).first,
      ];
    } on Object {
      return const [];
    }
  }

  /// The AVD the emulator behind [serial] runs, from its console.
  Future<String?> avdOf(String serial) async => (await emulatorConsole(adbPath, serial, ['avd', 'name']))?.firstOrNull;

  /// The serial of the emulator already running [avd].
  Future<String?> runningSerial(String avd) async {
    for (final serial in await runningSerials()) {
      if (await avdOf(serial) == avd) return serial;
    }
    return null;
  }

  /// Boots [avd] detached from glint on a free console port, with gRPC asked for (the emulator does not always start it alone), and waits until Android has booted; returns its serial. A [webcam] id becomes its front camera; one Mac camera cannot back both, so the back keeps the AVD's own. When adb shows the emulator offline for [offlineLimit], glint stops it (it started it) and boots once more with `-no-snapshot-load`, recording that in [notes].
  Future<String> boot(
    String avd, {
    String? webcam,
    void Function(int elapsedSec, String phase)? onProgress,
    Duration timeout = const Duration(minutes: 5),
    Duration progressEvery = const Duration(seconds: 15),
    Duration offlineLimit = const Duration(seconds: 60),
    List<String>? notes,
  }) async {
    final exe = emulatorPath;
    if (exe == null) {
      throw AvdBootError('found no Android emulator binary',
          detail: 'looked next to adb and under ANDROID_HOME, ANDROID_SDK_ROOT and the default SDK folder');
    }
    final clock = Stopwatch()..start();
    final first = await _start(exe, avd, webcam: webcam);
    try {
      return await _awaitBoot(first, clock, timeout, progressEvery, offlineLimit, onProgress);
    } on _StuckOffline catch (stuck) {
      onProgress?.call(clock.elapsed.inSeconds,
          'adb kept ${first.serial} offline for ${stuck.offlineSec}s, restarting $avd with a cold boot');
      await _stop(first);
      final second = await _start(exe, avd, webcam: webcam, coldBoot: true);
      try {
        final serial = await _awaitBoot(second, clock, timeout, progressEvery, offlineLimit, onProgress);
        notes?.add('${first.serial} came up with adb offline from its saved snapshot, so glint restarted $avd with a '
            'cold boot (-no-snapshot-load); it now runs as $serial');
        return serial;
      } on _StuckOffline catch (again) {
        throw await _offlineError(avd, second.serial, again.offlineSec, offlineLimit,
            coldBooted: true, log: second.log, adbPath: adbPath);
      }
    }
  }

  /// Waits up to [limit] for the already running emulator behind [serial] to leave `offline` in adb; it never restarts an emulator glint did not start.
  Future<void> awaitOnline(
    String serial,
    String avd, {
    void Function(int elapsedSec, String phase)? onProgress,
    Duration limit = const Duration(seconds: 60),
    Duration progressEvery = const Duration(seconds: 15),
  }) async {
    final clock = Stopwatch()..start();
    var lastReport = Duration.zero;
    while ((await _adbState(serial)) == 'offline') {
      if (clock.elapsed >= limit) {
        throw await _offlineError(avd, serial, clock.elapsed.inSeconds, limit, coldBooted: false, adbPath: adbPath);
      }
      if (clock.elapsed - lastReport >= progressEvery) {
        lastReport = clock.elapsed;
        onProgress?.call(clock.elapsed.inSeconds, 'waiting for adb: $serial offline for ${clock.elapsed.inSeconds}s');
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  Future<_Launched> _start(String exe, String avd, {String? webcam, bool coldBoot = false}) async {
    final port = await _freePort();
    final grpcPort = await _freeGrpcPort(port + 3000);
    final log = File('${Directory.systemTemp.path}/glint-emulator-$avd.log');
    final process = await Process.start(
      '/bin/sh',
      [
        '-c',
        r'exec "$@" > "$0" 2>&1',
        log.path,
        exe,
        ...['-avd', avd, '-port', '$port', '-grpc', '$grpcPort', '-grpc-use-token'],
        if (coldBoot) '-no-snapshot-load',
        if (webcam != null) ...['-camera-front', webcam],
      ],
      mode: ProcessStartMode.detached,
    );
    return _Launched(avd, 'emulator-$port', process.pid, log);
  }

  Future<String> _awaitBoot(
    _Launched run,
    Stopwatch clock,
    Duration timeout,
    Duration progressEvery,
    Duration offlineLimit,
    void Function(int elapsedSec, String phase)? onProgress,
  ) async {
    final avd = run.avd;
    final deadline = clock.elapsed + timeout;
    var lastReport = Duration.zero;
    Duration? offlineSince;
    var phase = 'starting the $avd emulator';
    onProgress?.call(clock.elapsed.inSeconds, phase);
    while (clock.elapsed < deadline) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final failure = _fatal(run.log);
      if (failure != null) throw AvdBootError('the $avd emulator stopped while starting', detail: failure);
      final state = await _adbState(run.serial);
      var offline = state == 'offline';
      if (state == 'device') {
        phase = 'booting Android on $avd (${run.serial})';
        switch (await _booted(run.serial)) {
          case _Boot.ready:
            return run.serial;
          case _Boot.offline:
            offline = true;
          case _Boot.notYet:
            break;
        }
      }
      if (offline) {
        offlineSince ??= clock.elapsed;
        final offlineFor = clock.elapsed - offlineSince;
        phase = 'waiting for adb: ${run.serial} offline for ${offlineFor.inSeconds}s';
        if (offlineFor >= offlineLimit) throw _StuckOffline(offlineFor.inSeconds);
      } else {
        offlineSince = null;
      }
      if (clock.elapsed - lastReport >= progressEvery) {
        lastReport = clock.elapsed;
        onProgress?.call(clock.elapsed.inSeconds, phase);
      }
    }
    throw AvdBootError('$avd did not finish booting in ${timeout.inMinutes} min', detail: _tail(run.log));
  }

  /// Asks the emulator glint started to quit through its console first, which reaches it even with adbd offline, then signals its pid.
  Future<void> _stop(_Launched run) async {
    Future<bool> gone() async {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (await _adbState(run.serial) == null) return true;
      }
      return false;
    }

    try {
      await emulatorConsole(adbPath, run.serial, ['kill']);
    } on Object {
      // the signals below still stop it
    }
    if (await gone()) return;
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigkill]) {
      Process.killPid(run.pid, signal);
      if (await gone()) return;
    }
    throw AvdBootError('the ${run.avd} emulator ${run.serial} would not stop for the cold boot restart',
        detail: 'glint started it (pid ${run.pid}) and asked it to quit, but adb still lists it',
        errorKind: GlintErrorKind.deviceNotConnected,
        nextSteps: [
          'close the ${run.serial} emulator window or `shutdown_sim device:"${run.serial}"`',
          'then `attach device:"${run.avd}"` again',
        ]);
  }

  /// The failure for an emulator whose adb stayed offline, with the adb version clash when there is one.
  static Future<AvdBootError> _offlineError(
    String avd,
    String serial,
    int offlineSec,
    Duration limit, {
    required bool coldBooted,
    File? log,
    required String adbPath,
  }) async {
    final clash = await mismatchedAdbs(adbPath);
    final tail = log == null ? null : _tail(log);
    final detail = [
      'adb -s $serial shell getprop sys.boot_completed failed: device offline',
      if (mismatchedAdbsDetail(clash) case final text?) text,
      if (coldBooted) 'a cold boot (-no-snapshot-load) stayed offline too',
      if (tail != null) tail,
    ].join('\n');
    return AvdBootError(
      'adb kept $serial offline for ${offlineSec}s (gave up after ${limit.inSeconds}s)',
      detail: detail,
      errorKind: GlintErrorKind.deviceNotConnected,
      nextSteps: [
        if (clash.isNotEmpty) ...[
          'remove or unlink all but one adb (e.g. `brew uninstall android-platform-tools`), '
              'then run `adb kill-server`',
          'glint used $adbPath',
        ],
        if (coldBooted)
          '`shutdown_sim device:"$serial"`, fix adb, then `attach device:"$avd"` again'
        else
          'cold boot it: close $serial (it was not started by glint, so glint left it running), then '
              '`emulator -avd $avd -no-snapshot-load`, or "Cold Boot Now" in the device manager',
        'if no second adb exists, run `adb kill-server` and `attach` again',
      ],
    );
  }

  /// The adb state of [serial] (`device`, `offline`, `unauthorized`), or null when adb does not list it.
  Future<String?> _adbState(String serial) async {
    try {
      final r = await Process.run(adbPath, ['devices']).timeout(const Duration(seconds: 10));
      for (final line in '${r.stdout}'.split('\n')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length >= 2 && parts.first == serial) return parts[1];
      }
    } on Object {
      return null;
    }
    return null;
  }

  Future<_Boot> _booted(String serial) async {
    try {
      final r = await Process.run(adbPath, ['-s', serial, 'shell', 'getprop', 'sys.boot_completed'])
          .timeout(const Duration(seconds: 10));
      if ('${r.stdout}'.trim() == '1') return _Boot.ready;
      return '${r.stderr}'.contains('offline') ? _Boot.offline : _Boot.notYet;
    } on Object {
      return _Boot.notYet;
    }
  }

  /// The emulator's fatal lines, once it logged any.
  String? _fatal(File log) {
    if (!log.existsSync()) return null;
    final lines = log.readAsLinesSync().where((l) => l.contains('FATAL') || l.contains('already running')).toList();
    return lines.isEmpty ? null : lines.take(3).join('\n');
  }

  static String? _tail(File log) {
    if (!log.existsSync()) return null;
    final lines = log.readAsLinesSync();
    return lines.skip(lines.length > 6 ? lines.length - 6 : 0).join('\n');
  }

  /// The first even console port from 5554 that no emulator uses and nothing listens on, together with its adb port.
  Future<int> _freePort() async {
    final taken = {for (final s in await runningSerials()) int.parse(s.substring('emulator-'.length))};
    for (var port = 5554; port <= 5682; port += 2) {
      if (taken.contains(port)) continue;
      if (await _free(port) && await _free(port + 1)) return port;
    }
    throw AvdBootError('found no free emulator console port between 5554 and 5682');
  }

  Future<int> _freeGrpcPort(int preferred) async {
    for (var port = preferred; port < preferred + 200; port++) {
      if (await _free(port)) return port;
    }
    throw AvdBootError('found no free port for the emulator gRPC control from $preferred');
  }

  Future<bool> _free(int port) async {
    try {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await socket.close();
      return true;
    } on SocketException {
      return false;
    }
  }
}

class _Launched {
  const _Launched(this.avd, this.serial, this.pid, this.log);
  final String avd;
  final String serial;
  final int pid;
  final File log;
}

enum _Boot { ready, notYet, offline }

class _StuckOffline implements Exception {
  const _StuckOffline(this.offlineSec);
  final int offlineSec;
}
