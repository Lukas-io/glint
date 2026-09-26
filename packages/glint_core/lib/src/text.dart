/// Levenshtein distance between [a] and [b]: the fewest single-character edits turning one into the other.
int editDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var cur = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      final insert = cur[j - 1] + 1;
      final delete = prev[j] + 1;
      final replace = prev[j - 1] + cost;
      cur[j] = insert < delete ? (insert < replace ? insert : replace) : (delete < replace ? delete : replace);
    }
    final t = prev;
    prev = cur;
    cur = t;
  }
  return prev[b.length];
}
