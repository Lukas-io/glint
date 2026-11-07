import 'dart:async';

import 'bounded_process.dart';

/// What a lookup found: positive evidence for each answer, [unknown] when the lookup itself failed or timed out.
enum ProcessLife { running, stopped, gone, unknown }

/// One process check: its [life] and the `ps` state letters when it exists.
typedef ProcessCheck = ({ProcessLife life, String? state});

const ProcessCheck _unknownProcess = (life: ProcessLife.unknown, state: null);

/// Looks [pid] up with `ps`: stopped on state `T`, gone only when `ps` says there is no such process, unknown when `ps` fails.
Future<ProcessCheck> checkProcess(int pid) async {
  try {
    final r = await runBounded('ps', ['-o', 'stat=', '-p', '$pid'], timeout: const Duration(seconds: 2), phase: 'ps');
    final state = (r.stdout as String).trim();
    if (r.exitCode == 0 && state.isNotEmpty) {
      if (state.startsWith('Z')) return (life: ProcessLife.gone, state: state);
      return (life: state.startsWith('T') ? ProcessLife.stopped : ProcessLife.running, state: state);
    }
    return r.exitCode == 1 && state.isEmpty ? (life: ProcessLife.gone, state: null) : _unknownProcess;
  } on Object {
    return _unknownProcess;
  }
}

/// The command line of process [pid], or null when it is gone or cannot be read.
Future<String?> processCommand(int pid) async {
  try {
    final r =
        await runBounded('ps', ['-o', 'command=', '-p', '$pid'], timeout: const Duration(seconds: 2), phase: 'ps');
    final out = (r.stdout as String).trim();
    return r.exitCode == 0 && out.isNotEmpty ? out : null;
  } on Object {
    return null;
  }
}

/// [pid]'s check once it is no longer stopped, polled for up to [within]; the stopped check when it stays so.
Future<ProcessCheck> checkAfterResume(int pid, {Duration within = const Duration(seconds: 3)}) async {
  final deadline = DateTime.now().add(within);
  var check = await checkProcess(pid);
  while (check.life == ProcessLife.stopped && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    check = await checkProcess(pid);
  }
  return check;
}

/// Who listens on a TCP port: [known] is false when `lsof` failed, so an empty [pids] then means nothing.
typedef PortOwners = ({bool known, List<int> pids});

/// The processes listening on TCP [port]; `lsof` exits 1 with no output when nobody does.
Future<PortOwners> portOwners(int port) async {
  final out = await _lsof(['-nP', '-iTCP:$port', '-sTCP:LISTEN', '-Fp']);
  if (out == null) return (known: false, pids: const <int>[]);
  final pids = <int>[];
  for (final line in out.split('\n')) {
    final pid = line.startsWith('p') ? int.tryParse(line.substring(1)) : null;
    if (pid != null && !pids.contains(pid)) pids.add(pid);
  }
  return (known: true, pids: pids);
}

Future<String?> _lsof(List<String> args) async {
  try {
    final r = await runBounded('lsof', args, timeout: const Duration(seconds: 3), phase: 'lsof');
    if (r.exitCode == 0) return r.stdout as String;
    return r.exitCode == 1 && '${r.stdout}'.trim().isEmpty ? '' : null;
  } on Object {
    return null;
  }
}

/// Feeds [stream] to [onData] and completes when it ends, so output can be read after the process exited without losing its tail.
Future<void> consume<T>(Stream<T> stream, void Function(T) onData) {
  final done = Completer<void>();
  stream.listen(onData, onError: (Object _) {}, onDone: done.complete, cancelOnError: false);
  return done.future;
}

/// Waits briefly for [streams] started with [consume] to end.
Future<void> settleOutput(Iterable<Future<void>> streams) =>
    Future.wait(streams).timeout(const Duration(seconds: 2), onTimeout: () => const []);

