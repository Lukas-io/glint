/// Aggregates raw tool-call rows into per-tool stats, the outcome-tagged
/// tool→next-tool transition graph, and self-correction rates (after an
/// error, did the next call in the same turn succeed?). Row contract:
/// `correlation_id`, `tool`, `outcome`, `error_kind` (String?),
/// `duration_ms` (int?), `result_bytes` (int?), pre-ordered by
/// `(correlation_id, id)`. Same shape flutter_network_mcp ships, so the
/// shared collector's tables fill for both products.
library;

/// Rough chars-per-token used to estimate agent-side context cost from the
/// bytes we already record (~4 is the standard heuristic for JSON-ish text).
const double kCharsPerToken = 4.0;

int estimateTokens(int bytes) =>
    bytes <= 0 ? 0 : (bytes / kCharsPerToken).round();

Map<String, Object?> summarizeUsage(
  List<Map<String, Object?>> rows, {
  int topTransitions = 100,
}) {
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
    turns.add(corr);
    perTool.putIfAbsent(tool, () => _ToolAgg(tool)).add(
          outcome,
          r['duration_ms'] as int?,
          r['result_bytes'] as int?,
          errorKind,
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
    return {
      'from': parts[0],
      'fromOutcome': parts[1],
      'to': parts[2],
      'count': e.value,
    };
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
      'recoveryRate':
          occ == 0 ? 0.0 : double.parse((rec / occ).toStringAsFixed(4)),
    };
  }).toList()
    ..sort((a, b) =>
        (b['occurrences'] as int).compareTo(a['occurrences'] as int));

  final totalTokens =
      perTool.values.fold<int>(0, (s, a) => s + a.tokensSum);
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
  final Map<String, int> errorKinds = {};

  void add(String outcome, int? durMs, int? bytes, String? errorKind) {
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
      tokensSum += estimateTokens(bytes);
    }
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
      'errorRate':
          count == 0 ? 0.0 : double.parse((error / count).toStringAsFixed(4)),
      'emptyRate':
          count == 0 ? 0.0 : double.parse((empty / count).toStringAsFixed(4)),
      'p50Ms': _percentile(sorted, 0.50),
      'p95Ms': _percentile(sorted, 0.95),
      if (bytesCount > 0) 'avgResultBytes': (bytesSum / bytesCount).round(),
      if (tokensSum > 0) 'totalEstimatedTokens': tokensSum,
      if (errorKinds.isNotEmpty) 'errorKinds': errorKinds,
    };
  }
}

int? _percentile(List<int> sorted, double p) {
  if (sorted.isEmpty) return null;
  if (sorted.length == 1) return sorted.first;
  final rank = (sorted.length * p).floor();
  return sorted[rank >= sorted.length ? sorted.length - 1 : rank];
}
