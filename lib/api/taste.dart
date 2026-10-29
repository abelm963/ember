import 'dart:math';

import 'jellyfin.dart';
import 'seerr.dart';

// Recommended's ranking, as agreed in "Ember Recommended: how titles are ranked":
//   1. every title watched in the last 2 years gets a taste score (how much was watched, likes,
//      rewatches, faded by age);
//   2. titles linked to those (next part, related series, "viewers also liked", same people,
//      similar) become candidates, each link with a strength;
//   3. a candidate scores the sum of taste × link over every title it is linked to, then quality,
//      on-server and new-release adjustments;
//   4. rows are built from that, with variety in Top picks and each title once on the page.
// Nothing here talks to a server; `recommend.dart` gathers the facts. The numbers live here, in one
// place, so they can be tuned.

/// One season of a show, as far as this person watched it.
class SeasonWatch {
  final int episodesWatched;
  final bool finished;
  final DateTime? first;
  final DateTime? last;
  const SeasonWatch({required this.episodesWatched, this.finished = false, this.first, this.last});

  /// Finished within 14 days of starting.
  bool get binged => finished && first != null && last != null && last!.difference(first!).inDays <= 14;
}

/// A title this person watched (or put on their watchlist), and how.
class Watched {
  final String key;
  final String title;
  final String mediaType;
  final int? tmdbId;
  final String? jfId;
  final DateTime? lastPlayed;
  final bool favourite;

  /// On the Seerr watchlist, not watched.
  final bool watchlistOnly;
  final int playCount;

  /// Movies: how far towards the credits (1 = finished).
  final double fraction;

  /// Shows: the seasons watched.
  final List<SeasonWatch> seasons;

  /// Shows: nothing left unwatched on the server.
  final bool caughtUp;

  const Watched({
    required this.key,
    required this.title,
    required this.mediaType,
    this.tmdbId,
    this.jfId,
    this.lastPlayed,
    this.favourite = false,
    this.watchlistOnly = false,
    this.playCount = 0,
    this.fraction = 0,
    this.seasons = const [],
    this.caughtUp = false,
  });

  bool get isShow => mediaType == 'tv';
}

/// Points before fading (Step 1's tables). Negative = given up on.
double tastePoints(Watched w, DateTime now) {
  if (w.watchlistOnly) return 0.3;
  final idle = w.lastPlayed == null ? 0 : now.difference(w.lastPlayed!).inDays;
  double p;
  if (w.isShow) {
    final finished = w.seasons.where((s) => s.finished).length;
    final most = w.seasons.fold<int>(0, (m, s) => max(m, s.episodesWatched));
    if (finished > 0) {
      p = 1.0 + 0.4 * (finished - 1) + (w.caughtUp ? 0.3 : 0);
      if (w.seasons.any((s) => s.binged)) p *= 1.2;
    } else if (most >= 3) {
      p = 0.5;
    } else if (most > 0) {
      p = idle > 30 ? -0.2 : 0.2;
    } else {
      p = 0;
    }
  } else {
    final f = w.fraction;
    if (f >= 1) {
      p = 1.0 * (w.playCount >= 3 ? 2 : (w.playCount == 2 ? 1.5 : 1));
    } else if (f >= 0.5) {
      p = 0.5;
    } else if (f >= 0.15) {
      p = idle > 30 ? -0.3 : 0.15;
    } else {
      p = 0;
    }
  }
  if (w.favourite) p = max(p, 0) + 0.7;
  return p;
}

/// Halves every 9 months, never below 15%.
double recency(DateTime? last, DateTime now) {
  if (last == null) return 1;
  final months = now.difference(last).inDays / 30.44;
  return max(0.15, pow(0.5, months / 9).toDouble());
}

double taste(Watched w, DateTime now) => tastePoints(w, now) * recency(w.lastPlayed, now);

/// How a candidate is tied to a watched title (Step 2).
enum LinkKind { next, newSeason, related, recommended, people, similar, genre }

