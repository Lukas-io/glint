import 'dart:io' as io;
import 'dart:math';

/// Collector endpoint baked into the binary so users can audit where payloads go.
const String kCollectorEndpoint =
    'https://flutter-network-telemetry.wisdomiyamu.workers.dev/v1/telemetry';

/// Budget for one POST, short enough that shutdown never waits on an unreachable collector.
const Duration kTelemetryTimeout = Duration(seconds: 3);

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
  final id = [for (var i = 0; i < 12; i++) rnd.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  try {
    io.Directory(dataDir).createSync(recursive: true);
    file.writeAsStringSync(id);
  } on Object {
    // Unwritable data dir: the id lives for this run only.
  }
  return id;
}

/// `"macos 14.6"`, with long version strings capped at 60 characters.
String osDescriptor() {
  final ver = io.Platform.operatingSystemVersion;
  final trimmed = ver.length > 60 ? '${ver.substring(0, 60)}…' : ver;
  return '${io.Platform.operatingSystem} $trimmed';
}

/// The Dart SDK version: the leading semver triple of `Platform.version`.
String dartVersion() {
  final raw = io.Platform.version;
  final spaceIdx = raw.indexOf(' ');
  return spaceIdx < 0 ? raw : raw.substring(0, spaceIdx);
}

/// Treats `true`, `1`, `yes` and `on` (any case, trimmed) as true.
bool truthyEnv(String? v) {
  final s = v?.trim().toLowerCase();
  return s == 'true' || s == '1' || s == 'yes' || s == 'on';
}

/// POSTs [jsonStr] to [endpoint] and returns the HTTP status; throws when the collector can't be reached.
Future<int> postToCollector(String jsonStr,
    {required String userAgent, String endpoint = kCollectorEndpoint}) async {
  final client = io.HttpClient()
    ..connectionTimeout = kTelemetryTimeout
    ..userAgent = userAgent;
  try {
    final request = await client.postUrl(Uri.parse(endpoint)).timeout(kTelemetryTimeout);
    request.headers.contentType = io.ContentType.json;
    request.write(jsonStr);
    final response = await request.close().timeout(kTelemetryTimeout);
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

/// A package's telemetry switches, read under its env var [prefix] (`GLINT_`, `GLINT_NETWORK_`); `DO_NOT_TRACK` always wins.
class TelemetrySwitches {
  const TelemetrySwitches(this.prefix);

  final String prefix;

  /// `<prefix>NO_TELEMETRY` turns off recording and sharing alike.
  bool disabled(Map<String, String> env) => truthyEnv(env['${prefix}NO_TELEMETRY']);

  /// Local usage recording is off under `<prefix>NO_TELEMETRY` or `<prefix>NO_USAGE`.
  bool usageDisabled(Map<String, String> env) =>
      disabled(env) || truthyEnv(env['${prefix}NO_USAGE']);

  /// Why nothing is shared, or null when the user opted in with `<prefix>TELEMETRY=on`; [usage] also honours `<prefix>NO_USAGE`, which crash reports ignore.
  String? sharingOffReason(Map<String, String> env, {bool usage = true}) {
    if (disabled(env)) return '${prefix}NO_TELEMETRY is set';
    if (usage && truthyEnv(env['${prefix}NO_USAGE'])) return '${prefix}NO_USAGE is set';
    if (truthyEnv(env['DO_NOT_TRACK'])) return 'DO_NOT_TRACK is set';
    if (!truthyEnv(env['${prefix}TELEMETRY'])) {
      return 'off by default; set ${prefix}TELEMETRY=on to share anonymous '
          '${usage ? 'usage stats' : 'crash reports'}';
    }
    return null;
  }
}
