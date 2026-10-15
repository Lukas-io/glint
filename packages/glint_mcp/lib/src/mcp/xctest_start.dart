import 'dart:io';

import '../../interaction.dart';
import 'envelope.dart';

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
