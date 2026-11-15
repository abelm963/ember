import 'dart:async';

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

/// True from the moment something is asked to play until its player closes. A second press of
/// Play while the first is still getting going (easy to do with a remote) would otherwise open
/// two players on top of each other, both with sound.
bool _playerOpen = false;

/// Apple's player covers the screen within a moment and tells Ember when it closes. Should that
/// message ever go missing, Play must not stay switched off, so it is let go once the player is up.
void _applePlayerShowing() => Timer(const Duration(seconds: 3), () => _playerOpen = false);

/// Runs [open] unless a player is already open or on its way.
Future<void> _oneAtATime(Future<void> Function() open) async {
  if (_playerOpen) return;
  _playerOpen = true;
  try {
    await open();
  } finally {
    _playerOpen = false;
  }
}

/// Starts playback, resuming where the person left off unless [fromStart].
Future<void> play(BuildContext context, JfItem item, {bool fromStart = false, bool isTrailer = false}) =>
    _oneAtATime(() => _play(context, item, fromStart: fromStart, isTrailer: isTrailer));

Future<void> _play(BuildContext context, JfItem item, {bool fromStart = false, bool isTrailer = false}) async {
  final start = fromStart || item.positionTicks == 0 ? null : ticksToDuration(item.positionTicks);
  if (isAppleTv && context.read<AppState>().useApplePlayer && !isTrailer) {
    // Apple's own player, when chosen in Settings: true HDR, Dolby Vision and Atmos.
    _applePlayerShowing();
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
Future<void> playSeries(BuildContext context, JellyfinClient jf, JfItem series) =>
    _oneAtATime(() => _playSeries(context, jf, series));

Future<void> _playSeries(BuildContext context, JellyfinClient jf, JfItem series) async {
  JfItem? ep;
  List<JfItem> next;
  try {
    next = await jf.nextUp(limit: 50);
  } catch (e) {
    if (context.mounted) toast(context, "Couldn't reach your server. Try again.");
    return;
  }
  for (final e in next) {
    if (e.seriesId == series.id) {
      ep = e;
      break;
    }
  }
  if (ep == null) {
    final all = await jf.episodes(series.id, limit: 1).catchError((_) => <JfItem>[]);
    if (all.isNotEmpty) ep = all.first;
  }
  if (ep == null) {
    if (context.mounted) toast(context, 'No episodes on the server yet.');
    return;
  }
  if (context.mounted) await _play(context, ep);
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
}) => _oneAtATime(() => _playTrailer(context, item: item, ytKey: ytKey, title: title, backdropUrl: backdropUrl));

Future<void> _playTrailer(
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
      await _play(context, local.first, fromStart: true, isTrailer: true);
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
    _applePlayerShowing();
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
