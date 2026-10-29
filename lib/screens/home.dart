import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:provider/provider.dart';

import '../api/jellyfin.dart';
import '../api/seerr.dart';
import '../player/hero_preview.dart';
import '../state/app_state.dart';
import '../ui/browse.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'nav.dart';
import 'shell.dart';

class _HomeData {
  JfItem? hero;
  List<JfItem> resume = [];
  List<JfItem> nextUp = [];
  List<(String, List<JfItem>)> latest = [];
  List<SeerrMedia> trending = [];
  List<JfItem> favorites = [];
}

class HomeScreen extends StatefulWidget {
  final ValueChanged<Section> onNavigate;
  const HomeScreen({super.key, required this.onNavigate});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// The hero preview plays only while the hero is on screen.
  final _heroActive = ValueNotifier<bool>(true);

  @override
  void dispose() {
    _heroActive.dispose();
    super.dispose();
  }

  void onNavigate(Section s) => widget.onNavigate(s);

  Future<_HomeData> _load(AppState app) async {
    final jf = app.jf!;
    final d = _HomeData();
    final views = await jf.views();
    final results = await Future.wait<Object?>([
      jf.resume().catchError((_) => <JfItem>[]),
      jf.nextUp().catchError((_) => <JfItem>[]),
      jf.favorites().catchError((_) => <JfItem>[]),
      if (app.seerrConfigured && app.showTrendingRow)
        app.seerr!.trending().catchError((_) => <SeerrMedia>[])
      else
        Future.value(<SeerrMedia>[]),
    ]);
    d.resume = results[0] as List<JfItem>;
    d.nextUp = (results[1] as List<JfItem>).where((n) => !d.resume.any((r) => r.id == n.id)).toList();
    d.favorites = results[2] as List<JfItem>;
    d.trending = (results[3] as List<SeerrMedia>).where((m) => !m.isAvailable).toList();

    final libs = views.where((v) => v.collectionType == 'movies' || v.collectionType == 'tvshows').toList();
    final latest = await Future.wait(libs.map((v) => jf.latest(parentId: v.id).catchError((_) => <JfItem>[])));
    for (var i = 0; i < libs.length; i++) {
      if (latest[i].isNotEmpty) d.latest.add(('Recently added in ${libs[i].name}', latest[i]));
    }

    // Hero: a recent movie or series that has a backdrop.
    final pool = <JfItem>[
      for (final l in d.latest) ...l.$2.where((i) => (i.isMovie || i.isSeries) && i.backdropTags.isNotEmpty),
    ];
    if (pool.isNotEmpty) {
      final pick = pool[Random().nextInt(min(pool.length, 8))];
      // Full details carry the file's formats (4K, HDR…) for the badge.
      d.hero = await jf.item(pick.id).catchError((_) => pick);
      if (mounted) await warmImages(context, [jf.logoImage(d.hero!), jf.backdropImage(d.hero!)]);
    }
    return d;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Loader<_HomeData>(
      deps: app.revision,
      load: () => _load(app),
      builder: (context, d) {
        final jf = app.jf!;
        if (!app.isPhone) return _tvHome(context, app, d);
        final rows = <Widget>[
          if (d.hero != null) _Hero(item: d.hero!, jf: jf, active: _heroActive) else SizedBox(height: context.px(60)),
          if (app.isPhone)
            Padding(
              padding: EdgeInsets.fromLTRB(context.px(40), 0, context.px(40), context.px(24)),
              child: Wrap(spacing: context.px(14), children: [
                Chip2(label: 'Shows', selected: false, onTap: () => onNavigate(Section.shows)),
                Chip2(label: 'Movies', selected: false, onTap: () => onNavigate(Section.movies)),
              ]),
            ),
          MediaRow(
            title: 'Continue Watching',
            tileHeight: 216,
            children: [
              for (final it in d.resume)
                MediaTile(
                  title: it.isEpisode ? (it.seriesName ?? it.name) : it.name,
                  subtitle: it.isEpisode ? it.episodeLabel : _left(it),
                  imageUrl: jf.landscapeImage(it),
                  progress: it.progress,
                  autofocus: d.hero == null && it == d.resume.first,
                  onTap: () => play(context, it),
                ),
            ],
          ),
          MediaRow(
            title: 'Next Up',
            tileHeight: 216,
            children: [
              for (final it in d.nextUp)
                MediaTile(
                  title: it.seriesName ?? it.name,
                  subtitle: it.episodeLabel,
                  imageUrl: jf.landscapeImage(it),
                  onTap: () => play(context, it),
                ),
            ],
          ),
          if (d.trending.isNotEmpty)
            MediaRow(
              title: 'Trending — not in your library yet',
              tileHeight: 216,
              children: [
                for (final m in d.trending)
                  MediaTile(
                    title: m.title,
                    imageUrl: m.backdropUrl,
                    badge: m.isRequested ? 'Requested' : 'Not on server',
                    badgeAlt: m.isRequested,
                    onTap: () => openSeerr(context, m),
                  ),
              ],
            ),
          for (final (title, items) in d.latest)
            MediaRow(
              title: title,
              tileHeight: 216,
              children: [
                for (final it in items)
                  MediaTile(
                    title: it.isEpisode ? (it.seriesName ?? it.name) : it.name,
                    subtitle: it.isEpisode ? it.episodeLabel : null,
                    imageUrl: jf.landscapeImage(it),
                    onTap: () => openItem(context, it),
                  ),
              ],
            ),
          MediaRow(
            title: 'My List',
            tileHeight: 216,
            children: [
              for (final it in d.favorites)
                MediaTile(title: it.name, imageUrl: jf.landscapeImage(it), onTap: () => openItem(context, it)),
            ],
          ),
          SizedBox(height: context.px(80)),
        ];
        if (d.hero == null && d.resume.isEmpty && d.latest.isEmpty) {
          return Center(
            child: Text('Your library is empty. Add some movies or shows to Jellyfin to see them here.',
                style: body(context.px(26), color: C.muted)),
          );
        }
        return NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.axis == Axis.vertical) _heroActive.value = n.metrics.pixels < context.px(350);
            return false;
          },
          child: ListView(scrollCacheExtent: const ScrollCacheExtent.pixels(4000), padding: EdgeInsets.zero, children: rows),
        );
      },
    );
  }

  /// TV and desktop: a billboard. The featured title (or the one in focus) fills the top of the
  /// screen, with the rows underneath.
  Widget _tvHome(BuildContext context, AppState app, _HomeData d) {
    final jf = app.jf!;
    if (d.hero == null && d.resume.isEmpty && d.latest.isEmpty) {
      return Center(
        child: Text('Your library is empty. Add some movies or shows to Jellyfin to see them here.',
            style: body(context.px(26), color: C.muted)),
      );
    }
    final hero = d.hero;
    final rows = <Widget>[
      PosterRow(
        title: 'Continue Watching',
        autofocusFirst: hero == null,
        entries: [for (final it in d.resume) posterEntry(context, jf, it, onTap: () => play(context, it), resume: true)],
      ),
      PosterRow(
        title: 'Next Up',
        entries: [for (final it in d.nextUp) posterEntry(context, jf, it, onTap: () => play(context, it), resume: true)],
      ),
      if (d.trending.isNotEmpty)
        PosterRow(
          title: 'Trending — not in your library yet',
          entries: [
            for (final m in d.trending)
              PosterEntry(
                title: m.title,
                poster: m.posterUrl,
                wide: m.backdropUrl,
                backdrop: m.backdropUrl,
                badge: m.isRequested ? 'Requested' : null,
                badgeAlt: true,
                overview: m.overview,
                meta: [if (m.year != null) '${m.year}'],
                onTap: () => openSeerr(context, m),
              ),
          ],
        ),
      for (final (title, items) in d.latest)
        PosterRow(title: title, entries: [for (final it in items) posterEntry(context, jf, it, onTap: () => openItem(context, it))]),
      PosterRow(title: 'My List', entries: [for (final it in d.favorites) posterEntry(context, jf, it, onTap: () => openItem(context, it))]),
    ];
    return Billboard(
      featured: hero == null ? null : posterEntry(context, jf, hero, onTap: () => openItem(context, hero)),
      preview: hero == null ? null : (active) => HeroPreview(item: hero, active: active, overlay: const SizedBox.shrink()),
      actions: hero == null
          ? const []
          : [
              PillButton(
                label: hero.progress != null ? 'Resume' : 'Play',
                icon: Icons.play_arrow_rounded,
                autofocus: app.isTv,
                scrollIntoView: false,
                onTap: () => hero.isSeries ? playSeries(context, jf, hero) : play(context, hero),
              ),
              PillButton(label: 'More Info', icon: Icons.info_outline, scrollIntoView: false, onTap: () => openItem(context, hero)),
            ],
      rows: rows,
    );
  }

  static String? _left(JfItem it) {
    final rt = it.runtime;
    if (rt == null || it.positionTicks == 0) return null;
    final left = rt - ticksToDuration(it.positionTicks);
    return '${formatRuntime(left)} left';
  }
}

