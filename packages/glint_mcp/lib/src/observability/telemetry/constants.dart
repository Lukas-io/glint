/// Compile-time constants for the telemetry layer — intentionally NOT read from
/// env/config but baked into the binary, so users can audit what their install
/// does by inspecting this file (or `glint telemetry audit show`).
library;

export 'package:glint_core/glint_core.dart' show kCollectorEndpoint, kTelemetryTimeout;

/// Max chars in the `errorMessage` field for crash payloads.
const int kErrorMessageMaxChars = 200;

/// Max stack frames in crash payloads.
const int kStackHeadFrames = 8;

/// User-Agent for the HTTPS request. Lets the collector rate-limit by
/// product if a future glint fork misuses the endpoint.
const String kTelemetryUserAgent = 'glint-telemetry';
