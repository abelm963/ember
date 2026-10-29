import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:provider/provider.dart';

import '../api/jellyfin.dart';
import '../api/seerr.dart';
import '../state/app_state.dart';
import '../ui/browse.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'coming_soon.dart';
import 'home.dart' show posterEntry, seerrEntry;
import 'nav.dart';
import 'preview.dart' show showRequestDialog;
import 'settings.dart' show pickOption;

const _tabs = ['New & Hot', 'Coming Soon', 'Explore'];

/// A genre as TMDB numbers it: movies and shows have separate lists (null: not in that list).
class DiscoverGenre {
  final String name;
  final int? movie;
  final int? tv;
  const DiscoverGenre(this.name, this.movie, this.tv);
  int? idFor(String mediaType) => mediaType == 'tv' ? tv : movie;
}

const discoverGenres = [
  DiscoverGenre('Action', 28, 10759),
  DiscoverGenre('Animation', 16, 16),
  DiscoverGenre('Comedy', 35, 35),
  DiscoverGenre('Crime', 80, 80),
  DiscoverGenre('Documentary', 99, 99),
  DiscoverGenre('Drama', 18, 18),
  DiscoverGenre('Family', 10751, 10751),
  DiscoverGenre('Fantasy', 14, 10765),
  DiscoverGenre('Horror', 27, null),
  DiscoverGenre('Kids', null, 10762),
  DiscoverGenre('Mystery', 9648, 9648),
  DiscoverGenre('Reality', null, 10764),
  DiscoverGenre('Romance', 10749, null),
  DiscoverGenre('Sci-Fi', 878, 10765),
  DiscoverGenre('Thriller', 53, null),
  DiscoverGenre('War', 10752, 10768),
  DiscoverGenre('Western', 37, 37),
];

/// Movies, shows or both, for Explore.
enum DiscoverKind { all, movies, shows }

extension on DiscoverKind {
  List<String> get types => switch (this) { DiscoverKind.all => ['movie', 'tv'], DiscoverKind.movies => ['movie'], DiscoverKind.shows => ['tv'] };
}

/// One row of Discover: library items (New & Hot) or Seerr titles (Explore).
class _Row {
  final String title;
  final List<JfItem> items;
  final List<SeerrMedia> seerr;
  const _Row(this.title, {this.items = const [], this.seerr = const []});
  bool get isEmpty => items.isEmpty && seerr.isEmpty;
}

/// Seerr titles that aren't (even partly) on the server.
List<SeerrMedia> notOnServer(Iterable<SeerrMedia> list) =>
    list.where((m) => !m.isAvailable && m.status != MediaStatus.partiallyAvailable).toList();

/// Movies and shows taken in turn, so a mixed row isn't all one kind.
List<SeerrMedia> interleave(List<List<SeerrMedia>> lists) {
  final out = <SeerrMedia>[];
  final seen = <String>{};
  for (var i = 0; lists.any((l) => i < l.length); i++) {
    for (final l in lists) {
      if (i < l.length && seen.add('${l[i].mediaType}:${l[i].id}')) out.add(l[i]);
    }
  }
  return out;
}

