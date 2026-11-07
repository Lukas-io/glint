import 'dart:async';
import 'dart:convert';
import 'dart:io';

final _ownedBy = <String, RegExp>{
  'helper': RegExp(r'^\S*/\.glint/bin/glint-\S*( |$)'),
  'helper-build': RegExp(r'^\S*/(\.build|target)/(debug|release)/glint-(iossim|devicehid|webcam)\S*( |$)'),
  'xctest-runner': RegExp(r'xcodebuild test-without-building -xctestrun \S*/\.glint/xctest/'),
  'glint-server':
      RegExp(r'(bin/glint\.dart|\.pub-cache/bin/glint|bin/glint_network\.dart|glint_network:glint_network)'),
  'flutter-run':
      RegExp(r'flutter_tools\.snapshot (run|attach)\b|frontend_server_aot\.dart\.snapshot|dart development-service'),
};

class Proc {
  Proc(this.pid, this.ppid, this.cpu, this.kind, this.command);
  final int pid;
  final int ppid;
  final double cpu;
  final String kind;
  final String command;

  Map<String, Object?> toJson() => {'pid': pid, 'ppid': ppid, 'cpu': cpu, 'kind': kind, 'command': command};

  static Proc fromJson(Map<String, Object?> j) => Proc(
      j['pid'] as int, j['ppid'] as int, (j['cpu'] as num).toDouble(), j['kind'] as String, j['command'] as String);
}

class Snapshot {
  Snapshot(this.procs, this.pidFiles);
  final List<Proc> procs;
  final int pidFiles;

  double get cpu => procs.fold(0.0, (a, p) => a + p.cpu);

  Map<String, int> get byKind {
    final out = <String, int>{};
    for (final p in procs) {
      out[p.kind] = (out[p.kind] ?? 0) + 1;
    }
    return out;
  }

  Map<String, Object?> toJson() => {
        'at': DateTime.now().toIso8601String(),
        'procs': [for (final p in procs) p.toJson()],
        'pidFiles': pidFiles,
      };

  static Snapshot fromJson(Map<String, Object?> j) => Snapshot(
        [for (final p in j['procs'] as List) Proc.fromJson((p as Map).cast<String, Object?>())],
        j['pidFiles'] as int,
      );
}

Future<Snapshot> takeSnapshot({int? under}) async {
  final r = await Process.run('ps', ['-Aww', '-o', 'pid=,ppid=,pcpu=,command=']);
  final line = RegExp(r'^\s*(\d+)\s+(\d+)\s+([\d.,]+)\s+(.*)$');
  final parents = <int, int>{};
  for (final l in '${r.stdout}'.split('\n')) {
    final m = line.firstMatch(l);
    if (m != null) parents[int.parse(m.group(1)!)] = int.parse(m.group(2)!);
  }
  bool inScope(int id) {
    if (under == null) return true;
    for (var at = id, hops = 0; hops < 64 && at > 1; hops++) {
      if (at == under) return true;
      at = parents[at] ?? 0;
    }
    return (parents[id] ?? 0) == 1;
  }

  final procs = <Proc>[];
  for (final l in '${r.stdout}'.split('\n')) {
    final m = line.firstMatch(l);
    if (m == null) continue;
    final id = int.parse(m.group(1)!);
    if (id == pid) continue;
    final command = m.group(4)!;
    if (command.contains('tool/leak_check.dart') || !inScope(id)) continue;
    for (final e in _ownedBy.entries) {
      if (e.value.hasMatch(command)) {
        procs.add(
            Proc(pid, int.parse(m.group(2)!), double.tryParse(m.group(3)!.replaceAll(',', '.')) ?? 0, e.key, command));
        break;
      }
    }
  }
  return Snapshot(procs, _livePidFiles(procs));
}

int _livePidFiles(List<Proc> procs) {
  final dir = Directory(Platform.environment['GLINT_PROCS_DIR'] ?? '${Platform.environment['HOME']}/.glint/procs');
  if (!dir.existsSync()) return 0;
  return dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).length;
}

class Verdict {
  Verdict(this.problems, this.after);
  final List<String> problems;
  final Snapshot after;
}

