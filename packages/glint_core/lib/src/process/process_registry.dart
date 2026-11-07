import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'process_table.dart';

/// How long a helper outlives the thing that asked for it.
enum HelperLife {
  /// Stopped when the app or device it serves is detached.
  attachment,

  /// Stopped when glint exits or the device is shut down, but survives a detach.
  session,

  /// Started detached on purpose (an emulator): recorded so it is visible, never stopped or reaped by glint.
  external,
}

/// What to do when a helper for the same purpose and device is already running.
enum OnRunning { replace, reuse }

/// One long-lived child glint started.
class HelperInfo {
  const HelperInfo({
    required this.id,
    required this.purpose,
    required this.device,
    required this.owner,
    required this.pid,
    required this.started,
    required this.command,
    required this.startedAtMs,
    required this.ownerPid,
    required this.ownerStarted,
    required this.ownerCommand,
    required this.life,
    this.cpu,
  });

  factory HelperInfo.fromJson(Map<String, Object?> j) => HelperInfo(
        id: j['id'] as String,
        purpose: j['purpose'] as String,
        device: j['device'] as String?,
        owner: j['owner'] as String?,
        pid: (j['pid'] as num).toInt(),
        started: j['started'] as String,
        command: j['command'] as String,
        startedAtMs: (j['startedAtMs'] as num).toInt(),
        ownerPid: (j['ownerPid'] as num).toInt(),
        ownerStarted: j['ownerStarted'] as String,
        ownerCommand: j['ownerCommand'] as String,
        life: HelperLife.values.byName(j['life'] as String),
      );

  final String id;
  final String purpose;
  final String? device;

  /// The app or session the helper works for, as free text.
  final String? owner;
  final int pid;

  /// The helper's process start time, from `ps`, for telling it from a later process that reused its pid.
  final String started;
  final String command;
  final int startedAtMs;
  final int ownerPid;
  final String ownerStarted;
  final String ownerCommand;
  final HelperLife life;
  final double? cpu;

  Duration get age => DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(startedAtMs));

  HelperInfo withCpu(double? value) => HelperInfo(
        id: id,
        purpose: purpose,
        device: device,
        owner: owner,
        pid: pid,
        started: started,
        command: command,
        startedAtMs: startedAtMs,
        ownerPid: ownerPid,
        ownerStarted: ownerStarted,
        ownerCommand: ownerCommand,
        life: life,
        cpu: value,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'purpose': purpose,
        'device': device,
        'owner': owner,
        'pid': pid,
        'started': started,
        'command': command,
        'startedAtMs': startedAtMs,
        'ownerPid': ownerPid,
        'ownerStarted': ownerStarted,
        'ownerCommand': ownerCommand,
        'life': life.name,
      };

  /// The compact form shown to agents: what it is, which device, how old and how busy.
  Map<String, Object?> toReport() => {
        'purpose': purpose,
        if (device != null) 'device': device,
        if (owner != null) 'owner': owner,
        'pid': pid,
        'ageSec': age.inSeconds,
        if (cpu != null) 'cpu': cpu,
        'life': life.name,
      };
}

/// A helper glint reaped, and why.
class ReapedHelper {
  const ReapedHelper(this.purpose, this.pid, this.reason);
  final String purpose;
  final int pid;
  final String reason;

  @override
  String toString() => '$purpose (pid $pid): $reason';
}

/// The helpers visible from this process.
class HelperSnapshot {
  const HelperSnapshot({required this.mine, required this.others, required this.stale, required this.inFlight});

  /// Started by this glint process.
  final List<HelperInfo> mine;

  /// Started by another glint process that is still running.
  final List<HelperInfo> others;

  /// Left by a glint process that is gone; the next startup reaps them.
  final List<HelperInfo> stale;

  /// Short child processes of tool calls in flight.
  final int inFlight;
}

class _Live {
  _Live(this.info, this.process);
  final HelperInfo info;
  final Process? process;
  bool exited = false;
}