/// The link strengths, strongest first.
double linkStrength(LinkKind k, {int rank = 0}) => switch (k) {
      LinkKind.next || LinkKind.newSeason => 1.0,
      LinkKind.related => 0.6,
      // TMDB's first pick counts 0.5, its tenth about 0.25.
      LinkKind.recommended => 0.5 / (1 + rank / 9),
      LinkKind.people => 0.4,
      LinkKind.similar => 0.3,
      LinkKind.genre => 0.1,
    };

/// Something Recommended may show: on the server ([item]), or on Seerr only ([media]).
class Candidate {
  final String key;
  final String title;
  final String mediaType;
  final JfItem? item;
  final SeerrMedia? media;
  final double? rating;
  final int? votes;
  final DateTime? released;
  final String? genre;

  /// The series of films it belongs to, when known.
  String? franchise;

  /// Per watched title (its key), the strongest link to it.
  final Map<String, (double, LinkKind)> links = {};

  Candidate({
    required this.key,
    required this.title,
    required this.mediaType,
    this.item,
    this.media,
    this.rating,
    this.votes,
    this.released,
    this.genre,
    this.franchise,
  });

  bool get onServer => item != null;

  void link(String seed, LinkKind kind, {int rank = 0}) {
    final s = linkStrength(kind, rank: rank);
    final had = links[seed];
    if (had == null || s > had.$1) links[seed] = (s, kind);
  }

  /// Takes [other]'s links (the same title found two ways).
  void absorb(Candidate other) {
    for (final e in other.links.entries) {
      final had = links[e.key];
      if (had == null || e.value.$1 > had.$1) links[e.key] = e.value;
    }
  }
}

/// TMDB rating 5 → 0.8, 7 → 1.0, 8.5 → 1.15; no say with under 200 votes.
double quality(double? rating, int? votes) {
  if (rating == null || rating <= 0 || (votes != null && votes < 200)) return 1;
  if (rating <= 5) return 0.8;
  if (rating <= 7) return 0.8 + 0.1 * (rating - 5);
  return min(1.15, 1 + 0.1 * (rating - 7));
}

class Scored {
  final Candidate c;
  final double score;

  /// The watched title that contributes most, and how.
  final String mainSeed;
  final LinkKind mainKind;
  const Scored(this.c, this.score, this.mainSeed, this.mainKind);
}

/// Step 3. Candidates whose links add up to nothing (or less) are left out.
/// [day] varies near-ties from day to day; null leaves the score as it is (tests).
Scored? score(Candidate c, Map<String, double> tasteOf, DateTime now, {int? day}) {
  var sum = 0.0, best = 0.0;
  String? main;
  var kind = LinkKind.similar;
  for (final e in c.links.entries) {
    final t = tasteOf[e.key];
    if (t == null) continue;
    final part = t * e.value.$1;
    sum += part;
    if (part > best) {
      best = part;
      main = e.key;
      kind = e.value.$2;
    }
  }
  if (main == null || sum <= 0) return null;
  var s = sum * quality(c.rating, c.votes);
  if (!c.onServer) s *= 0.85;
  if (c.released != null && now.difference(c.released!).inDays.abs() <= 183) s *= 1.1;
  // Near-ties swap places from day to day (±3%), so the page changes a little each day.
  if (day != null) s *= 1 + 0.03 * (2 * _unit('${c.key}|$day') - 1);
  return Scored(c, s, main, kind);
}

double _unit(String s) {
  var h = 0x811c9dc5;
  for (final u in s.codeUnits) {
    h = ((h ^ u) * 0x01000193) & 0xffffffff;
  }
  return (h % 10000) / 10000;
}

