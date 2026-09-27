import 'dart:convert';
import 'dart:io';

import 'backend.dart';

/// One native crash of the app, summarized: what killed it and the top of the crashing thread.
class NativeCrash {
  const NativeCrash({required this.time, required this.reason, this.frames = const [], this.source});

  final DateTime time;

  /// e.g. `EXC_BAD_ACCESS (SIGSEGV)`, `java.lang.IllegalStateException: boom`, `signal 11 (SIGSEGV)`.
  final String reason;

  /// Top frames of the crashing thread, most recent first.
  final List<String> frames;

  /// The report file (iOS) or `logcat -b crash` (Android).
  final String? source;

  String get line => '$reason${frames.isEmpty ? '' : ' at ${frames.first}'}';

  Map<String, Object?> toJson() => {
        'time': time.toIso8601String(),
        'reason': reason,
        if (frames.isNotEmpty) 'frames': frames,
        if (source != null) 'source': source,
      };
}

/// Crash reports the simulator wrote to the host for [bundleId] since [since], newest first.
List<NativeCrash> iosCrashes({required String bundleId, required DateTime since, String? dir}) {
  final d = Directory(dir ?? '${Platform.environment['HOME'] ?? '.'}/Library/Logs/DiagnosticReports');
  if (!d.existsSync()) return const [];
  final out = <NativeCrash>[];
  for (final f in d.listSync().whereType<File>()) {
    if (!f.path.endsWith('.ips') || f.lastModifiedSync().isBefore(since)) continue;
    final crash = parseIpsCrash(f.readAsStringSync(), bundleId: bundleId, path: f.path);
    if (crash != null && !crash.time.isBefore(since)) out.add(crash);
  }
  out.sort((a, b) => b.time.compareTo(a.time));
  return out;
}

/// The crash in one `.ips` report when it belongs to [bundleId], else null.
NativeCrash? parseIpsCrash(String ips, {required String bundleId, String? path}) {
  final nl = ips.indexOf('\n');
  if (nl < 0) return null;
  try {
    final head = jsonDecode(ips.substring(0, nl)) as Map<String, Object?>;
    if (head['bundleID'] != bundleId) return null;
    final body = jsonDecode(ips.substring(nl + 1)) as Map<String, Object?>;
    final exception = (body['exception'] as Map?)?.cast<String, Object?>() ?? const {};
    final termination = (body['termination'] as Map?)?.cast<String, Object?>() ?? const {};
    final type = exception['type'] as String?;
    final signal = exception['signal'] as String?;
    final reasons = (termination['reasons'] as List?)?.cast<Object?>().join('; ');
    final reason = [
      if (type != null) signal == null ? type : '$type ($signal)',
      if (reasons != null && reasons.isNotEmpty) reasons else if (termination['indicator'] != null) '${termination['indicator']}',
    ].join(': ');
    final images = (body['usedImages'] as List?) ?? const [];
    final threads = (body['threads'] as List?)?.cast<Map>() ?? const [];
    final crashed = threads.where((t) => t['triggered'] == true).firstOrNull;
    final frames = <String>[
      for (final f in ((crashed?['frames'] as List?) ?? const []).cast<Map>().take(6))
        '${f['symbol'] ?? '?'} (${_imageName(images, f['imageIndex'])})',
    ];
    return NativeCrash(
      time: _ipsTime(head['timestamp'] as String?) ?? DateTime.now(),
      reason: reason.isEmpty ? 'the app crashed' : reason,
      frames: frames,
      source: path,
    );
  } on Object {
    return null;
  }
}

String _imageName(List images, Object? index) {
  if (index is! int || index < 0 || index >= images.length) return '?';
  final name = (images[index] as Map)['name'];
  return name is String ? name : '?';
}

