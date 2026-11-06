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
