import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:path/path.dart' as p;

import 'audit_log.dart';
import 'telemetry.dart';

/// Rough characters per token, the usual heuristic for JSON-ish text.
const double kCharsPerToken = 4.0;

/// Estimated agent-side tokens for a reply of [bytes] characters.
int estimateTokens(int bytes) => bytes <= 0 ? 0 : (bytes / kCharsPerToken).round();

/// `ok`, `error`, or `empty` (a reply whose `count` is 0) for one tool call.
String usageOutcome({required bool isError, Map<String, Object?>? structured}) {
  if (isError) return 'error';
  if (structured != null && structured['count'] == 0) return 'empty';
  return 'ok';
}

/// The sorted argument names of a call; values are never recorded.
List<String> usageArgKeys(Map<String, Object?>? args) =>
    args == null || args.isEmpty ? const [] : (args.keys.toList()..sort());

/// Groups calls into turns: a gap longer than [gapMs] starts a new correlation id, prefixed with a random per-process token.
class TurnTracker {
  TurnTracker({this.gapMs = 60000});

  final int gapMs;
  final String _procToken = _randomToken();
  int _turnSeq = 0;
  int _lastEventMs = 0;
  String _correlationId = '';

  String correlationIdFor(int nowMs) {
    if (_correlationId.isEmpty || nowMs - _lastEventMs > gapMs) {
      _turnSeq++;
      _correlationId = '$_procToken-$_turnSeq';
    }
    _lastEventMs = nowMs;
    return _correlationId;
  }

  /// Forgets the current turn; the next call starts turn 1 again.
  void reset() {
    _turnSeq = 0;
    _lastEventMs = 0;
    _correlationId = '';
  }

  static String _randomToken() {
    final r = Random.secure();
    return List.generate(4, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}

/// Aggregates tool-call rows, ordered by `correlation_id` then `id`, into per-tool stats, the outcome-tagged tool-to-next-tool transitions, and self-correction rates; tokens come from `estimated_tokens` or else `result_bytes`.
Map<String, Object?> summarizeUsage(List<Map<String, Object?>> rows, {int topTransitions = 15}) {
  final perTool = <String, _ToolAgg>{};
  final transitions = <String, int>{};
  final selfCorr = <String, List<int>>{};
  final turns = <String>{};
  String? prevCorr;
  String? prevTool;
  var prevOutcome = 'ok';
  String? prevErrorKind;

  for (final r in rows) {
    final corr = (r['correlation_id'] as String?) ?? '';
    final tool = (r['tool'] as String?) ?? '?';
    final outcome = (r['outcome'] as String?) ?? 'ok';
    final errorKind = r['error_kind'] as String?;
    final bytes = r['result_bytes'] as int?;
    turns.add(corr);
    perTool.putIfAbsent(tool, () => _ToolAgg(tool)).add(
          outcome,
          r['duration_ms'] as int?,
          bytes,
          (r['estimated_tokens'] as int?) ?? (bytes == null ? null : estimateTokens(bytes)),
          errorKind,
          (r['degraded'] as int? ?? 0) != 0,
        );
    if (prevCorr == corr && prevTool != null) {
      final key = '$prevTool|$prevOutcome|$tool';
      transitions[key] = (transitions[key] ?? 0) + 1;
      final signal = prevOutcome == 'error'
          ? (prevErrorKind ?? 'error')
          : (prevOutcome == 'empty' ? 'empty' : null);
      if (signal != null) {
        final agg = selfCorr.putIfAbsent('$prevTool|$signal', () => [0, 0]);
        agg[0]++;
        if (outcome == 'ok') agg[1]++;
      }
    }
    prevCorr = corr;
    prevTool = tool;
    prevOutcome = outcome;
    prevErrorKind = errorKind;
  }

  final toolsOut = perTool.values.map((a) => a.toJson()).toList()
    ..sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));
  final transOut = transitions.entries.map((e) {
    final parts = e.key.split('|');
    return {'from': parts[0], 'fromOutcome': parts[1], 'to': parts[2], 'count': e.value};
  }).toList()
    ..sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));
  final selfCorrOut = selfCorr.entries.map((e) {
    final parts = e.key.split('|');
    final occ = e.value[0];
    final rec = e.value[1];
    return {
      'tool': parts[0],
      'signal': parts[1],
      'occurrences': occ,
      'recovered': rec,
      'recoveryRate': occ == 0 ? 0.0 : _rate(rec, occ),
    };
  }).toList()
    ..sort((a, b) => (b['occurrences'] as int).compareTo(a['occurrences'] as int));

  final totalTokens = perTool.values.fold<int>(0, (s, a) => s + a.tokensSum);
  return {
    'totalEvents': rows.length,
    'totalTurns': turns.length,
    if (totalTokens > 0) 'totalEstimatedTokens': totalTokens,
    'tools': toolsOut,
    'transitions': transOut.take(topTransitions).toList(),
    if (selfCorrOut.isNotEmpty) 'selfCorrection': selfCorrOut,
  };
}

