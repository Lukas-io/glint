import 'dart:async';

import 'package:dart_mcp/server.dart';

import 'package:glint_core/glint_core.dart' show summarizeUsage;

import '../storage/captures_db.dart';
import 'result.dart';

final usageStatsTool = Tool(
  name: 'usage_stats',
  description:
      'How agents use this MCP: per tool, call count, outcome (ok/error/'
      'empty), error/empty rates, error breakdown by kind (errorKinds), '
      'degraded/fallback count, p50/p95 latency, avg result size, estimated '
      'token cost (avgEstimatedTokens / totalEstimatedTokens), the '
      'tool->next-tool transition graph tagged with the prior call outcome '
      '(fromOutcome), and selfCorrection (after an error/empty, did the next '
      'call recover). Read-only, process-wide. Opt out with '
      'GLINT_NETWORK_NO_USAGE.',
  inputSchema: Schema.object(
    properties: {
      'sinceMs': Schema.int(
        description: 'Window in ms (e.g. 3600000 = 1h). Omit or 0 for all history.',
      ),
      'topTransitions': Schema.int(
        description: 'How many transitions to return, busiest first. Default 15, cap 100.',
      ),
    },
  ),
);

const int _kRawCap = 50000;

FutureOr<CallToolResult> usageStats(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final sinceRaw = args['sinceMs'] as int?;
  final topRaw = (args['topTransitions'] as int?) ?? 15;
  final topTransitions = topRaw <= 0 ? 15 : (topRaw > 100 ? 100 : topRaw);

  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final cutoff = (sinceRaw == null || sinceRaw <= 0) ? null : nowMs - sinceRaw;

  final List<Map<String, Object?>> rows;
  try {
    rows = CapturesDao().allToolEvents(sinceMs: cutoff, limit: _kRawCap);
  } catch (e) {
    return errorResult('usage_stats query failed: $e', extra: const {
      'nextSteps': [
        'glint_network usage — inspect the raw capture from the CLI',
      ],
    });
  }

  final stats = summarizeUsage(rows, topTransitions: topTransitions);
  final tools = stats['tools'] as List;
  final windowDesc = cutoff == null ? 'all history' : _formatWindow(sinceRaw!);

  final summary = rows.isEmpty
      ? 'No tool usage captured over $windowDesc. (Capture is on by default; '
          'opt out with GLINT_NETWORK_NO_USAGE=true.)'
      : '${stats['totalEvents']} call(s) across ${stats['totalTurns']} turn(s) '
          'over $windowDesc, ${tools.length} distinct tool(s).';

  final nextSteps = <String>[];
  if (tools.isNotEmpty) {
    final worst = _highestErrorRate(tools.cast<Map<String, Object?>>());
    if (worst != null && (worst['errorRate'] as num) > 0) {
      nextSteps.add(
        '${worst['tool']} has the highest error rate '
        '(${((worst['errorRate'] as num) * 100).round()}% of '
        '${worst['count']} call(s)) — worth a look',
      );
    }
    nextSteps.add('usage_stats sinceMs:3600000 — narrow to the last hour');
    nextSteps.add('glint_network usage --show — raw events from the CLI');
  }

  return jsonResult({
    'summary': summary,
    'window': windowDesc,
    ...stats,
    'nextSteps': nextSteps,
  });
}

Map<String, Object?>? _highestErrorRate(List<Map<String, Object?>> tools) {
  Map<String, Object?>? worst;
  for (final t in tools) {
    if (worst == null ||
        (t['errorRate'] as num) > (worst['errorRate'] as num)) {
      worst = t;
    }
  }
  return worst;
}

String _formatWindow(int ms) {
  if (ms < 60000) return '${ms}ms';
  if (ms < 3600000) return '${(ms / 60000).round()}m';
  if (ms < 86400000) return '${(ms / 3600000).round()}h';
  return '${(ms / 86400000).round()}d';
}
