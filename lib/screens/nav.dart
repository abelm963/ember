import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/jellyfin.dart';
import '../api/seerr.dart';
import '../api/youtube.dart';
import '../platform.dart';
import '../player/native_player.dart';
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
  if (isAppleTv) {
    // Apple's own player: true HDR, Dolby Vision and Atmos.
    await NativePlayer.play(context.read<AppState>(), item, start: start);
    return;
  }
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

/// YouTube trailers for a title: the links Jellyfin keeps with it (from TMDB), then Seerr's
/// official trailer when the library has none.
Future<List<String>> trailerKeys(AppState app, JfItem item) async {
  final keys = <String>[];
  for (final t in item.remoteTrailers) {
    final k = youtubeKey(t['Url'] as String?);
    if (k != null && !keys.contains(k)) keys.add(k);
  }
  final tmdb = int.tryParse(item.tmdbId ?? '');
  if (keys.isEmpty && tmdb != null && app.seerrConfigured) {
    try {
      final m = await app.seerr!.details(item.isSeries ? 'tv' : 'movie', tmdb);
      final k = m.bestTrailer?['key'] as String?;
      if (k != null) keys.add(k);
    } catch (_) {}
  }
  return keys;
}

final Map<String, (DateTime, Future<(String?, TrailerStream?)>)> _trailers = {};

/// The trailer for [item] (or YouTube video [key]) and its stream, found on this device.
/// Tries the title's trailers in turn until one plays. Kept for 50 minutes, so looking it up
/// when a page opens makes the Trailer button and the Home preview start at once.
Future<(String?, TrailerStream?)> findTrailer(AppState app, {JfItem? item, String? key}) {
  final id = item?.id ?? key ?? '';
  final hit = _trailers[id];
  if (hit != null && DateTime.now().difference(hit.$1) < const Duration(minutes: 50)) return hit.$2;
  Future<(String?, TrailerStream?)> look() async {
    final keys = key != null ? [key] : await trailerKeys(app, item!);
    for (final k in keys.take(3)) {
      final s = await YouTubeTrailers.resolve(k);
      if (s != null) return (k, s);
    }
    return (keys.isEmpty ? null : keys.first, null);
  }

  final f = look();
  _trailers[id] = (DateTime.now(), f);
  f.then((r) {
    if (r.$2 == null) _trailers.remove(id);
  });
  return f;
}

/// Plays a trailer inside Ember: a trailer file stored with the title, otherwise the official
/// YouTube trailer, found and played on this device. Falls back to the YouTube app when YouTube
/// won't hand the stream over (or when "Play trailers in the app" is off).
Future<void> playTrailer(BuildContext context, {JfItem? item, String? ytKey, required String title, String? backdropUrl}) async {
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

  Future<TrailerStream> resolve() async {
    final (_, stream) = await findTrailer(app, item: item, key: ytKey);
    if (stream == null) throw ApiException(0, 'YouTube didn\'t hand this trailer over.');
    return stream;
  }

  if (isAppleTv) {
    final played = await NativePlayer.playTrailer(app, title: '$title · Trailer', artwork: artwork, resolve: resolve);
    if (!played) await fallback();
    return;
  }
  if (!context.mounted) return;
  // Open the player at once; it finds the trailer while showing what it's doing.
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => PlayerScreen(
      item: JfItem({'Id': 'trailer-${item?.id ?? ytKey}', 'Name': '$title · Trailer', 'Type': 'Trailer'}),
      isTrailer: true,
      youtubeKey: ytKey,
      backdropUrl: artwork,
      resolveTrailer: resolve,
    ),
  ));
}

/// Looks the trailer up early (when a page opens), so the Trailer button starts at once.
void prefetchTrailer(AppState app, JfItem item) {
  if (app.trailersInApp && app.jf != null && (item.remoteTrailers.isNotEmpty || item.tmdbId != null)) {
    findTrailer(app, item: item).ignore();
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