/// Discover: New & Hot (what just arrived on the server), Coming Soon (the release calendar) and
/// Explore (Seerr's movies and shows that aren't on the server yet, by genre).
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});
  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  int _tab = 0;
  DiscoverKind _kind = DiscoverKind.all;
  DiscoverGenre? _genre;
  int _reload = 0;

  Future<List<_Row>> _loadNewHot(AppState app) async {
    final jf = app.jf!;
    final server = app.serverName ?? 'your server';
    final r = await Future.wait([
      jf.items(types: const ['Movie', 'Series'], sortBy: 'DateCreated', sortOrder: 'Descending', limit: 24).catchError((_) => <JfItem>[]),
      jf.items(types: const ['Episode'], sortBy: 'DateCreated', sortOrder: 'Descending', limit: 24).catchError((_) => <JfItem>[]),
      jf.items(types: const ['Movie'], sortBy: 'PremiereDate', sortOrder: 'Descending', limit: 24).catchError((_) => <JfItem>[]),
      jf.items(types: const ['Series'], sortBy: 'PremiereDate', sortOrder: 'Descending', limit: 24).catchError((_) => <JfItem>[]),
    ]);
    return [
      _Row('New on $server', items: r[0]),
      _Row('New episodes', items: r[1]),
      _Row('Latest movie releases', items: r[2]),
      _Row('Latest shows', items: r[3]),
    ].where((x) => !x.isEmpty).toList();
  }

  Future<List<_Row>> _loadExplore(AppState app, DiscoverKind kind, DiscoverGenre? genre) async {
    final seerr = app.seerr!;
    final now = DateTime.now();
    final types = kind.types.where((t) => genre == null || genre.idFor(t) != null).toList();
    if (types.isEmpty) return [];

    Future<List<SeerrMedia>> mixed({int? Function(String type)? genreOf, String sortBy = 'popularity.desc', DateTime? from, DateTime? to, int? minVotes, int page = 1}) async {
      final lists = await Future.wait(types.map((t) => seerr
          .discover(t, genre: genreOf?.call(t), sortBy: sortBy, from: from, to: to, minVotes: minVotes, page: page)
          .catchError((_) => <SeerrMedia>[])));
      return notOnServer(interleave(lists));
    }

    final word = switch (kind) { DiscoverKind.all => '', DiscoverKind.movies => ' movies', DiscoverKind.shows => ' shows' };
    final recent = now.subtract(const Duration(days: 120));
    if (genre != null) {
      int? g(String t) => genre.idFor(t);
      final r = await Future.wait([
        mixed(genreOf: g),
        mixed(genreOf: g, from: recent, to: now),
        mixed(genreOf: g, sortBy: 'vote_average.desc', minVotes: 300),
        mixed(genreOf: g, page: 2),
      ]);
      return [
        _Row('Popular ${genre.name}$word', seerr: r[0]),
        _Row('New ${genre.name}$word', seerr: r[1]),
        _Row('Top rated ${genre.name}$word', seerr: r[2]),
        _Row('More ${genre.name}$word', seerr: r[3]),
      ].where((x) => !x.isEmpty).toList();
    }
    final picks = discoverGenres.where((x) => types.any((t) => x.idFor(t) != null)).take(8).toList();
    final r = await Future.wait([
      seerr.trending().then((l) => notOnServer(l.where((m) => types.contains(m.mediaType)))).catchError((_) => <SeerrMedia>[]),
      mixed(),
      mixed(from: recent, to: now),
      mixed(sortBy: 'vote_average.desc', minVotes: 1000),
      for (final x in picks) mixed(genreOf: x.idFor),
    ]);
    return [
      _Row('Trending now', seerr: r[0]),
      _Row('Popular$word', seerr: r[1]),
      _Row('New releases', seerr: r[2]),
      _Row('Critically acclaimed$word', seerr: r[3]),
      for (var i = 0; i < picks.length; i++) _Row('${picks[i].name}$word', seerr: r[4 + i]),
    ].where((x) => !x.isEmpty).toList();
  }

  Future<void> _request(SeerrMedia m) async {
    final app = context.read<AppState>();
    try {
      final full = await app.seerr!.details(m.mediaType, m.id);
      if (!mounted) return;
      await showRequestDialog(context, full);
      if (mounted) setState(() => _reload++);
    } catch (e) {
      if (mounted) toast(context, requestErrorText(e));
    }
  }

  void _pickGenre() {
    final types = _kind.types;
    pickOption<DiscoverGenre?>(
      context,
      'Genres',
      {null: 'All genres', for (final g in discoverGenres.where((g) => types.any((t) => g.idFor(t) != null))) g: g.name},
      _genre,
      (v) => setState(() => _genre = v),
    );
  }

  List<String> get _visibleTabs => [
        _tabs[0],
        _tabs[1],
        if (context.read<AppState>().seerrConfigured) _tabs[2],
      ];

  Future<List<_Row>> _load(AppState app) =>
      _tab == 2 ? _loadExplore(app, _kind, _genre) : _loadNewHot(app);

  String get _deps => '$_tab-${_kind.name}-${_genre?.name}-$_reload';

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (_tab == 2 && !app.seerrConfigured) _tab = 0;
    return app.isPhone ? _phoneBuild(context, app) : _tvBuild(context, app);
  }

  // ---------------------------------------------------------------- TV and desktop

  /// Movies or Shows on its own; choosing the chosen one again goes back to both.
  void _toggleKind(DiscoverKind k) => setState(() {
        _kind = _kind == k ? DiscoverKind.all : k;
        if (_genre != null && !_kind.types.any((t) => _genre!.idFor(t) != null)) _genre = null;
      });

  String _soonFilter = 'All';

  List<FilterGroup> _soonFilters() => [
        FilterGroup(
          title: 'Show',
          options: ComingSoonView.filters,
          selected: ComingSoonView.filters.indexOf(_soonFilter),
          onPick: (i) => setState(() => _soonFilter = ComingSoonView.filters[i]),
        ),
      ];

  List<FilterGroup> _exploreFilters() {
    final genres = discoverGenres.where((g) => _kind.types.any((t) => g.idFor(t) != null)).toList();
    return [
      FilterGroup(
        title: 'Type',
        options: const ['Movies and shows', 'Movies', 'Shows'],
        selected: _kind.index,
        onPick: (i) => setState(() {
          _kind = DiscoverKind.values[i];
          if (_genre != null && !_kind.types.any((t) => _genre!.idFor(t) != null)) _genre = null;
        }),
      ),
      FilterGroup(
        title: 'Genre',
        options: ['All genres', for (final g in genres) g.name],
        selected: _genre == null ? 0 : genres.indexOf(_genre!) + 1,
        onPick: (i) => setState(() => _genre = i == 0 ? null : genres[i - 1]),
      ),
    ];
  }

  /// The page header: Discover, its three tabs, and the filters of the open tab after them.
  Widget _tvHeader(BuildContext context) => PageHeader(
        title: 'Discover',
        tabs: [
          for (final (i, t) in _visibleTabs.indexed)
            PillButton(label: t, compact: true, scrollIntoView: false, selected: _tab == i, onTap: () => setState(() => _tab = i)),
        ],
        filters: switch (_tab) {
          1 => _soonFilters,
          2 => _exploreFilters,
          _ => null,
        },
      );

  Widget _tvBuild(BuildContext context, AppState app) {
    final jf = app.jf!;
    final header = _tvHeader(context);
    if (_tab == 1) {
      // The calendar is a list of its own, with the same header in the same place.
      return ComingSoonView(
        key: const ValueKey('soon'),
        top: PageHeader.top,
        filter: _soonFilter,
        header: Padding(
            padding: EdgeInsets.fromLTRB(context.px(gutter(context)), 0, context.px(gutter(context)), context.px(30)), child: header),
      );
    }
    PosterEntry libEntry(JfItem it) => posterEntry(context, jf, it,
        onTap: () => it.isEpisode ? play(context, it) : openItem(context, it), resume: it.isEpisode);
    return Loader<List<_Row>>(
      key: ValueKey(_deps),
      deps: _deps,
      load: () => _load(app),
      builder: (context, rows) {
        if (rows.isEmpty) {
          return Billboard(header: header, rows: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.px(60)),
              child: Text(_tab == 2 ? 'Nothing here that isn\'t on your server already.' : 'Nothing new on your server yet.',
                  style: body(context.px(24), color: C.faint)),
            ),
          ]);
        }
        final first = rows.first;
        final libFeatured = first.items.where((it) => it.backdropTags.isNotEmpty && !it.isEpisode).firstOrNull;
        final seerrFeatured = first.seerr.where((m) => m.backdropUrl != null).firstOrNull;
        return Billboard(
          key: ValueKey('bb-$_deps'),
          header: header,
          featured: libFeatured != null
              ? libEntry(libFeatured)
              : seerrFeatured != null
                  ? seerrEntry(context, seerrFeatured)
                  : null,
          actions: [
            if (libFeatured != null) ...[
              PillButton(
                label: 'Play',
                icon: Icons.play_arrow_rounded,
                autofocus: app.isTv,
                scrollIntoView: false,
                onTap: () => libFeatured.isSeries ? playSeries(context, jf, libFeatured) : play(context, libFeatured),
              ),
              PillButton(label: 'More Info', icon: Icons.info_outline, scrollIntoView: false, onTap: () => openItem(context, libFeatured)),
            ] else if (seerrFeatured != null) ...[
              PillButton(
                label: seerrFeatured.isRequested ? 'Requested' : 'Request',
                icon: seerrFeatured.isRequested ? Icons.schedule : Icons.add,
                autofocus: app.isTv,
                scrollIntoView: false,
                onTap: () => _request(seerrFeatured),
              ),
              PillButton(
                  label: 'More Info', icon: Icons.info_outline, scrollIntoView: false, onTap: () => openSeerr(context, seerrFeatured)),
            ],
          ],
          rows: [
            for (final r in rows)
              PosterRow(
                title: r.title,
                entries: [for (final it in r.items) libEntry(it), for (final m in r.seerr) seerrEntry(context, m)],
              ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------- phone

  Widget _phoneBuild(BuildContext context, AppState app) {
    final jf = app.jf!;
    final pad = context.px(gutter(context));
    final header = Padding(
      padding: EdgeInsets.symmetric(horizontal: pad),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Discover', style: display(context.px(72))),
        SizedBox(height: context.px(22)),
        FocusTraversalGroup(
          child: Wrap(spacing: context.px(12), runSpacing: context.px(12), children: [
            for (final (i, t) in _visibleTabs.indexed) Chip2(label: t, selected: _tab == i, onTap: () => setState(() => _tab = i)),
          ]),
        ),
        if (_tab == 2) ...[
          SizedBox(height: context.px(12)),
          Wrap(spacing: context.px(12), runSpacing: context.px(12), children: [
            Chip2(label: 'Movies', selected: _kind == DiscoverKind.movies, onTap: () => _toggleKind(DiscoverKind.movies)),
            Chip2(label: 'Shows', selected: _kind == DiscoverKind.shows, onTap: () => _toggleKind(DiscoverKind.shows)),
            Chip2(label: '${_genre?.name ?? 'Genres'} ▾', selected: _genre != null, onTap: _pickGenre),
          ]),
        ],
        SizedBox(height: context.px(30)),
      ]),
    );
    if (_tab == 1) return ComingSoonView(key: const ValueKey('soon'), header: header);
    return Loader<List<_Row>>(
      key: ValueKey(_deps),
      deps: _deps,
      load: () => _load(app),
      builder: (context, rows) => ListView(
        scrollCacheExtent: const ScrollCacheExtent.pixels(4000),
        padding: EdgeInsets.only(top: context.px(30), bottom: context.px(80)),
        children: [
          header,
          for (final r in rows)
            MediaRow(
              title: r.title,
              tileHeight: 216,
              children: [
                for (final it in r.items)
                  MediaTile(
                    title: it.isEpisode ? (it.seriesName ?? it.name) : it.name,
                    subtitle: it.isEpisode ? it.episodeLabel : null,
                    imageUrl: jf.landscapeImage(it),
                    onTap: () => it.isEpisode ? play(context, it) : openItem(context, it),
                  ),
                for (final m in r.seerr)
                  MediaTile(
                    title: m.title,
                    imageUrl: m.backdropUrl ?? m.posterUrl,
                    badge: m.isRequested ? 'Requested' : 'Not on server',
                    badgeAlt: m.isRequested,
                    onTap: () => openSeerr(context, m),
                  ),
              ],
            ),
          if (rows.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: pad),
              child: Text(_tab == 2 ? 'Nothing here that isn\'t on your server already.' : 'Nothing new on your server yet.',
                  style: body(context.px(22), color: C.faint)),
            ),
        ],
      ),
    );
  }
}
