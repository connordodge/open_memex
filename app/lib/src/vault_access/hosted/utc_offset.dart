/// The `X-Memex-UTC-Offset` value for [offset] (D5, D10a, req 59):
/// `±HH:MM`, zero as `+00:00`, e.g. `-00:30`, `+05:45`, `-12:00`, `+14:00`.
String formatUtcOffset(Duration offset) {
  // Sign and magnitude separately: `Duration(minutes: -30).inHours` is 0,
  // which would lose the sign of `-00:30`.
  final minutes = offset.inMinutes;
  final sign = minutes < 0 ? '-' : '+';
  final magnitude = minutes.abs();
  String two(int n) => n.toString().padLeft(2, '0');
  return '$sign${two(magnitude ~/ 60)}:${two(magnitude % 60)}';
}
