import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:provider/provider.dart';

import '../api/jellyfin.dart';
import '../api/seerr.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'nav.dart';
import 'preview.dart';

/// One thing on the release calendar.
class _Release {
  final DateTime day;
  /// cinema, digital, series (new show), season (new season of a show), episode (show on the server).
  final String kind;
  final String mediaType;
  final int? tmdbId;
  final String title;
  final String? overview;
  final String? image;
  final List<String> genres;
  final int? season;
  final DateTime? cinemaDate;
  final DateTime? digitalDate;
  final JfItem? episode;
  JfItem? inLibrary;
  Map<String, dynamic>? seerr;

  _Release({
    required this.day,
    required this.kind,
    required this.mediaType,
    required this.title,
    this.tmdbId,
    this.overview,
    this.image,
    this.genres = const [],
    this.season,
    this.cinemaDate,
    this.digitalDate,
    this.episode,
  });

  bool get isMovie => mediaType == 'movie';
  bool get yourShow => episode != null || (!isMovie && inLibrary != null);
  bool matches(String filter) => switch (filter) {
        'Movies' => isMovie,
        'Shows' => !isMovie && episode == null,
        'Your shows' => yourShow,
        _ => true,
      };

  /// Seerr's status for this (the season, for shows): 2 pending, 3 processing, 4 partial, 5 available.
  int? get seerrStatus {
    final m = seerr;
    if (m == null) return null;
    if (season != null) {
      for (final s in (m['seasons'] as List? ?? const [])) {
        if ((s as Map)['seasonNumber'] == season) return (s['status'] as num?)?.toInt();
      }
      return null;
    }
    return (m['status'] as num?)?.toInt();
  }

  bool get onServer => episode != null || seerrStatus == 5 || (isMovie && inLibrary != null);
  bool get requested => const {2, 3, 4}.contains(seerrStatus);
}

// TMDB genre ids → names (movie and TV lists combined; they're stable).
const _genres = {
  28: 'Action', 12: 'Adventure', 16: 'Animation', 35: 'Comedy', 80: 'Crime', 99: 'Documentary', 18: 'Drama',
  10751: 'Family', 14: 'Fantasy', 36: 'History', 27: 'Horror', 10402: 'Music', 9648: 'Mystery', 10749: 'Romance',
  878: 'Sci-Fi', 10770: 'TV Movie', 53: 'Thriller', 10752: 'War', 37: 'Western', 10759: 'Action & Adventure',
  10762: 'Kids', 10763: 'News', 10764: 'Reality', 10765: 'Sci-Fi & Fantasy', 10766: 'Soap', 10767: 'Talk',
  10768: 'War & Politics',
};

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

String _when(DateTime day) {
  final today = _dayOf(DateTime.now());
  final diff = day.difference(today).inDays;
  if (diff <= 0) return 'Out today';
  if (diff == 1) return 'Coming tomorrow';
  if (diff < 7) return 'Coming ${_weekdays[day.weekday - 1]}';
  return 'Coming ${_weekdays[day.weekday - 1].substring(0, 3)} ${day.day} ${_months[day.month - 1]}';
}

/// The "Coming Soon" release calendar: everything releasing in the next few months, day by day,
/// with Request on titles that aren't on the server so they arrive the day they're out.
class ComingSoonView extends StatefulWidget {
  /// Shown above the calendar (the New & Hot title and tabs), so it scrolls with the list.
  final Widget header;
  const ComingSoonView({super.key, required this.header});
  @override
  State<ComingSoonView> createState() => _ComingSoonViewState();
}

class _ComingSoonViewState extends State<ComingSoonView> {
  String _filter = 'All';
  int _reload = 0;

  static String _region() {
    try {
      final parts = Platform.localeName.split(RegExp('[_.-]'));
      if (parts.length > 1 && parts[1].length == 2) return parts[1].toUpperCase();
    } catch (_) {}
    return 'US';
  }

  static DateTime? _date(Object? v) {
    final d = DateTime.tryParse('${v ?? ''}');
    return d == null ? null : _dayOf(d);
  }

