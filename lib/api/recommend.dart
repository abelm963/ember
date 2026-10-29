import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'jellyfin.dart';
import 'seerr.dart';
import 'taste.dart';

// Gathers what Recommended ranks (see taste.dart for the numbers):
//   - from Jellyfin: every movie and episode played in the last 2 years, how far, how often and
//     when; which seasons were finished; likes (favourites);
//   - from Seerr: the watchlist, and per watched title TMDB's recommendations and similar titles,
//     the film series it belongs to and who made it.
// Seerr's answers are kept for a day, so opening Recommended again is quick.

/// One title in a Recommended row: on the server ([item]) or on Seerr only ([media]), and why.
class RecPick {
  final JfItem? item;
  final SeerrMedia? media;
  final String reason;
  const RecPick({this.item, this.media, this.reason = ''});
}

class RecommendedRow {
  final String title;
  final List<RecPick> picks;
  const RecommendedRow(this.title, this.picks);
}

const _window = Duration(days: 730);

/// TMDB's genre numbers, named as Jellyfin names them (for variety across server and Seerr titles).
const _tmdbGenres = {
  28: 'Action',
  12: 'Adventure',
  16: 'Animation',
  35: 'Comedy',
  80: 'Crime',
  99: 'Documentary',
  18: 'Drama',
  10751: 'Family',
  14: 'Fantasy',
  36: 'History',
  27: 'Horror',
  10402: 'Music',
  9648: 'Mystery',
  10749: 'Romance',
  878: 'Science Fiction',
  53: 'Thriller',
  10752: 'War',
  37: 'Western',
  10759: 'Action & Adventure',
  10762: 'Kids',
  10764: 'Reality',
  10765: 'Sci-Fi & Fantasy',
  10768: 'War & Politics',
};

String _itemKey(JfItem it) {
  final t = it.tmdbId;
  return t == null || t.isEmpty ? 'jf:${it.id}' : '${it.isSeries ? 'tv' : 'movie'}:$t';
}

String _mediaKey(SeerrMedia m) => '${m.mediaType}:${m.id}';

/// Runs [f] over [list], [n] at a time (so the servers aren't flooded).
Future<void> _inBatches<T>(Iterable<T> list, int n, Future<void> Function(T) f) async {
  final all = list.toList();
  for (var i = 0; i < all.length; i += n) {
    await Future.wait(all.skip(i).take(n).map((x) => f(x).catchError((_) {})));
  }
}

/// Seerr answers kept for a day in shared preferences.
class _DayCache {
  SharedPreferences? _prefs;
  final DateTime now;
  _DayCache(this.now);

  static const _keep = {
    'id',
    'mediaType',
    'title',
    'name',
    'overview',
    'posterPath',
    'backdropPath',
    'releaseDate',
    'firstAirDate',
    'voteAverage',
    'voteCount',
    'genreIds',
    'mediaInfo',
    'collection',
    'createdBy',
    'seasons',
    'numberOfSeasons',
  };

  static Map<String, dynamic> _trim(Map<String, dynamic> raw) {
    final out = {
      for (final e in raw.entries)
        if (_keep.contains(e.key)) e.key: e.value,
    };
    final info = out['mediaInfo'];
    if (info is Map) out['mediaInfo'] = {'status': info['status'], 'status4k': info['status4k']};
    final seasons = out['seasons'];
    if (seasons is List) {
      out['seasons'] = [
        for (final s in seasons.whereType<Map>()) {'seasonNumber': s['seasonNumber'], 'airDate': s['airDate']},
      ];
    }
    return out;
  }

  Future<List<SeerrMedia>> list(String key, Future<List<SeerrMedia>> Function() fetch) async {
    final hit = await _read(key);
    if (hit is List) return [for (final m in hit.whereType<Map>()) SeerrMedia(m.cast<String, dynamic>())];
    final fresh = await fetch();
    await _write(key, [for (final m in fresh) _trim(m.raw)]);
    return fresh;
  }

  Future<SeerrMedia> one(String key, Future<SeerrMedia> Function() fetch) async {
    final hit = await _read(key);
    if (hit is Map) return SeerrMedia(hit.cast<String, dynamic>());
    final fresh = await fetch();
    await _write(key, _trim(fresh.raw));
    return fresh;
  }

