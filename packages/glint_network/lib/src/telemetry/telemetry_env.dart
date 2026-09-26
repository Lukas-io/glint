import 'package:glint_core/glint_core.dart';

import '../util/network_env.dart';
import '../version.dart';
import 'telemetry_constants.dart';

export 'package:glint_core/glint_core.dart' show dartVersion, installId, osDescriptor, truthyEnv;

/// glint_network's telemetry switches: `GLINT_NETWORK_TELEMETRY`, `GLINT_NETWORK_NO_TELEMETRY`, `GLINT_NETWORK_NO_USAGE`.
const TelemetrySwitches networkSwitches = TelemetrySwitches('GLINT_NETWORK_');

/// Why nothing is sent, or null when the user opted in with `GLINT_NETWORK_TELEMETRY=on`; [usage] also honours `GLINT_NETWORK_NO_USAGE`.
String? sharingOffReason({Map<String, String>? env, bool usage = false}) =>
    networkSwitches.sharingOffReason(env ?? networkEnv, usage: usage);

/// True when `GLINT_NETWORK_NO_TELEMETRY` turns telemetry off entirely.
bool telemetryDisabled([Map<String, String>? env]) => networkSwitches.disabled(env ?? networkEnv);

/// First 12 hex chars of the build commit, or null when unknown.
String? shortCommit() {
  final sha = currentCommitSha();
  if (sha == null) return null;
  return sha.length > 12 ? sha.substring(0, 12) : sha;
}

/// POSTs [jsonStr] to the collector as glint_network; callers check `kCollectorEndpoint.isNotEmpty` first and swallow failures.
Future<int> postTelemetry(String jsonStr) =>
    postToCollector(jsonStr, userAgent: kTelemetryUserAgent);
