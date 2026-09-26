/// Compile-time constants for the telemetry layer.
///
/// These are intentionally NOT read from environment / config — they're
/// baked into the binary so users can audit what their install will do
/// just by inspecting this file (or running `glint_network audit
/// show` to see the payloads themselves).
library;

export 'package:glint_core/glint_core.dart' show kCollectorEndpoint, kTelemetryTimeout;

/// Max stack frames in the payload. Trim depth keeps the payload small
/// + privacy footprint bounded.
const int kStackHeadFrames = 8;

/// Max chars in the `errorMessage` field. Trims long Dart error strings
/// (some carry inline JSON or stack-trace fragments) before they hit
/// the wire.
const int kErrorMessageMaxChars = 200;

/// User-Agent for the HTTPS request. Identifies the client so the
/// collector can rate-limit by UA pattern if a future MCP fork misuses
/// the endpoint.
const String kTelemetryUserAgent = 'flutter_network_mcp-telemetry';
