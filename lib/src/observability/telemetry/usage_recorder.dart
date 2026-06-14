/// Records tool-usage events for glint, mirroring flutter_network_mcp's
/// privacy-safe model: tool NAME, arg KEYS only (never values), outcome
/// category, duration, result size. Bounded in-memory ring; events
/// older than capacity drop off.
library;

import 'dart:collection';
import 'dart:io' as io;
import 'dart:math';

import 'env.dart';

/// `ok` / `error` / `empty`. Same vocabulary as flutter_network_mcp.
enum ToolOutcome { ok, error, empty }

class ToolEvent {
  ToolEvent({
    required this.id,
    required this.tsMs,
    required this.correlationId,
    required this.tool,
    required this.outcome,
    required this.argKeys,
    required this.durationMs,
    required this.resultBytes,
  });

  final int id;
  final int tsMs;
  final String correlationId;
  final String tool;
  final ToolOutcome outcome;
  final List<String> argKeys;
  final int durationMs;
  final int resultBytes;

  /// Row form consumed by [summarizeUsage].
  Map<String, Object?> toRow() => {
        'id': id,
        'ts_ms': tsMs,
        'correlation_id': correlationId,
        'tool': tool,
        'outcome': outcome.name,
        'arg_keys': argKeys.join(','),
        'duration_ms': durationMs,
        'result_bytes': resultBytes,
      };
}

/// Bounded ring of [ToolEvent]s with FNM-style correlation IDs. One
/// process-wide instance; tool handlers call [record] post-call.
class UsageRecorder {
  UsageRecorder.config({
    required this.enabled,
    this.gapMs = 60000,
    this.capacity = 50000,
  });

  /// Default constructor reads env: `GLINT_NO_TELEMETRY` /
  /// `GLINT_NO_USAGE` disable; `GLINT_USAGE_GAP_MS` overrides the gap.
  factory UsageRecorder.fromEnv() {
    final env = io.Platform.environment;
    final off = usageDisabled(env);
    final gapRaw = int.tryParse(env['GLINT_USAGE_GAP_MS'] ?? '');
    final gap = (gapRaw == null || gapRaw < 1000) ? 60000 : gapRaw;
    return UsageRecorder.config(enabled: !off, gapMs: gap);
  }

  final bool enabled;
  final int gapMs;
  final int capacity;

  final Queue<ToolEvent> _events = Queue();
  // Ids are 1-based: afterId=0 means "ship from the start". Matches the
  // SQLite autoincrement convention the collector schema assumes.
  int _nextId = 1;
  final String _procToken = _randomToken();
  int _turnSeq = 0;
  int _lastEventMs = 0;
  String _correlationId = '';

  int get length => _events.length;
  int get nextId => _nextId;

  /// Rolls over after the idle gap. Public so it's unit-testable.
  String correlationIdFor(int nowMs) {
    if (_correlationId.isEmpty || nowMs - _lastEventMs > gapMs) {
      _turnSeq++;
      _correlationId = '$_procToken-$_turnSeq';
    }
    _lastEventMs = nowMs;
    return _correlationId;
  }

  void record({
    required String tool,
    required ToolOutcome outcome,
    required List<String> argKeys,
    required int durationMs,
    required int resultBytes,
  }) {
    if (!enabled) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _events.add(ToolEvent(
      id: _nextId++,
      tsMs: nowMs,
      correlationId: correlationIdFor(nowMs),
      tool: tool,
      outcome: outcome,
      argKeys: argKeys,
      durationMs: durationMs,
      resultBytes: resultBytes,
    ));
    while (_events.length > capacity) {
      _events.removeFirst();
    }
  }

  /// Rows newer than [afterId], in insertion order.
  List<Map<String, Object?>> eventsAfterId(int afterId, {int limit = 50000}) {
    final out = <Map<String, Object?>>[];
    for (final e in _events) {
      if (e.id <= afterId) continue;
      out.add(e.toRow());
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Sorted arg keys — never values.
  static List<String> argKeysFrom(Map<String, Object?>? args) {
    if (args == null || args.isEmpty) return const [];
    return args.keys.toList()..sort();
  }

  static ToolOutcome outcomeFrom({
    required bool isError,
    Map<String, Object?>? structured,
  }) {
    if (isError) return ToolOutcome.error;
    if (structured != null && structured['count'] == 0) {
      return ToolOutcome.empty;
    }
    return ToolOutcome.ok;
  }

  void clearForTest() {
    _events.clear();
    _nextId = 1;
    _correlationId = '';
    _turnSeq = 0;
    _lastEventMs = 0;
  }

  static String _randomToken() {
    final r = Random.secure();
    return List.generate(
      4,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
