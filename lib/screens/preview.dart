import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:provider/provider.dart';

import '../api/jellyfin.dart';
import '../api/seerr.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'nav.dart';
import 'requests.dart';

class _Preview {
  late SeerrMedia media;
  List<SeerrMedia> similar = [];
  JfItem? inLibrary;
}

/// A title that isn't on the server (from Seerr): look it over, watch the trailer, then request.
class PreviewScreen extends StatefulWidget {
  final String mediaType;
  final int tmdbId;
  const PreviewScreen({super.key, required this.mediaType, required this.tmdbId});
  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  int _tab = 0;
  int _reload = 0;
  bool? _onWatchlist;

  /// Adds the title to this person's Seerr watchlist (shown on My List), or takes it off.
  Future<void> _toggleWatchlist(SeerrMedia m) async {
    final seerr = context.read<AppState>().seerr!;
    final on = _onWatchlist ?? m.onWatchlist;
    setState(() => _onWatchlist = !on);
    try {
      on ? await seerr.removeFromWatchlist(m) : await seerr.addToWatchlist(m);
      if (mounted) toast(context, on ? 'Removed from your watchlist' : 'Added to your watchlist');
    } catch (_) {
      if (!mounted) return;
      setState(() => _onWatchlist = on);
      toast(context, 'Seerr couldn\'t change your watchlist. Try again in a moment.');
    }
  }