/// Every long-lived child glint starts, in one place: who owns it, one per purpose and device, a pid file under `~/.glint/procs` so a later glint finds what a crashed one left, and a tree kill that never touches a reused pid.
class ProcessRegistry {
  ProcessRegistry({String? dir}) : dir = dir ?? defaultDir();

  /// The registry of this glint process.
  static final ProcessRegistry instance = ProcessRegistry();

  /// Where the pid files live: `$GLINT_PROCS_DIR`, else `~/.glint/procs`.
  static String defaultDir() =>
      Platform.environment['GLINT_PROCS_DIR'] ?? '${Platform.environment['HOME'] ?? '.'}/.glint/procs';

  final String dir;

  final Map<String, _Live> _live = {};
  final Set<Process> _transient = {};
  final Map<String, Future<void>> _locks = {};
  final List<HelperInfo> _startLog = [];
  int _startedCount = 0;
  ProcRow? _self;

  /// Command lines of processes glint ships; one found with the launchd parent has lost its glint and is reaped at startup.
  final List<RegExp> orphanSignatures = [
    RegExp(r'^\S*/\.glint/bin/glint-\S*( |$)'),
    RegExp(r'^\S*/native/\S+/(debug|release)/glint-(iossim|devicehid|webcam)\S*( |$)'),
    RegExp(r'^\S*/(\.build|target)/(debug|release)/glint-(iossim|devicehid|webcam)\S*( |$)'),
    RegExp(r'xcodebuild test-without-building -xctestrun \S*/\.glint/xctest/'),
  ];

  static String _key(String purpose, String? device) => '$purpose|${device ?? ''}';

  /// How many helpers this process has started; compare before and after a tool call to see what it started.
  int get startedCount => _startedCount;

  /// The helpers started after [count] (a past [startedCount]) that are still running.
  List<HelperInfo> startedSince(int count) {
    final fresh = _startLog.skip(count.clamp(0, _startLog.length)).toList();
    return [
      for (final h in fresh)
        if (_live[_key(h.purpose, h.device)]?.info.id == h.id) h
    ];
  }

  /// Starts [executable] as the helper for [purpose] on [device]. A helper already running for the same purpose and device is stopped first ([OnRunning.replace]) or returned as is ([OnRunning.reuse]).
  Future<Process> start(
    String purpose,
    String executable,
    List<String> arguments, {
    String? device,
    String? owner,
    HelperLife life = HelperLife.session,
    OnRunning onRunning = OnRunning.replace,
    Map<String, String>? environment,
    String? workingDirectory,
  }) =>
      _serialized(_key(purpose, device), () async {
        final existing = _live[_key(purpose, device)];
        if (existing != null && !existing.exited) {
          final process = existing.process;
          if (onRunning == OnRunning.reuse && process != null) return process;
          await _stopLive(existing);
        }
        final process =
            await Process.start(executable, arguments, environment: environment, workingDirectory: workingDirectory);
        final live =
            await _record(process.pid, purpose: purpose, device: device, owner: owner, life: life, process: process);
        if (live != null) {
          unawaited(process.exitCode.then((_) => _forget(live)));
        }
        return process;
      });

  /// Records a process glint started detached, such as an emulator, so it is listed; [HelperLife.external] helpers are never stopped.
  Future<void> adopt(
    int pid,
    String purpose, {
    String? device,
    String? owner,
    HelperLife life = HelperLife.external,
  }) =>
      _serialized(_key(purpose, device), () async {
        await _record(pid, purpose: purpose, device: device, owner: owner, life: life, process: null);
      });

  /// The running helper for [purpose] on [device] started by this process, or null.
  HelperInfo? find(String purpose, {String? device}) {
    final live = _live[_key(purpose, device)];
    return live == null || live.exited ? null : live.info;
  }

  /// The Process of the helper for [purpose] on [device], when this process started it and holds the handle.
  Process? processFor(String purpose, {String? device}) {
    final live = _live[_key(purpose, device)];
    return live == null || live.exited ? null : live.process;
  }

  /// Tracks a short child of a tool call so exit tears it down too; it is forgotten when it exits.
  Process track(Process process) {
    _transient.add(process);
    unawaited(process.exitCode.then((_) => _transient.remove(process)));
    return process;
  }

