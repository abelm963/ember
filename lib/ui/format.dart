/// Durations as people read them.
library;

String formatRuntime(Duration? d) {
  if (d == null) return '';
  final h = d.inHours, m = d.inMinutes % 60;
  return h > 0 ? '${h}h ${m}m' : '${m}m';
}

String formatClock(Duration d) {
  final neg = d.isNegative;
  d = d.abs();
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  final body = h > 0
      ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      : '$m:${s.toString().padLeft(2, '0')}';
  return neg ? '-$body' : body;
}