  Future<List<_Release>> _load(AppState app) async {
    final jf = app.jf!;
    final today = _dayOf(DateTime.now());
    final until = today.add(const Duration(days: 120));
    final seerr = app.seerrConfigured ? app.seerr : null;

    final r = await Future.wait<Object?>([
      jf.releaseCalendar(region: _region()).catchError((_) => null),
      jf.upcomingEpisodes().catchError((_) => <JfItem>[]),
      jf.libraryByTmdb().catchError((_) => <String, JfItem>{}),
      seerr == null ? Future.value(<String, Map<String, dynamic>>{}) : seerr.allMedia().catchError((_) => <String, Map<String, dynamic>>{}),
    ]);
    final calendar = r[0] as List<Map<String, dynamic>>?;
    final episodes = r[1] as List<JfItem>;
    final library = r[2] as Map<String, JfItem>;
    final known = r[3] as Map<String, Map<String, dynamic>>;

    final all = <_Release>[];
    // Shows on the server: their next episodes arrive by themselves.
    for (final e in episodes) {
      if (e.premiereDate == null) continue;
      all.add(_Release(
        day: _dayOf(e.premiereDate!),
        kind: 'episode',
        mediaType: 'tv',
        title: e.seriesName ?? e.name,
        overview: e.overview,
        image: jf.landscapeImage(e),
        episode: e,
      ));
    }

    if (calendar != null) {
      // From the Ember plugin on the server (TMDB, plus Trakt when set up).
      for (final c in calendar) {
        final day = _date(c['date']);
        if (day == null) continue;
        all.add(_Release(
          day: day,
          kind: '${c['kind']}',
          mediaType: '${c['mediaType']}',
          tmdbId: (c['tmdbId'] as num?)?.toInt(),
          title: '${c['title']}',
          overview: c['overview'] as String?,
          image: SeerrMedia.image(c['backdropPath'] as String? ?? c['posterPath'] as String?, size: 'w780'),
          genres: ((c['genres'] as List?) ?? const []).map((g) => '$g').toList(),
          season: (c['seasonNumber'] as num?)?.toInt(),
          cinemaDate: _date(c['cinemaDate']),
          digitalDate: _date(c['digitalDate']),
        ));
      }
    } else if (seerr != null) {
      // Older plugin or none: Seerr's release search (movies and brand-new shows only).
      final lists = await Future.wait([
        for (final type in const ['movie', 'tv'])
          for (var page = 1; page <= 3; page++) seerr.releasing(type, today, until, page: page).catchError((_) => <SeerrMedia>[]),
      ]);
      for (final m in lists.expand((l) => l)) {
        final day = _date(m.date);
        if (day == null) continue;
        all.add(_Release(
          day: day,
          kind: m.isTv ? 'series' : 'cinema',
          mediaType: m.mediaType,
          tmdbId: m.id,
          title: m.title,
          overview: m.overview,
          image: m.backdropUrl ?? m.posterUrl,
          genres: ((m.raw['genreIds'] as List?) ?? const []).map((g) => _genres[(g as num).toInt()]).whereType<String>().toList(),
          season: m.isTv ? 1 : null,
        ));
      }
    }

    final seen = <String>{};
    final out = <_Release>[];
    for (final x in all) {
      if (x.day.isBefore(today)) continue;
      final key = x.episode != null ? 'ep:${x.episode!.id}' : '${x.mediaType}:${x.tmdbId}:${x.kind}:${x.season}';
      if (!seen.add(key)) continue;
      if (x.tmdbId != null) {
        x.inLibrary = library['${x.mediaType}:${x.tmdbId}'];
        x.seerr = known['${x.mediaType}:${x.tmdbId}'];
      }
      out.add(x);
    }
    out.sort((a, b) => a.day.compareTo(b.day));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pad = context.px(gutter(context));
    return Loader<List<_Release>>(
      deps: '${app.revision}-$_reload',
      load: () => _load(app),
      placeholder: ListView(padding: EdgeInsets.only(top: context.px(app.isPhone ? 30 : 60)), children: [
        widget.header,
        SkeletonPulse(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: pad),
            child: Column(children: [
              for (var i = 0; i < 3; i++)
                Padding(
                  padding: EdgeInsets.only(bottom: context.px(40)),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Bone(110, 110, radius: 14),
                    SizedBox(width: context.px(30)),
                    const Bone(520, 292, radius: 14),
                    SizedBox(width: context.px(36)),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Bone(420, 44),
                      SizedBox(height: context.px(18)),
                      const Bone(260, 26),
                      SizedBox(height: context.px(18)),
                      const Bone(560, 22),
                      SizedBox(height: context.px(10)),
                      const Bone(520, 22),
                    ]),
                  ]),
                ),
            ]),
          ),
        ),
      ]),
      builder: (context, all) {
        final filters = ['All', 'Movies', 'Shows', 'Your shows'];
        final shown = all.where((r) => r.matches(_filter)).toList();
        // Group by day.
        final days = <DateTime, List<_Release>>{};
        for (final r in shown) {
          days.putIfAbsent(r.day, () => []).add(r);
        }
        final entries = days.entries.toList();
        return ListView.builder(
          scrollCacheExtent: const ScrollCacheExtent.pixels(3000),
          padding: EdgeInsets.only(top: context.px(app.isPhone ? 30 : 60), bottom: context.px(80)),
          itemCount: entries.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                widget.header,
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: pad),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      app.seerrConfigured
                          ? 'The next four months of movies, new shows and new seasons. Request anything now and it\'s added as soon as it can be.'
                          : 'What\'s coming in the next four months. Connect Seerr in Settings to request titles ahead of time.',
                      style: body(context.px(23), color: C.faint),
                    ),
                    SizedBox(height: context.px(24)),
                    FocusTraversalGroup(
                      child: Wrap(spacing: context.px(12), runSpacing: context.px(12), children: [
                        for (final f in filters)
                          Chip2(label: f, selected: _filter == f, onTap: () => setState(() => _filter = f)),
                      ]),
                    ),
                    SizedBox(height: context.px(36)),
                    if (entries.isEmpty) Text('Nothing scheduled here yet.', style: body(context.px(24), color: C.faint)),
                  ]),
                ),
              ]);
            }
            final e = entries[i - 1];
            return _DayGroup(
              day: e.key,
              releases: e.value,
              firstOfMonth: i == 1 || entries[i - 2].key.month != e.key.month,
              onRequested: () => setState(() => _reload++),
            );
          },
        );
      },
    );
  }
}