  /// Stops the helper for [purpose] on [device]; with [only] it acts just when that is the registered process, so a stale holder cannot stop its replacement.
  Future<void> stop(String purpose, {String? device, Process? only}) async {
    final live = _live[_key(purpose, device)];
    if (live == null || (only != null && !identical(live.process, only))) return;
    await _stopLive(live);
  }

  /// Stops this process's helpers for [device]: only the attachment ones on a detach, every one but external on [all] (device shutdown).
  Future<int> stopDevice(String device, {bool all = false}) => _stopWhere(
      (h) => h.device == device && h.life != HelperLife.external && (all || h.life == HelperLife.attachment));

  Future<int> stopOwner(String owner) => _stopWhere((h) => h.owner == owner && h.life != HelperLife.external);

  /// Stops every helper this process started, and the short children of tool calls in flight; external ones are only forgotten.
  Future<int> stopAll({Duration within = const Duration(seconds: 6)}) async {
    final transient = _transient.toList();
    _transient.clear();
    final count =
        await _stopWhere((h) => h.life != HelperLife.external).timeout(within, onTimeout: () => 0).catchError((_) => 0);
    await Future.wait([for (final p in transient) killTree(p.pid)]).timeout(within, onTimeout: () => const []);
    for (final live in _live.values.where((l) => l.info.life == HelperLife.external).toList()) {
      _forget(live);
    }
    return count + transient.length;
  }

  Future<int> _stopWhere(bool Function(HelperInfo) test) async {
    final targets = [
      for (final l in _live.values)
        if (!l.exited && test(l.info)) l
    ];
    await Future.wait([for (final l in targets) _stopLive(l)]);
    return targets.length;
  }

  Future<void> _stopLive(_Live live) async {
    _forget(live);
    await killTree(live.info.pid, started: live.info.started, command: live.info.command);
  }

  void _forget(_Live live) {
    live.exited = true;
    final key = _key(live.info.purpose, live.info.device);
    if (identical(_live[key], live)) _live.remove(key);
    _delete(live.info);
  }

  Future<_Live?> _record(
    int pid, {
    required String purpose,
    required String? device,
    required String? owner,
    required HelperLife life,
    required Process? process,
  }) async {
    final self = await _selfRow();
    final row = (await ProcessTable.read(pids: [pid]))[pid];
    if (self == null || row == null) return null;
    final info = HelperInfo(
      id: '${self.pid}-$pid',
      purpose: purpose,
      device: device,
      owner: owner,
      pid: pid,
      started: row.started,
      command: row.command,
      startedAtMs: DateTime.now().millisecondsSinceEpoch,
      ownerPid: self.pid,
      ownerStarted: self.started,
      ownerCommand: self.command,
      life: life,
    );
    final live = _Live(info, process);
    _live[_key(purpose, device)] = live;
    _startLog.add(info);
    _startedCount++;
    _write(info);
    return live;
  }

  Future<ProcRow?> _selfRow() async {
    final cached = _self;
    if (cached != null) return cached;
    return _self = (await ProcessTable.read(pids: [pid]))[pid];
  }

  File _file(HelperInfo h) => File('$dir/${h.id}.json');

  void _write(HelperInfo h) {
    try {
      Directory(dir).createSync(recursive: true);
      final tmp = File('$dir/${h.id}.tmp')..writeAsStringSync(jsonEncode(h.toJson()));
      tmp.renameSync(_file(h).path);
    } on Object {
      return;
    }
  }

  void _delete(HelperInfo h) {
    try {
      final f = _file(h);
      if (f.existsSync()) f.deleteSync();
    } on Object {
      return;
    }
  }

  Future<T> _serialized<T>(String key, Future<T> Function() body) {
    final previous = _locks[key] ?? Future<void>.value();
    final result = previous.then((_) => body());
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _locks[key] = tail;
    tail.whenComplete(() {
      if (identical(_locks[key], tail)) _locks.remove(key);
    });
    return result;
  }

