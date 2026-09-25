/// Compile-time constants for the telemetry layer — intentionally NOT read from
/// env/config but baked into the binary, so users can audit what their install
/// does by inspecting this file (or `glint telemetry audit show`).
library;

/// Collector POST endpoint. The same Cloudflare Worker + D1 that backs
/// flutter_network_mcp — it routes by payload `kind` and dedupes products
/// via the `version` field (`glint/<v>` vs `flutter_network_mcp/<v>`).
const String kCollectorEndpoint =
    'https://flutter-network-telemetry.wisdomiyamu.workers.dev/v1/telemetry';

/// Wire deadline for the POST attempt. Best-effort: a 3s budget covers
/// healthy networks and leaves shutdown free to exit if the collector
/// is unreachable.
const Duration kTelemetryTimeout = Duration(seconds: 3);

/// Max chars in the `errorMessage` field for crash payloads.
const int kErrorMessageMaxChars = 200;

/// Max stack frames in crash payloads.
const int kStackHeadFrames = 8;

/// User-Agent for the HTTPS request. Lets the collector rate-limit by
/// product if a future glint fork misuses the endpoint.
const String kTelemetryUserAgent = 'glint-telemetry';