class _DayGroup extends StatelessWidget {
  final DateTime day;
  final List<_Release> releases;
  final bool firstOfMonth;
  final VoidCallback onRequested;
  const _DayGroup({required this.day, required this.releases, required this.firstOfMonth, required this.onRequested});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pad = context.px(gutter(context));
    final dateBox = SizedBox(
      width: context.px(app.isPhone ? 0 : 110),
      child: app.isPhone
          ? null
          : Column(children: [
              Text(_months[day.month - 1].toUpperCase(),
                  style: body(context.px(22), color: C.accent, weight: FontWeight.w700).copyWith(letterSpacing: context.px(3))),
              Text('${day.day}', style: display(context.px(64), height: 1.0)),
              Text(_weekdays[day.weekday - 1].substring(0, 3), style: body(context.px(20), color: C.faint)),
            ]),
    );
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: pad),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (firstOfMonth)
          Padding(
            padding: EdgeInsets.only(bottom: context.px(26), top: context.px(10)),
            child: Text('${['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][day.month - 1]}'
                '${day.year != DateTime.now().year ? ' ${day.year}' : ''}',
                style: display(context.px(44))),
          ),
        if (app.isPhone)
          Padding(
            padding: EdgeInsets.only(bottom: context.px(14)),
            child: Text('${_weekdays[day.weekday - 1]} ${day.day} ${_months[day.month - 1]}',
                style: body(context.px(30), color: C.accent, weight: FontWeight.w700)),
          ),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          dateBox,
          if (!app.isPhone) SizedBox(width: context.px(30)),
          Expanded(
            child: Column(children: [
              for (final r in releases) _ReleaseCard(release: r, onRequested: onRequested),
            ]),
          ),
        ]),
        SizedBox(height: context.px(18)),
      ]),
    );
  }
}

String _short(DateTime d) => '${d.day} ${_months[d.month - 1]}';

class _ReleaseCard extends StatelessWidget {
  final _Release release;
  final VoidCallback onRequested;
  const _ReleaseCard({required this.release, required this.onRequested});

  Future<void> _request(BuildContext context, AppState app) async {
    final r = release;
    try {
      final media = await app.seerr!.details(r.mediaType, r.tmdbId!);
      if (!context.mounted) return;
      await showRequestDialog(context, media, preselect: r.season == null ? null : {r.season!});
      onRequested();
    } catch (e) {
      if (context.mounted) toast(context, '$e');
    }
  }