class _ToolAgg {
  _ToolAgg(this.tool);

  final String tool;
  int count = 0;
  int ok = 0;
  int error = 0;
  int empty = 0;
  final List<int> durations = [];
  int bytesSum = 0;
  int bytesCount = 0;
  int tokensSum = 0;
  int tokensCount = 0;
  int degraded = 0;
  final Map<String, int> errorKinds = {};

  void add(String outcome, int? durMs, int? bytes, int? tokens, String? errorKind, bool isDegraded) {
    count++;
    switch (outcome) {
      case 'error':
        error++;
      case 'empty':
        empty++;
      default:
        ok++;
    }
    if (durMs != null && durMs >= 0) durations.add(durMs);
    if (bytes != null && bytes >= 0) {
      bytesSum += bytes;
      bytesCount++;
    }
    if (tokens != null && tokens > 0) {
      tokensSum += tokens;
      tokensCount++;
    }
    if (isDegraded) degraded++;
    if (errorKind != null && errorKind.isNotEmpty) {
      errorKinds[errorKind] = (errorKinds[errorKind] ?? 0) + 1;
    }
  }

  Map<String, Object?> toJson() {
    final sorted = [...durations]..sort();
    return {
      'tool': tool,
      'count': count,
      'ok': ok,
      'error': error,
      'empty': empty,
      'errorRate': count == 0 ? 0.0 : _rate(error, count),
      'emptyRate': count == 0 ? 0.0 : _rate(empty, count),
      'p50Ms': _percentile(sorted, 0.50),
      'p95Ms': _percentile(sorted, 0.95),
      if (bytesCount > 0) 'avgResultBytes': (bytesSum / bytesCount).round(),
      if (tokensCount > 0) 'avgEstimatedTokens': (tokensSum / tokensCount).round(),
      if (tokensCount > 0) 'totalEstimatedTokens': tokensSum,
      if (degraded > 0) 'degraded': degraded,
      if (errorKinds.isNotEmpty)
        'errorKinds': Map.fromEntries(errorKinds.entries.toList()..sort((a, b) => b.value.compareTo(a.value))),
    };
  }
}

double _rate(int part, int whole) => double.parse((part / whole).toStringAsFixed(4));

int? _percentile(List<int> sorted, double p) {
  if (sorted.isEmpty) return null;
  if (sorted.length == 1) return sorted.first;
  final rank = (sorted.length * p).floor();
  return sorted[rank >= sorted.length ? sorted.length - 1 : rank];
}

