import 'package:ember/api/taste.dart';
import 'package:flutter_test/flutter_test.dart';

// The worked example from "Ember Recommended: how titles are ranked".
void main() {
  final now = DateTime(2026, 10, 29);
  DateTime ago(int days) => now.subtract(Duration(days: days));

  final northbound = Watched(
    key: 'tv:1',
    title: 'Northbound',
    mediaType: 'tv',
    lastPlayed: ago(30),
    caughtUp: true,
    seasons: [
      SeasonWatch(episodesWatched: 8, finished: true, first: ago(400), last: ago(300)),
      SeasonWatch(episodesWatched: 8, finished: true, first: ago(200), last: ago(120)),
      SeasonWatch(episodesWatched: 8, finished: true, first: ago(40), last: ago(30)),
    ],
  );
  final ironMeridian = Watched(key: 'movie:2', title: 'Iron Meridian', mediaType: 'movie', lastPlayed: ago(426), fraction: 1, playCount: 2);
  final copperSky = Watched(key: 'movie:3', title: 'Copper Sky', mediaType: 'movie', lastPlayed: ago(91), fraction: 0.3);
  final seeds = [northbound, ironMeridian, copperSky];
  final tasteOf = {for (final w in seeds) w.key: taste(w, now)};

  test('taste: seasons, rewatches and giving up', () {
    expect(tastePoints(northbound, now), closeTo(2.52, 0.001));
    expect(tasteOf['tv:1'], closeTo(2.33, 0.01));
    expect(tasteOf['movie:2'], closeTo(0.51, 0.01));
    expect(tasteOf['movie:3'], closeTo(-0.24, 0.01));
  });

  test('taste: fading stops at 15%, likes add, a quick try counts once it goes idle', () {
    expect(recency(ago(3000), now), 0.15);
    expect(recency(null, now), 1);
    final liked = Watched(key: 'movie:9', title: 'X', mediaType: 'movie', favourite: true);
    expect(tastePoints(liked, now), closeTo(0.7, 0.001));
    final tried = Watched(key: 'tv:9', title: 'Y', mediaType: 'tv', lastPlayed: ago(5), seasons: [SeasonWatch(episodesWatched: 1)]);
    expect(tastePoints(tried, now), 0.2);
    final dropped = Watched(key: 'tv:9', title: 'Y', mediaType: 'tv', lastPlayed: ago(60), seasons: [SeasonWatch(episodesWatched: 1)]);
    expect(tastePoints(dropped, now), -0.2);
    expect(tastePoints(const Watched(key: 'w', title: 'W', mediaType: 'movie', watchlistOnly: true), now), 0.3);
  });

  // Not on the server (no library item).
  Candidate cand(String key, String title, {double? rating, DateTime? released, String? franchise, String? genre}) =>
      Candidate(
        key: key,
        title: title,
        mediaType: 'tv',
        rating: rating,
        votes: 5000,
        released: released,
        franchise: franchise,
        genre: genre,
      );

  test('scores: the three candidates', () {
    // Southline and The Assessor are on the server (_OnServer stands in for a library item).
    final southline = _OnServer('tv:10', 'Southline', rating: 7.8)..link('tv:1', LinkKind.related);
    final assessor = _OnServer('tv:11', 'The Assessor', rating: 8.2)
      ..link('tv:1', LinkKind.recommended, rank: 0)
      ..link('movie:2', LinkKind.similar)
      ..link('movie:3', LinkKind.similar);
    final sequel = cand('movie:12', 'Iron Meridian 2', rating: 6.5, released: ago(60))..link('movie:2', LinkKind.next);

    final a = score(southline, tasteOf, now)!;
    final b = score(assessor, tasteOf, now)!;
    final c = score(sequel, tasteOf, now)!;
    expect(a.score, closeTo(1.51, 0.01));
    expect(b.score, closeTo(1.40, 0.01));
    expect(c.score, closeTo(0.45, 0.01));
    expect(b.mainSeed, 'tv:1');
    expect(b.mainKind, LinkKind.recommended);
    expect(c.mainKind, LinkKind.next);
    expect(reasonFor(c, {for (final w in seeds) w.key: w}), 'Next after Iron Meridian');
    expect(reasonFor(a, {for (final w in seeds) w.key: w}), 'Because you watched Northbound');

    // Linked only to the title given up on: left out.
    final only = cand('tv:13', 'Gloom')..link('movie:3', LinkKind.similar);
    expect(score(only, tasteOf, now), isNull);

    // The daily change stays within 3%.
    final j = score(southline, tasteOf, now, day: 7)!;
    expect((j.score / a.score - 1).abs(), lessThanOrEqualTo(0.03));
  });

  test('keeps the strongest link to each watched title', () {
    final x = cand('tv:20', 'X')
      ..link('tv:1', LinkKind.similar)
      ..link('tv:1', LinkKind.related)
      ..link('tv:1', LinkKind.genre);
    expect(x.links['tv:1']!.$2, LinkKind.related);
  });

  Scored s(String key, double v, {bool onServer = true, String seed = 'a', String? genre, LinkKind kind = LinkKind.similar}) =>
      Scored(onServer ? _OnServer(key, key, genre: genre) : cand(key, key, genre: genre), v, seed, kind);

  test('Top picks: variety, and enough on the server', () {
    final ranked = [
      for (var i = 0; i < 10; i++) s('a$i', 10.0 - i * 0.01, seed: 'a', onServer: false),
      for (var i = 0; i < 10; i++) s('b$i', 6.0 - i * 0.01, seed: 'b'),
      for (var i = 0; i < 10; i++) s('c$i', 5.0 - i * 0.01, seed: 'c'),
    ];
    final top = pickVaried(ranked, count: 20, minOnServer: 12);
    expect(top.length, 20);
    expect(top.where((x) => x.c.onServer).length, greaterThanOrEqualTo(12));
    // Without the 30% cost, the ten "a" titles would fill the start of the row.
    expect(top.take(6).map((x) => x.mainSeed).toSet().length, greaterThan(1));
  });

  test('rows: each title once, Next in the series apart, Because you watched by taste', () {
    final ws = [
      const Watched(key: 'a', title: 'Alpha', mediaType: 'movie', fraction: 1),
      const Watched(key: 'b', title: 'Beta', mediaType: 'movie', fraction: 1),
    ];
    final t = {'a': 2.0, 'b': 1.0};
    final ranked = [
      s('n', 9, seed: 'b', kind: LinkKind.next),
      for (var i = 0; i < 30; i++) s('a$i', 5.0 - i * 0.01, seed: 'a', genre: 'g$i'),
      for (var i = 0; i < 30; i++) s('b$i', 4.0 - i * 0.01, seed: 'b', genre: 'h$i'),
    ];
    final rows = buildRows(ranked: ranked, seeds: ws, tasteOf: t, popular: [for (var i = 0; i < 6; i++) _OnServer('p$i', 'P$i')], server: 'Hearth');
    expect(rows.map((r) => r.title), ['Top picks for you', 'Next in the series', 'Because you watched Alpha', 'Because you watched Beta', 'Popular on Hearth']);
    final keys = [for (final r in rows) ...r.picks.map((p) => p.c.key)];
    expect(keys.toSet().length, keys.length);
    expect(rows[1].picks.single.c.key, 'n');
  });
}

/// A candidate that counts as on the server without a real library item.
class _OnServer extends Candidate {
  _OnServer(String key, String title, {super.rating, super.genre}) : super(key: key, title: title, mediaType: 'tv', votes: 5000);
  @override
  bool get onServer => true;
}
