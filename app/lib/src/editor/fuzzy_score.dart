/// Scores how well [needle] matches [hay]; higher is better, 0 is no match.
///
/// Both arguments are compared as given: the caller lowercases them.
int fuzzyScore(String hay, String needle) {
  if (needle.isEmpty) return 1;
  if (hay.startsWith(needle)) return 1000 - hay.length;
  if (hay.contains(needle)) return 500 - hay.length;
  var i = 0;
  var consecutive = 0;
  var bonus = 0;
  for (final c in hay.split('')) {
    if (i < needle.length && c == needle[i]) {
      i++;
      consecutive++;
      bonus += consecutive * 2;
    } else {
      consecutive = 0;
    }
  }
  if (i < needle.length) return 0;
  return 100 + bonus - hay.length;
}

/// The indices in [hay] that [fuzzyScore] matched [needle] at, taking the
/// same branch: a prefix gives `0..n-1`, a substring the first occurrence's
/// indices, otherwise the greedy left-to-right subsequence. An empty needle
/// or no match gives `[]`. Both are compared as given: the caller lowercases.
List<int> fuzzyMatchPositions(String hay, String needle) {
  if (needle.isEmpty) return const [];
  if (hay.startsWith(needle)) {
    return [for (var k = 0; k < needle.length; k++) k];
  }
  final at = hay.indexOf(needle);
  if (at >= 0) return [for (var k = 0; k < needle.length; k++) at + k];
  final positions = <int>[];
  for (var h = 0; h < hay.length && positions.length < needle.length; h++) {
    if (hay[h] == needle[positions.length]) positions.add(h);
  }
  if (positions.length < needle.length) return const [];
  return positions;
}