/// The privacy-safe rollup the collector receives: [identity] (version, and optionally commit and isAot), host descriptors, the random install id, the event window, and the [summarizeUsage] aggregate; never argument values, ids, names, paths or per-event rows.
Map<String, Object?> buildUsagePayload({
  required List<Map<String, Object?>> rows,
  required String dataDir,
  required Map<String, Object?> identity,
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
    ...identity,
    'os': osDescriptor(),
    'dart': dartVersion(),
    'machineHash': installId(dataDir),
    'window': {'firstEventMs': firstMs, 'lastEventMs': lastMs, 'toEventId': toEventId},
    'totalEvents': stats['totalEvents'],
    'totalTurns': stats['totalTurns'],
    if (stats['totalEstimatedTokens'] != null) 'totalEstimatedTokens': stats['totalEstimatedTokens'],
    'tools': stats['tools'],
    'transitions': stats['transitions'],
    if (stats['selfCorrection'] != null) 'selfCorrection': stats['selfCorrection'],
    'reportedAt': DateTime.now().toUtc().toIso8601String(),
  };
}

/// Where a package keeps its recorded tool calls: glint's JSONL file, glint_network's SQLite table.
abstract interface class UsageEventSource {
  /// Rows with an id above [afterId], ordered by `correlation_id` then `id`, at most [limit].
  List<Map<String, Object?>> eventsAfter(int afterId, {required int limit});

  /// The highest id recorded; 0 when nothing has been.
  int get maxEventId;
}

/// Ships usage rollups for one package: the rollup goes to the audit log first, then to the collector, and a watermark in `usage-ship-state.json` keeps re-runs from double-counting.
class UsageShipper {
  UsageShipper({
    required this.source,
    required this.switches,
    required this.identity,
    required this.userAgent,
    required this.dataDir,
    required this.env,
    this.endpoint = kCollectorEndpoint,
    this.maxEventsPerShip = 50000,
  });

  final UsageEventSource source;
  final TelemetrySwitches switches;

  /// The package's identity fields, read at ship time (version, optionally commit and isAot).
  final Map<String, Object?> Function() identity;
  final String userAgent;

  /// Resolves the data dir holding the watermark and audit log; null when there is none.
  final String? Function() dataDir;

  /// The environment the switches read, re-read on each ship.
  final Map<String, String> Function() env;

  /// Empty means audit-log-only: the rollup is recorded but never posted.
  final String endpoint;
  final int maxEventsPerShip;

  static const String stateFileName = 'usage-ship-state.json';

  /// Auto-ship runs at most this often, so a flurry of restarts writes one rollup a day.
  static const Duration autoShipMinInterval = Duration(hours: 24);

  /// Startup hook: ships what earlier runs recorded, at most once a day; never throws.
  Future<void> maybeAutoShip() async {
    try {
      if (switches.sharingOffReason(env()) != null) return;
      final dir = dataDir();
      if (dir == null) return;
      final last = _readState(dir).lastShippedAtMs;
      if (last != null &&
          DateTime.now().millisecondsSinceEpoch - last < autoShipMinInterval.inMilliseconds) {
        return;
      }
      await ship(dataDir: dir);
    } on Object {
      return;
    }
  }

  /// Shutdown hook: ships what is unshipped within the collector timeout, so exit is never held up; never throws.
  Future<void> shipOnExit({String? dataDir}) async {
    try {
      if (switches.sharingOffReason(env()) != null) return;
      final dir = dataDir ?? this.dataDir();
      if (dir == null || unshippedCount(dataDir: dir) == 0) return;
      await ship(dataDir: dir).timeout(kTelemetryTimeout + const Duration(seconds: 1));
    } on Object {
      return;
    }
  }

  /// Events a ship would send now.
  int unshippedCount({String? dataDir}) {
    final dir = dataDir ?? this.dataDir();
    if (dir == null) return 0;
    return source.eventsAfter(_shipFromId(dir), limit: maxEventsPerShip).length;
  }

  /// A watermark past every known id means the store was reset, so shipping starts over instead of skipping everything.
  int _shipFromId(String dir) {
    final mark = _readState(dir).lastShippedEventId;
    return mark > source.maxEventId ? 0 : mark;
  }

