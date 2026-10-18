import 'dart:async';
import 'dart:io';

import 'emulator_control.dart';

/// Booting an AVD failed; [detail] holds the emulator's last log lines when it left any.
class AvdBootError implements Exception {
  AvdBootError(this.summary, {this.detail});
  final String summary;
  final String? detail;

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

  /// Boots [avd] detached from glint on a free console port, with gRPC asked for (the emulator does not always start it alone), and waits until Android has booted; returns its serial. A [webcam] id becomes its front camera; one Mac camera cannot back both, so the back keeps the AVD's own.
  Future<String> boot(
    String avd, {
    String? webcam,
    void Function(int elapsedSec, String phase)? onProgress,
    Duration timeout = const Duration(minutes: 5),
    Duration progressEvery = const Duration(seconds: 15),
  }) async {
    final exe = emulatorPath;
    if (exe == null) {
      throw AvdBootError('found no Android emulator binary',
          detail: 'looked next to adb and under ANDROID_HOME, ANDROID_SDK_ROOT and the default SDK folder');
    }
    final port = await _freePort();
    final grpcPort = await _freeGrpcPort(port + 3000);
    final serial = 'emulator-$port';
    final log = File('${Directory.systemTemp.path}/glint-emulator-$avd.log');
    await Process.start(
      '/bin/sh',
      [
        '-c',
        r'exec "$@" > "$0" 2>&1',
        log.path,
        exe,
        ...['-avd', avd, '-port', '$port', '-grpc', '$grpcPort', '-grpc-use-token'],
        if (webcam != null) ...['-camera-front', webcam],
      ],
      mode: ProcessStartMode.detached,
    );

    final clock = Stopwatch()..start();
    var lastReport = Duration.zero;
    var phase = 'starting the $avd emulator';
    onProgress?.call(0, phase);
    while (clock.elapsed < timeout) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final failure = _fatal(log);
      if (failure != null) throw AvdBootError('the $avd emulator stopped while starting', detail: failure);
      if ((await runningSerials()).contains(serial)) {
        phase = 'booting Android on $avd ($serial)';
        if (await _booted(serial)) return serial;
      }
      if (clock.elapsed - lastReport >= progressEvery) {
        lastReport = clock.elapsed;
        onProgress?.call(clock.elapsed.inSeconds, phase);
      }
    }
    throw AvdBootError('$avd did not finish booting in ${timeout.inMinutes} min', detail: _tail(log));
  }

  Future<bool> _booted(String serial) async {
    try {
      final r = await Process.run(adbPath, ['-s', serial, 'shell', 'getprop', 'sys.boot_completed'])
          .timeout(const Duration(seconds: 10));
      return '${r.stdout}'.trim() == '1';
    } on Object {
      return false;
    }
  }

  /// The emulator's fatal lines, once it logged any.
  String? _fatal(File log) {
    if (!log.existsSync()) return null;
    final lines = log.readAsLinesSync().where((l) => l.contains('FATAL') || l.contains('already running')).toList();
    return lines.isEmpty ? null : lines.take(3).join('\n');
  }

  String? _tail(File log) {
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
