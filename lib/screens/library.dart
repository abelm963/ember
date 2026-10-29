import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:provider/provider.dart';

import '../api/jellyfin.dart';
import '../state/app_state.dart';
import '../ui/browse.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'nav.dart';
import 'shared/media_entries.dart';

enum LibraryKind { movies, shows }

class _Sort {
  final String label;
  final String sortBy;
  final String order;
  final String? filters;
  const _Sort(this.label, this.sortBy, this.order, [this.filters]);
}

const _sorts = [
  _Sort('Recently added', 'DateCreated', 'Descending'),
  _Sort('A–Z', 'SortName', 'Ascending'),
  _Sort('Top rated', 'CommunityRating', 'Descending'),
  _Sort('Release date', 'PremiereDate', 'Descending'),
  _Sort('Unwatched', 'DateCreated', 'Descending', 'IsUnplayed'),
];

/// Movies or Shows: genre chips, a Top 10 row, then a row per genre (or every title in the
/// chosen genre), as in the design.
class LibraryScreen extends StatefulWidget {
  final LibraryKind kind;
  const LibraryScreen({super.key, required this.kind});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  String? _genre;
  int _sort = 0;
  List<String>? _genres;
  int? _count;

  String get _type => widget.kind == LibraryKind.movies ? 'Movie' : 'Series';

  @override
  void initState() {
    super.initState();
    final jf = context.read<AppState>().jf!;
    jf
        .genres(types: [_type])
        .then((g) {
          if (mounted) setState(() => _genres = g);
        })
        .catchError((_) {});
    jf
        .count([_type])
        .then((c) {
          if (mounted) setState(() => _count = c);
        })
        .catchError((_) {});
  }

  Widget _tile(BuildContext context, JellyfinClient jf, JfItem it, {double width = 384}) => MediaTile(
    title: it.name,
    imageUrl: jf.landscapeImage(it),
    width: width,
    badge: it.isSeries && (it.unplayedCount ?? 0) > 0 ? '${it.unplayedCount} new' : null,
    badgeAlt: true,
    onTap: () => openItem(context, it),
  );

