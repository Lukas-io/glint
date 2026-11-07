import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:glint_core/glint_core.dart';

import '../observability/call_progress.dart';
import '../observability/process_tree.dart';
import 'backend.dart';
import 'result.dart';

export '../observability/process_tree.dart' show killProcessTree;
export 'package:glint_core/glint_core.dart' show HelperLife, OnRunning;

/// The cap for a child process whose site names none.
const Duration kDefaultProcessTimeout = Duration(seconds: 30);

/// A child process ran past its cap and was killed.
class ProcessTimeoutError extends BackendFailure {
  ProcessTimeoutError({
    required this.command,
    required this.phase,
    required this.timeout,
    this.partialStdout = '',
    this.partialStderr = '',
    List<String> hints = const [],
  }) : super(
          GlintErrorKind.toolTimeout,
          '$phase: `$command` did not finish within ${_secs(timeout)} and was killed'
          '${partialStderr.trim().isEmpty ? '' : '; stderr so far: ${_tail(partialStderr)}'}',
          nextSteps: [
            ...hints,
            'retry once; the stuck command was killed, nothing keeps running',
            'if it repeats, `device op:screenshot` shows whether the device is frozen; reboot or re-attach it',
          ],
          data: {'phase': phase, 'command': command, 'timeoutMs': timeout.inMilliseconds, 'scope': 'command'},
        );

  final String command;
  final String phase;
  final Duration timeout;
  final String partialStdout;
  final String partialStderr;

  static String _secs(Duration d) => d.inMilliseconds % 1000 == 0 ? '${d.inSeconds}s' : '${d.inMilliseconds}ms';
  static String _tail(String s) => s.trim().length <= 200 ? s.trim() : '…${s.trim().substring(s.trim().length - 200)}';
}

/// Runs a child process with a hard cap: on timeout the process and its direct children are killed and a [ProcessTimeoutError] names the command and [phase]. Same result as [Process.run], plus the phase shows in heartbeats and the call's timeout reply.
Future<ProcessResult> runBounded(
  String executable,
  List<String> arguments, {
  Duration timeout = kDefaultProcessTimeout,
  String? phase,
  Map<String, String>? environment,
  String? workingDirectory,
  Encoding? stdoutEncoding = systemEncoding,
  Encoding? stderrEncoding = systemEncoding,
  List<String> hints = const [],
}) async {
  CallProgress.checkAlive();
  final command = describeCommand(executable, arguments);
  final label = phase ?? command;
  return CallProgress.during(label, () async {
    final process = ProcessRegistry.instance.track(
        await Process.start(executable, arguments, environment: environment, workingDirectory: workingDirectory));
    final call = CallProgress.current;
    call?.registerProcess(process, label);
    process.stdin.close().ignore();
    final out = _Drain(process.stdout);
    final err = _Drain(process.stderr);
    try {
      final code = await process.exitCode.timeout(timeout);
      await Future.wait([out.done, err.done]).timeout(const Duration(seconds: 3), onTimeout: () => const []);
      return ProcessResult(process.pid, code, out.decode(stdoutEncoding), err.decode(stderrEncoding));
    } on TimeoutException {
      await killProcessTree(process);
      throw ProcessTimeoutError(
        command: command,
        phase: label,
        timeout: timeout,
        partialStdout: out.decode(systemEncoding) as String,
        partialStderr: err.decode(systemEncoding) as String,
        hints: hints,
      );
    } finally {
      call?.unregisterProcess(process);
      out.cancel();
      err.cancel();
    }
  });
}

/// Starts a child that belongs to the current tool call: it is stopped if the call is abandoned, and forgotten once it exits. Call [CallProgress.release] to hand it over to outlive the call.
Future<Process> startManaged(
  String executable,
  List<String> arguments, {
  String? label,
  Map<String, String>? environment,
  String? workingDirectory,
}) async {
  CallProgress.checkAlive();
  final process = ProcessRegistry.instance
      .track(await Process.start(executable, arguments, environment: environment, workingDirectory: workingDirectory));
  return _ownedByCall(process, label ?? describeCommand(executable, arguments));
}

/// Starts the long-lived helper for [purpose] on [device] through the process registry: one per purpose and device, stopped with its [life], reaped by a later glint if this one dies. Like [startManaged], an abandoned call stops it until [CallProgress.release] hands it over.
Future<Process> startHelper(
  String purpose,
  String executable,
  List<String> arguments, {
  String? device,
  String? owner,
  HelperLife life = HelperLife.session,
  OnRunning onRunning = OnRunning.replace,
  String? label,
  Map<String, String>? environment,
  String? workingDirectory,
}) async {
  CallProgress.checkAlive();
  final process = await ProcessRegistry.instance.start(
    purpose,
    executable,
    arguments,
    device: device,
    owner: owner,
    life: life,
    onRunning: onRunning,
    environment: environment,
    workingDirectory: workingDirectory,
  );
  return _ownedByCall(process, label ?? describeCommand(executable, arguments));
}

Process _ownedByCall(Process process, String label) {
  final call = CallProgress.current;
  if (call != null) {
    call.registerProcess(process, label);
    unawaited(process.exitCode.then((_) => call.unregisterProcess(process)));
  }
  return process;
}

/// [runBounded] with the default cap, shaped as a [ProcessRunner] so it can stand in for [Process.run].
Future<ProcessResult> boundedRun(String executable, List<String> arguments) => runBounded(executable, arguments);

/// Runs through the injected [run], giving the default [boundedRun] this call's own [timeout] and [phase].
Future<ProcessResult> runCapped(
  ProcessRunner run,
  String executable,
  List<String> arguments, {
  required Duration timeout,
  String? phase,
}) =>
    identical(run, boundedRun)
        ? runBounded(executable, arguments, timeout: timeout, phase: phase)
        : run(executable, arguments);

/// A short readable name for a command line: the tool and its first arguments.
String describeCommand(String executable, List<String> arguments) {
  final name = executable.split('/').last;
  final line = [name, ...arguments.take(4)].join(' ');
  return line.length <= 90 ? line : '${line.substring(0, 89)}…';
}

class _Drain {
  _Drain(Stream<List<int>> stream) {
    _sub = stream.listen(_bytes.addAll, onDone: _finished.complete, onError: (Object _) {}, cancelOnError: false);
  }

  final List<int> _bytes = [];
  final Completer<void> _finished = Completer<void>();
  late final StreamSubscription<List<int>> _sub;

  Future<void> get done => _finished.future;

  /// The bytes as text in [encoding], or as raw bytes when [encoding] is null.
  Object decode(Encoding? encoding) => encoding == null ? List<int>.of(_bytes) : encoding.decode(_bytes);

  void cancel() => _sub.cancel().ignore();
}
