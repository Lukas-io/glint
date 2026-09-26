import 'package:glint_core/glint_core.dart' show editDistance;

/// Closest glintIds to a stale or mistyped one, so a failed lookup names the
/// likely replacement instead of sending the agent back to a full re-read.
/// Same base name (before `#hash`) wins, then small edit distance, then prefix.
List<String> suggestIds(Iterable<String> candidates, String wanted,
    {int max = 3}) {
  final want = wanted.trim();
  if (want.isEmpty) return const [];
  final wantBase = _base(want);
  final scored = <(int, String)>[];
  for (final c in candidates) {
    if (c == want) continue;
    final cBase = _base(c);
    int? score;
    if (cBase == wantBase) {
      score = 0;
    } else {
      final d = editDistance(cBase, wantBase);
      if (d <= 3) {
        score = 10 + d;
      } else if (cBase.startsWith(wantBase) || wantBase.startsWith(cBase)) {
        score = 20 + (cBase.length - wantBase.length).abs();
      }
    }
    if (score != null) scored.add((score, c));
  }
  scored.sort((a, b) {
    final s = a.$1.compareTo(b.$1);
    return s != 0 ? s : a.$2.compareTo(b.$2);
  });
  return [for (final e in scored.take(max)) e.$2];
}

String _base(String id) {
  final hash = id.indexOf('#');
  return hash < 0 ? id : id.substring(0, hash);
}


/// "did you mean" nextStep line, or null when there is nothing to suggest.
String? didYouMean(List<String> suggestions) => suggestions.isEmpty
    ? null
    : 'did you mean: ${suggestions.map((s) => '"$s"').join(', ')}';