  void _open(BuildContext context) {
    final r = release;
    if (r.episode != null) return openItem(context, r.episode!);
    if (r.inLibrary != null) return openItem(context, r.inLibrary!);
    if (r.tmdbId != null) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => PreviewScreen(mediaType: r.mediaType, tmdbId: r.tmdbId!)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final r = release;
    final server = app.serverName ?? 'your server';
    final ep = r.episode;

    // What it is.
    final what = switch (r.kind) {
      'cinema' => 'In cinemas',
      'digital' => 'Out to stream and buy',
      'series' => 'New series',
      'season' => 'Season ${r.season}',
      _ => ep != null ? '${ep.episodeLabel} · ${ep.name}' : '',
    };
    final kindLine = [what, ...r.genres.take(3)].where((x) => x.isNotEmpty).join(' · ');

    // When it can actually be added to the server (movies arrive with the digital release).
    String? arrival;
    if (r.kind == 'cinema' && !r.onServer) {
      arrival = r.digitalDate != null && r.digitalDate!.isAfter(r.day)
          ? 'Can be added from ${_short(r.digitalDate!)}, when it\'s out digitally'
          : 'Can be added once it\'s out digitally (date not announced yet)';
    }

    Widget? action;
    if (r.onServer) {
      action = _Note(icon: Icons.check, text: ep != null ? 'On $server · arrives automatically' : 'On $server');
    } else if (r.requested) {
      action = _Note(
          icon: Icons.schedule,
          text: r.kind == 'cinema' ? 'Requested · added when it\'s out digitally' : 'Requested · added when it\'s out',
          accent: true);
    } else if (app.seerrConfigured && r.tmdbId != null) {
      action = EmberButton(
        label: r.kind == 'season' ? 'Request Season ${r.season}' : 'Request',
        icon: Icons.add,
        kind: BtnKind.accent,
        compact: true,
        onTap: () => _request(context, app),
      );
    }

    final imageBox = ClipRRect(
      borderRadius: BorderRadius.circular(context.px(14)),
      child: SizedBox(
        width: app.isPhone ? double.infinity : context.px(520),
        height: app.isPhone ? null : context.px(292),
        child: AspectRatio(aspectRatio: 16 / 9, child: NetImage(r.image, fallback: TitleCard(r.title))),
      ),
    );

    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(_when(r.day).toUpperCase(),
          style: body(context.px(19), color: C.accent, weight: FontWeight.w700).copyWith(letterSpacing: context.px(2))),
      SizedBox(height: context.px(8)),
      Text(r.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: display(context.px(app.isPhone ? 40 : 46))),
      SizedBox(height: context.px(10)),
      if (kindLine.isNotEmpty) Text(kindLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: body(context.px(21), color: C.muted)),
      if (r.overview != null && r.overview!.isNotEmpty) ...[
        SizedBox(height: context.px(12)),
        Text(r.overview!, maxLines: 3, overflow: TextOverflow.ellipsis, style: body(context.px(21), color: C.faint, height: 1.45)),
      ],
      if (arrival != null) ...[
        SizedBox(height: context.px(12)),
        Text(arrival, style: body(context.px(20), color: C.blue)),
      ],
      if (action != null) ...[SizedBox(height: context.px(18)), action],
    ]);

    return Padding(
      padding: EdgeInsets.only(bottom: context.px(30)),
      child: FocusTraversalGroup(
        child: Focusable(
          onTap: () => _open(context),
          semanticLabel: '${r.title}, ${_when(r.day)}',
          builder: (context, active) => AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: EdgeInsets.all(context.px(14)),
            decoration: BoxDecoration(
              color: active ? C.surface2 : Colors.transparent,
              borderRadius: BorderRadius.circular(context.px(20)),
              border: Border.all(color: active ? C.text : Colors.transparent, width: context.px(3)),
            ),
            child: app.isPhone
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [imageBox, SizedBox(height: context.px(18)), text])
                : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    imageBox,
                    SizedBox(width: context.px(36)),
                    Expanded(child: Padding(padding: EdgeInsets.only(top: context.px(10)), child: text)),
                  ]),
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool accent;
  const _Note({required this.icon, required this.text, this.accent = false});
  @override
  Widget build(BuildContext context) => Container(
        height: context.px(48),
        padding: EdgeInsets.symmetric(horizontal: context.px(18)),
        decoration: BoxDecoration(
          color: accent ? C.accentDark : const Color(0xFF1B3322),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: context.px(24), color: accent ? C.accent : C.good),
          SizedBox(width: context.px(10)),
          Flexible(
            child: Text(text,
                overflow: TextOverflow.ellipsis, style: body(context.px(20), weight: FontWeight.w700, color: accent ? C.accent : C.good)),
          ),
        ]),
      );
}
