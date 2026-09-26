/// Environment + identity helpers for telemetry. Ported from
/// flutter_network_mcp so glint payloads share the same identity scheme
/// and the same collector contract.
library;

import 'dart:io' as io;
import 'dart:math';

import 'constants.dart';

/// A random id created once per install in [dataDir]; unlike a hash of the path, it reveals nothing about the user or the machine.
String installId(String dataDir) {
  final file = io.File('$dataDir/install-id');
  try {
    final existing = file.readAsStringSync().trim();
    if (RegExp(r'^[0-9a-f]{24}$').hasMatch(existing)) return existing;
  } on Object {
    // Not created yet.
  }
  final rnd = Random.secure();
  final id = [
    for (var i = 0; i < 12; i++)
      rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
  try {
    io.Directory(dataDir).createSync(recursive: true);
    file.writeAsStringSync(id);
  } on Object {
    // Unwritable data dir: the id lives for this run only.
  }
  return id;
}

/// `"macos 14.6"`. Long Linux version strings (kernel + distro + build)
/// are capped at 60 chars so the payload stays bounded.
String osDescriptor() {
  final ver = io.Platform.operatingSystemVersion;
  final trimmed = ver.length > 60 ? '${ver.substring(0, 60)}…' : ver;
  return '${io.Platform.operatingSystem} $trimmed';
}

/// Dart SDK version — leading semver triple of `Platform.version`.
String dartVersion() {
  final raw = io.Platform.version;
  final spaceIdx = raw.indexOf(' ');
  return spaceIdx < 0 ? raw : raw.substring(0, spaceIdx);
}

/// POSTs [jsonStr] to [kCollectorEndpoint] with the telemetry User-Agent.
/// Returns the HTTP status; throws on connection failure. Callers swallow.
Future<int> postTelemetry(String jsonStr) async {
  final client = io.HttpClient()
    ..connectionTimeout = kTelemetryTimeout
    ..userAgent = kTelemetryUserAgent;
  try {
    final request = await client
        .postUrl(Uri.parse(kCollectorEndpoint))
        .timeout(kTelemetryTimeout);
    request.headers.contentType = io.ContentType.json;
    request.write(jsonStr);
    final response = await request.close().timeout(kTelemetryTimeout);
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

/// True when `GLINT_NO_TELEMETRY` turns off local usage recording and sharing alike.
bool telemetryDisabled([Map<String, String>? env]) {
  final e = env ?? io.Platform.environment;
  return truthyEnv(e['GLINT_NO_TELEMETRY']);
}

/// True when local usage recording is off (`GLINT_NO_TELEMETRY` or `GLINT_NO_USAGE`).
bool usageDisabled([Map<String, String>? env]) {
  final e = env ?? io.Platform.environment;
  return telemetryDisabled(env) || truthyEnv(e['GLINT_NO_USAGE']);
}

/// Why usage stats are not shared, or null when the user opted in with `GLINT_TELEMETRY=on` and nothing overrides it.
String? sharingOffReason([Map<String, String>? env]) {
  final e = env ?? io.Platform.environment;
  if (truthyEnv(e['GLINT_NO_TELEMETRY'])) return 'GLINT_NO_TELEMETRY is set';
  if (truthyEnv(e['GLINT_NO_USAGE'])) return 'GLINT_NO_USAGE is set';
  if (truthyEnv(e['DO_NOT_TRACK'])) return 'DO_NOT_TRACK is set';
  if (!truthyEnv(e['GLINT_TELEMETRY'])) {
    return 'off by default; set GLINT_TELEMETRY=on to share anonymous usage stats';
  }
  return null;
}

/// True only when the user opted in to sharing usage stats.
bool sharingEnabled([Map<String, String>? env]) =>
    sharingOffReason(env) == null;

/// Treats `true` / `1` / `yes` / `on` (case-insensitive, trimmed) as true.
bool truthyEnv(String? v) {
  final s = v?.trim().toLowerCase();
  return s == 'true' || s == '1' || s == 'yes' || s == 'on';
}

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
