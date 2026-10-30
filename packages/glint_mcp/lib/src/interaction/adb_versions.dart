import 'dart:async';
import 'dart:io';

/// One adb binary and the version it reports.
class AdbBinary {
  const AdbBinary(this.path, this.version);
  final String path;
  final String version;

  @override
  String toString() => '$path ($version)';
}

/// Every distinct adb glint could meet (the one it uses, each on PATH, the SDK's), with its version.
Future<List<AdbBinary>> installedAdbs(String adbPath, {Map<String, String>? env}) async {
  final e = env ?? Platform.environment;
  final paths = <String>[
    if (adbPath.contains('/')) adbPath,
    ...await _onPath(),
    ..._sdkAdbs(e),
  ];
  final seen = <String>{};
  final found = <AdbBinary>[];
  for (final path in paths) {
    final real = _real(path);
    if (real == null || !seen.add(real)) continue;
    found.add(AdbBinary(path, await _version(path)));
  }
  return found;
}

/// The adbs that disagree on version, or empty when there is one adb or all report the same.
Future<List<AdbBinary>> mismatchedAdbs(String adbPath, {Map<String, String>? env}) async {
  final all = await installedAdbs(adbPath, env: env);
  return all.map((a) => a.version).toSet().length > 1 ? all : const [];
}

/// The sentence for an error `detail` naming the disagreeing adbs, or null when they agree.
String? mismatchedAdbsDetail(List<AdbBinary> adbs) => adbs.isEmpty
    ? null
    : 'more than one adb is installed and they differ: ${adbs.join('; ')}. '
        'Each version kills the other\'s adb server, so a device can stay offline';

Future<List<String>> _onPath() async {
  try {
    final r = await Process.run('which', ['-a', 'adb']).timeout(const Duration(seconds: 5));
    return [
      for (final line in '${r.stdout}'.split('\n'))
        if (line.trim().startsWith('/')) line.trim(),
    ];
  } on Object {
    return const [];
  }
}

List<String> _sdkAdbs(Map<String, String> env) {
  final home = env['HOME'] ?? '';
  return [
    for (final root in [
      env['ANDROID_HOME'],
      env['ANDROID_SDK_ROOT'],
      if (home.isNotEmpty) '$home/Library/Android/sdk',
      if (home.isNotEmpty) '$home/Android/Sdk',
    ])
      if (root != null && root.isNotEmpty && File('$root/platform-tools/adb').existsSync()) '$root/platform-tools/adb',
  ];
}

String? _real(String path) {
  try {
    return File(path).existsSync() ? File(path).resolveSymbolicLinksSync() : null;
  } on Object {
    return null;
  }
}

Future<String> _version(String adb) async {
  try {
    final r = await Process.run(adb, ['version']).timeout(const Duration(seconds: 5));
    final text = '${r.stdout}';
    final version = RegExp(r'^Version (\S+)', multiLine: true).firstMatch(text)?.group(1);
    return version ?? text.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => 'unknown').trim();
  } on Object {
    return 'unknown';
  }
}
