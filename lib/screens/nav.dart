import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/jellyfin.dart';
import '../api/seerr.dart';
import '../api/youtube.dart';
import '../platform.dart';
import '../player/native_player.dart';
import '../player/player_screen.dart';
import '../player/trailers.dart';
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
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailsScreen(itemId: item.seriesId!, seasonId: item.id),
      ),
    );
    return;
  }
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => DetailsScreen(itemId: item.id)));
}

/// Opens the "not on your server" preview for a Seerr title.
void openSeerr(BuildContext context, SeerrMedia media) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PreviewScreen(mediaType: media.mediaType, tmdbId: media.id),
    ),
  );
}

/// Starts playback, resuming where the person left off unless [fromStart].
Future<void> play(BuildContext context, JfItem item, {bool fromStart = false, bool isTrailer = false}) async {
  final start = fromStart || item.positionTicks == 0 ? null : ticksToDuration(item.positionTicks);
  if (isAppleTv && context.read<AppState>().useApplePlayer && !isTrailer) {
    // Apple's own player, when chosen in Settings: true HDR, Dolby Vision and Atmos.
    await NativePlayer.play(context.read<AppState>(), item, start: start);
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PlayerScreen(item: item, start: start, isTrailer: isTrailer),
    ),
  );
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

/// Plays a trailer inside Ember: a trailer file stored with the title, otherwise the official
/// YouTube trailer, found and played on this device. Falls back to the YouTube app when YouTube
/// won't hand the stream over (or when "Play trailers in the app" is off).
Future<void> playTrailer(
  BuildContext context, {
  JfItem? item,
  String? ytKey,
  required String title,
  String? backdropUrl,
}) async {
  final app = context.read<AppState>();
  final jf = app.jf!;
  if (item != null && item.localTrailerCount > 0 && app.trailersInApp) {
    final local = await jf.localTrailers(item.id);
    if (local.isNotEmpty && context.mounted) {
      await play(context, local.first, fromStart: true, isTrailer: true);
      return;
    }
  }
  if (item == null && ytKey == null) return;
  final artwork = backdropUrl ?? (item != null ? jf.backdropImage(item) : null);

  Future<void> fallback() async {
    final key = ytKey ?? (item != null ? (await trailerKeys(app, item)).firstOrNull : null);
    if (!context.mounted) return;
    if (key != null) {
      await openYouTube(context, key);
    } else {
      toast(context, 'No trailer available for this title.');
    }
  }

  if (!app.trailersInApp) return fallback();

  // When a stream won't play, the same trailer is asked for another way (see YouTubeTrailers).
  final tried = <TrailerSource>{};
  Future<TrailerStream?> resolve([TrailerStream? failed]) async {
    if (failed != null) return YouTubeTrailers.nextAfter(failed, tried);
    final (_, stream) = await findTrailer(app, item: item, key: ytKey);
    return stream;
  }

  if (isAppleTv) {
    final played = await NativePlayer.playTrailer(app, title: '$title · Trailer', artwork: artwork, resolve: resolve);
    if (!played) await fallback();
    return;
  }
  if (!context.mounted) return;
  // Open the player at once; it finds the trailer while showing what it's doing.
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PlayerScreen(
        item: JfItem({'Id': 'trailer-${item?.id ?? ytKey}', 'Name': '$title · Trailer', 'Type': 'Trailer'}),
        isTrailer: true,
        youtubeKey: ytKey,
        backdropUrl: artwork,
        resolveTrailer: resolve,
      ),
    ),
  );
}

/// Gets playback ready while a title page is open: the connection test that Auto quality needs
/// runs now (and is remembered), so pressing Play doesn't wait for it.
void warmPlayback(AppState app) {
  if (app.quality == 'auto') app.jf?.connectionSpeed().ignore();
}
