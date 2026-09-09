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
      final d = _levenshtein(cBase, wantBase);
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

int _levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var cur = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      cur[j] = [cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost]
          .reduce((x, y) => x < y ? x : y);
    }
    final t = prev;
    prev = cur;
    cur = t;
  }
  return prev[b.length];
}

/// "did you mean" nextStep line, or null when there is nothing to suggest.
String? didYouMean(List<String> suggestions) => suggestions.isEmpty
    ? null
    : 'did you mean: ${suggestions.map((s) => '"$s"').join(', ')}';