  Future<_Preview> _load(AppState app) async {
    final p = _Preview()..media = await app.seerr!.details(widget.mediaType, widget.tmdbId);
    // Seerr knows the Jellyfin item for titles it has seen on the server.
    final linked = p.media.mediaInfo?['jellyfinMediaId'] as String?;
    Future<JfItem?> inLibrary() async {
      if (linked != null && linked.isNotEmpty) {
        try {
          return await app.jf!.item(linked);
        } catch (_) {}
      }
      return app.jf!.findByTmdb('${widget.tmdbId}', widget.mediaType, title: p.media.title);
    }

    final r = await Future.wait<Object?>([
      app.seerr!.similar(widget.mediaType, widget.tmdbId).catchError((_) => <SeerrMedia>[]),
      inLibrary().catchError((_) => null),
    ]);
    p.similar = r[0] as List<SeerrMedia>;
    p.inLibrary = r[1] as JfItem?;
    if (mounted) await warmImages(context, [p.media.backdropUrl]);
    return p;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      body: Loader<_Preview>(
        deps: _reload,
        load: () => _load(app),
        placeholder: const TitlePageSkeleton(),
        builder: (context, p) => _body(context, app, p),
      ),
    );
  }

  Widget _body(BuildContext context, AppState app, _Preview p) {
    final m = p.media;
    final pad = context.px(app.isPhone ? 40 : 120);
    final size = MediaQuery.sizeOf(context);
    final trailer = m.bestTrailer;
    final cast = m.cast.take(4).map((c) => c['name']).join(', ');
    final creators = m.crew.where((c) => c['job'] == 'Director').map((c) => c['name']).take(2).join(', ');
    final statusText = switch (m.status) {
      MediaStatus.available => 'ON YOUR SERVER',
      MediaStatus.partiallyAvailable => 'PARTLY ON YOUR SERVER',
      MediaStatus.processing => 'DOWNLOADING',
      MediaStatus.pending => 'REQUESTED · WAITING FOR APPROVAL',
      _ => 'NOT ON YOUR SERVER',
    };
    final canRequest = m.status != MediaStatus.available && m.status != MediaStatus.processing && m.status != MediaStatus.pending;

    final tabs = [if (m.isTv) 'Seasons', 'Cast & Crew', 'More Like This'];
    if (_tab >= tabs.length) _tab = 0;

    Widget tabBody;
    switch (tabs[_tab]) {
      case 'Seasons':
        tabBody = Padding(
          padding: EdgeInsets.symmetric(horizontal: pad),
          child: Wrap(spacing: context.px(20), runSpacing: context.px(20), children: [
            for (final s in m.seasons)
              Focusable(
                onTap: canRequest || m.status == MediaStatus.partiallyAvailable
                    ? () => showRequestDialog(context, m, preselect: {(s['seasonNumber'] as num).toInt()}).then((_) => setState(() => _reload++))
                    : null,
                semanticLabel: s['name'] as String?,
                builder: (context, active) => AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: context.px(400),
                  padding: EdgeInsets.all(context.px(24)),
                  decoration: BoxDecoration(color: active ? C.text : C.surface, borderRadius: BorderRadius.circular(context.px(14))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s['name'] as String? ?? 'Season ${s['seasonNumber']}',
                        style: body(context.px(28), weight: FontWeight.w700, color: active ? const Color(0xFF111111) : C.text)),
                    SizedBox(height: context.px(8)),
                    Text('${s['episodeCount'] ?? '?'} episodes${s['airDate'] != null ? ' · ${(s['airDate'] as String).substring(0, 4)}' : ''}',
                        style: body(context.px(20), color: active ? const Color(0xFF444444) : C.faint)),
                    SizedBox(height: context.px(8)),
                    Text('Request this season', style: body(context.px(20), weight: FontWeight.w700, color: active ? const Color(0xFF111111) : C.accent)),
                  ]),
                ),
              ),
          ]),
        );
        break;
      case 'Cast & Crew':
        tabBody = MediaRow(inset: app.isPhone ? 40 : 120, title: '', tileHeight: 260, children: [
          for (final c in m.cast.take(24))
            _SeerrPerson(name: c['name'] as String? ?? '', role: c['character'] as String? ?? '', path: c['profilePath'] as String?),
        ]);
        break;
      default:
        tabBody = MediaRow(inset: app.isPhone ? 40 : 120, title: '', tileHeight: 191, children: [
          for (final s in p.similar)
            MediaTile(
              title: s.title,
              imageUrl: s.backdropUrl ?? s.posterUrl,
              width: 340,
              badge: s.isAvailable ? 'In your library' : (s.isRequested ? 'Requested' : 'Not on server'),
              badgeAlt: s.isAvailable || s.isRequested,
              onTap: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => PreviewScreen(mediaType: s.mediaType, tmdbId: s.id))),
            ),
        ]);
    }

    return ListView(scrollCacheExtent: const ScrollCacheExtent.pixels(4000), padding: EdgeInsets.zero, children: [
      ConstrainedBox(
        constraints: BoxConstraints(minHeight: app.isPhone ? 0 : context.px(700)),
        child: Stack(children: [
          Positioned.fill(child: NetImage(m.backdropUrl, alignment: Alignment.topRight)),
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
                Container(
                  padding: EdgeInsets.symmetric(horizontal: context.px(16), vertical: context.px(8)),
                  decoration: BoxDecoration(
                    border: Border.all(color: C.accent, width: context.px(2)),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(statusText,
                      style: body(context.px(18), color: const Color(0xFFFF9A5C), weight: FontWeight.w700).copyWith(letterSpacing: 2)),
                ),
                SizedBox(height: context.px(20)),
                Text(m.title, style: display(context.px(app.isPhone ? 64 : 96))),
                SizedBox(height: context.px(20)),
                Wrap(spacing: context.px(18), runSpacing: context.px(8), crossAxisAlignment: WrapCrossAlignment.center, children: [
                  if (m.voteAverage != null && m.voteAverage! > 0)
                    Text('${m.voteAverage!.toStringAsFixed(1)} TMDB', style: body(context.px(23), weight: FontWeight.w700)),
                  if (m.year != null) Text('${m.year}', style: body(context.px(23), color: C.muted)),
                  if (m.certification != null) Badge2(m.certification!),
                  if (m.isTv && m.numberOfSeasons != null)
                    Text('${m.numberOfSeasons} Season${m.numberOfSeasons == 1 ? '' : 's'}', style: body(context.px(23), color: C.muted)),
                  if (!m.isTv && m.runtime != null) Text(formatRuntime(Duration(minutes: m.runtime!)), style: body(context.px(23), color: C.muted)),
                  if (m.genres.isNotEmpty) Text(m.genres.take(2).join(' · '), style: body(context.px(23), color: C.muted)),
                ]),
                if (m.overview != null) ...[
                  SizedBox(height: context.px(22)),
                  Text(m.overview!,
                      maxLines: app.isPhone ? 6 : 4, overflow: TextOverflow.ellipsis, style: body(context.px(25), color: C.soft, height: 1.5)),
                ],
                SizedBox(height: context.px(12)),
                if (cast.isNotEmpty) Text('Starring  $cast', maxLines: 1, overflow: TextOverflow.ellipsis, style: body(context.px(21), color: C.faint)),
                if (creators.isNotEmpty) Text('Director  $creators', style: body(context.px(21), color: C.faint)),
                SizedBox(height: context.px(28)),
                FocusTraversalGroup(
                  child: Wrap(spacing: context.px(16), runSpacing: context.px(14), children: [
                    if (p.inLibrary != null)
                      EmberButton(
                        label: 'Open in library',
                        icon: Icons.play_arrow_rounded,
                        kind: BtnKind.primary,
                        autofocus: app.isTv,
                        onTap: () => openItem(context, p.inLibrary!),
                      ),
                    if (canRequest || m.status == MediaStatus.partiallyAvailable)
                      EmberButton(
                        label: m.status == MediaStatus.partiallyAvailable ? 'Request more' : 'Request',
                        icon: Icons.download_outlined,
                        kind: p.inLibrary == null ? BtnKind.primary : BtnKind.secondary,
                        autofocus: app.isTv && p.inLibrary == null,
                        onTap: () => showRequestDialog(context, m).then((_) => setState(() => _reload++)),
                      ),
                    if (!canRequest && m.status != MediaStatus.available)
                      EmberButton(
                        label: 'View requests',
                        icon: Icons.list_alt,
                        autofocus: app.isTv && p.inLibrary == null,
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const Scaffold(body: RequestsScreen()))),
                      ),
                    if (p.inLibrary == null)
                      EmberButton(
                        label: (_onWatchlist ?? m.onWatchlist) ? 'On Watchlist' : 'Watchlist',
                        icon: (_onWatchlist ?? m.onWatchlist) ? Icons.check : Icons.add,
                        onTap: () => _toggleWatchlist(m),
                      ),
                    if (trailer != null)
                      EmberButton(
                        label: 'Watch Trailer',
                        icon: Icons.movie_filter_outlined,
                        onTap: () => playTrailer(context, ytKey: trailer['key'] as String, title: m.title, backdropUrl: m.backdropUrl),
                      ),
                  ]),
                ),
                if (canRequest) ...[
                  SizedBox(height: context.px(14)),
                  Text('Nothing is requested until you choose Request and confirm.', style: body(context.px(20), color: C.faint)),
                ],
              ]),
            ),
          ),
        ]),
      ),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: pad),
        child: FocusTraversalGroup(
          child: Wrap(spacing: context.px(44), children: [
            for (var i = 0; i < tabs.length; i++)
              Focusable(
                onTap: () => setState(() => _tab = i),
                semanticLabel: tabs[i],
                builder: (context, active) => Container(
                  padding: EdgeInsets.only(bottom: context.px(10)),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: _tab == i ? C.accent : Colors.transparent, width: context.px(4))),
                  ),
                  child: Text(tabs[i], style: body(context.px(28), weight: FontWeight.w700, color: _tab == i || active ? C.text : C.faint)),
                ),
              ),
          ]),
        ),
      ),
      SizedBox(height: context.px(24)),
      tabBody,
      SizedBox(height: context.px(80)),
    ]);
  }
}

