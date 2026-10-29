import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:provider/provider.dart';

import '../api/jellyfin.dart';
import '../api/seerr.dart';
import '../state/app_state.dart';
import '../ui/browse.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'home.dart';
import 'nav.dart';
import 'preview.dart';

class _Details {
  late JfItem item;
  List<JfItem> seasons = [];
  List<JfItem> similar = [];
  List<JfItem> localTrailers = [];
  List<JfItem> extras = [];
  JfItem? nextEpisode; // series: what Play will start
  SeerrMedia? seerr; // series: for seasons missing from the server
}

/// Details for a movie or series in the library, laid out as in the design:
/// movies get tabs under the header; series get seasons on the left and episodes on the right.
class DetailsScreen extends StatefulWidget {
  final String itemId;
  final String? seasonId;
  const DetailsScreen({super.key, required this.itemId, this.seasonId});
  @override
  State<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends State<DetailsScreen> {
  int _reload = 0;

  Future<_Details> _load(AppState app) async {
    final jf = app.jf!;
    final d = _Details()..item = await jf.item(widget.itemId);
    final it = d.item;
    final r = await Future.wait<Object?>([
      it.isSeries ? jf.seasons(it.id).catchError((_) => <JfItem>[]) : Future.value(<JfItem>[]),
      jf.similar(it.id).catchError((_) => <JfItem>[]),
      it.localTrailerCount > 0 ? jf.localTrailers(it.id) : Future.value(<JfItem>[]),
      jf.specialFeatures(it.id),
      it.isSeries ? _nextEpisode(jf, it) : Future.value(null),
    ]);
    d.seasons = (r[0] as List<JfItem>).where((s) => (s.indexNumber ?? 0) > 0 || (r[0] as List<JfItem>).length == 1).toList();
    d.similar = r[1] as List<JfItem>;
    d.localTrailers = r[2] as List<JfItem>;
    d.extras = r[3] as List<JfItem>;
    d.nextEpisode = r[4] as JfItem?;
    if (it.isSeries && app.seerrConfigured && it.tmdbId != null) {
      try {
        d.seerr = await app.seerr!.details('tv', int.parse(it.tmdbId!));
      } catch (_) {}
    }
    // Have the title logo and backdrop ready so the page appears whole.
    prefetchTrailer(app, it);
    warmPlayback(app);
    if (mounted) await warmImages(context, [jf.logoImage(it), jf.backdropImage(it)]);
    return d;
  }

  static Future<JfItem?> _nextEpisode(JellyfinClient jf, JfItem series) async {
    try {
      for (final e in await jf.nextUp(limit: 50)) {
        if (e.seriesId == series.id) return e;
      }
      final all = await jf.episodes(series.id, limit: 1);
      return all.isEmpty ? null : all.first;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      body: Loader<_Details>(
        deps: '${app.revision}-$_reload',
        load: () => _load(app),
        placeholder: const TitlePageSkeleton(),
        builder: (context, d) => _DetailsBody(d: d, initialSeasonId: widget.seasonId, onChanged: () => setState(() => _reload++)),
      ),
    );
  }
}

class _DetailsBody extends StatefulWidget {
  final _Details d;
  final String? initialSeasonId;
  final VoidCallback onChanged;
  const _DetailsBody({required this.d, required this.onChanged, this.initialSeasonId});
  @override
  State<_DetailsBody> createState() => _DetailsBodyState();
}

/// What the right-hand side of a series page shows.
enum _Pane { episodes, missing, similar, cast }

class _DetailsBodyState extends State<_DetailsBody> {
  int _tab = 0;
  String? _seasonId;
  int? _missingSeason;
  _Pane _pane = _Pane.episodes;

  @override
  void initState() {
    super.initState();
    final seasons = widget.d.seasons;
    final next = widget.d.nextEpisode;
    if (seasons.isNotEmpty) {
      _seasonId = widget.initialSeasonId ??
          (next?.seasonId != null && seasons.any((s) => s.id == next!.seasonId) ? next!.seasonId : seasons.first.id);
    }
  }

  List<int> get _missing {
    final s = widget.d.seerr;
    if (s == null) return [];
    final have = widget.d.seasons.map((x) => x.indexNumber).whereType<int>().toSet();
    return s.seasons.map((x) => (x['seasonNumber'] as num).toInt()).where((n) => !have.contains(n)).toList();
  }

  Future<void> _trailer() async {
    final d = widget.d;
    if (d.localTrailers.isNotEmpty) {
      await play(context, d.localTrailers.first, fromStart: true, isTrailer: true);
      return;
    }
    await playTrailer(context, item: d.item, title: d.item.name);
  }

