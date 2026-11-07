import 'dart:async';
import 'dart:io';

import '../interaction/bounded_process.dart';
import '../observability/call_progress.dart';

/// Where glint's long-lived helper processes are tracked: one per name and scope, stopped when asked, found again by a later glint.
abstract class HelperRegistry {
  /// The helper running for [name] in [scope], or null.
  Process? running(String name, String scope);

  /// Starts [executable] as the one helper for [name] in [scope], stopping an older one first.
  Future<Process> start(String name, String scope, String executable, List<String> arguments);

  /// Stops the helper for [name] in [scope], this glint's or one an earlier glint left behind.
  Future<void> stop(String name, String scope);
}

/// Keeps a pid file per helper under [directory] and a map of the children this glint started.
class PidFileHelpers implements HelperRegistry {
  PidFileHelpers(this.directory);

  final String Function(String scope) directory;

  static final Map<String, Process> _children = {};

  String _key(String name, String scope) => '$scope/$name';

  File _pidFile(String name, String scope) => File('${directory(scope)}/$name.pid');

  @override
  Process? running(String name, String scope) => _children[_key(name, scope)];

  @override
  Future<Process> start(String name, String scope, String executable, List<String> arguments) async {
    await stop(name, scope);
    Directory(directory(scope)).createSync(recursive: true);
    final process = await startManaged(executable, arguments, label: 'the $name helper');
    unawaited(process.stderr.drain<void>());
    _children[_key(name, scope)] = process;
    _pidFile(name, scope).writeAsStringSync('${process.pid}');
    unawaited(process.exitCode.then((_) {
      if (_children[_key(name, scope)] == process) _children.remove(_key(name, scope));
      final file = _pidFile(name, scope);
      if (file.existsSync() && file.readAsStringSync().trim() == '${process.pid}') file.deleteSync();
    }));
    return process;
  }

  /// Hands the helper over so it outlives the tool call that started it.
  void handOver(Process process) => CallProgress.release(process);

  @override
  Future<void> stop(String name, String scope) async {
    final child = _children.remove(_key(name, scope));
    if (child != null) {
      child.kill();
      await child.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
        child.kill(ProcessSignal.sigkill);
        return -9;
      });
    }
    final file = _pidFile(name, scope);
    if (!file.existsSync()) return;
    final pid = int.tryParse(file.readAsStringSync().trim());
    file.deleteSync();
    if (pid == null || !await _isHelper(pid, name)) return;
    Process.killPid(pid);
    for (var i = 0; i < 20 && await _isHelper(pid, name); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (await _isHelper(pid, name)) Process.killPid(pid, ProcessSignal.sigkill);
  }

  Future<bool> _isHelper(int pid, String name) async {
    final r = await Process.run('ps', ['-p', '$pid', '-o', 'command=']);
    return r.exitCode == 0 && '${r.stdout}'.contains('glint-$name');
  }
}
