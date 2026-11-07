import 'dart:io';

/// One row of the machine's process table.
class ProcRow {
  const ProcRow({
    required this.pid,
    required this.ppid,
    required this.cpu,
    required this.started,
    required this.command,
  });

  final int pid;
  final int ppid;
  final double cpu;

  /// The start time as `ps` prints it (`Sat Nov  8 12:34:56 2026`): with [command], what tells a process from a later one that reused its pid.
  final String started;
  final String command;

  bool sameProcessAs(String startedAt, String commandLine) => started == startedAt && command == commandLine;
}

/// A snapshot of the process table, read with one `ps` call.
class ProcessTable {
  ProcessTable(Iterable<ProcRow> rows) : _rows = {for (final r in rows) r.pid: r};

  final Map<int, ProcRow> _rows;

  static final _line = RegExp(r'^\s*(\d+)\s+(\d+)\s+([\d.,]+)\s+(\w{3} \w{3}\s+\d+ \d\d:\d\d:\d\d \d{4})\s+(.*)$');

  /// Reads every process, or only [pids]; an unreadable table is empty.
  static Future<ProcessTable> read({Iterable<int>? pids}) async {
    final ids = pids?.toList();
    if (ids != null && ids.isEmpty) return ProcessTable(const []);
    try {
      final result = await Process.run(
        'ps',
        [
          '-ww',
          if (ids == null) '-A' else ...['-p', ids.join(',')],
          '-o',
          'pid=,ppid=,pcpu=,lstart=,command='
        ],
        environment: const {'LC_ALL': 'C'},
      );
      return ProcessTable(parse('${result.stdout}'));
    } on Object {
      return ProcessTable(const []);
    }
  }

  static List<ProcRow> parse(String text) {
    final rows = <ProcRow>[];
    for (final line in text.split('\n')) {
      final m = _line.firstMatch(line);
      if (m == null) continue;
      rows.add(ProcRow(
        pid: int.parse(m.group(1)!),
        ppid: int.parse(m.group(2)!),
        cpu: double.tryParse(m.group(3)!.replaceAll(',', '.')) ?? 0,
        started: m.group(4)!,
        command: m.group(5)!.trim(),
      ));
    }
    return rows;
  }

  Iterable<ProcRow> get rows => _rows.values;

  ProcRow? operator [](int pid) => _rows[pid];

  /// Whether [pid] is still the process that started at [started] with [command], not a later one that reused the number.
  bool isSame(int pid, String started, String command) => _rows[pid]?.sameProcessAs(started, command) ?? false;

  /// Every process below [pid], deepest first, so signalling in order stops children before their parents.
  List<int> descendantsOf(int pid) {
    final children = <int, List<int>>{};
    for (final r in _rows.values) {
      children.putIfAbsent(r.ppid, () => []).add(r.pid);
    }
    final ordered = <int>[];
    void walk(int p, Set<int> seen) {
      for (final c in children[p] ?? const <int>[]) {
        if (!seen.add(c)) continue;
        walk(c, seen);
        ordered.add(c);
      }
    }

    walk(pid, {pid});
    return ordered;
  }
}