/// `2026-09-26 22:24:12.00 +0100` as a DateTime.
DateTime? _ipsTime(String? s) {
  final m = RegExp(r'^(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d)(?:\.\d+)? ([+-])(\d\d)(\d\d)$').firstMatch(s ?? '');
  if (m == null) return null;
  final local = DateTime.parse('${m.group(1)}T${m.group(2)}Z');
  final offset = Duration(hours: int.parse(m.group(4)!), minutes: int.parse(m.group(5)!));
  return (m.group(3) == '+' ? local.subtract(offset) : local.add(offset)).toLocal();
}

/// Crashes of [package] in the device's crash log buffer since [since], newest first.
Future<List<NativeCrash>> androidCrashes({
  required String serial,
  required String adbPath,
  required String package,
  required DateTime since,
  ProcessRunner run = Process.run,
}) async {
  try {
    final r = await run(adbPath, ['-s', serial, 'logcat', '-b', 'crash', '-d', '-v', 'year']);
    if (r.exitCode != 0) return const [];
    return parseAndroidCrashes(r.stdout as String, package: package)
        .where((c) => !c.time.isBefore(since))
        .toList()
      ..sort((a, b) => b.time.compareTo(a.time));
  } on Object {
    return const [];
  }
}

final _logLine = RegExp(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\s+\d+\s+\d+\s+[A-Z]\s+([^:]+?)\s*:\s?(.*)$');

/// Java exceptions (`FATAL EXCEPTION`) and native crashes (`>>> package <<<` tombstones) of [package] in `logcat -v year` output.
List<NativeCrash> parseAndroidCrashes(String logcat, {required String package}) {
  final out = <NativeCrash>[];
  DateTime? start;
  String? kind;
  var body = <String>[];
  void flush() {
    if (start == null || kind == null) return;
    final text = body.join('\n');
    final ours = kind == 'java'
        ? RegExp('Process: ${RegExp.escape(package)}, PID').hasMatch(text)
        : text.contains('>>> $package <<<');
    if (ours) {
      final frames = kind == 'java'
          ? [for (final l in body) if (l.trimLeft().startsWith('at ')) l.trim().substring(3)]
          : [
              for (final l in body)
                if (RegExp(r'^\s*#\d+ pc ').hasMatch(l))
                  l.trim().replaceFirst(RegExp(r'^#\d+ pc [0-9a-f]+\s+'), '').replaceFirst(RegExp(r'\s*\(BuildId: \w+\)$'), ''),
            ];
      final reason = kind == 'java'
          ? body.firstWhere((l) => !l.startsWith('FATAL EXCEPTION') && !l.startsWith('Process:') && l.trim().isNotEmpty,
              orElse: () => 'java exception')
          : [
              RegExp(r'signal \d+ \(\w+\)').firstMatch(text)?.group(0) ?? 'native crash',
              if (RegExp(r"Abort message: '([^']*)'").firstMatch(text) case final m?) m.group(1)!,
            ].join(': ');
      out.add(NativeCrash(time: start!, reason: reason.trim(), frames: frames.take(6).toList(), source: 'logcat -b crash'));
    }
    start = null;
    kind = null;
    body = [];
  }

  for (final raw in const LineSplitter().convert(logcat)) {
    final m = _logLine.firstMatch(raw);
    if (m == null) continue;
    final tag = m.group(2)!;
    final msg = m.group(3)!;
    if (tag == 'AndroidRuntime' && msg.startsWith('FATAL EXCEPTION')) {
      flush();
      start = DateTime.tryParse(m.group(1)!.replaceFirst(' ', 'T'));
      kind = 'java';
    } else if (tag == 'DEBUG' && msg.contains('*** *** ***')) {
      flush();
      start = DateTime.tryParse(m.group(1)!.replaceFirst(' ', 'T'));
      kind = 'native';
      continue;
    } else if (kind == 'java' && tag != 'AndroidRuntime') {
      flush();
      continue;
    } else if (kind == 'native' && tag != 'DEBUG' && tag != 'libc') {
      continue;
    }
    if (kind != null) body.add(msg);
  }
  flush();
  return out;
}