/// Top picks: one at a time; each pick costs titles like it (same franchise, same title behind
/// it, same main genre) 30% for the rest of the row, and at least [minOnServer] are on the server.
List<Scored> pickVaried(List<Scored> ranked, {int count = 20, int minOnServer = 12}) {
  final pool = [...ranked];
  final factor = {for (final s in pool) s.c.key: 1.0};
  final out = <Scored>[];
  bool alike(Scored a, Scored b) =>
      a.mainSeed == b.mainSeed ||
      (a.c.franchise != null && a.c.franchise == b.c.franchise) ||
      (a.c.genre != null && a.c.genre == b.c.genre);
  while (out.length < count && pool.isNotEmpty) {
    final need = minOnServer - out.where((s) => s.c.onServer).length;
    final mustServe = need >= count - out.length;
    Scored? best;
    for (final s in pool) {
      if (mustServe && !s.c.onServer) continue;
      if (best == null || s.score * factor[s.c.key]! > best.score * factor[best.c.key]!) best = s;
    }
    if (best == null) break;
    pool.remove(best);
    out.add(best);
    for (final s in pool) {
      if (alike(s, best)) factor[s.c.key] = factor[s.c.key]! * 0.7;
    }
  }
  return out;
}

class RecRow {
  final String title;
  final List<Scored> picks;
  const RecRow(this.title, this.picks);
}

/// Step 4: Top picks, Next in the series, Because you watched (×3), Because you liked, More like,
/// then Popular on the server. Each title appears once.
List<RecRow> buildRows({
  required List<Scored> ranked,
  required List<Watched> seeds,
  required Map<String, double> tasteOf,
  List<Candidate> popular = const [],
  String server = 'your server',
}) {
  final used = <String>{};
  final rows = <RecRow>[];
  final sorted = [...ranked]..sort((a, b) => b.score.compareTo(a.score));
  bool isNext(Scored s) => s.mainKind == LinkKind.next || s.mainKind == LinkKind.newSeason;

  final top = pickVaried(sorted.where((s) => !isNext(s)).toList());
  if (top.length >= 4) {
    rows.add(RecRow('Top picks for you', top));
    used.addAll(top.map((s) => s.c.key));
  }
  final next = sorted.where((s) => isNext(s) && used.add(s.c.key)).take(20).toList();
  if (next.isNotEmpty) rows.add(RecRow('Next in the series', next));

  final bySeed = [...seeds]..sort((a, b) => (tasteOf[b.key] ?? 0).compareTo(tasteOf[a.key] ?? 0));
  final given = <String>{};
  void rowFor(Watched w, String words, {int min = 6}) {
    final picks = sorted.where((s) => s.mainSeed == w.key && !used.contains(s.c.key)).take(20).toList();
    if (picks.length < min) return;
    used.addAll(picks.map((s) => s.c.key));
    given.add(w.key);
    rows.add(RecRow('$words ${w.title}', picks));
  }

  var watchedRows = 0;
  for (final w in bySeed) {
    if (watchedRows >= 3) break;
    if (w.watchlistOnly || (tasteOf[w.key] ?? 0) <= 0) continue;
    final before = rows.length;
    rowFor(w, 'Because you watched');
    if (rows.length > before) watchedRows++;
  }
  for (final w in bySeed) {
    if (w.favourite && !given.contains(w.key)) {
      final before = rows.length;
      rowFor(w, 'Because you liked');
      if (rows.length > before) break;
    }
  }
  for (final w in bySeed) {
    if (w.watchlistOnly) {
      final before = rows.length;
      rowFor(w, 'More like', min: 4);
      if (rows.length > before) break;
    }
  }
  final pop = [
    for (final c in popular)
      if (used.add(c.key)) Scored(c, 0, '', LinkKind.genre),
  ].take(20).toList();
  if (pop.length >= 4) rows.add(RecRow('Popular on $server', pop));
  return rows;
}

/// The words under a pick: why it is there.
String reasonFor(Scored s, Map<String, Watched> seeds) {
  final w = seeds[s.mainSeed];
  if (w == null) return '';
  return switch (s.mainKind) {
    LinkKind.next => 'Next after ${w.title}',
    LinkKind.newSeason => 'New season',
    _ when w.watchlistOnly => 'Like ${w.title}, on your watchlist',
    _ when w.favourite && !w.isShow && w.fraction < 1 => 'Because you liked ${w.title}',
    _ => 'Because you watched ${w.title}',
  };
}
