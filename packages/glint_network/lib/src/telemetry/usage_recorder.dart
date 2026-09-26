import 'dart:io' as io;

import 'package:dart_mcp/server.dart';
import 'package:glint_core/glint_core.dart';

import '../storage/captures_db.dart';
import '../storage/database.dart';
import '../util/network_env.dart';
import 'telemetry_env.dart';

/// Records tool-usage events (issue #79, Phase 1). Privacy-safe by
/// construction: only the tool NAME, the arg KEYS the agent passed (never
/// their values), an outcome category, a duration, and a result size are
/// stored. No URLs, hosts, bodies, or log text ever reach it.
///
/// Local-only: events go to the captures DB `tool_events` table. Nothing is
/// shipped anywhere in Phase 1 (aggregate shipping is Phase 3, gated on the
/// collector).
///
/// Default-on. Opt out with `GLINT_NETWORK_NO_TELEMETRY=true` (the same
/// flag that disables crash telemetry) or the granular
/// `GLINT_NETWORK_NO_USAGE=true`.
///
/// Correlation: a per-call id groups a burst of tool calls into one "turn".
/// It rolls over after `GLINT_NETWORK_USAGE_GAP_MS` (default 60s) of
/// inactivity — MCP carries no conversation id, so this gap heuristic is the
/// proxy. The id is `<process-token>-<turnSeq>`, so it carries no PII.
class UsageRecorder {
  /// Visible-for-testing constructor with explicit config.
  UsageRecorder.config({required this.enabled, int gapMs = 60000})
      : _gapMs = gapMs;

  static UsageRecorder? _instance;
  static UsageRecorder get instance => _instance ??= _fromEnv();

  /// Test seams.
  static void overrideForTest(UsageRecorder r) => _instance = r;
  static void resetForTest() => _instance = null;

  static UsageRecorder _fromEnv() {
    final env = networkEnv;
    final off = networkSwitches.usageDisabled(env);
    final gapRaw = int.tryParse(env['GLINT_NETWORK_USAGE_GAP_MS'] ?? '');
    final gap = (gapRaw == null || gapRaw < 1000) ? 60000 : gapRaw;
    return UsageRecorder.config(enabled: !off, gapMs: gap);
  }

  final bool enabled;
  final int _gapMs;

  late final TurnTracker _turns = TurnTracker(gapMs: _gapMs);

  /// Correlation id for an event at [nowMs]. Rolls over after the idle gap.
  /// Stateful + exposed so the rollover logic is unit-testable.
  String correlationIdFor(int nowMs) => _turns.correlationIdFor(nowMs);

  /// Records one tool call. NEVER throws: a recording failure must not break
  /// the tool call it is measuring. [result] is null when the handler threw.
  void record({
    required String tool,
    required CallToolRequest request,
    required int durationMs,
    required CallToolResult? result,
  }) {
    if (!enabled) return;
    try {
      if (!CapturesDatabase.isOpen) return;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final sc = result?.structuredContent;
      CapturesDao().insertToolEvent(
        tsMs: nowMs,
        correlationId: correlationIdFor(nowMs),
        tool: tool,
        outcome: outcomeFrom(
          threw: result == null,
          isError: result?.isError == true,
          structured: sc,
        ),
        argKeys: argKeysFrom(request.arguments),
        durationMs: durationMs,
        resultBytes: resultBytesOf(result),
        estimatedTokens: _estimateTokens(result),
        errorKind: sc?['errorKind'] as String?,
        degraded: sc?['degraded'] == true,
      );
    } catch (e) {
      io.stderr.writeln('UsageRecorder: record failed (ignored): $e');
    }
  }

  /// Sorted parameter NAMES the agent passed. Keys only, never values.
  static List<String> argKeysFrom(Map<String, Object?>? args) => usageArgKeys(args);

  /// `ok | error | empty`. `error` = the handler threw or returned isError.
  /// `empty` is a best-effort heuristic (a top-level `count: 0` in the
  /// structured result) refined in Phase 2.
  static String outcomeFrom({
    required bool threw,
    required bool isError,
    Map<String, Object?>? structured,
  }) =>
      usageOutcome(isError: threw || isError, structured: structured);

  static int resultBytesOf(CallToolResult? result) {
    if (result == null) return 0;
    var n = 0;
    for (final c in result.content) {
      if (c is TextContent) n += c.text.length;
    }
    return n;
  }

  /// Rough token estimate for the result text (4 chars per token, UTF-8 proxy).
  /// Null when the result is empty or null so the DB column stays NULL rather
  /// than storing a meaningless 0.
  static int? _estimateTokens(CallToolResult? result) {
    final tokens = estimateTokens(resultBytesOf(result));
    return tokens > 0 ? tokens : null;
  }


}
