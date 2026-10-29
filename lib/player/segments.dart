import '../api/jellyfin.dart';

// The intro, recap and credits times that drive Skip Intro / Skip Recap and Next Episode.
// They come from a server plugin (Intro Skipper or similar) that guesses them, and a bad guess
// makes the player feel broken: credits marked halfway through start the Next Episode countdown
// mid-scene, a 9-minute "intro" skips the cold open. So every time is checked before it is used,
// and when the server has none, the file's chapter names ("Opening", "Recap", "End Credits") fill in.

/// A chapter of the file: its name and where it starts.
typedef Chapter = ({String name, Duration start});

/// The chapters of a full item (`/Items/{id}`), in order.
List<Chapter> chaptersOf(JfItem item) {
  final list = item.raw['Chapters'];
  if (list is! List) return const [];
  return [
    for (final c in list)
      if (c is Map && c['StartPositionTicks'] is num)
        (name: (c['Name'] as String? ?? '').trim(), start: ticksToDuration((c['StartPositionTicks'] as num).toInt())),
  ]..sort((a, b) => a.start.compareTo(b.start));
}

const _maxIntro = Duration(minutes: 4);
const _maxRecap = Duration(minutes: 6);

/// The segments worth showing a button for, given the title's [runtime] (zero when not known yet).
/// At most one of each kind, in order.
List<MediaSegment> tidySegments(List<MediaSegment> raw, Duration runtime, {List<Chapter> chapters = const []}) {
  final known = runtime > Duration.zero;
  bool early(Duration at) => !known || at < runtime * 0.4;
  bool late(Duration at) => !known || at >= runtime * 0.6;

  MediaSegment? clean(MediaSegment s) {
    var end = s.end;
    if (known && end > runtime) end = runtime;
    if (end - s.start < const Duration(seconds: 3)) return null;
    return MediaSegment(s.type, s.start, end);
  }

  bool fits(MediaSegment s) => switch (s.type) {
        'Intro' => early(s.start) && s.end - s.start <= _maxIntro,
        'Recap' => early(s.start) && s.end - s.start <= _maxRecap,
        // Credits only near the end; a "credits" mark mid-episode would end the episode early.
        'Outro' || 'Preview' => late(s.start),
        _ => false,
      };

  final out = <String, MediaSegment>{};
  final sorted = [...raw]..sort((a, b) => a.start.compareTo(b.start));
  for (final s in sorted) {
    final c = clean(s);
    if (c != null && fits(c)) out.putIfAbsent(c.type, () => c);
  }

  // Nothing from the server for a kind: the file's chapter names, when they say what they are.
  for (var i = 0; i < chapters.length; i++) {
    final type = _chapterType(chapters[i].name);
    if (type == null || out.containsKey(type)) continue;
    final end = i + 1 < chapters.length ? chapters[i + 1].start : runtime;
    if (end <= chapters[i].start) continue;
    final c = clean(MediaSegment(type, chapters[i].start, end));
    if (c != null && fits(c)) out[type] = c;
  }
  return out.values.toList()..sort((a, b) => a.start.compareTo(b.start));
}

String? _chapterType(String name) {
  final n = name.toLowerCase();
  if (RegExp(r'^(intro|opening|opening credits|opening titles|title sequence|theme|op)$').hasMatch(n)) return 'Intro';
  if (RegExp(r'^(recap|previously|previously on.*)$').hasMatch(n)) return 'Recap';
  if (RegExp(r'^(credits|end credits|ending|ending credits|closing credits|outro|ed)$').hasMatch(n)) return 'Outro';
  if (RegExp(r'^(preview|next episode|next time|next on.*)$').hasMatch(n)) return 'Preview';
  return null;
}