  Future<void> _request4k() async {
    final app = context.read<AppState>();
    final tmdb = widget.d.item.tmdbId;
    if (tmdb == null) return;
    try {
      final m = await app.seerr!.details('movie', int.parse(tmdb));
      if (mounted) await showRequestDialog(context, m, uhd: true);
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final d = widget.d;
    if (!app.isPhone) return _tvPage(context, app);
    return ListView(scrollCacheExtent: const ScrollCacheExtent.pixels(4000), padding: EdgeInsets.zero, children: [
      _header(context, app),
      SizedBox(height: context.px(10)),
      if (d.item.isSeries) _seriesBody(context, app) else _movieBody(context, app),
      SizedBox(height: context.px(80)),
    ]);
  }

  // ------------------------------------------------------------------ TV / desktop

  /// Text and a list of actions on the left, the backdrop on the right fading into black;
  /// More Like This and extras further down.
  Widget _tvPage(BuildContext context, AppState app) {
    final jf = app.jf!;
    final d = widget.d;
    final it = d.item;
    final size = MediaQuery.sizeOf(context);
    final logo = jf.logoImage(it);
    final next = d.nextEpisode;
    final hasTrailer = d.localTrailers.isNotEmpty || it.remoteTrailers.isNotEmpty;
    final cast = it.people.where((p) => p['Type'] == 'Actor').take(3).map((p) => p['Name']).join(', ');
    final is4k = FormatInfo.fromStreams(it.mediaStreams).badges.contains('4K');
    final resume = it.isSeries ? next?.progress : it.progress;
    final epLabel = next == null
        ? ''
        : (next.parentIndexNumber != null && next.indexNumber != null)
            ? ' Season ${next.parentIndexNumber}: Episode ${next.indexNumber}'
            : ' ${next.episodeLabel}';
    final playLabel = it.isSeries ? '${resume != null ? 'Resume' : 'Play'}$epLabel' : (resume != null ? 'Resume playing' : 'Play');
    final meta = [
      if (it.year != null) '${it.year}',
      if (it.genres.isNotEmpty) it.genres.first,
      if (it.isSeries && it.childCount != null) '${it.childCount} Season${it.childCount == 1 ? '' : 's'}',
      if (it.isMovie && it.runtime != null) formatRuntime(it.runtime),
    ];
    final badges = [...FormatInfo.fromStreams(it.mediaStreams).badges.take(3)];

    final header = SizedBox(
      height: size.height,
      child: Stack(children: [
        Positioned(
          right: 0,
          top: 0,
          width: size.width * 0.64,
          height: size.height * 0.64,
          child: Stack(fit: StackFit.expand, children: [
            NetImage(jf.backdropImage(it), alignment: Alignment.topCenter),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [C.bg, Color(0x990A0A0B), Color(0x000A0A0B)], stops: [0, 0.22, 0.5]),
              ),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [C.bg, Color(0x000A0A0B)], stops: [0, 0.35]),
              ),
            ),
          ]),
        ),
        if (!app.isTv) Positioned(left: context.px(36), top: context.px(40), child: BackArrow(onTap: () => Navigator.pop(context))),
        Positioned(
          left: context.px(80),
          top: context.px(80),
          width: context.px(660),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (logo != null)
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: context.px(140), maxWidth: context.px(480)),
                child: NetImage(logo,
                    fit: BoxFit.contain,
                    alignment: Alignment.centerLeft,
                    loading: SizedBox(height: context.px(120)),
                    fallback: Text(it.name, style: display(context.px(68)))),
              )
            else
              Text(it.name, maxLines: 2, style: display(context.px(68))),
            SizedBox(height: context.px(16)),
            Wrap(spacing: context.px(12), runSpacing: context.px(8), crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (final m in meta) Text(m, style: body(context.px(19), weight: FontWeight.w600)),
              for (final b in badges) Badge2(b),
              if (it.officialRating != null) Badge2(it.officialRating!),
            ]),
            if (it.overview != null) ...[
              SizedBox(height: context.px(14)),
              Text(it.overview!, maxLines: 4, overflow: TextOverflow.ellipsis, style: body(context.px(21), height: 1.35)),
            ],
            if (cast.isNotEmpty) ...[
              SizedBox(height: context.px(8)),
              Text('Cast: $cast', maxLines: 1, overflow: TextOverflow.ellipsis, style: body(context.px(17), color: C.muted)),
            ],
            SizedBox(height: context.px(26)),
            FocusTraversalGroup(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ActionItem(
                  label: playLabel,
                  icon: Icons.play_arrow_rounded,
                  autofocus: app.isTv,
                  progress: resume,
                  onTap: () => it.isSeries ? (next != null ? play(context, next) : playSeries(context, jf, it)) : play(context, it),
                ),
                if (it.isMovie && it.progress != null)
                  ActionItem(label: 'Play from beginning', icon: Icons.replay, onTap: () => play(context, it, fromStart: true)),
                if (it.isSeries)
                  ActionItem(
                    label: 'More episodes',
                    icon: Icons.video_library_outlined,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => _EpisodesPage(d: d, initialSeasonId: _seasonId, missing: _missing),
                    )),
                  ),
                if (hasTrailer) ActionItem(label: 'Play trailer', icon: Icons.movie_filter_outlined, onTap: _trailer),
                ActionItem(
                  label: it.isFavorite ? 'Remove from My List' : 'Add to My List',
                  icon: it.isFavorite ? Icons.close : Icons.add,
                  onTap: () async {
                    await jf.setFavorite(it.id, !it.isFavorite);
                    widget.onChanged();
                  },
                ),
                ActionItem(
                  label: it.played ? 'Mark as unwatched' : 'Mark as watched',
                  icon: it.played ? Icons.visibility_off_outlined : Icons.check_circle_outline,
                  onTap: () async {
                    await jf.setPlayed(it.id, !it.played);
                    widget.onChanged();
                  },
                ),
                if (it.isMovie && app.seerrConfigured && !is4k && it.tmdbId != null)
                  ActionItem(label: 'Request in 4K', icon: Icons.download_outlined, onTap: _request4k),
              ]),
            ),
          ]),
        ),
      ]),
    );

    final extras = <Widget>[
      for (final t in d.localTrailers)
        _ExtraTile(
            title: t.name.isEmpty ? 'Trailer' : t.name,
            meta: 'Trailer · ${formatRuntime(t.runtime)}',
            imageUrl: jf.landscapeImage(t) ?? jf.backdropImage(it),
            onTap: () => play(context, t, fromStart: true, isTrailer: true)),
      for (final x in d.extras)
        _ExtraTile(
            title: x.name,
            meta: formatRuntime(x.runtime),
            imageUrl: jf.landscapeImage(x) ?? jf.backdropImage(it),
            onTap: () => play(context, x, fromStart: true, isTrailer: true)),
    ];
    return ListView(scrollCacheExtent: const ScrollCacheExtent.pixels(3000), padding: EdgeInsets.zero, children: [
      header,
      PosterRow(
        title: 'More Like This',
        entries: [for (final s in d.similar) posterEntry(context, jf, s, onTap: () => openItem(context, s))],
      ),
      if (extras.isNotEmpty) MediaRow(title: 'Trailers & Extras', tileHeight: 191, inset: 60, children: extras),
      if (it.people.isNotEmpty)
        MediaRow(title: 'Cast & Crew', tileHeight: 260, inset: 60, children: [
          for (final p in it.people.take(30)) _PersonTile(person: p, imageUrl: jf.personImage(p)),
        ]),
      SizedBox(height: context.px(200)),
    ]);
  }

  // ------------------------------------------------------------------ header

  Widget _header(BuildContext context, AppState app) {
    final jf = app.jf!;
    final d = widget.d;
    final it = d.item;
    final pad = context.px(app.isPhone ? 40 : 120);
    final size = MediaQuery.sizeOf(context);
    final hasTrailer = d.localTrailers.isNotEmpty || it.remoteTrailers.isNotEmpty;
    final cast = it.people.where((p) => p['Type'] == 'Actor').take(4).map((p) => p['Name']).join(', ');
    final directors = it.people.where((p) => p['Type'] == 'Director').map((p) => p['Name']).join(', ');
    final logo = jf.logoImage(it);
    final next = d.nextEpisode;
    final is4k = FormatInfo.fromStreams(it.mediaStreams).badges.contains('4K');

    final playLabel = it.isSeries
        ? (next == null ? 'Play' : '${next.progress != null ? 'Resume' : 'Play'} ${next.episodeLabel}')
        : (it.progress != null ? 'Resume' : 'Play');

    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: app.isPhone ? 0 : context.px(it.isSeries ? 560 : 700)),
      child: Stack(children: [
        Positioned.fill(child: NetImage(jf.backdropImage(it), alignment: Alignment.topRight)),
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [C.bg, Color(0xE60A0A0B), Color(0x1A0A0A0B)], stops: [0, 0.42, 0.8]),
            ),
          ),
        ),
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                  begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [C.bg, Color(0x000A0A0B)], stops: [0, 0.45]),
            ),
          ),
        ),
        if (!app.isTv)
          Positioned(
            left: context.px(app.isPhone ? 20 : 36),
            top: context.px(app.isPhone ? 20 : 56),
            child: BackArrow(onTap: () => Navigator.pop(context)),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(pad, context.px(app.isPhone ? 100 : 80), pad, context.px(30)),
          child: SizedBox(
            width: app.isPhone ? size.width : context.px(1000),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (logo != null)
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: context.px(170), maxWidth: context.px(620)),
                  child: NetImage(logo,
                      fit: BoxFit.contain,
                      alignment: Alignment.centerLeft,
                      loading: SizedBox(height: context.px(150)),
                      fallback: Text(it.name, style: display(context.px(96)))),
                )
              else
                Text(it.name, style: display(context.px(app.isPhone ? 64 : 96))),
              SizedBox(height: context.px(22)),
              MetaLine(item: it),
              if (it.progress != null && it.isMovie) ...[
                SizedBox(height: context.px(18)),
                Row(children: [
                  SizedBox(
                    width: context.px(360),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(value: it.progress, minHeight: context.px(6), backgroundColor: C.surface3),
                    ),
                  ),
                  SizedBox(width: context.px(16)),
                  Text('${formatRuntime(it.runtime! - ticksToDuration(it.positionTicks))} remaining',
                      style: body(context.px(21), color: C.muted)),
                ]),
              ],
              SizedBox(height: context.px(26)),
              FocusTraversalGroup(
                child: Wrap(spacing: context.px(16), runSpacing: context.px(14), children: [
                  EmberButton(
                    label: playLabel,
                    icon: Icons.play_arrow_rounded,
                    kind: BtnKind.primary,
                    autofocus: app.isTv,
                    onTap: () => it.isSeries ? (next != null ? play(context, next) : playSeries(context, jf, it)) : play(context, it),
                  ),
                  if (it.progress != null && it.isMovie)
                    EmberButton(label: 'Start Over', icon: Icons.replay, onTap: () => play(context, it, fromStart: true)),
                  if (hasTrailer && it.isMovie) EmberButton(label: 'Trailer', icon: Icons.movie_filter_outlined, onTap: _trailer),
                  EmberButton(
                    label: it.isSeries ? (it.isFavorite ? 'In My List' : 'My List') : '',
                    icon: it.isFavorite ? Icons.check : Icons.add,
                    onTap: () async {
                      await jf.setFavorite(it.id, !it.isFavorite);
                      widget.onChanged();
                    },
                  ),
                  EmberButton(
                    label: '',
                    icon: it.played ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    onTap: () async {
                      await jf.setPlayed(it.id, !it.played);
                      widget.onChanged();
                    },
                  ),
                  if (hasTrailer && it.isSeries) EmberButton(label: '', icon: Icons.movie_filter_outlined, onTap: _trailer),
                  if (it.isMovie && app.seerrConfigured && !is4k && it.tmdbId != null)
                    EmberButton(label: 'Request 4K', icon: Icons.download_outlined, onTap: _request4k),
                ]),
              ),
              if (it.overview != null) ...[
                SizedBox(height: context.px(26)),
                Text(it.overview!,
                    maxLines: app.isPhone ? 6 : 4,
                    overflow: TextOverflow.ellipsis,
                    style: body(context.px(25), color: C.soft, height: 1.5)),
              ],
              SizedBox(height: context.px(14)),
              if (cast.isNotEmpty) _labelled(context, 'Starring', cast),
              if (directors.isNotEmpty) _labelled(context, 'Director', directors),
              if (_audioBadges(it).isNotEmpty) ...[
                SizedBox(height: context.px(14)),
                Wrap(spacing: context.px(10), runSpacing: context.px(8), children: [
                  for (final b in _audioBadges(it)) Badge2(b),
                ]),
              ],
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _labelled(BuildContext context, String label, String value) => Padding(
        padding: EdgeInsets.only(top: context.px(6)),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: '$label  ', style: body(context.px(21), color: C.muted)),
            TextSpan(text: value, style: body(context.px(21), color: C.faint)),
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );

  // ------------------------------------------------------------------ movie

  Widget _movieBody(BuildContext context, AppState app) {
    final jf = app.jf!;
    final d = widget.d;
    final it = d.item;
    final pad = context.px(app.isPhone ? 40 : 120);
    const tabs = ['More Like This', 'Trailers & Extras', 'Cast & Crew'];

    Widget content;
    switch (_tab) {
      case 0:
        content = d.similar.isEmpty
            ? _empty(context, 'Nothing similar on your server.')
            : MediaRow(title: '', tileHeight: 191, inset: app.isPhone ? 40 : 120, children: [
                for (final s in d.similar) MediaTile(title: s.name, imageUrl: jf.landscapeImage(s), width: 340, onTap: () => openItem(context, s)),
              ]);
        break;
      case 1:
        final tiles = <Widget>[
          for (final t in d.localTrailers)
            _ExtraTile(title: t.name.isEmpty ? 'Trailer' : t.name, meta: 'Trailer · ${formatRuntime(t.runtime)}', imageUrl: jf.landscapeImage(t) ?? jf.backdropImage(it), onTap: () => play(context, t, fromStart: true, isTrailer: true)),
          if (d.localTrailers.isEmpty && it.remoteTrailers.isNotEmpty)
            _ExtraTile(
              title: 'Official Trailer',
              meta: app.trailersInApp ? 'Plays here' : 'Opens in YouTube',
              imageUrl: jf.backdropImage(it, maxWidth: 640),
              onTap: _trailer,
            ),
          for (final x in d.extras)
            _ExtraTile(title: x.name, meta: formatRuntime(x.runtime), imageUrl: jf.landscapeImage(x) ?? jf.backdropImage(it), onTap: () => play(context, x, fromStart: true, isTrailer: true)),
        ];
        content = tiles.isEmpty ? _empty(context, 'No trailers or extras for this title.') : MediaRow(title: '', tileHeight: 191, inset: app.isPhone ? 40 : 120, children: tiles);
        break;
      default:
        content = MediaRow(title: '', tileHeight: 260, inset: app.isPhone ? 40 : 120, children: [
          for (final p in it.people.take(30)) _PersonTile(person: p, imageUrl: jf.personImage(p)),
        ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: EdgeInsets.symmetric(horizontal: pad),
        child: FocusTraversalGroup(
          child: Wrap(spacing: context.px(48), children: [
            for (var i = 0; i < tabs.length; i++) _Tab(label: tabs[i], selected: _tab == i, onTap: () => setState(() => _tab = i)),
          ]),
        ),
      ),
      SizedBox(height: context.px(16)),
      content,
    ]);
  }

  Widget _empty(BuildContext context, String text) => Padding(
        padding: EdgeInsets.symmetric(horizontal: context.px(120), vertical: context.px(20)),
        child: Text(text, style: body(context.px(23), color: C.faint)),
      );

  // ------------------------------------------------------------------ series

  Widget _seriesBody(BuildContext context, AppState app) {
    final jf = app.jf!;
    final d = widget.d;
    final pad = context.px(app.isPhone ? 40 : 120);
    final missing = _missing;

    String note(JfItem s) {
      final total = s.childCount;
      final unplayed = s.unplayedCount ?? 0;
      if (total == null || total == 0) return '';
      if (unplayed == 0) return 'Watched';
      if (unplayed == total) return '$total episodes';
      return '${total - unplayed} of $total';
    }

    final column = FocusTraversalGroup(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final s in d.seasons)
          _SideItem(
            label: s.name,
            note: note(s),
            selected: _pane == _Pane.episodes && _seasonId == s.id,
            onTap: () => setState(() {
              _seasonId = s.id;
              _pane = _Pane.episodes;
            }),
          ),
        for (final n in missing)
          _SideItem(
            label: 'Season $n',
            note: 'Request',
            accentNote: true,
            selected: _pane == _Pane.missing && _missingSeason == n,
            onTap: () => setState(() {
              _missingSeason = n;
              _pane = _Pane.missing;
            }),
          ),
        SizedBox(height: context.px(18)),
        _SideItem(label: 'More Like This', note: '', selected: _pane == _Pane.similar, onTap: () => setState(() => _pane = _Pane.similar)),
        _SideItem(label: 'Cast & Crew', note: '', selected: _pane == _Pane.cast, onTap: () => setState(() => _pane = _Pane.cast)),
      ]),
    );

    Widget pane;
    switch (_pane) {
      case _Pane.missing:
        final n = _missingSeason!;
        pane = Container(
          padding: EdgeInsets.all(context.px(40)),
          decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(context.px(16))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("Season $n isn't on your server yet", style: display(context.px(44))),
            SizedBox(height: context.px(16)),
            Text('Request it with Seerr and it will show up here, and in My List, once it has downloaded.',
                style: body(context.px(24), color: C.muted, height: 1.5)),
            SizedBox(height: context.px(24)),
            EmberButton(
              label: 'Request Season $n',
              icon: Icons.download_outlined,
              kind: BtnKind.primary,
              onTap: () => showRequestDialog(context, widget.d.seerr!, preselect: {n}),
            ),
          ]),
        );
        break;
      case _Pane.similar:
        pane = d.similar.isEmpty
            ? Text('Nothing similar on your server.', style: body(context.px(23), color: C.faint))
            : Wrap(spacing: context.px(24), runSpacing: context.px(28), children: [
                for (final s in d.similar) MediaTile(title: s.name, imageUrl: jf.landscapeImage(s), width: 340, onTap: () => openItem(context, s)),
              ]);
        break;
      case _Pane.cast:
        pane = Wrap(spacing: context.px(36), runSpacing: context.px(30), children: [
          for (final p in d.item.people.take(30)) _PersonTile(person: p, imageUrl: jf.personImage(p)),
        ]);
        break;
      case _Pane.episodes:
        pane = _seasonId == null
            ? Text('No episodes on the server yet.', style: body(context.px(23), color: C.faint))
            : Loader<List<JfItem>>(
                deps: _seasonId,
                load: () => jf.episodes(d.item.id, seasonId: _seasonId),
                builder: (context, eps) => Column(children: [
                  for (final e in eps) _EpisodeRow(ep: e, jf: jf, autofocus: false),
                ]),
              );
    }

    if (app.isPhone) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: pad),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [column, SizedBox(height: context.px(24)), pane]),
      );
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: pad),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: context.px(360), child: column),
        SizedBox(width: context.px(60)),
        Expanded(child: pane),
      ]),
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Tab({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => Focusable(
        onTap: onTap,
        semanticLabel: label,
        builder: (context, active) => Container(
          padding: EdgeInsets.only(bottom: context.px(10)),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: selected ? C.accent : Colors.transparent, width: context.px(4))),
          ),
          child: Text(label, style: body(context.px(28), weight: FontWeight.w700, color: selected || active ? C.text : C.faint)),
        ),
      );
}

