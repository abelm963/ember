import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/jellyfin.dart';
import '../api/seerr.dart';
import '../player/player_screen.dart';
import '../state/app_state.dart';
import '../ui/widgets.dart';
import 'details.dart';
import 'preview.dart';

/// Opens the details page for a library item. Episodes open their series.
void openItem(BuildContext context, JfItem item) {
  if (item.isEpisode && item.seriesId != null) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => DetailsScreen(itemId: item.seriesId!)));
    return;
  }
  if (item.isSeason && item.seriesId != null) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => DetailsScreen(itemId: item.seriesId!, seasonId: item.id)));
    return;
  }
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => DetailsScreen(itemId: item.id)));
}

/// Opens the "not on your server" preview for a Seerr title.
void openSeerr(BuildContext context, SeerrMedia media) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => PreviewScreen(mediaType: media.mediaType, tmdbId: media.id)));
}

/// Starts playback, resuming where the person left off unless [fromStart].
Future<void> play(BuildContext context, JfItem item, {bool fromStart = false, bool isTrailer = false}) async {
  final start = fromStart || item.positionTicks == 0 ? null : ticksToDuration(item.positionTicks);
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => PlayerScreen(item: item, start: start, isTrailer: isTrailer),
  ));
}

/// Plays a series: the next unwatched (or in-progress) episode.
Future<void> playSeries(BuildContext context, JellyfinClient jf, JfItem series) async {
  final next = await jf.nextUp(limit: 50);
  JfItem? ep;
  for (final e in next) {
    if (e.seriesId == series.id) {
      ep = e;
      break;
    }
  }
  if (ep == null) {
    final all = await jf.episodes(series.id, limit: 1);
    if (all.isNotEmpty) ep = all.first;
  }
  if (ep == null) {
    if (context.mounted) toast(context, 'No episodes on the server yet.');
    return;
  }
  if (context.mounted) await play(context, ep);
}

/// Plays a trailer inside Ember: streamed by the server's Ember Trailers plugin when it can, otherwise
/// straight from YouTube in Ember's own player. Only when in-app trailers are turned off (or YouTube
/// refuses) does it open the YouTube app.
Future<void> playTrailer(BuildContext context, {JfItem? item, String? ytKey, required String title, String? backdropUrl}) async {
  final app = context.read<AppState>();
  final jf = app.jf!;
  var key = ytKey;
  if (key == null && item != null) {
    for (final t in item.remoteTrailers) {
      key = youtubeKey(t['Url'] as String?);
      if (key != null) break;
    }
  }
  final viaServer = app.trailerServiceOk && (item != null || key != null);
  if (app.trailersInApp && (viaServer || key != null)) {
    // Open the player at once; it finds the trailer while showing what it's doing.
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(
          item: JfItem({'Id': 'trailer-${item?.id ?? key}', 'Name': '$title · Trailer', 'Type': 'Trailer'}),
          isTrailer: true,
          youtubeKey: key,
          youtubeOnly: !viaServer,
          backdropUrl: backdropUrl ?? (item != null ? jf.backdropImage(item) : null),
          resolveUrl: !viaServer ? null : () async {
            String? ok;
            String? reason;
            if (item != null) {
              (ok, reason) = await jf.trailerCheckForItem(item.id);
            } else {
              ok = await jf.trailerKeyChecked(key!);
            }
            if (ok == null) {
              throw ApiException(0, reason ?? 'Your server couldn\'t play this trailer.');
            }
            return TrailerStream(jf.trailerStreamUrl(ok), ok);
          },
        ),
    ));
    return;
  }
  if (key != null && context.mounted) {
    await openYouTube(context, key);
  } else if (context.mounted) {
    toast(context, 'No trailer available for this title.');
  }
}

/// Starts the server's trailer check early (when a page opens) so the Trailer button is instant.
void prefetchTrailer(AppState app, JfItem item) {
  if (app.trailersInApp && app.trailerServiceOk && app.jf != null) {
    app.jf!.trailerCheckForItem(item.id);
  }
}

/// Hands a YouTube trailer to the YouTube app (or the browser on desktop).
Future<void> openYouTube(BuildContext context, String key) async {
  final app = Uri.parse('youtube://watch?v=$key');
  final web = Uri.parse('https://www.youtube.com/watch?v=$key');
  try {
    if (await canLaunchUrl(app) && await launchUrl(app)) return;
  } catch (_) {}
  try {
    if (await launchUrl(web, mode: LaunchMode.externalApplication)) return;
  } catch (_) {}
  if (context.mounted) toast(context, "Couldn't open the trailer.");
}

String? youtubeKey(String? url) {
  if (url == null) return null;
  final u = Uri.tryParse(url);
  if (u == null) return null;
  if (u.host.contains('youtu.be')) return u.pathSegments.isNotEmpty ? u.pathSegments.first : null;
  if (u.host.contains('youtube')) return u.queryParameters['v'];
  return null;
}