Verdict judge(Snapshot before, Snapshot after, double cpuSlack) {
  final known = {for (final p in before.procs) p.pid};
  final problems = <String>[];
  for (final p in after.procs) {
    if (known.contains(p.pid)) continue;
    problems.add(
        'new ${p.kind} left running: pid ${p.pid} (ppid ${p.ppid}, ${p.cpu.toStringAsFixed(1)}% cpu) ${_short(p.command)}');
  }
  final grown = after.cpu - before.cpu;
  if (grown > cpuSlack) {
    problems.add(
        'glint-owned cpu grew ${before.cpu.toStringAsFixed(1)}% to ${after.cpu.toStringAsFixed(1)}% (slack $cpuSlack)');
  }
  if (after.pidFiles > before.pidFiles) {
    problems.add('pid files under ~/.glint/procs grew ${before.pidFiles} to ${after.pidFiles}');
  }
  return Verdict(problems, after);
}

String _short(String c) => c.length <= 140 ? c : '${c.substring(0, 139)}…';

Future<Verdict> settleAndJudge(Snapshot before, int settleSec, double cpuSlack, {int? under}) async {
  final deadline = DateTime.now().add(Duration(seconds: settleSec));
  var verdict = judge(before, await takeSnapshot(under: under), cpuSlack);
  while (verdict.problems.isNotEmpty && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(seconds: 1));
    verdict = judge(before, await takeSnapshot(under: under), cpuSlack);
  }
  return verdict;
}

void printSnapshot(String label, Snapshot s) {
  stdout.writeln(
      '$label: ${s.procs.length} glint-owned process(es), ${s.cpu.toStringAsFixed(1)}% cpu, ${s.pidFiles} pid file(s) ${s.byKind}');
}

int report(Snapshot before, Verdict v) {
  printSnapshot('before', before);
  printSnapshot('after ', v.after);
  if (v.problems.isEmpty) {
    stdout.writeln('leak_check: ok, nothing grew');
    return 0;
  }
  for (final p in v.problems) {
    stdout.writeln('LEAK: $p');
  }
  stdout.writeln('leak_check: FAILED, ${v.problems.length} problem(s)');
  return 1;
}

/// Usage: `snapshot [--out f]`, `compare before.json [--settle 8] [--cpu-slack 25]`, `run [--settle 8] [--cpu-slack 25] [--under pid] -- <command>`; exit 0 clean, 1 leak, 2 bad usage.
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: leak_check.dart snapshot [--out f] | compare before.json | run -- <command>');
    exit(2);
  }
  var settle = 8;
  var slack = 25.0;
  String? out;
  int? under;
  final rest = <String>[];
  final command = <String>[];
  for (var i = 1; i < args.length; i++) {
    if (args[i] == '--') {
      command.addAll(args.skip(i + 1));
      break;
    }
    switch (args[i]) {
      case '--settle':
        settle = int.parse(args[++i]);
      case '--cpu-slack':
        slack = double.parse(args[++i]);
      case '--out':
        out = args[++i];
      case '--under':
        under = int.parse(args[++i]);
      default:
        rest.add(args[i]);
    }
  }
  switch (args.first) {
    case 'snapshot':
      final s = await takeSnapshot(under: under);
      final text = const JsonEncoder.withIndent('  ').convert(s.toJson());
      if (out != null) {
        File(out).writeAsStringSync(text);
      } else {
        stdout.writeln(text);
      }
      printSnapshot('snapshot', s);
    case 'compare':
      if (rest.isEmpty) exit(2);
      final before =
          Snapshot.fromJson((jsonDecode(File(rest.first).readAsStringSync()) as Map).cast<String, Object?>());
      exit(report(before, await settleAndJudge(before, settle, slack, under: under)));
    case 'run':
      if (command.isEmpty) exit(2);
      final before = await takeSnapshot(under: under ?? -1);
      final run = await Process.start(command.first, command.skip(1).toList(), mode: ProcessStartMode.inheritStdio);
      final code = await run.exitCode;
      final status = report(before, await settleAndJudge(before, settle, slack, under: under ?? run.pid));
      exit(code != 0 ? code : status);
    default:
      stderr.writeln('unknown command ${args.first}');
      exit(2);
  }
}