/// The remote ports of [pid]'s established TCP connections that it did not accept on [ownPort].
Future<Set<int>> _outboundPorts(int pid, int ownPort) async {
  final ports = <int>{};
  final pair = RegExp(r':(\d+)->\S*:(\d+)$');
  final out = await _lsof(['-nP', '-a', '-p', '$pid', '-iTCP', '-sTCP:ESTABLISHED', '-Fn']);
  for (final line in (out ?? '').split('\n')) {
    final m = pair.firstMatch(line.trim());
    if (m == null || int.parse(m.group(1)!) == ownPort) continue;
    ports.add(int.parse(m.group(2)!));
  }
  return ports;
}

bool _isSimulatorApp(String? command) =>
    command != null && command.contains('/CoreSimulator/Devices/') && command.contains('.app/');

/// The processes behind a VM service port: [owner] listens on it (the app, or the `flutter run` / DDS process in front of it) and [app] is the simulator app process, when exactly one is found.
typedef VmProcesses = ({
  int? owner,
  String? ownerCommand,
  ProcessCheck? ownerCheck,
  int? app,
  String? appCommand,
  ProcessCheck? appCheck,
  int? stoppedPeer,
  String? stoppedPeerCommand,
  String? stoppedPeerState,
});

const VmProcesses _noVmProcesses = (
  owner: null,
  ownerCommand: null,
  ownerCheck: null,
  app: null,
  appCommand: null,
  appCheck: null,
  stoppedPeer: null,
  stoppedPeerCommand: null,
  stoppedPeerState: null,
);

/// A process connected to the VM service at [port] other than [owner] that is stopped, such as a suspended `flutter run` or DDS in front of the app.
Future<({int pid, String command, String state})?> _stoppedPeer(int port, int owner) async {
  final out = await _lsof(['-nP', '-iTCP:$port', '-sTCP:ESTABLISHED', '-Fp']);
  final pids = <int>{};
  for (final line in (out ?? '').split('\n')) {
    final pid = line.startsWith('p') ? int.tryParse(line.substring(1)) : null;
    if (pid != null && pid != owner) pids.add(pid);
  }
  for (final pid in pids.take(6)) {
    final (check, command) = await (checkProcess(pid), processCommand(pid)).wait;
    if (check.life == ProcessLife.stopped) return (pid: pid, command: command ?? '', state: check.state ?? 'T');
  }
  return null;
}

/// Finds the processes behind the VM service at [port] and checks both; owner and app are null when they cannot be resolved to exactly one process.
Future<VmProcesses> vmProcesses(int port) async {
  final owners = await portOwners(port);
  if (owners.pids.length != 1) return _noVmProcesses;
  final owner = owners.pids.single;
  final (ownerCommand, ownerCheck) = await (processCommand(owner), checkProcess(owner)).wait;
  if (_isSimulatorApp(ownerCommand)) {
    final peer = ownerCheck.life == ProcessLife.stopped ? null : await _stoppedPeer(port, owner);
    return (
      owner: owner,
      ownerCommand: ownerCommand,
      ownerCheck: ownerCheck,
      app: owner,
      appCommand: ownerCommand,
      appCheck: ownerCheck,
      stoppedPeer: peer?.pid,
      stoppedPeerCommand: peer?.command,
      stoppedPeerState: peer?.state,
    );
  }
  final found = <int, String>{};
  for (final remote in (await _outboundPorts(owner, port)).take(12)) {
    for (final pid in (await portOwners(remote)).pids) {
      final command = await processCommand(pid);
      if (pid != owner && _isSimulatorApp(command)) found[pid] = command!;
    }
  }
  final app = found.length == 1 ? found.keys.single : null;
  return (
    owner: owner,
    ownerCommand: ownerCommand,
    ownerCheck: ownerCheck,
    app: app,
    appCommand: app == null ? null : found[app],
    appCheck: app == null ? null : await checkProcess(app),
    stoppedPeer: null,
    stoppedPeerCommand: null,
    stoppedPeerState: null,
  );
}
