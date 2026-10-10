import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A host binary the request needs is not installed.
class MissingHostTool implements Exception {
  MissingHostTool(this.binary, {this.reason});
  final String binary;
  final String? reason;

  @override
  String toString() => reason ?? '$binary is not installed on the host';
}

/// The finished run of a host process; [out] holds raw stdout bytes.
class HostRun {
  const HostRun(this.exitCode, this.out, this.err);
  final int exitCode;
  final List<int> out;
  final String err;

  bool get ok => exitCode == 0;
  String get text => utf8.decode(out, allowMalformed: true);

  /// The last non-empty stderr lines, where tools print why they failed.
  String errTail([int lines = 4]) {
    final all = err.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    return all.skip(all.length > lines ? all.length - lines : 0).join('\n');
  }
}

const _extraSearchDirs = ['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin'];

/// Absolute path of [name] on PATH or in the usual Homebrew locations, or null.
String? findHostBinary(String name, [Map<String, String>? env]) {
  final path = (env ?? Platform.environment)['PATH'] ?? '';
  for (final dir in [...path.split(':'), ..._extraSearchDirs]) {
    if (dir.isEmpty) continue;
    final file = File('$dir/$name');
    if (file.existsSync()) return file.path;
  }
  return null;
}

/// [name] as an absolute path, or throws [MissingHostTool].
String requireHostBinary(String name) => findHostBinary(name) ?? (throw MissingHostTool(name));

/// Runs [exe] with [args] (no shell); kills it and reports exit 124 after [timeout].
Future<HostRun> runHost(String exe, List<String> args, {Duration timeout = const Duration(minutes: 5)}) async {
  final process = await Process.start(exe, args);
  final out = <int>[];
  final err = StringBuffer();
  final outDone = process.stdout.forEach(out.addAll);
  final errDone = process.stderr.transform(utf8.decoder).forEach(err.write);
  process.stdin.close().ignore();
  var timedOut = false;
  final timer = Timer(timeout, () {
    timedOut = true;
    process.kill();
  });
  final code = await process.exitCode;
  timer.cancel();
  await Future.wait([outDone, errDone]);
  return HostRun(timedOut ? 124 : code, out, timedOut ? '$err\ntimed out after ${timeout.inSeconds}s' : '$err');
}

/// Sends a phase message at once and again every [every] while slow work runs.
class PhaseReporter {
  PhaseReporter(this._send, {this.every = const Duration(seconds: 15)});

  final void Function(int elapsedSec, String phase)? _send;
  final Duration every;
  final Stopwatch _clock = Stopwatch()..start();

  /// Runs [body] under [phase], re-announcing it while it takes long.
  Future<T> during<T>(String phase, Future<T> Function() body) async {
    _send?.call(_clock.elapsed.inSeconds, phase);
    final timer = Timer.periodic(every, (_) => _send?.call(_clock.elapsed.inSeconds, phase));
    try {
      return await body();
    } finally {
      timer.cancel();
    }
  }
}