class _SeerrPerson extends StatelessWidget {
  final String name;
  final String role;
  final String? path;
  const _SeerrPerson({required this.name, required this.role, this.path});
  @override
  Widget build(BuildContext context) {
    final s = context.px(150);
    return Focusable(
      onTap: () {},
      semanticLabel: '$name, $role',
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
                  child: NetImage(SeerrMedia.image(path, size: 'w185'),
                      fallback: Container(color: C.surface3, alignment: Alignment.center, child: Text(name.isEmpty ? '?' : name[0], style: display(context.px(56), height: 1)))),
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

/// The request form: pick seasons (for series) and HD or 4K, then confirm.
Future<void> showRequestDialog(BuildContext context, SeerrMedia media, {Set<int>? preselect, bool uhd = false}) async {
  await showDialog(
    context: context,
    barrierColor: const Color(0xD0050506),
    builder: (_) => _RequestDialog(media: media, preselect: preselect, uhd: uhd),
  );
}

class _RequestDialog extends StatefulWidget {
  final SeerrMedia media;
  final Set<int>? preselect;
  final bool uhd;
  const _RequestDialog({required this.media, this.preselect, this.uhd = false});
  @override
  State<_RequestDialog> createState() => _RequestDialogState();
}

class _RequestDialogState extends State<_RequestDialog> {
  late Set<int> _seasons;
  late bool _uhd = widget.uhd;
  bool _busy = false;
  bool _done = false;
  bool _waitsForApproval = false;
  String? _error;

  List<int> get _available {
    // Seasons Seerr reports as already available/requested (in the chosen quality) can't be
    // requested again. Season 0 (specials) is left out unless it was asked for.
    final key = _uhd ? 'status4k' : 'status';
    final taken = <int>{};
    for (final s in (widget.media.mediaInfo?['seasons'] as List? ?? const [])) {
      final st = ((s as Map)[key] as num?)?.toInt() ?? 1;
      if (st >= 2) taken.add((s['seasonNumber'] as num).toInt());
    }
    return widget.media.seasons
        .map((s) => (s['seasonNumber'] as num).toInt())
        .where((n) => !taken.contains(n) && (n > 0 || (widget.preselect?.contains(0) ?? false)))
        .toList();
  }

  void _setQuality(bool uhd) => setState(() {
        _uhd = uhd;
        final open = _available.toSet();
        _seasons = _seasons.intersection(open);
        if (_seasons.isEmpty && widget.preselect == null) _seasons = open;
      });

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    if (_uhd && !app.canRequest4k(tv: widget.media.isTv)) _uhd = false;
    final open = _available.toSet();
    _seasons = widget.preselect?.intersection(open) ?? open;
  }

  Future<void> _submit() async {
    final app = context.read<AppState>();
    if (widget.media.isTv && _seasons.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sent = await app.seerr!.request(
        mediaType: widget.media.mediaType,
        tmdbId: widget.media.id,
        seasons: widget.media.isTv ? (_seasons.toList()..sort()) : null,
        is4k: _uhd,
      );
      app.bumpRevision();
      setState(() {
        _done = true;
        _waitsForApproval = sent?.status == 1;
      });
    } catch (e) {
      setState(() => _error = requestErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.media;
    final seasons = _available;
    final all = seasons.isNotEmpty && seasons.every(_seasons.contains);
    final count = _seasons.length;
    final label = m.isTv
        ? (count == 0 ? 'Choose a season' : 'Request $count season${count == 1 ? '' : 's'}${_uhd ? ' in 4K' : ''}')
        : 'Request${_uhd ? ' in 4K' : ''}';

    return Dialog(
      backgroundColor: C.surface,
      insetPadding: EdgeInsets.all(context.px(60)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(context.px(28))),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: context.px(1000), maxHeight: context.px(900)),
        child: Padding(
          padding: EdgeInsets.all(context.px(56)),
          child: _done
              ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: context.px(96),
                    height: context.px(96),
                    decoration: const BoxDecoration(color: C.accent, shape: BoxShape.circle),
                    child: Icon(Icons.check, color: C.accentInk, size: context.px(56)),
                  ),
                  SizedBox(height: context.px(26)),
                  Text('Requested', style: display(context.px(60))),
                  SizedBox(height: context.px(18)),
                  Text(
                      _waitsForApproval
                          ? "${m.title} is waiting for the server's owner to approve it. You'll find it under Requests, and in your library once it's downloaded."
                          : "${m.title} has been sent to Seerr. It will appear in your library once it's downloaded.",
                      style: body(context.px(25), color: C.muted, height: 1.5)),
                  SizedBox(height: context.px(36)),
                  EmberButton(label: 'Done', kind: BtnKind.accent, autofocus: true, onTap: () => Navigator.pop(context)),
                ])
              : SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('REQUEST WITH SEERR',
                        style: body(context.px(19), color: C.accent, weight: FontWeight.w700).copyWith(letterSpacing: 3)),
                    SizedBox(height: context.px(10)),
                    Text(m.title, style: display(context.px(54))),
                    SizedBox(height: context.px(28)),
                    if (m.isTv) ...[
                      Text('Seasons', style: body(context.px(22), color: C.muted, weight: FontWeight.w700)),
                      SizedBox(height: context.px(12)),
                      if (seasons.isEmpty)
                        Text('Every season is already on the server or requested.', style: body(context.px(22), color: C.faint))
                      else ...[
                        _CheckRow(
                          label: 'All seasons',
                          checked: all,
                          autofocus: true,
                          onTap: () => setState(() => _seasons = all ? {} : seasons.toSet()),
                        ),
                        for (final n in seasons)
                          _CheckRow(
                            label: 'Season $n',
                            checked: _seasons.contains(n),
                            onTap: () => setState(() => _seasons.contains(n) ? _seasons.remove(n) : _seasons.add(n)),
                          ),
                      ],
                      SizedBox(height: context.px(20)),
                    ],
                    if (context.read<AppState>().canRequest4k(tv: m.isTv)) ...[
                      Text('Quality', style: body(context.px(22), color: C.muted, weight: FontWeight.w700)),
                      SizedBox(height: context.px(12)),
                      Row(children: [
                        Chip2(label: 'HD', selected: !_uhd, onTap: () => _setQuality(false)),
                        SizedBox(width: context.px(12)),
                        Chip2(label: '4K', selected: _uhd, onTap: () => _setQuality(true)),
                      ]),
                    ],
                    if (_error != null) ...[
                      SizedBox(height: context.px(18)),
                      Text(_error!, style: body(context.px(21), color: C.bad)),
                    ],
                    SizedBox(height: context.px(36)),
                    Wrap(spacing: context.px(16), runSpacing: context.px(12), children: [
                      _busy
                          ? SizedBox(width: context.px(200), height: context.px(72), child: const Loading())
                          : EmberButton(label: label, kind: BtnKind.accent, autofocus: !m.isTv, onTap: _submit),
                      EmberButton(label: 'Cancel', kind: BtnKind.ghost, onTap: () => Navigator.pop(context)),
                    ]),
                  ]),
                ),
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final String label;
  final bool checked;
  final bool autofocus;
  final VoidCallback onTap;
  const _CheckRow({required this.label, required this.checked, required this.onTap, this.autofocus = false});
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: context.px(8)),
        child: Focusable(
          onTap: onTap,
          autofocus: autofocus,
          semanticLabel: label,
          builder: (context, active) {
            final fg = active ? const Color(0xFF111111) : C.soft;
            return Container(
              height: context.px(64),
              padding: EdgeInsets.symmetric(horizontal: context.px(20)),
              decoration: BoxDecoration(color: active ? C.text : C.surface2, borderRadius: BorderRadius.circular(context.px(12))),
              child: Row(children: [
                Container(
                  width: context.px(30),
                  height: context.px(30),
                  decoration: BoxDecoration(
                    color: checked ? C.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(context.px(7)),
                    border: Border.all(color: checked ? C.accent : fg, width: context.px(3)),
                  ),
                  child: checked ? Icon(Icons.check, size: context.px(22), color: C.accentInk) : null,
                ),
                SizedBox(width: context.px(18)),
                Text(label, style: body(context.px(24), weight: FontWeight.w600, color: fg)),
              ]),
            );
          },
        ),
      );
}
