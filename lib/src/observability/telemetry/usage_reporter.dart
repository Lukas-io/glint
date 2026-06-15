/// Ships privacy-safe usage rollups to the shared collector.
///
/// Same contract as flutter_network_mcp: per-tool counts, outcome +
/// latency stats, and the tool→next-tool transition graph. Raw events
/// never leave the machine; only the aggregate does.
///
/// Trust model:
/// 1. Audit log first (always, when not opted out) — the exact rollup
///    JSON is appended to the hash-chained `telemetry-audit.log` BEFORE
///    any network attempt.
/// 2. HTTPS POST when [kCollectorEndpoint] is non-empty.
///
/// Idempotent via a high-watermark: `usage-ship-state.json` in the data
/// dir records the last `id` shipped. Re-running never double-counts.
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:path/path.dart' as p;

import '../../version.dart';
import 'audit_log.dart';
import 'constants.dart';
import 'env.dart';
import 'summarize.dart';
import 'usage_recorder.dart';

const String _kStateFileName = 'usage-ship-state.json';
const Duration _kAutoShipMinInterval = Duration(hours: 24);

/// `glint/<version>` — sent in the rollup `version` field so the collector
/// can disambiguate this product from flutter_network_mcp in the shared D1.
String get kGlintVersion => 'glint/$packageVersion';

class UsageReporter {
  UsageReporter(this.recorder);

  final UsageRecorder recorder;

  /// Fire-and-forget startup hook. Daily-gated. Never throws — safe to
  /// `unawaited(...)` from server bootstrap.
  Future<void> maybeAutoShip() async {
    try {
      if (usageDisabled()) return;
      final dir = resolveDataDir();
      final state = _readState(dir);
      final last = state.lastShippedAtMs;
      if (last != null &&
          DateTime.now().millisecondsSinceEpoch - last <
              _kAutoShipMinInterval.inMilliseconds) {
        return;
      }
      await ship(dataDir: dir);
    } on Object {
      // Telemetry hiccup must never disturb the server.
    }
  }

  /// Builds + ships the rollup of every event newer than the watermark.
  /// Returns a [UsageShipResult]. Never throws.
  Future<UsageShipResult> ship({
    String? dataDir,
    bool dryRun = false,
    String? endpointOverride,
  }) async {
    final dir = dataDir ?? resolveDataDir();
    if (usageDisabled()) {
      return const UsageShipResult(
        shipped: false,
        message: 'usage telemetry disabled (GLINT_NO_TELEMETRY / NO_USAGE)',
      );
    }

    final state = _readState(dir);
    final rows = recorder.eventsAfterId(state.lastShippedEventId);
    if (rows.isEmpty) {
      return UsageShipResult(
        shipped: false,
        events: 0,
        fromEventId: state.lastShippedEventId,
        toEventId: state.lastShippedEventId,
        message: 'no new events since the last ship '
            '(watermark id=${state.lastShippedEventId})',
      );
    }

    final payload = buildUsagePayload(rows: rows, dataDir: dir);
    final toEventId = (payload['window'] as Map)['toEventId'] as int;
    final jsonStr = jsonEncode(payload);

    if (dryRun) {
      return UsageShipResult(
        shipped: false,
        dryRun: true,
        events: rows.length,
        fromEventId: state.lastShippedEventId,
        toEventId: toEventId,
        payloadJson: jsonStr,
        message: 'dry run: ${rows.length} event(s) would ship; nothing written',
      );
    }

    var auditWritten = true;
    try {
      AuditLog.append(dir, jsonStr);
    } on Object {
      auditWritten = false;
    }

    var posted = false;
    final endpoint = endpointOverride ?? kCollectorEndpoint;
    if (endpoint.isNotEmpty) {
      try {
        final status = await _postTo(endpoint, jsonStr).timeout(kTelemetryTimeout);
        posted = status >= 200 && status < 300;
      } on Object {
        // Best-effort: the audit log already holds the rollup.
      }
    }

    _writeState(
      dir,
      _ShipState(
        lastShippedEventId: toEventId,
        lastShippedAtMs: DateTime.now().millisecondsSinceEpoch,
        shipCount: state.shipCount + 1,
      ),
    );

    final String msg;
    if (posted) {
      msg = 'shipped ${rows.length} event(s) to the collector + audit log';
    } else if (endpoint.isEmpty) {
      msg = 'recorded ${rows.length} event(s) to the audit log '
          '(collector not configured; audit-log-only mode)';
    } else if (!auditWritten) {
      msg = 'collector POST and audit write both failed; watermark advanced';
    } else {
      msg = 'audit log written; collector POST failed (will resume next ship)';
    }
    return UsageShipResult(
      shipped: true,
      events: rows.length,
      fromEventId: state.lastShippedEventId,
      toEventId: toEventId,
      posted: posted,
      payloadJson: jsonStr,
      message: msg,
    );
  }

