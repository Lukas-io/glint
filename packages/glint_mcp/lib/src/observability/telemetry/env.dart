import 'dart:io' as io;

import 'package:glint_core/glint_core.dart';

import 'constants.dart';

export 'package:glint_core/glint_core.dart' show dartVersion, installId, osDescriptor, truthyEnv;

/// glint's telemetry switches: `GLINT_TELEMETRY`, `GLINT_NO_TELEMETRY`, `GLINT_NO_USAGE`.
const TelemetrySwitches glintSwitches = TelemetrySwitches('GLINT_');

/// POSTs [jsonStr] to the collector as glint; throws on connection failure, callers swallow.
Future<int> postTelemetry(String jsonStr) =>
    postToCollector(jsonStr, userAgent: kTelemetryUserAgent);

/// True when `GLINT_NO_TELEMETRY` turns off local usage recording and sharing alike.
bool telemetryDisabled([Map<String, String>? env]) =>
    glintSwitches.disabled(env ?? io.Platform.environment);

/// True when local usage recording is off (`GLINT_NO_TELEMETRY` or `GLINT_NO_USAGE`).
bool usageDisabled([Map<String, String>? env]) =>
    glintSwitches.usageDisabled(env ?? io.Platform.environment);

/// Why usage stats are not shared, or null when the user opted in with `GLINT_TELEMETRY=on` and nothing overrides it.
String? sharingOffReason([Map<String, String>? env]) =>
    glintSwitches.sharingOffReason(env ?? io.Platform.environment);

/// True only when the user opted in to sharing usage stats.
bool sharingEnabled([Map<String, String>? env]) => sharingOffReason(env) == null;

/// Glint's per-install data dir. Holds the audit log + ship watermark.
String resolveDataDir() {
  final env = io.Platform.environment;
  final override = env['GLINT_DATA_DIR'];
  if (override != null && override.isNotEmpty) return override;
  final home = env['HOME'] ?? env['USERPROFILE'];
  if (home == null || home.isEmpty) {
    return io.Directory.systemTemp.createTempSync('glint-').path;
  }
  return '$home/.glint';
}
