import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:provider/provider.dart';

import '../api/jellyfin.dart';
import '../api/seerr.dart';
import '../state/app_state.dart';
import '../ui/browse.dart' show PageHeader;
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'nav.dart';

class _ListData {
  List<JfItem> favorites = [];
  List<SeerrMedia> watchlist = [];
  List<SeerrMedia> arriving = [];
  int get count => favorites.length + watchlist.length + arriving.length;
}

/// Three parts: My List (favourites on the server), Watchlist (this person's Seerr watchlist: titles
/// they want that may not be on the server yet) and Requested (their requests that haven't arrived).
class MyListScreen extends StatelessWidget {
  const MyListScreen({super.key});

  Future<_ListData> _load(AppState app) async {
    final d = _ListData()..favorites = await app.jf!.favorites();
    if (!app.seerrConfigured) return d;
    final seerr = app.seerr!;
    final me = app.seerrUser?['id'];
    final r = await Future.wait<Object>([
      seerr.watchlist().catchError((_) => <WatchlistEntry>[]),
      app.addRequestsToMyList
          // Ask Seerr for this person's requests only, so other people's don't crowd them out.
          ? seerr.requests(take: 30, requestedBy: me).catchError((_) => <SeerrRequest>[])
          : Future.value(<SeerrRequest>[]),
    ]);
    final seen = <String>{};
    final listed = [
      for (final w in (r[0] as List<WatchlistEntry>).take(40))
        if (seen.add('${w.mediaType}/${w.tmdbId}')) (w.mediaType, w.tmdbId),
    ];
    final mine = [
      for (final q in r[1] as List<SeerrRequest>)
        if ((me == null || (q.raw['requestedBy'] as Map?)?['id'] == me) &&
            q.arriving &&
            q.tmdbId != null &&
            seen.add('${q.mediaType}/${q.tmdbId}'))
          (q.mediaType, q.tmdbId!),
    ];
    Future<List<SeerrMedia>> details(List<(String, int)> ids) async => [
      for (final m in await Future.wait(
        ids.map((x) => seerr.details(x.$1, x.$2).then<SeerrMedia?>((m) => m).catchError((_) => null)),
      ))
        ?m,
    ];
    final both = await Future.wait([details(listed), details(mine)]);
    d.watchlist = both[0];
    d.arriving = both[1];
    return d;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final jf = app.jf!;
    final pad = context.px(gutter(context));
    String? badge(SeerrMedia m) => switch (m.status) {
      MediaStatus.available => 'Ready to watch',
      MediaStatus.partiallyAvailable => 'Partly here',
      MediaStatus.processing => 'Arriving',
      MediaStatus.pending => 'Requested',
      _ => null,
    };
    Widget section(String title, String? note, List<Widget> tiles) => Padding(
      padding: EdgeInsets.only(bottom: context.px(44)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: display(context.px(32))),
          if (note != null) ...[
            SizedBox(height: context.px(6)),
            Text(note, style: body(context.px(20), color: C.faint)),
          ],
          SizedBox(height: context.px(20)),
          Wrap(spacing: context.px(24), runSpacing: context.px(36), children: tiles),
        ],
      ),
    );
    return Loader<_ListData>(
      deps: app.revision,
      load: () => _load(app),
      builder: (context, d) => ListView(
        scrollCacheExtent: const ScrollCacheExtent.pixels(3000),
        // TV and desktop: the page header sits where every page has it (just under the menu bar).
        padding: EdgeInsets.fromLTRB(pad, context.px(app.isPhone ? 30 : PageHeader.top - 100), pad, context.px(80)),
        children: [
          if (app.isPhone) Text('My List', style: display(context.px(72))) else const PageHeader(title: 'My List'),
          SizedBox(height: context.px(30)),
          if (d.count == 0)
            Text(
              app.seerrConfigured
                  ? 'Nothing here yet. Use "My List" on anything on ${app.serverName ?? 'your server'}, or "Watchlist" on anything that isn\'t.'
                  : 'Nothing here yet. Use "My List" on any title to add it.',
              style: body(context.px(24), color: C.muted),
            ),
          if (d.favorites.isNotEmpty)
            section('My List', null, [
              for (final it in d.favorites)
                MediaTile(
                  title: it.name,
                  imageUrl: jf.landscapeImage(it),
                  width: 384,
                  autofocus: app.isTv && it == d.favorites.first,
                  onTap: () => openItem(context, it),
                ),
            ]),
          if (d.watchlist.isNotEmpty)
            section(
              'Watchlist',
              'From Seerr, including titles that aren\'t on ${app.serverName ?? 'your server'} yet',
              [
                for (final m in d.watchlist)
                  MediaTile(
                    title: m.title,
                    imageUrl: m.backdropUrl,
                    width: 384,
                    autofocus: app.isTv && d.favorites.isEmpty && m == d.watchlist.first,
                    badge: badge(m),
                    onTap: () => openSeerr(context, m),
                  ),
              ],
            ),
          if (d.arriving.isNotEmpty)
            section('Requested', 'Added here when you request something', [
              for (final m in d.arriving)
                MediaTile(
                  title: m.title,
                  imageUrl: m.backdropUrl,
                  width: 384,
                  autofocus: app.isTv && d.favorites.isEmpty && d.watchlist.isEmpty && m == d.arriving.first,
                  badge: badge(m) ?? 'Requested',
                  onTap: () => openSeerr(context, m),
                ),
            ]),
        ],
      ),
    );
  }
}