  static Future<int> _postTo(String endpoint, String jsonStr) async {
    final client = io.HttpClient()
      ..connectionTimeout = kTelemetryTimeout
      ..userAgent = kTelemetryUserAgent;
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

  static _ShipState _readState(String dataDir) {
    try {
      final f = io.File(p.join(dataDir, _kStateFileName));
      if (!f.existsSync()) return const _ShipState();
      final m = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      return _ShipState(
        lastShippedEventId: (m['lastShippedEventId'] as int?) ?? 0,
        lastShippedAtMs: m['lastShippedAtMs'] as int?,
        shipCount: (m['shipCount'] as int?) ?? 0,
      );
    } on Object {
      return const _ShipState();
    }
  }

  static void _writeState(String dataDir, _ShipState s) {
    final f = io.File(p.join(dataDir, _kStateFileName));
    if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
    f.writeAsStringSync(
      jsonEncode({
        'lastShippedEventId': s.lastShippedEventId,
        'lastShippedAtMs': s.lastShippedAtMs,
        'shipCount': s.shipCount,
      }),
      flush: true,
    );
  }
}

/// Builds the rollup payload. Visible for testing.
///
/// IN: package version, host OS + Dart version, the HMAC machineHash,
/// the event-id + timestamp window, and the [summarizeUsage] aggregate.
/// NOT IN: arg values, glintIds, app names, paths, or any per-event row.
Map<String, Object?> buildUsagePayload({
  required List<Map<String, Object?>> rows,
  required String dataDir,
  int topTransitions = 100,
}) {
  final stats = summarizeUsage(rows, topTransitions: topTransitions);

  var firstMs = 0;
  var lastMs = 0;
  var toEventId = 0;
  var seen = false;
  for (final r in rows) {
    final ts = (r['ts_ms'] as int?) ?? 0;
    final id = (r['id'] as int?) ?? 0;
    if (!seen) {
      firstMs = ts;
      lastMs = ts;
      seen = true;
    } else {
      if (ts < firstMs) firstMs = ts;
      if (ts > lastMs) lastMs = ts;
    }
    if (id > toEventId) toEventId = id;
  }

  return <String, Object?>{
    'kind': 'usage_rollup',
    'version': kGlintVersion,
    'os': osDescriptor(),
    'dart': dartVersion(),
    'machineHash': machineHash(dataDir),
    'window': {
      'firstEventMs': firstMs,
      'lastEventMs': lastMs,
      'toEventId': toEventId,
    },
    'totalEvents': stats['totalEvents'],
    'totalTurns': stats['totalTurns'],
    'tools': stats['tools'],
    'transitions': stats['transitions'],
    'reportedAt': DateTime.now().toUtc().toIso8601String(),
  };
}

class UsageShipResult {
  const UsageShipResult({
    required this.shipped,
    required this.message,
    this.events = 0,
    this.fromEventId = 0,
    this.toEventId = 0,
    this.posted = false,
    this.dryRun = false,
    this.payloadJson,
  });

  final bool shipped;
  final String message;
  final int events;
  final int fromEventId;
  final int toEventId;
  final bool posted;
  final bool dryRun;
  final String? payloadJson;
}

class _ShipState {
  const _ShipState({
    this.lastShippedEventId = 0,
    this.lastShippedAtMs,
    this.shipCount = 0,
  });

  final int lastShippedEventId;
  final int? lastShippedAtMs;
  final int shipCount;
}
