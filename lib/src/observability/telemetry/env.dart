/// Environment + identity helpers for telemetry. Ported from
/// flutter_network_mcp so glint payloads share the same identity scheme
/// and the same collector contract.
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:crypto/crypto.dart';

import 'constants.dart';

/// `HMAC-SHA256(dataDir, kPublicSalt)[:24]`. One-way per-machine id: the
/// collector can dedupe installs without learning a value it could
/// reverse to the user.
String machineHash(String dataDir) {
  final hmac = Hmac(sha256, utf8.encode(kPublicSalt));
  return hmac.convert(utf8.encode(dataDir)).toString().substring(0, 24);
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

/// True when telemetry is globally disabled via `GLINT_NO_TELEMETRY`.
/// Layered on top of this: `GLINT_NO_USAGE` disables only usage rollups.
bool telemetryDisabled([Map<String, String>? env]) {
  final e = env ?? io.Platform.environment;
  return truthyEnv(e['GLINT_NO_TELEMETRY']);
}

/// True when usage telemetry specifically is disabled.
bool usageDisabled([Map<String, String>? env]) {
  final e = env ?? io.Platform.environment;
  return telemetryDisabled(env) || truthyEnv(e['GLINT_NO_USAGE']);
}

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
