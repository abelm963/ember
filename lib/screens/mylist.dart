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
  List<SeerrMedia> arriving = [];
}

/// Jellyfin favourites, plus this person's Seerr requests that haven't arrived yet.
class MyListScreen extends StatelessWidget {
  const MyListScreen({super.key});

  Future<_ListData> _load(AppState app) async {
    final d = _ListData()..favorites = await app.jf!.favorites();
    if (app.seerrConfigured && app.addRequestsToMyList) {
      try {
        final me = app.seerrUser?['id'];
        // Ask Seerr for this person's requests only, so other people's don't crowd them out.
        final reqs = await app.seerr!.requests(take: 30, requestedBy: me);
        final seen = <String>{};
        final mine = reqs.where((r) =>
            (me == null || (r.raw['requestedBy'] as Map?)?['id'] == me) &&
            r.arriving &&
            r.tmdbId != null &&
            seen.add('${r.mediaType}/${r.tmdbId}'));
        d.arriving = await Future.wait(mine.map((r) => app.seerr!.details(r.mediaType, r.tmdbId!)));
      } catch (_) {}
    }
    return d;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final jf = app.jf!;
    final pad = context.px(gutter(context));
    return Loader<_ListData>(
      deps: app.revision,
      load: () => _load(app),
      builder: (context, d) => ListView(
        scrollCacheExtent: const ScrollCacheExtent.pixels(3000),
        // TV and desktop: the page header sits where every page has it (just under the menu bar).
        padding: EdgeInsets.fromLTRB(pad, context.px(app.isPhone ? 30 : PageHeader.top - 100), pad, context.px(80)),
        children: [
          if (app.isPhone)
            Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: context.px(28), children: [
              Text('My List', style: display(context.px(72))),
              Padding(
                padding: EdgeInsets.only(bottom: context.px(10)),
                child: Text(
                  '${d.favorites.length + d.arriving.length} titles · requests you make are added here automatically',
                  style: body(context.px(24), color: C.faint),
                ),
              ),
            ])
          else
            PageHeader(
              title: 'My List',
              note: '${d.favorites.length + d.arriving.length} titles · requests you make are added here automatically',
            ),
          SizedBox(height: context.px(30)),
          if (d.favorites.isEmpty && d.arriving.isEmpty)
            Text('Nothing here yet. Use "My List" on any title to add it.', style: body(context.px(24), color: C.muted)),
          Wrap(spacing: context.px(24), runSpacing: context.px(36), children: [
            for (final m in d.arriving)
              MediaTile(
                title: m.title,
                imageUrl: m.backdropUrl,
                width: 384,
                badge: m.status == MediaStatus.processing ? 'Arriving' : 'Requested',
                onTap: () => openSeerr(context, m),
              ),
            for (final it in d.favorites)
              MediaTile(
                title: it.name,
                imageUrl: jf.landscapeImage(it),
                width: 384,
                autofocus: app.isTv && it == d.favorites.first && d.arriving.isEmpty,
                onTap: () => openItem(context, it),
              ),
          ]),
        ],
      ),
    );
  }
}