  List<HelperInfo> _readFiles() {
    final out = <HelperInfo>[];
    final d = Directory(dir);
    if (!d.existsSync()) return out;
    for (final f in d.listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
      try {
        out.add(HelperInfo.fromJson((jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>()));
      } on Object {
        try {
          f.deleteSync();
        } on Object {
          continue;
        }
      }
    }
    return out;
  }

  /// This process's helpers with their CPU, those of other live glint processes, and those left by dead ones.
  Future<HelperSnapshot> snapshot() async {
    final table = await ProcessTable.read();
    final mine = <HelperInfo>[];
    for (final l in _live.values.toList()) {
      final row = table[l.info.pid];
      if (l.exited) continue;
      if (row != null) {
        mine.add(l.info.withCpu(row.cpu));
      } else if (l.process == null) {
        _forget(l);
      }
    }
    final others = <HelperInfo>[];
    final stale = <HelperInfo>[];
    final self = await _selfRow();
    for (final h in _readFiles()) {
      if (h.ownerPid == self?.pid || !table.isSame(h.pid, h.started, h.command)) continue;
      final info = h.withCpu(table[h.pid]?.cpu);
      (table.isSame(h.ownerPid, h.ownerStarted, h.ownerCommand) ? others : stale).add(info);
    }
    return HelperSnapshot(mine: mine, others: others, stale: stale, inFlight: _transient.length);
  }

  /// Stops helpers recorded by glint processes that are gone, and glint's own helpers found with the launchd parent. A process is touched only when its start time and command still match what glint recorded.
  Future<List<ReapedHelper>> reapStale() async {
    final reaped = <ReapedHelper>[];
    final table = await ProcessTable.read();
    final self = await _selfRow();
    final claimed = <int>{};
    for (final h in _readFiles()) {
      if (h.ownerPid == self?.pid) continue;
      if (table.isSame(h.ownerPid, h.ownerStarted, h.ownerCommand)) continue;
      final alive = table.isSame(h.pid, h.started, h.command);
      if (alive && h.life != HelperLife.external) {
        await killTree(h.pid, started: h.started, command: h.command);
        reaped.add(ReapedHelper(h.purpose, h.pid, 'its glint (pid ${h.ownerPid}) is gone'));
        claimed.add(h.pid);
      }
      _delete(h);
    }
    final after = reaped.isEmpty ? table : await ProcessTable.read();
    for (final row in after.rows) {
      if (row.ppid != 1 || claimed.contains(row.pid)) continue;
      if (!orphanSignatures.any((s) => s.hasMatch(row.command))) continue;
      await killTree(row.pid, started: row.started, command: row.command);
      reaped.add(ReapedHelper(_purposeOf(row.command), row.pid, 'orphaned (parent gone)'));
    }
    return reaped;
  }

  static String _purposeOf(String command) {
    final first = command.split(' ').first.split('/').last;
    return first == 'xcodebuild' ? 'xctest-runner' : first.replaceFirst(RegExp(r'-[0-9a-f.]+$'), '');
  }
}

/// Stops [pid] and everything below it: polite first, forceful after [grace]. With [started] and [command] it acts only if the pid is still that process.
Future<void> killTree(
  int pid, {
  String? started,
  String? command,
  Duration grace = const Duration(seconds: 2),
}) async {
  final table = await ProcessTable.read();
  final root = table[pid];
  if (root == null) return;
  if (started != null && command != null && !root.sameProcessAs(started, command)) return;
  final victims = [...table.descendantsOf(pid), pid];
  for (final v in victims) {
    _signal(v, ProcessSignal.sigterm);
  }
  final deadline = DateTime.now().add(grace);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final now = await ProcessTable.read(pids: victims);
    if (victims.every((v) => !(now[v]?.sameProcessAs(table[v]!.started, table[v]!.command) ?? false))) return;
  }
  final now = await ProcessTable.read(pids: victims);
  for (final v in victims) {
    final before = table[v];
    if (before != null && (now[v]?.sameProcessAs(before.started, before.command) ?? false)) {
      _signal(v, ProcessSignal.sigkill);
    }
  }
}

void _signal(int pid, ProcessSignal signal) {
  try {
    Process.killPid(pid, signal);
  } on Object {
    return;
  }
}
