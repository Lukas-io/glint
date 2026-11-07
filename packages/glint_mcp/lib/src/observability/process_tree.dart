import 'dart:io';

import 'package:glint_core/glint_core.dart';

/// Kills [process] and everything below it: polite first, forceful after two seconds.
Future<void> killProcessTree(Process process) async {
  await killTree(process.pid);
  process.kill(ProcessSignal.sigkill);
}