  /// Builds and ships (or with [dryRun] only builds) the rollup of every event past the watermark; never throws.
  Future<UsageShipResult> ship({String? dataDir, bool dryRun = false}) async {
    final e = env();
    if (switches.usageDisabled(e)) {
      return UsageShipResult(
          shipped: false,
          message: 'usage recording is off (${switches.prefix}NO_TELEMETRY / ${switches.prefix}NO_USAGE)');
    }
    final offReason = switches.sharingOffReason(e);
    if (!dryRun && offReason != null) {
      return UsageShipResult(
          shipped: false, message: 'not sent: sharing is $offReason. A dry run shows what would be sent.');
    }
    final dir = dataDir ?? this.dataDir();
    if (dir == null) return const UsageShipResult(shipped: false, message: 'could not resolve a data dir');

    final state = _readState(dir);
    final List<Map<String, Object?>> rows;
    final int fromId;
    try {
      fromId = _shipFromId(dir);
      rows = source.eventsAfter(fromId, limit: maxEventsPerShip);
    } on Object catch (err) {
      return UsageShipResult(shipped: false, message: 'reading usage events failed ($err)');
    }
    if (rows.isEmpty) {
      return UsageShipResult(
        shipped: false,
        fromEventId: fromId,
        toEventId: fromId,
        message: 'no new events since the last ship (watermark id=$fromId)',
      );
    }

    final payload = buildUsagePayload(rows: rows, dataDir: dir, identity: identity());
    final toEventId = (payload['window'] as Map)['toEventId'] as int;
    final jsonStr = jsonEncode(payload);
    if (dryRun) {
      return UsageShipResult(
        shipped: false,
        dryRun: true,
        events: rows.length,
        fromEventId: fromId,
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
    if (endpoint.isNotEmpty) {
      try {
        final status = await postToCollector(jsonStr, userAgent: userAgent, endpoint: endpoint)
            .timeout(kTelemetryTimeout);
        posted = status >= 200 && status < 300;
      } on Object {
        posted = false;
      }
    }
    _writeState(dir, lastShippedEventId: toEventId, shipCount: state.shipCount + 1);

    final String msg;
    if (posted) {
      msg = 'shipped ${rows.length} event(s) to the collector + audit log';
    } else if (endpoint.isEmpty) {
      msg = 'recorded ${rows.length} event(s) to the audit log (collector not configured; audit-log-only mode)';
    } else if (!auditWritten) {
      msg = 'collector POST and audit write both failed; watermark advanced';
    } else {
      msg = 'audit log written; collector POST failed (will resume next ship)';
    }
    return UsageShipResult(
      shipped: true,
      events: rows.length,
      fromEventId: fromId,
      toEventId: toEventId,
      posted: posted,
      payloadJson: jsonStr,
      message: msg,
    );
  }

  static _ShipState _readState(String dataDir) {
    try {
      final f = io.File(p.join(dataDir, stateFileName));
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

  static void _writeState(String dataDir, {required int lastShippedEventId, required int shipCount}) {
    final f = io.File(p.join(dataDir, stateFileName));
    if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
    f.writeAsStringSync(
      jsonEncode({
        'lastShippedEventId': lastShippedEventId,
        'lastShippedAtMs': DateTime.now().millisecondsSinceEpoch,
        'shipCount': shipCount,
      }),
      flush: true,
    );
  }
}

/// The outcome of [UsageShipper.ship].
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

  /// True when a rollup was written and the watermark moved.
  final bool shipped;
  final String message;
  final int events;
  final int fromEventId;
  final int toEventId;

  /// True when the collector answered 2xx.
  final bool posted;
  final bool dryRun;

  /// The exact rollup JSON; null when there was nothing to build.
  final String? payloadJson;
}

class _ShipState {
  const _ShipState({this.lastShippedEventId = 0, this.lastShippedAtMs, this.shipCount = 0});

  final int lastShippedEventId;
  final int? lastShippedAtMs;
  final int shipCount;
}