class _Hero extends StatelessWidget {
  final JfItem item;
  final JellyfinClient jf;
  final ValueListenable<bool> active;
  const _Hero({required this.item, required this.jf, required this.active});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final size = MediaQuery.sizeOf(context);
    final h = app.isPhone ? size.width * 0.9 : context.px(700);
    final logo = jf.logoImage(item);
    final pad = context.px(gutter(context));
    return SizedBox(
      height: h,
      child: Stack(fit: StackFit.expand, children: [
        NetImage(jf.backdropImage(item), alignment: Alignment.topCenter),
        HeroPreview(
          item: item,
          active: active,
          overlay: const Stack(fit: StackFit.expand, children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [C.bg, Color(0xD90A0A0B), Color(0x000A0A0B)], stops: [0, 0.38, 0.75]),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [C.bg, Color(0x000A0A0B)], stops: [0, 0.4]),
              ),
            ),
          ]),
        ),
        Positioned(
          left: pad,
          bottom: context.px(app.isPhone ? 30 : 70),
          width: app.isPhone ? size.width - pad * 2 : context.px(860),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(item.isSeries ? 'SERIES · NEW IN YOUR LIBRARY' : 'FILM · NEW IN YOUR LIBRARY',
                style: body(context.px(20), color: C.accent, weight: FontWeight.w700).copyWith(letterSpacing: context.px(4))),
            SizedBox(height: context.px(16)),
            if (logo != null)
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: context.px(180), maxWidth: context.px(640)),
                child: NetImage(logo,
                    fit: BoxFit.contain,
                    alignment: Alignment.centerLeft,
                    loading: SizedBox(height: context.px(160)),
                    fallback: Text(item.name, style: display(context.px(104)))),
              )
            else
              Text(item.name, maxLines: 2, style: display(context.px(app.isPhone ? 72 : 104))),
            SizedBox(height: context.px(18)),
            _MetaLine(item: item),
            if (!app.isPhone && item.overview != null) ...[
              SizedBox(height: context.px(18)),
              Text(item.overview!,
                  maxLines: 3, overflow: TextOverflow.ellipsis, style: body(context.px(25), color: C.soft, height: 1.45)),
            ],
            SizedBox(height: context.px(28)),
            Wrap(spacing: context.px(18), runSpacing: context.px(12), children: [
              EmberButton(
                label: item.progress != null ? 'Resume' : 'Play',
                icon: Icons.play_arrow_rounded,
                kind: BtnKind.primary,
                autofocus: app.isTv,
                onTap: () => item.isSeries ? playSeries(context, jf, item) : play(context, item),
              ),
              EmberButton(label: 'More Info', icon: Icons.info_outline, onTap: () => openItem(context, item)),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _MetaLine extends StatelessWidget {
  final JfItem item;
  const _MetaLine({required this.item});
  @override
  Widget build(BuildContext context) {
    final parts = <Widget>[
      if (item.communityRating != null)
        Text('★ ${item.communityRating!.toStringAsFixed(1)}', style: body(context.px(23), color: C.good, weight: FontWeight.w700)),
      if (item.year != null) Text('${item.year}', style: body(context.px(23), color: C.muted)),
      if (item.officialRating != null) Badge2(item.officialRating!),
      if (item.isMovie && item.runtime != null) Text(formatRuntime(item.runtime), style: body(context.px(23), color: C.muted)),
      if (item.isSeries && item.childCount != null)
        Text('${item.childCount} Season${item.childCount == 1 ? '' : 's'}', style: body(context.px(23), color: C.muted)),
      if (item.genres.isNotEmpty) Text(item.genres.take(2).join(' · '), style: body(context.px(23), color: C.muted)),
      if (_videoBadge(item) != null) Badge2(_videoBadge(item)!),
    ];
    return Wrap(spacing: context.px(18), runSpacing: context.px(8), crossAxisAlignment: WrapCrossAlignment.center, children: parts);
  }
}

/// "4K · HDR" style badge from the file's video stream, as in the design.
String? _videoBadge(JfItem item) {
  final b = FormatInfo.fromStreams(item.mediaStreams).badges;
  final video = b.where((x) => const ['4K', 'HD', 'Dolby Vision', 'HDR10', 'HDR10+', 'HLG'].contains(x)).take(2).toList();
  if (video.isEmpty) return null;
  return video.map((x) => x == 'HDR10' ? 'HDR' : x).join(' · ');
}

class MetaLine extends _MetaLine {
  const MetaLine({required super.item});
}

/// The poster-row entry for a library item. Episodes show their series' poster and logo, with
/// the episode and the time left underneath when focused ([resume]).
PosterEntry posterEntry(BuildContext context, JellyfinClient jf, JfItem it, {required VoidCallback onTap, bool resume = false}) {
  final left = _HomeScreenState._left(it);
  return PosterEntry(
    title: it.isEpisode ? (it.seriesName ?? it.name) : it.name,
    poster: jf.posterImage(it),
    wide: jf.landscapeImage(it, maxWidth: 960),
    logo: jf.logoImage(it, maxWidth: 600),
    progress: it.progress,
    subtitle: resume && it.isEpisode ? '${it.episodeLabel.replaceAll(' : ', ' ')} · ${it.name}' : null,
    note: resume ? left : null,
    meta: metaParts(it),
    rating: it.officialRating,
    overview: it.overview,
    backdrop: jf.backdropImage(it),
    onTap: onTap,
  );
}

/// "Series · Drama · 2026 · 5 Seasons" for a movie or series.
List<String> metaParts(JfItem it) => [
      if (it.isSeries) 'Series' else if (it.isMovie) 'Film',
      if (it.genres.isNotEmpty) it.genres.first,
      if (it.year != null) '${it.year}',
      if (it.isSeries && it.childCount != null) '${it.childCount} Season${it.childCount == 1 ? '' : 's'}',
      if (it.isMovie && it.runtime != null) formatRuntime(it.runtime),
      if (_videoBadge(it) != null) _videoBadge(it)!,
    ];
