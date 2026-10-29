/// The pieces several screens build their rows and title lines from: poster-row entries for
/// library and Seerr titles, and the meta line under a title.
library;

import 'package:flutter/material.dart';

import '../../api/jellyfin.dart';
import '../../api/seerr.dart';
import '../../ui/browse.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../nav.dart';

/// "1h 12m left" for a title that has been started, or null.
String? timeLeft(JfItem it) {
  final rt = it.runtime;
  if (rt == null || it.positionTicks == 0) return null;
  final left = rt - ticksToDuration(it.positionTicks);
  return '${formatRuntime(left)} left';
}

/// "★ 7.8 · 2024 · PG-13 · 2h 1m · Drama · 4K" under a title on Home and the details page.
class MetaLine extends StatelessWidget {
  final JfItem item;
  const MetaLine({super.key, required this.item});
  @override
  Widget build(BuildContext context) {
    final parts = <Widget>[
      if (item.communityRating != null)
        Text(
          '★ ${item.communityRating!.toStringAsFixed(1)}',
          style: body(context.px(23), color: C.good, weight: FontWeight.w700),
        ),
      if (item.year != null) Text('${item.year}', style: body(context.px(23), color: C.muted)),
      if (item.officialRating != null) Badge2(item.officialRating!),
      if (item.isMovie && item.runtime != null)
        Text(formatRuntime(item.runtime), style: body(context.px(23), color: C.muted)),
      if (item.isSeries && item.childCount != null)
        Text(
          '${item.childCount} Season${item.childCount == 1 ? '' : 's'}',
          style: body(context.px(23), color: C.muted),
        ),
      if (item.genres.isNotEmpty) Text(item.genres.take(2).join(' · '), style: body(context.px(23), color: C.muted)),
      if (videoBadge(item) != null) Badge2(videoBadge(item)!),
    ];
    return Wrap(
      spacing: context.px(18),
      runSpacing: context.px(8),
      crossAxisAlignment: WrapCrossAlignment.center,
      children: parts,
    );
  }
}

/// "4K · HDR" style badge from the file's video stream, as in the design.
String? videoBadge(JfItem item) {
  final b = FormatInfo.fromStreams(item.mediaStreams).badges;
  final video = b
      .where((x) => const ['4K', 'HD', 'Dolby Vision', 'HDR10', 'HDR10+', 'HLG'].contains(x))
      .take(2)
      .toList();
  if (video.isEmpty) return null;
  return video.map((x) => x == 'HDR10' ? 'HDR' : x).join(' · ');
}

/// The poster-row entry for a library item. Episodes show their series' poster and logo, with
/// the episode and the time left underneath when focused ([resume]).
PosterEntry posterEntry(
  BuildContext context,
  JellyfinClient jf,
  JfItem it, {
  required VoidCallback onTap,
  bool resume = false,
}) {
  final left = timeLeft(it);
  final cleanWide = !it.isEpisode && it.backdropTags.isNotEmpty;
  return PosterEntry(
    title: it.isEpisode ? (it.seriesName ?? it.name) : it.name,
    poster: jf.posterImage(it),
    // The focused card: a backdrop (clean art) with the logo drawn on it. Without one, the
    // Thumb, which usually has the title written on it already, so no logo goes over it.
    wide: cleanWide ? jf.backdropImage(it, maxWidth: 960) : jf.landscapeImage(it, maxWidth: 960),
    wideTitled: !cleanWide && it.imageTags['Thumb'] != null,
    logo: jf.logoImage(it, maxWidth: 600),
    progress: it.progress,
    subtitle: resume && it.isEpisode ? '${it.episodeLabel.replaceAll(' : ', ' ')} · ${it.name}' : null,
    note: resume ? left : null,
    meta: metaParts(it),
    rating: it.officialRating,
    overview: it.overview,
    backdrop: jf.backdropImage(it),
    onTap: onTap,
  );
}

/// The poster-row entry for a Seerr title that isn't on the server: opening it offers Request.
PosterEntry seerrEntry(BuildContext context, SeerrMedia m) => PosterEntry(
  title: m.title,
  poster: m.posterUrl,
  wide: m.backdropUrl,
  backdrop: m.backdropUrl,
  badge: m.isRequested ? 'Requested' : null,
  badgeAlt: true,
  overview: m.overview,
  meta: [m.isTv ? 'Series' : 'Film', if (m.year != null) '${m.year}'],
  onTap: () => openSeerr(context, m),
);

/// "Series · Drama · 2026 · 5 Seasons" for a movie or series.
List<String> metaParts(JfItem it) => [
  if (it.isSeries) 'Series' else if (it.isMovie) 'Film',
  if (it.genres.isNotEmpty) it.genres.first,
  if (it.year != null) '${it.year}',
  if (it.isSeries && it.childCount != null) '${it.childCount} Season${it.childCount == 1 ? '' : 's'}',
  if (it.isMovie && it.runtime != null) formatRuntime(it.runtime),
  if (videoBadge(it) != null) videoBadge(it)!,
];