  /// TV and desktop: a billboard like Home. The page name with Genres and Sort at the top, a
  /// featured title from the Top 10, then a Top 10 row and a row per genre (or every title in the
  /// chosen genre, a row at a time).
  Widget _tvBuild(BuildContext context, AppState app) {
    final jf = app.jf!;
    final s = _sorts[_sort];
    final title = widget.kind == LibraryKind.movies ? 'Movies' : 'Shows';
    final header = PageHeader(
      title: title,
      filters: () => [
        FilterGroup(
          title: 'Genre',
          options: ['All genres', ...?_genres],
          selected: _genre == null ? 0 : (_genres?.indexOf(_genre!) ?? -1) + 1,
          onPick: (i) => setState(() => _genre = i == 0 ? null : _genres![i - 1]),
        ),
        FilterGroup(
          title: 'Sort by',
          options: [for (final s in _sorts) s.label],
          selected: _sort,
          onPick: (i) => setState(() => _sort = i),
        ),
      ],
    );
    PosterEntry entry(JfItem it, {int? rank}) {
      final e = posterEntry(context, jf, it, onTap: () => openItem(context, it));
      return PosterEntry(
        title: e.title,
        poster: e.poster,
        wide: e.wide,
        wideTitled: e.wideTitled,
        logo: e.logo,
        meta: e.meta,
        rating: e.rating,
        overview: e.overview,
        backdrop: e.backdrop,
        badge: it.isSeries && (it.unplayedCount ?? 0) > 0 ? '${it.unplayedCount} new' : null,
        badgeAlt: true,
        rank: rank,
        onTap: e.onTap,
      );
    }

    return Loader<List<JfItem>>(
      deps: 'tv-top-$_genre',
      load: () =>
          jf.items(types: [_type], genre: _genre, sortBy: 'CommunityRating', sortOrder: 'Descending', limit: 10),
      builder: (context, top) {
        final featured = top.where((it) => it.backdropTags.isNotEmpty).firstOrNull ?? top.firstOrNull;
        final rows = <Widget>[
          PosterRow(
            title: _genre == null ? 'Top 10 on your server' : 'Top 10 in $_genre',
            autofocusFirst: featured == null,
            entries: [for (var i = 0; i < top.length; i++) entry(top[i], rank: i + 1)],
          ),
          if (_genre == null) ...[
            Loader<List<JfItem>>(
              deps: 'tv-all-$_sort',
              load: () => jf.items(types: [_type], sortBy: s.sortBy, sortOrder: s.order, filters: s.filters, limit: 30),
              builder: (context, items) => PosterRow(title: s.label, entries: [for (final it in items) entry(it)]),
            ),
            for (final g in (_genres ?? const <String>[]).take(14))
              Loader<List<JfItem>>(
                deps: 'tv-$g-$_sort',
                load: () => jf.items(
                  types: [_type],
                  genre: g,
                  sortBy: s.sortBy,
                  sortOrder: s.order,
                  filters: s.filters,
                  limit: 24,
                ),
                builder: (context, items) => PosterRow(title: g, entries: [for (final it in items) entry(it)]),
              ),
          ] else
            Loader<List<JfItem>>(
              deps: 'tv-$_genre-$_sort-all',
              load: () => jf.items(
                types: [_type],
                genre: _genre,
                sortBy: s.sortBy,
                sortOrder: s.order,
                filters: s.filters,
                limit: 300,
              ),
              builder: (context, items) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < items.length; i += 12)
                    PosterRow(
                      title: i == 0 ? 'All $_genre · ${s.label}' : '',
                      entries: [for (final it in items.skip(i).take(12)) entry(it)],
                    ),
                ],
              ),
            ),
        ];
        return Billboard(
          key: ValueKey('$_genre-$_sort'),
          header: header,
          featured: featured == null ? null : entry(featured),
          actions: featured == null
              ? const []
              : [
                  PillButton(
                    label: featured.progress != null ? 'Resume' : 'Play',
                    icon: Icons.play_arrow_rounded,
                    autofocus: app.isTv,
                    scrollIntoView: false,
                    onTap: () => featured.isSeries ? playSeries(context, jf, featured) : play(context, featured),
                  ),
                  PillButton(
                    label: 'More Info',
                    icon: Icons.info_outline,
                    scrollIntoView: false,
                    onTap: () => openItem(context, featured),
                  ),
                ],
          rows: rows,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (!app.isPhone) return _tvBuild(context, app);
    final jf = app.jf!;
    final pad = context.px(gutter(context));
    final s = _sorts[_sort];
    final title = widget.kind == LibraryKind.movies ? 'Movies' : 'Shows';

    final header = Padding(
      padding: EdgeInsets.fromLTRB(pad, context.px(app.isPhone ? 30 : 60), pad, context.px(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: context.px(28),
            children: [
              Text(title, style: display(context.px(72))),
              if (_count != null)
                Padding(
                  padding: EdgeInsets.only(bottom: context.px(10)),
                  child: Text('$_count in your library', style: body(context.px(24), color: C.faint)),
                ),
            ],
          ),
          SizedBox(height: context.px(28)),
          FocusTraversalGroup(
            child: Wrap(
              spacing: context.px(12),
              runSpacing: context.px(12),
              children: [
                Chip2(label: 'All genres', selected: _genre == null, onTap: () => setState(() => _genre = null)),
                for (final g in _genres ?? const <String>[])
                  Chip2(label: g, selected: _genre == g, onTap: () => setState(() => _genre = g)),
                Chip2(
                  label: 'Sort: ${s.label}',
                  selected: false,
                  onTap: () => pickOption<int>(
                    context,
                    'Sort by',
                    {for (var i = 0; i < _sorts.length; i++) i: _sorts[i].label},
                    _sort,
                    (v) => setState(() => _sort = v),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final top10 = Loader<List<JfItem>>(
      deps: 'top-$_genre',
      load: () =>
          jf.items(types: [_type], genre: _genre, sortBy: 'CommunityRating', sortOrder: 'Descending', limit: 10),
      builder: (context, items) => MediaRow(
        title: _genre == null ? 'Top 10 rated on your server' : 'Top 10 rated in $_genre',
        tileHeight: 300,
        children: [
          for (var i = 0; i < items.length; i++) _TopTile(rank: i + 1, item: items[i], jf: jf),
        ],
      ),
    );

    final List<Widget> rows;
    if (_genre == null) {
      rows = [
        top10,
        Loader<List<JfItem>>(
          deps: 'all-$_sort',
          load: () => jf.items(types: [_type], sortBy: s.sortBy, sortOrder: s.order, filters: s.filters, limit: 30),
          builder: (context, items) => MediaRow(
            title: s.label,
            tileHeight: 216,
            children: [for (final it in items) _tile(context, jf, it)],
          ),
        ),
        for (final g in (_genres ?? const <String>[]).take(14))
          Loader<List<JfItem>>(
            deps: '$g-$_sort',
            load: () =>
                jf.items(types: [_type], genre: g, sortBy: s.sortBy, sortOrder: s.order, filters: s.filters, limit: 24),
            builder: (context, items) => MediaRow(
              title: g,
              tileHeight: 216,
              children: [for (final it in items) _tile(context, jf, it)],
            ),
          ),
      ];
    } else {
      rows = [
        top10,
        Loader<List<JfItem>>(
          deps: '$_genre-$_sort-grid',
          load: () => jf.items(
            types: [_type],
            genre: _genre,
            sortBy: s.sortBy,
            sortOrder: s.order,
            filters: s.filters,
            limit: 300,
          ),
          builder: (context, items) => Padding(
            padding: EdgeInsets.fromLTRB(pad, context.px(10), pad, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('All $_genre', style: body(context.px(30), weight: FontWeight.w700)),
                SizedBox(height: context.px(24)),
                Wrap(
                  spacing: context.px(24),
                  runSpacing: context.px(30),
                  children: [
                    for (final it in items) _tile(context, jf, it, width: app.isPhone ? 420 : 384),
                  ],
                ),
              ],
            ),
          ),
        ),
      ];
    }

    return ListView(
      scrollCacheExtent: const ScrollCacheExtent.pixels(3000),
      padding: EdgeInsets.only(bottom: context.px(80)),
      children: [
        header,
        SizedBox(height: context.px(20)),
        ...rows,
      ],
    );
  }
}

/// Netflix-style Top 10 tile: a big outlined number beside the poster.
class _TopTile extends StatelessWidget {
  final int rank;
  final JfItem item;
  final JellyfinClient jf;
  const _TopTile({required this.rank, required this.item, required this.jf});

  @override
  Widget build(BuildContext context) {
    final h = context.px(300);
    return Focusable(
      onTap: () => openItem(context, item),
      semanticLabel: 'Number $rank, ${item.name}',
      builder: (context, active) => AnimatedScale(
        scale: active ? 1.06 : 1,
        duration: const Duration(milliseconds: 180),
        child: SizedBox(
          width: context.px(rank >= 10 ? 400 : 330),
          height: h,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                bottom: -context.px(30),
                child: Text(
                  '$rank',
                  style: display(context.px(260), height: 1).copyWith(
                    letterSpacing: -context.px(14),
                    foreground: Paint()
                      ..style = PaintingStyle.stroke
                      ..strokeWidth = context.px(4)
                      ..color = const Color(0xFF6E6A64),
                  ),
                ),
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: context.px(200),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(context.px(10)),
                    border: Border.all(color: active ? C.text : Colors.transparent, width: context.px(4)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(context.px(8)),
                    child: NetImage(jf.posterImage(item), fallback: TitleCard(item.name)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