/// A season (or other entry) in the left-hand list of a series page.
class _SideItem extends StatelessWidget {
  final String label;
  final String note;
  final bool selected;
  final bool accentNote;
  final VoidCallback onTap;
  const _SideItem({required this.label, required this.note, required this.selected, required this.onTap, this.accentNote = false});
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: context.px(8)),
        child: Focusable(
          onTap: onTap,
          semanticLabel: label,
          builder: (context, active) {
            final fg = active ? const Color(0xFF111111) : (selected ? C.text : C.faint);
            return Container(
              height: context.px(68),
              padding: EdgeInsets.symmetric(horizontal: context.px(24)),
              decoration: BoxDecoration(
                color: active ? C.text : (selected ? C.surface3 : Colors.transparent),
                borderRadius: BorderRadius.circular(context.px(12)),
              ),
              child: Row(children: [
                Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: body(context.px(26), weight: FontWeight.w700, color: fg))),
                if (note.isNotEmpty)
                  Text(note,
                      style: body(context.px(18),
                          weight: FontWeight.w600, color: active ? const Color(0xFF444444) : (accentNote ? C.accent : fg.withValues(alpha: 0.8)))),
              ]),
            );
          },
        ),
      );
}

/// A trailer or extra in the Trailers & Extras tab.
class _ExtraTile extends StatelessWidget {
  final String title;
  final String meta;
  final String? imageUrl;
  final VoidCallback onTap;
  const _ExtraTile({required this.title, required this.meta, required this.onTap, this.imageUrl});
  @override
  Widget build(BuildContext context) {
    final w = context.px(340), h = w * 9 / 16;
    return Focusable(
      onTap: onTap,
      semanticLabel: title,
      builder: (context, active) => AnimatedScale(
        scale: active ? 1.07 : 1,
        duration: const Duration(milliseconds: 180),
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(context.px(10)),
            border: Border.all(color: active ? C.text : Colors.transparent, width: context.px(4)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(context.px(8)),
            child: Stack(fit: StackFit.expand, children: [
              NetImage(imageUrl, fallback: TitleCard(title)),
              Container(color: const Color(0x66000000)),
              Center(
                child: Container(
                  width: context.px(64),
                  height: context.px(64),
                  decoration: const BoxDecoration(color: Color(0xB30A0A0B), shape: BoxShape.circle),
                  child: Icon(Icons.play_arrow_rounded, color: C.text, size: context.px(40)),
                ),
              ),
              Positioned(
                left: context.px(18),
                right: context.px(18),
                bottom: context.px(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: body(context.px(23), weight: FontWeight.w700)),
                  Text(meta, style: body(context.px(18), color: C.soft, weight: FontWeight.w600)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

List<String> _audioBadges(JfItem it) => FormatInfo.fromStreams(it.mediaStreams)
    .badges
    .where((x) => !const ['4K', 'HD', 'Dolby Vision', 'HDR10', 'HDR10+', 'HLG'].contains(x))
    .toList();

class _EpisodeRow extends StatelessWidget {
  final JfItem ep;
  final JellyfinClient jf;
  final bool autofocus;
  const _EpisodeRow({required this.ep, required this.jf, this.autofocus = false});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final thumbW = context.px(app.isPhone ? 260 : 300);
    return Focusable(
      autofocus: autofocus,
      onTap: () => play(context, ep),
      semanticLabel: '${ep.episodeLabel} ${ep.name}',
      builder: (context, active) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: EdgeInsets.only(bottom: context.px(6)),
        padding: EdgeInsets.all(context.px(16)),
        decoration: BoxDecoration(
          color: active ? C.surface2 : Colors.transparent,
          borderRadius: BorderRadius.circular(context.px(14)),
          border: Border.all(color: active ? C.text : Colors.transparent, width: context.px(3)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(context.px(10)),
            child: SizedBox(
              width: thumbW,
              height: thumbW * 9 / 16,
              child: Stack(fit: StackFit.expand, children: [
                NetImage(jf.landscapeImage(ep, maxWidth: 480), fallback: TitleCard(ep.name)),
                if (active) Center(child: Icon(Icons.play_circle_fill, color: Colors.white, size: context.px(64))),
                if (ep.progress != null || ep.played)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: context.px(6),
                    child: Container(
                      color: Colors.white24,
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(widthFactor: ep.played ? 1 : ep.progress, child: Container(color: C.accent)),
                    ),
                  ),
              ]),
            ),
          ),
          SizedBox(width: context.px(28)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text('${ep.indexNumber ?? ''}. ${ep.name}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: body(context.px(28), weight: FontWeight.w700)),
                ),
                Text(formatRuntime(ep.runtime), style: body(context.px(21), color: C.faint)),
              ]),
              SizedBox(height: context.px(10)),
              Text(ep.overview ?? '',
                  maxLines: app.isPhone ? 2 : 3,
                  overflow: TextOverflow.ellipsis,
                  style: body(context.px(21), color: C.muted, height: 1.45)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _PersonTile extends StatelessWidget {
  final Map<String, dynamic> person;
  final String? imageUrl;
  const _PersonTile({required this.person, this.imageUrl});
  @override
  Widget build(BuildContext context) {
    final name = person['Name'] as String? ?? '';
    final role = (person['Role'] as String?)?.isNotEmpty == true ? person['Role'] as String : (person['Type'] as String? ?? '');
    final s = context.px(150);
    return Focusable(
      semanticLabel: '$name, $role',
      onTap: () {},
      builder: (context, active) => AnimatedScale(
        scale: active ? 1.08 : 1,
        duration: const Duration(milliseconds: 160),
        child: SizedBox(
          width: context.px(170),
          child: Column(children: [
            Container(
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: active ? C.text : Colors.transparent, width: context.px(4))),
              child: ClipOval(
                child: SizedBox(
                  width: s,
                  height: s,
                  child: NetImage(imageUrl,
                      fallback: Container(
                          color: C.surface3,
                          alignment: Alignment.center,
                          child: Text(name.isEmpty ? '?' : name[0], style: display(context.px(56), height: 1)))),
                ),
              ),
            ),
            SizedBox(height: context.px(10)),
            Text(name, textAlign: TextAlign.center, maxLines: 2, style: body(context.px(20), weight: FontWeight.w700)),
            Text(role, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: body(context.px(18), color: C.faint)),
          ]),
        ),
      ),
    );
  }
}

/// "More episodes" on TV and desktop: the series and its seasons on the left, the season's
/// episodes as a list on the right.
class _EpisodesPage extends StatefulWidget {
  final _Details d;
  final String? initialSeasonId;
  final List<int> missing;
  const _EpisodesPage({required this.d, required this.missing, this.initialSeasonId});
  @override
  State<_EpisodesPage> createState() => _EpisodesPageState();
}

class _EpisodesPageState extends State<_EpisodesPage> {
  String? _seasonId;
  int? _missingSeason;

  @override
  void initState() {
    super.initState();
    _seasonId = widget.initialSeasonId ?? (widget.d.seasons.isEmpty ? null : widget.d.seasons.first.id);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final jf = app.jf!;
    final it = widget.d.item;
    final logo = jf.logoImage(it);
    final total = widget.d.seasons.fold<int>(0, (n, s) => n + (s.childCount ?? 0));

    Widget season(String label, String note, bool selected, VoidCallback onTap, {bool accent = false}) => Padding(
          padding: EdgeInsets.only(bottom: context.px(8)),
          child: Focusable(
            onTap: onTap,
            semanticLabel: label,
            builder: (context, active) {
              final fg = active ? const Color(0xFF111111) : (selected ? C.text : C.muted);
              return Container(
                height: context.px(48),
                padding: EdgeInsets.symmetric(horizontal: context.px(22)),
                decoration: BoxDecoration(
                  color: active ? C.text : (selected ? const Color(0xFF3A3A40) : Colors.transparent),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(children: [
                  Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: body(context.px(19), weight: FontWeight.w600, color: fg))),
                  if (note.isNotEmpty)
                    Text(note, style: body(context.px(16), color: active ? const Color(0xFF444444) : (accent ? C.accent : C.faint))),
                ]),
              );
            },
          ),
        );

    final left = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (logo != null)
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: context.px(110), maxWidth: context.px(400)),
          child: NetImage(logo, fit: BoxFit.contain, alignment: Alignment.centerLeft, fallback: Text(it.name, style: display(context.px(52)))),
        )
      else
        Text(it.name, maxLines: 2, style: display(context.px(52))),
      SizedBox(height: context.px(14)),
      MetaDots(parts: [if (it.year != null) '${it.year}', if (total > 0) '$total Episodes'], rating: it.officialRating, size: 20),
      SizedBox(height: context.px(40)),
      FocusTraversalGroup(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final s in widget.d.seasons)
            season(s.name, s.childCount == null ? '' : '${s.childCount} Episodes', _missingSeason == null && _seasonId == s.id,
                () => setState(() {
                      _seasonId = s.id;
                      _missingSeason = null;
                    })),
          for (final n in widget.missing)
            season('Season $n', 'Request', _missingSeason == n, () => setState(() => _missingSeason = n), accent: true),
        ]),
      ),
    ]);

    Widget right;
    if (_missingSeason != null) {
      final n = _missingSeason!;
      right = Padding(
        padding: EdgeInsets.only(top: context.px(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text("Season $n isn't on your server yet", style: display(context.px(44))),
          SizedBox(height: context.px(16)),
          Text('Request it and it will show up here once it has downloaded.', style: body(context.px(24), color: C.muted, height: 1.5)),
          SizedBox(height: context.px(24)),
          PillButton(
            label: 'Request Season $n',
            icon: Icons.download_outlined,
            onTap: () => showRequestDialog(context, widget.d.seerr!, preselect: {n}),
          ),
        ]),
      );
    } else if (_seasonId == null) {
      right = Text('No episodes on the server yet.', style: body(context.px(23), color: C.faint));
    } else {
      right = Loader<List<JfItem>>(
        deps: _seasonId,
        load: () => jf.episodes(it.id, seasonId: _seasonId),
        builder: (context, eps) => FocusTraversalGroup(
          child: ListView(
            padding: EdgeInsets.only(bottom: context.px(300)),
            children: [
              for (final e in eps)
                _EpisodeListItem(
                  ep: e,
                  jf: jf,
                  autofocus: app.isTv && e.id == (widget.d.nextEpisode?.id ?? eps.first.id),
                ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: Padding(
        padding: EdgeInsets.fromLTRB(context.px(80), context.px(80), context.px(80), 0),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: context.px(500), child: left),
          SizedBox(width: context.px(70)),
          Expanded(child: right),
        ]),
      ),
    );
  }
}

/// An episode on the episodes page: the still on the left with "S1: E3" on it, the title,
/// summary and length on the right.
class _EpisodeListItem extends StatelessWidget {
  final JfItem ep;
  final JellyfinClient jf;
  final bool autofocus;
  const _EpisodeListItem({required this.ep, required this.jf, this.autofocus = false});

  @override
  Widget build(BuildContext context) {
    final w = context.px(400);
    return Padding(
      padding: EdgeInsets.only(bottom: context.px(28)),
      child: Focusable(
        autofocus: autofocus,
        onTap: () => play(context, ep),
        semanticLabel: '${ep.episodeLabel} ${ep.name}',
        builder: (context, active) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: w,
            height: w * 9 / 16,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(context.px(12)),
              border: Border.all(color: active ? C.text : Colors.transparent, width: context.px(3)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(context.px(9)),
              child: Stack(fit: StackFit.expand, children: [
                NetImage(jf.landscapeImage(ep, maxWidth: 640), fallback: TitleCard(ep.name)),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                        begin: Alignment.bottomCenter, end: Alignment(0, 0.2), colors: [Color(0xAA000000), Color(0x00000000)]),
                  ),
                ),
                Positioned(
                  left: context.px(16),
                  bottom: context.px(14),
                  child: Text(ep.episodeLabel.replaceAll(' : ', ': '), style: body(context.px(22), weight: FontWeight.w700)),
                ),
                if (ep.progress != null || ep.played)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: context.px(6),
                    child: Container(
                      color: Colors.white24,
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(widthFactor: ep.played ? 1 : ep.progress, child: Container(color: C.accent)),
                    ),
                  ),
              ]),
            ),
          ),
          SizedBox(width: context.px(30)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(ep.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: body(context.px(25), weight: FontWeight.w700)),
              SizedBox(height: context.px(8)),
              Text(ep.overview ?? '',
                  maxLines: 4, overflow: TextOverflow.ellipsis, style: body(context.px(20), color: active ? C.text : C.soft, height: 1.35)),
              if (ep.runtime != null) ...[
                SizedBox(height: context.px(8)),
                Text('(${formatRuntime(ep.runtime)})', style: body(context.px(18), color: C.muted)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
