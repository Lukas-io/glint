import 'dart:convert';
import 'dart:io';

import 'bounded_process.dart';

/// Runs `devicectl` with `--json-output` and returns its `result`; null when it fails.
Future<Map<String, Object?>?> _devicectl(List<String> args) async {
  final tmp = await Directory.systemTemp.createTemp('glint-devicectl-');
  try {
    final out = '${tmp.path}/out.json';
    final r = await runBounded(
      'xcrun',
      ['devicectl', ...args, '--json-output', out, '-q'],
      timeout: const Duration(seconds: 30),
      phase: 'devicectl ${args.take(3).join(' ')}',
    );
    if (r.exitCode != 0 || !File(out).existsSync()) return null;
    return ((jsonDecode(File(out).readAsStringSync()) as Map)['result'] as Map?)?.cast<String, Object?>();
  } on Object {
    return null;
  } finally {
    await tmp.delete(recursive: true);
  }
}

/// The pids of [bundleId]'s main process on the phone [udid] (extensions excluded); empty when it is not running.
Future<List<int>> phoneAppPids(String udid, String bundleId) async {
  final apps = await _devicectl(['device', 'info', 'apps', '--device', udid, '--bundle-id', bundleId]);
  final url = ((apps?['apps'] as List?)?.cast<Map>().firstOrNull)?['url'] as String?;
  if (url == null) return const [];
  final bundlePath = Uri.parse(url).path;
  final procs = await _devicectl(['device', 'info', 'processes', '--device', udid]);
  return [
    for (final p in (procs?['runningProcesses'] as List? ?? const []).cast<Map>())
      if (Uri.tryParse('${p['executable']}')?.path case final exe?
          when exe.startsWith(bundlePath) && !exe.substring(bundlePath.length).contains('/'))
        (p['processIdentifier'] as num).toInt(),
  ];
}

/// Stops [bundleId] on the phone [udid]; null when it stopped or was not running, else why not.
Future<String?> phoneTerminate(String udid, String bundleId) async {
  final pids = await phoneAppPids(udid, bundleId);
  for (final pid in pids) {
    final r = await runBounded(
      'xcrun',
      ['devicectl', 'device', 'process', 'terminate', '--device', udid, '--pid', '$pid', '--kill', '-q'],
      timeout: const Duration(seconds: 30),
      phase: 'devicectl terminate',
    );
    if (r.exitCode != 0) return '${r.stderr}'.trim().split('\n').last;
  }
  return null;
}

/// Opens [url] on the phone [udid] the way a tap on a link would; null on success, else why not.
Future<String?> phoneOpenUrl(String udid, String url) async {
  final r = await runBounded(
    'xcrun',
    ['devicectl', 'device', 'process', 'openURL', '--device', udid, url, '-q'],
    timeout: const Duration(seconds: 30),
    phase: 'devicectl openURL',
  );
  return r.exitCode == 0 ? null : '${r.stderr}'.trim().split('\n').last;
}
