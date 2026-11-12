/// The agent age of [unixMs] at [now] (#390 req 22): floor rounding; under
/// 60 s or negative is `now`, then `<n>m`, `<n>h`, `<n>d`.
String formatAgentAge(int unixMs, {required DateTime now}) {
  final ageMs = now.millisecondsSinceEpoch - unixMs;
  const minute = 60 * 1000;
  const hour = 60 * minute;
  const day = 24 * hour;
  if (ageMs < minute) return 'now';
  if (ageMs < hour) return '${ageMs ~/ minute}m';
  if (ageMs < day) return '${ageMs ~/ hour}h';
  return '${ageMs ~/ day}d';
}
