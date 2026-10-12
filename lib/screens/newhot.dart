import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:provider/provider.dart';

import '../api/jellyfin.dart';
import '../api/seerr.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'coming_soon.dart';
import 'nav.dart';

class _NewHot {
  List<JfItem> newTitles = [];
  List<JfItem> newEpisodes = [];
  List<SeerrMedia> trending = [];
  List<SeerrMedia> soonMovies = [];
  List<SeerrMedia> soonShows = [];
}

/// What just arrived on the server, what's popular, and what's coming soon (from Seerr).
class NewHotScreen extends StatefulWidget {
  const NewHotScreen({super.key});
  @override
  State<NewHotScreen> createState() => _NewHotScreenState();
}

class _NewHotScreenState extends State<NewHotScreen> {
  int _tab = 0;

  Future<_NewHot> _load(AppState app) async {
    final jf = app.jf!;
    final d = _NewHot();
    final r = await Future.wait<Object>([
      jf.items(types: const ['Movie', 'Series'], sortBy: 'DateCreated', sortOrder: 'Descending', limit: 24).catchError((_) => <JfItem>[]),
      jf.items(types: const ['Episode'], sortBy: 'DateCreated', sortOrder: 'Descending', limit: 24).catchError((_) => <JfItem>[]),
      if (app.seerrConfigured) ...[
        app.seerr!.trending().catchError((_) => <SeerrMedia>[]),
        app.seerr!.upcoming('movie').catchError((_) => <SeerrMedia>[]),
        app.seerr!.upcoming('tv').catchError((_) => <SeerrMedia>[]),
      ],
    ]);
    d.newTitles = r[0] as List<JfItem>;
    d.newEpisodes = r[1] as List<JfItem>;
    if (r.length > 2) {
      d.trending = (r[2] as List<SeerrMedia>).where((m) => !m.isAvailable).toList();
      d.soonMovies = r[3] as List<SeerrMedia>;
      d.soonShows = r[4] as List<SeerrMedia>;
    }
    return d;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final jf = app.jf!;
    final pad = context.px(gutter(context));
    final header = Padding(
      padding: EdgeInsets.symmetric(horizontal: pad),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('New & Hot', style: display(context.px(72))),
        SizedBox(height: context.px(22)),
        FocusTraversalGroup(
          child: Wrap(spacing: context.px(12), runSpacing: context.px(12), children: [
            Chip2(label: 'New & Hot', selected: _tab == 0, onTap: () => setState(() => _tab = 0)),
            Chip2(label: 'Coming Soon', selected: _tab == 1, onTap: () => setState(() => _tab = 1)),
          ]),
        ),
        SizedBox(height: context.px(30)),
      ]),
    );
    if (_tab == 1) return ComingSoonView(key: const ValueKey('soon'), header: header);
    Widget seerrRow(String title, List<SeerrMedia> list, {bool soon = false}) => MediaRow(
          title: title,
          tileHeight: 216,
          children: [
            for (final m in list)
              MediaTile(
                title: m.title,
                subtitle: soon && m.date != null ? 'Coming ${_date(m.date!)}' : null,
                imageUrl: m.backdropUrl ?? m.posterUrl,
                badge: m.isAvailable ? 'On your server' : (m.isRequested ? 'Requested' : 'Not on server'),
                badgeAlt: m.isAvailable || m.isRequested,
                onTap: () => openSeerr(context, m),
              ),
          ],
        );
    return Loader<_NewHot>(
      deps: app.revision,
      load: () => _load(app),
      builder: (context, d) => ListView(
        scrollCacheExtent: const ScrollCacheExtent.pixels(4000),
        padding: EdgeInsets.only(top: context.px(app.isPhone ? 30 : 60), bottom: context.px(80)),
        children: [
          header,
          MediaRow(
            title: 'New on ${app.serverName ?? 'your server'}',
            tileHeight: 216,
            children: [
              for (final it in d.newTitles)
                MediaTile(
                  title: it.name,
                  imageUrl: jf.landscapeImage(it),
                  autofocus: false,
                  onTap: () => openItem(context, it),
                ),
            ],
          ),
          MediaRow(
            title: 'New episodes',
            tileHeight: 216,
            children: [
              for (final it in d.newEpisodes)
                MediaTile(
                  title: it.seriesName ?? it.name,
                  subtitle: it.episodeLabel,
                  imageUrl: jf.landscapeImage(it),
                  onTap: () => play(context, it),
                ),
            ],
          ),
          if (d.trending.isNotEmpty) seerrRow('Trending this week — not in your library', d.trending),
          if (d.soonMovies.isNotEmpty) seerrRow('Coming soon · Movies', d.soonMovies, soon: true),
          if (d.soonShows.isNotEmpty) seerrRow('Coming soon · Shows', d.soonShows, soon: true),
          if (!app.seerrConfigured)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: pad),
              child: Text('Connect Seerr in Settings to also see trending and upcoming titles you can request.',
                  style: body(context.px(22), color: C.faint)),
            ),
        ],
      ),
    );
  }

  static String _date(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${m[d.month - 1]}';
  }
}
