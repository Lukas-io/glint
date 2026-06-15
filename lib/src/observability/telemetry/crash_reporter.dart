/// Crash telemetry reporter.
///
/// Wired from `bin/glint.dart`'s top-level `runZonedGuarded` handler —
/// every uncaught error becomes a fire-and-forget call to [maybeReport].
///
/// Two writes per call (in this order):
/// 1. **Local audit log** (always, when telemetry isn't opted out):
///    appended to `<dataDir>/telemetry-audit.log` BEFORE the network
///    attempt, so the user can see what would have been sent even when
///    the wire send fails.
/// 2. **HTTPS POST** (only when [kCollectorEndpoint] is non-empty):
///    fire-and-forget with a 3s deadline. All errors swallowed.
///
/// Opt-out: `GLINT_NO_TELEMETRY=true` short-circuits the whole path —
/// no audit write, no network attempt.
///
/// **Privacy-first by design**: see [buildCrashPayload] for the schema.
/// No PII, no source paths, no captured app data.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../version.dart';
import 'audit_log.dart';
import 'constants.dart';
import 'env.dart';
import 'path_redactor.dart';

class CrashReporter {
  /// Fire-and-forget entry point. Caller MUST NOT await this in a path
  /// that blocks shutdown — use `unawaited(...)`.
  static Future<void> maybeReport({
    required Object error,
    required StackTrace stack,
  }) async {
    try {
      if (telemetryDisabled()) return;
      final dataDir = resolveDataDir();

      final payload = buildCrashPayload(
        error: error,
        stack: stack,
        dataDir: dataDir,
      );
      final jsonStr = jsonEncode(payload);

      // Audit log first. Failure is non-fatal; the network attempt still
      // runs.
      try {
        AuditLog.append(dataDir, jsonStr);
      } catch (_) {/* audit log is best-effort */}

      if (kCollectorEndpoint.isNotEmpty) {
        await postTelemetry(jsonStr)
            .timeout(kTelemetryTimeout)
            .catchError((_) => -1);
      }
    } catch (_) {
      // Belt-and-suspenders: nothing inside this method should propagate.
      // The runZonedGuarded handler is the last line of defense before
      // process exit; an exception here would replace the original error
      // in stderr — unacceptable.
    }
  }
}

/// Builds the wire payload. Visible for testing.
///
/// **Schema** (what's IN):
/// - `kind`: "crash" (lets the collector route the right table)
/// - `version`: `glint/<v>` so it can be told apart from FNM in the
///   shared D1 collector
/// - `commit`: 12-char SHA when known
/// - `isAot`: true under `glint install`, false under JIT
/// - `os`: `<platform> <truncated-version>`
/// - `dart`: Dart SDK version triple
/// - `errorClass`: `error.runtimeType.toString()`
/// - `errorMessage`: truncated to [kErrorMessageMaxChars]
/// - `stackHead`: first [kStackHeadFrames] frames, paths redacted
/// - `signature`: `sha256(errorClass + top-3-frames)[:12]` (dedupe key)
/// - `machineHash`: `HMAC(dataDir, salt)[:24]` (dedupe key)
/// - `reportedAt`: ISO-8601 UTC
///
/// **What's NOT in**: `$HOME`, target project path, vmServiceUri,
/// captured app data, env-var contents, glintIds, scene text.
Map<String, Object?> buildCrashPayload({
  required Object error,
  required StackTrace stack,
  required String dataDir,
}) {
  final errorClass = error.runtimeType.toString();
  final errorMessage = _truncate(error.toString(), kErrorMessageMaxChars);
  final stackHead = redactStackHead(stack, maxFrames: kStackHeadFrames);
  final signature = crashSignature(errorClass, stackHead);
  final commitShort = shortCommit();

  return <String, Object?>{
    'kind': 'crash',
    'version': 'glint/$packageVersion',
    if (commitShort != null) 'commit': commitShort,
    'isAot': isAotBuild,
    'os': osDescriptor(),
    'dart': dartVersion(),
    'errorClass': errorClass,
    if (errorMessage.isNotEmpty) 'errorMessage': errorMessage,
    'stackHead': stackHead,
    'signature': signature,
    'machineHash': machineHash(dataDir),
    'reportedAt': DateTime.now().toUtc().toIso8601String(),
  };
}

String _truncate(String s, int max) {
  if (s.length <= max) return s;
  return '${s.substring(0, max)}…(${s.length} chars)';
}

/// Visible for testing: `sha256(errorClass + ':' + top-3-frames)[:12]`.
/// Identical bugs across machines + versions collapse to one signature.
String crashSignature(String errorClass, List<String> stackHead) {
  final top = stackHead.take(3).join('\n');
  final digest = sha256.convert(utf8.encode('$errorClass:$top'));
  return digest.toString().substring(0, 12);
}
