import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/jellyfin.dart';
import '../api/youtube.dart';
import '../state/app_state.dart';
import '../ui/widgets.dart';

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
