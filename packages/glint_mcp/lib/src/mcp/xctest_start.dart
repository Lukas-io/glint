import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/server.dart';

import '../../interaction.dart';
import 'envelope.dart';
import 'session.dart';

/// Builds (once per Xcode) and starts glint's XCUITest runner on [udid], reusing one already answering; the error says why it could not.
Future<({XcTestRunner? runner, StructuredResponse? error})> startXcTestRunner(String udid, IosToolchain toolchain,
    {void Function(String phase)? onPhase}) async {
  final project = locateRunnerProject();
  if (project == null) {
    return (
      runner: null,
      error: StructuredResponse.error(
        summary: 'the XCTest runner project is not part of this glint install',
        errorKind: GlintErrorKind.unsupportedToolchain,
        detail: 'looked for $kRunnerProject above the running script',
        nextSteps: const ['attach again with iosBackend:bridge'],
      ),
    );
  }
  final home = Platform.environment['HOME'] ?? '.';
  final runner = XcTestRunner(
      udid: udid, projectPath: project, cacheDir: '$home/.glint/xctest/xcode-${toolchain.xcode.version ?? "unknown"}');
  try {
    await runner.ensureStarted(onPhase: onPhase);
  } on XcTestRunnerError catch (e) {
    return (
      runner: null,
      error: StructuredResponse.error(
        summary: e.message,
        errorKind: GlintErrorKind.backendToolError,
        detail: e.detail,
        nextSteps: e.nextSteps,
      ),
    );
  }
  return (runner: runner, error: null);
}

final _runners = <String, XcTestRunner>{};

/// The simulator's XCTest runner for a tool call: the attached backend's, one started earlier, or a new one (built on first use, with progress every 15 s).
Future<({XcTestRunner? runner, StructuredResponse? error})> xcTestRunnerFor(
    GlintSession session, IosSimulator dev, CallToolRequest request) async {
  final own = dev.runner;
  if (own != null && await own.ping() == expectedRunnerProtocol) return (runner: own, error: null);
  final cached = _runners[dev.udid];
  if (cached != null && await cached.ping() == expectedRunnerProtocol) return (runner: cached, error: null);
  final token = request.meta?.progressToken;
  final notifier = session.progressNotifier;
  var phase = 'checking the iOS toolchain';
  final started = DateTime.now();
  final ticker = token == null || notifier == null
      ? null
      : Timer.periodic(const Duration(seconds: 15), (_) {
          final sec = DateTime.now().difference(started).inSeconds;
          notifier(ProgressNotification(progressToken: token, progress: sec, message: '$phase (${sec}s)'));
        });
  try {
    final toolchain = await checkIosToolchain(null, onPhase: (p) => phase = p);
    final r = await startXcTestRunner(dev.udid, toolchain, onPhase: (p) => phase = p);
    if (r.runner != null) _runners[dev.udid] = r.runner!;
    return r;
  } finally {
    ticker?.cancel();
  }
}
