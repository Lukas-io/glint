/// Aggregates raw tool-call rows into per-tool stats + the consecutive
/// tool→next-tool transition graph. Ported from flutter_network_mcp so
/// both products emit the same shape for the collector.
///
/// Row contract: `correlation_id`, `tool`, `outcome`, `duration_ms`
/// (int?), `result_bytes` (int?). Rows should already be ordered by
/// `(correlation_id, id)`.
library;

Map<String, Object?> summarizeUsage(
  List<Map<String, Object?>> rows, {
  int topTransitions = 100,
}) {
  final perTool = <String, _ToolAgg>{};
  final transitions = <String, int>{};
  final turns = <String>{};
  String? prevCorr;
  String? prevTool;

  for (final r in rows) {
    final corr = (r['correlation_id'] as String?) ?? '';
    final tool = (r['tool'] as String?) ?? '?';
    final outcome = (r['outcome'] as String?) ?? 'ok';
    turns.add(corr);
    perTool
        .putIfAbsent(tool, () => _ToolAgg(tool))
        .add(outcome, r['duration_ms'] as int?, r['result_bytes'] as int?);
    if (prevCorr == corr && prevTool != null) {
      final key = '$prevTool $tool';
      transitions[key] = (transitions[key] ?? 0) + 1;
    }
    prevCorr = corr;
    prevTool = tool;
  }

  final toolsOut = perTool.values.map((a) => a.toJson()).toList()
    ..sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));

  final transOut = transitions.entries.map((e) {
    final parts = e.key.split(' ');
    return {'from': parts[0], 'to': parts[1], 'count': e.value};
  }).toList()
    ..sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));

  return {
    'totalEvents': rows.length,
    'totalTurns': turns.length,
    'tools': toolsOut,
    'transitions': transOut.take(topTransitions).toList(),
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

  void add(String outcome, int? durMs, int? bytes) {
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
  }

  Map<String, Object?> toJson() {
    final sorted = [...durations]..sort();
    return {
      'tool': tool,
      'count': count,
      'ok': ok,
      'error': error,
      'empty': empty,
      'errorRate':
          count == 0 ? 0.0 : double.parse((error / count).toStringAsFixed(4)),
      'emptyRate':
          count == 0 ? 0.0 : double.parse((empty / count).toStringAsFixed(4)),
      'p50Ms': _percentile(sorted, 0.50),
      'p95Ms': _percentile(sorted, 0.95),
      if (bytesCount > 0) 'avgResultBytes': (bytesSum / bytesCount).round(),
    };
  }
}

int? _percentile(List<int> sorted, double p) {
  if (sorted.isEmpty) return null;
  if (sorted.length == 1) return sorted.first;
  final rank = (sorted.length * p).floor();
  return sorted[rank >= sorted.length ? sorted.length - 1 : rank];
}
