/// Compile-time constants for the telemetry layer.
///
/// These are intentionally NOT read from environment / config — they're
/// baked into the binary so users can audit what their install will do
/// just by inspecting this file (or running `glint telemetry audit show`
/// to see the payloads themselves).
library;

/// Public HMAC salt. Every glint install uses this same value to compute
/// its `machineHash`, so the collector can dedupe machines without
/// learning anything identifying. Shares the salt with flutter_network_mcp
/// so the collector sees both products via one identity scheme.
///
/// Generated once via `openssl rand -hex 32`. DO NOT change without a
/// coordinated collector update.
const String kPublicSalt =
    '761d2c3db2b2719c04ad002499704b7e094048c57046457c545105be31de8d11';

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