  Future<Object?> _read(String key) async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final s = _prefs!.getString('rec1.$key');
      if (s == null) return null;
      final j = jsonDecode(s) as Map;
      if (now.millisecondsSinceEpoch - (j['t'] as num) > const Duration(days: 1).inMilliseconds) return null;
      return j['v'];
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String key, Object value) async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setString('rec1.$key', jsonEncode({'t': now.millisecondsSinceEpoch, 'v': value}));
    } catch (_) {}
  }
}

/// Recommended's rows for this person.
Future<List<RecommendedRow>> recommend(
  JellyfinClient jf,
  SeerrClient? seerr, {
  String server = 'your server',
  DateTime? now,
}) async {
  now ??= DateTime.now();
  final since = now.subtract(_window);
  final cache = _DayCache(now);

  // ---- 1. What was watched.
  final r = await Future.wait<Object>([
    jf.items(types: const ['Movie', 'Series'], sortBy: null).catchError((_) => <JfItem>[]),
    jf
        .items(
          types: const ['Episode'],
          filters: 'IsPlayed',
          sortBy: 'DatePlayed',
          sortOrder: 'Descending',
          limit: 5000,
          fields: 'ParentId',
          images: false,
        )
        .catchError((_) => <JfItem>[]),
    jf
        .items(
          types: const ['Episode'],
          filters: 'IsResumable',
          sortBy: 'DatePlayed',
          sortOrder: 'Descending',
          limit: 300,
          fields: 'ParentId',
          images: false,
        )
        .catchError((_) => <JfItem>[]),
    seerr?.watchlist(pages: 3).catchError((_) => <WatchlistEntry>[]) ?? Future.value(<WatchlistEntry>[]),
    seerr?.requests(take: 100).catchError((_) => <SeerrRequest>[]) ?? Future.value(<SeerrRequest>[]),
  ]);
  final library = (r[0] as List<JfItem>).where((it) => it.isMovie || it.isSeries).toList();
  final byKey = {for (final it in library) _itemKey(it): it};
  final byId = {for (final it in library) it.id: it};
  final requested = {
    for (final q in r[4] as List<SeerrRequest>)
      if (q.tmdbId != null && q.arriving) '${q.mediaType}:${q.tmdbId}',
  };

  final watched = <String, Watched>{};

  // Movies: played or started in the window.
  for (final it in library.where((it) => it.isMovie)) {
    final last = it.lastPlayed;
    if (last == null || last.isBefore(since) || (!it.played && it.positionTicks == 0)) continue;
    final run = it.runTimeTicks ?? 0;
    final f = it.played ? 1.0 : (run > 0 ? min(1.0, it.positionTicks / (run * 0.92)) : 0.0);
    watched[_itemKey(it)] = Watched(
      key: _itemKey(it),
      title: it.name,
      mediaType: 'movie',
      tmdbId: int.tryParse(it.tmdbId ?? ''),
      jfId: it.id,
      lastPlayed: last,
      favourite: it.isFavorite,
      playCount: max(it.playCount, it.played ? 1 : 0),
      fraction: f,
    );
  }

  // Shows: episodes in the window, by series and season.
  final eps = <String, Map<int, List<DateTime>>>{};
  for (final e in [...r[1] as List<JfItem>, ...r[2] as List<JfItem>]) {
    final last = e.lastPlayed;
    final sid = e.seriesId;
    if (!e.isEpisode || sid == null || last == null || last.isBefore(since)) continue;
    ((eps[sid] ??= {})[e.parentIndexNumber ?? 1] ??= []).add(last);
  }
  final seasonsOf = <String, List<JfItem>>{};
  final busiest = eps.keys.toList()..sort((a, b) => _count(eps[b]!).compareTo(_count(eps[a]!)));
  await _inBatches(busiest.take(60), 8, (sid) async => seasonsOf[sid] = await jf.seasons(sid));
  for (final MapEntry(key: sid, value: bySeason) in eps.entries) {
    final show = byId[sid];
    if (show == null) continue;
    final server = {for (final s in seasonsOf[sid] ?? const <JfItem>[]) s.indexNumber: s};
    final seasons = [
      for (final MapEntry(key: n, value: dates) in bySeason.entries)
        if (n > 0)
          SeasonWatch(
            episodesWatched: dates.length,
            finished: server[n] != null && (server[n]!.played || server[n]!.unplayedCount == 0),
            first: dates.reduce((a, b) => a.isBefore(b) ? a : b),
            last: dates.reduce((a, b) => a.isAfter(b) ? a : b),
          ),
    ];
    if (seasons.isEmpty) continue;
    final key = _itemKey(show);
    watched[key] = Watched(
      key: key,
      title: show.name,
      mediaType: 'tv',
      tmdbId: int.tryParse(show.tmdbId ?? ''),
      jfId: show.id,
      lastPlayed: seasons.map((s) => s.last!).reduce((a, b) => a.isAfter(b) ? a : b),
      favourite: show.isFavorite,
      seasons: seasons,
      caughtUp: show.unplayedCount == 0,
    );
  }

  // Likes not watched lately still count (and fade from when they were last played).
  for (final it in library.where((it) => it.isFavorite)) {
    final key = _itemKey(it);
    watched[key] ??= Watched(
      key: key,
      title: it.name,
      mediaType: it.isSeries ? 'tv' : 'movie',
      tmdbId: int.tryParse(it.tmdbId ?? ''),
      jfId: it.id,
      lastPlayed: it.lastPlayed,
      favourite: true,
    );
  }

  // The watchlist: what they want to see says something too.
  for (final w in r[3] as List<WatchlistEntry>) {
    final key = '${w.mediaType}:${w.tmdbId}';
    watched[key] ??= Watched(
      key: key,
      title: w.title.isEmpty ? (byKey[key]?.name ?? '') : w.title,
      mediaType: w.mediaType,
      tmdbId: w.tmdbId,
      jfId: byKey[key]?.id,
      watchlistOnly: true,
    );
  }

  final tasteOf = {for (final w in watched.values) w.key: taste(w, now)};
  final ordered = watched.values.where((w) => w.title.isNotEmpty).toList()
    ..sort((a, b) => tasteOf[b.key]!.compareTo(tasteOf[a.key]!));
  final liked = ordered.where((w) => tasteOf[w.key]! > 0).take(25).toList();
  final disliked = ordered.reversed.where((w) => tasteOf[w.key]! < 0).take(5).toList();
  if (liked.isEmpty) return [];

  // ---- 2. What each is linked to.
  final cands = <String, Candidate>{};
  Candidate fromItem(JfItem it) => cands.putIfAbsent(
    _itemKey(it),
    () => Candidate(
      key: _itemKey(it),
      title: it.name,
      mediaType: it.isSeries ? 'tv' : 'movie',
      item: byId[it.id] ?? it,
      rating: it.communityRating,
      released: it.premiereDate,
      genre: it.genres.firstOrNull,
    ),
  );
  Candidate fromMedia(SeerrMedia m, {String? key}) {
    final k = key ?? _mediaKey(m);
    final local = key == null ? byKey[k] : null;
    if (local != null) return fromItem(local);
    final g =
        (m.raw['genreIds'] as List?)?.whereType<num>().map((n) => _tmdbGenres[n.toInt()]).nonNulls.firstOrNull ??
        m.genres.firstOrNull;
    return cands.putIfAbsent(
      k,
      () => Candidate(
        key: k,
        title: m.title,
        mediaType: m.mediaType,
        media: m,
        rating: m.voteAverage,
        votes: m.voteCount,
        released: DateTime.tryParse(m.date ?? ''),
        genre: g,
      ),
    );
  }

  final seeds = [...liked, ...disliked];
  await _inBatches(seeds, 6, (w) async {
    final jobs = <Future<void>>[
      if (w.jfId != null)
        jf
            .similar(w.jfId!, limit: 12)
            .then((l) {
              for (final it in l) {
                if (it.isMovie || it.isSeries) fromItem(it).link(w.key, LinkKind.similar);
              }
            })
            .catchError((_) {}),
      if (seerr != null && w.tmdbId != null) ...[
        cache
            .list('rec.${w.key}', () => seerr.recommendations(w.mediaType, w.tmdbId!))
            .then((l) {
              for (final (i, m) in l.indexed) {
                fromMedia(m).link(w.key, LinkKind.recommended, rank: i);
              }
            })
            .catchError((_) {}),
        cache
            .list('sim.${w.key}', () => seerr.similar(w.mediaType, w.tmdbId!))
            .then((l) {
              for (final m in l.take(10)) {
                fromMedia(m).link(w.key, LinkKind.similar);
              }
            })
            .catchError((_) {}),
      ],
    ];
    await Future.wait(jobs);
  });

  // Film series, related shows and new seasons: only for titles liked.
  if (seerr != null) {
    await _inBatches(liked.where((w) => w.tmdbId != null && !w.watchlistOnly).take(15), 6, (w) async {
      final d = await cache.one('det.${w.key}', () => seerr.details(w.mediaType, w.tmdbId!));
      if (!w.isShow) {
        final col = d.collection;
        if (col == null) return;
        final parts = await cache.list('col.${col.id}', () => seerr.collection(col.id));
        final at = parts.indexWhere((m) => m.id == w.tmdbId);
        // The next film after the last one of the series they watched.
        var last = at;
        for (final (i, m) in parts.indexed) {
          final seen = watched[_mediaKey(m)];
          if (seen != null && !seen.watchlistOnly && i > last) last = i;
        }
        for (final (i, m) in parts.indexed) {
          final c = fromMedia(m)..franchise = col.name;
          if (i == last + 1 && last >= 0) c.link(w.key, LinkKind.next);
        }
        return;
      }
      // A newer season than the server has, once they've watched everything there.
      if (w.caughtUp && w.jfId != null) {
        final aired = d.seasons
            .where((s) => (DateTime.tryParse(s['airDate'] as String? ?? '') ?? now!).isBefore(now!))
            .length;
        final have = (seasonsOf[w.jfId] ?? const <JfItem>[]).where((s) => (s.indexNumber ?? 0) > 0).length;
        if (have > 0 && aired > have) fromMedia(d, key: '${w.key}#new').link(w.key, LinkKind.newSeason);
      }
      // Shows by the same creators among TMDB's top picks: related.
      final makers = d.createdBy.toSet();
      if (makers.isEmpty) return;
      final recs = await cache.list('rec.${w.key}', () => seerr.recommendations(w.mediaType, w.tmdbId!));
      for (final m in recs.take(4)) {
        final rd = await cache.one('det.${_mediaKey(m)}', () => seerr.details(m.mediaType, m.id)).catchError((_) => m);
        if (rd.createdBy.any(makers.contains)) fromMedia(m).link(w.key, LinkKind.related);
      }
    });
  }

  // The same director, or the two leads, on the server.
  await _inBatches(liked.where((w) => w.jfId != null && !w.watchlistOnly).take(8), 4, (w) async {
    final full = await jf.item(w.jfId!);
    final people = full.people;
    final ids = [
      ...people.where((p) => p['Type'] == 'Director').take(1).map((p) => p['Id']),
      ...people.where((p) => p['Type'] == 'Actor').take(2).map((p) => p['Id']),
    ].whereType<String>().toList();
    if (ids.isEmpty) return;
    for (final id in ids) {
      final l = await jf.items(
        types: const ['Movie', 'Series'],
        personIds: [id],
        sortBy: 'CommunityRating',
        sortOrder: 'Descending',
        limit: 12,
      );
      for (final it in l) {
        if (it.id != w.jfId && (it.isMovie || it.isSeries)) fromItem(it).link(w.key, LinkKind.people);
      }
    }
  });

  // ---- 3. Leave out what they've seen, started, asked for or put on the watchlist.
  bool started(JfItem it) => it.played || it.positionTicks > 0 || (it.playedPercentage ?? 0) > 0;
  bool keep(Candidate c) {
    if (c.links.isEmpty) return false;
    if (c.key.endsWith('#new')) return !requested.contains(c.key.replaceAll('#new', ''));
    if (watched.containsKey(c.key) || requested.contains(c.key)) return false;
    final it = c.item;
    if (it != null) return !started(byId[it.id] ?? it);
    // Seerr says it's on a server, but not one this person can see: nothing to do with it.
    final m = c.media;
    return m == null || !(m.isRequested || m.isAvailable);
  }

  final day = now.difference(DateTime(2020)).inDays;
  final ranked = [
    for (final c in cands.values)
      if (keep(c)) score(c, tasteOf, now, day: day),
  ].nonNulls.toList();

  final popular = [
    for (final it
        in library.where((it) => !started(it) && !watched.containsKey(_itemKey(it))).toList()
          ..sort((a, b) => (b.communityRating ?? 0).compareTo(a.communityRating ?? 0)))
      Candidate(key: _itemKey(it), title: it.name, mediaType: it.isSeries ? 'tv' : 'movie', item: it),
  ].take(60).toList();

  final rows = buildRows(ranked: ranked, seeds: ordered, tasteOf: tasteOf, popular: popular, server: server);
  return [
    for (final row in rows)
      RecommendedRow(row.title, [
        for (final s in row.picks)
          RecPick(item: s.c.item, media: s.c.item == null ? s.c.media : null, reason: reasonFor(s, watched)),
      ]),
  ];
}

int _count(Map<int, List<DateTime>> bySeason) => bySeason.values.fold(0, (n, l) => n + l.length);
