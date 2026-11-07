import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:glint_core/glint_core.dart' show HelperLife, ProcessRegistry;

import '../interaction/bounded_process.dart';
import '../interaction/result.dart';
import '../interaction/shipped_files.dart';
import '../interaction/siminject.dart';
import '../interaction/swift_helper.dart';
import '../observability/call_progress.dart';
import 'host_tools.dart';

const _source = 'native/ios_sim_inject/mac/frames.swift';

/// The protocol the frames helper must report; a different one is refused.
const int frameHelperProtocol = 1;

/// The Mac frames helper (Mac camera and simulator screen modes), built with the Xcode toolchain on first use.
Future<String> frameHelperBinary(PhaseReporter? phases) async {
  final source = shippedPath(_source);
  if (source == null) {
    throw SimInjectFailure(GlintErrorKind.unsupportedToolchain, 'the frames helper is not part of this glint install',
        'looked for $_source', ['reinstall glint']);
  }
  try {
    return await swiftHelper(source, 'glint-frames', phase: 'building the frames helper');
  } on SwiftHelperError catch (e) {
    throw SimInjectFailure(GlintErrorKind.unsupportedToolchain, e.message, e.detail,
        ['install Xcode and its command line tools (xcode-select --install), then retry']);
  }
}

/// Starts the frames helper for [purpose] on [device] and waits for its first line; [notReady] explains any line that is not a matching `ready`. The helper is handed over to outlive the call.
Future<({Process process, String line})> startFrameHelper({
  required String binary,
  required String purpose,
  required String device,
  required List<String> arguments,
  required String label,
  required String waiting,
  required Duration timeout,
  required SimInjectFailure Function(String line) notReady,
  PhaseReporter? phases,
}) async {
  final process = await startHelper(purpose, binary, arguments, device: device, life: HelperLife.session, label: label);
  unawaited(process.stderr.drain<void>());
  final ready = Completer<String>();
  process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if (!ready.isCompleted) ready.complete(line.trim());
  });
  unawaited(process.exitCode.then((code) {
    if (!ready.isCompleted) ready.complete(code == 3 ? 'denied' : 'exited $code');
  }));
  Future<String> first() => ready.future.timeout(timeout, onTimeout: () => 'timeout');
  final line = await (phases?.during(waiting, first) ?? first());
  final reported = RegExp(r'protocol=(\d+)').firstMatch(line)?.group(1);
  if (!line.startsWith('ready')) {
    await ProcessRegistry.instance.stop(purpose, device: device);
    throw notReady(line);
  }
  if (reported != '$frameHelperProtocol') {
    await ProcessRegistry.instance.stop(purpose, device: device);
    throw SimInjectFailure(GlintErrorKind.unsupportedToolchain, 'the frames helper speaks another protocol',
        'helper reports ${reported ?? 'none'}, this glint needs $frameHelperProtocol', [
      'remove ~/.glint/bin/glint-frames-* and repeat the call, or update glint',
    ]);
  }
  CallProgress.release(process);
  return (process: process, line: line);
}
