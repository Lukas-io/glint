import 'package:glint_core/glint_core.dart';

import '../storage/captures_db.dart';
import '../storage/database.dart';
import '../util/data_dir.dart';
import '../util/network_env.dart';
import '../version.dart';
import 'telemetry_constants.dart';
import 'telemetry_env.dart';

export 'package:glint_core/glint_core.dart' show UsageShipResult, buildUsagePayload;

/// glint_network's usage rollups: the shared [UsageShipper] over the `tool_events` table; sends nothing unless `GLINT_NETWORK_TELEMETRY=on`.
class UsageReporter {
  /// Watermark and bookkeeping file in the data dir.
  static const String stateFileName = UsageShipper.stateFileName;

  /// Auto-ship runs at most this often.
  static const Duration autoShipMinInterval = UsageShipper.autoShipMinInterval;

  static Map<String, String>? _envOverride;

  /// Test seam: pins the env the switches read; null reverts to the process environment.
  static set envForTest(Map<String, String>? env) => _envOverride = env;

  static String? _endpointOverride;

  /// Test seam: overrides the collector endpoint (`''` forces audit-log-only); null reverts to [kCollectorEndpoint].
  static set endpointForTest(String? endpoint) => _endpointOverride = endpoint;

  static UsageShipper get _shipper => UsageShipper(
        source: const _ToolEventsSource(),
        switches: networkSwitches,
        identity: networkUsageIdentity,
        userAgent: kTelemetryUserAgent,
        dataDir: resolveCandidateDataDir,
        env: () => _envOverride ?? networkEnv,
        endpoint: _endpointOverride ?? kCollectorEndpoint,
      );

  /// Startup hook, daily-gated; never throws.
  static Future<void> maybeAutoShip() => _shipper.maybeAutoShip();

  /// Builds and ships (or with [dryRun] only builds) the rollup of every event past the watermark; never throws.
  static Future<UsageShipResult> ship({String? dataDir, bool dryRun = false}) =>
      _shipper.ship(dataDir: dataDir, dryRun: dryRun);
}

/// Identity fields of glint_network's rollups, as the collector already stores them.
Map<String, Object?> networkUsageIdentity() {
  final commit = shortCommit();
  return {
    'version': packageVersion,
    if (commit != null) 'commit': commit,
    'isAot': isAotBuild,
  };
}

/// The `tool_events` table, opening the capture database when a CLI ship runs without a server.
class _ToolEventsSource implements UsageEventSource {
  const _ToolEventsSource();

  @override
  List<Map<String, Object?>> eventsAfter(int afterId, {required int limit}) {
    if (!CapturesDatabase.isOpen) CapturesDatabase.open();
    return CapturesDao().toolEventsAfterId(afterId: afterId, limit: limit);
  }

  @override
  int get maxEventId {
    if (!CapturesDatabase.isOpen) CapturesDatabase.open();
    return CapturesDao().maxToolEventId();
  }
}
