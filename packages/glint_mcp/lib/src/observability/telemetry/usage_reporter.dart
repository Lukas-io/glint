import 'dart:io' as io;

import 'package:glint_core/glint_core.dart';

import 'constants.dart';
import 'env.dart';
import 'usage_recorder.dart';
import '../../version.dart';

/// The `version` glint's rollups carry, so the shared collector tells the products apart.
const String kGlintVersion = 'glint/$glintVersion';

/// glint's usage rollups: the shared [UsageShipper] over the recorder's events; sends nothing unless `GLINT_TELEMETRY=on`.
class UsageReporter {
  UsageReporter(this.recorder, {Map<String, String>? env}) : _env = env;

  final UsageRecorder recorder;

  /// Environment the sharing switches are read from; null reads the process environment.
  final Map<String, String>? _env;

  UsageShipper _shipper({String? endpoint}) => UsageShipper(
        source: recorder,
        switches: glintSwitches,
        identity: () => const {'version': kGlintVersion},
        userAgent: kTelemetryUserAgent,
        dataDir: resolveDataDir,
        env: () => _env ?? io.Platform.environment,
        endpoint: endpoint ?? kCollectorEndpoint,
      );

  /// Startup hook, daily-gated; ships what earlier processes recorded and never throws.
  Future<void> maybeAutoShip() => _shipper().maybeAutoShip();

  /// Shutdown hook bounded by the collector timeout; never throws.
  Future<void> shipOnExit({String? dataDir}) => _shipper().shipOnExit(dataDir: dataDir);

  /// Events recorded since the last ship.
  int unshippedCount({String? dataDir}) => _shipper().unshippedCount(dataDir: dataDir);

  /// Builds and ships (or with [dryRun] only builds) the rollup of every event past the watermark; never throws.
  Future<UsageShipResult> ship({String? dataDir, bool dryRun = false, String? endpointOverride}) =>
      _shipper(endpoint: endpointOverride).ship(dataDir: dataDir, dryRun: dryRun);
}
