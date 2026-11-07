import 'dart:async';
import 'dart:io';

/// Kills [process] and its direct children: polite first, forceful after two seconds.
Future<void> killProcessTree(Process process) async {
  await _signalChildren(process.pid, 'TERM');
  process.kill();
  try {
    await process.exitCode.timeout(const Duration(seconds: 2));
  } on TimeoutException {
    await _signalChildren(process.pid, 'KILL');
    process.kill(ProcessSignal.sigkill);
  }
}

Future<void> _signalChildren(int pid, String signal) async {
  try {
    final helper = await Process.start('pkill', ['-$signal', '-P', '$pid']);
    helper.stdout.drain<void>().ignore();
    helper.stderr.drain<void>().ignore();
    await helper.exitCode.timeout(const Duration(seconds: 2));
  } on Object {
    return;
  }
}
