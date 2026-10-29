import 'dart:async';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// The browser identity YouTube's stream addresses are fetched with (the same one the library uses).
final String youTubeUserAgent = YoutubeHttpClient.defaultHeaders['user-agent']!;

/// One way to play a YouTube video straight from YouTube in Ember's own player: a single stream,
/// or a picture stream plus a separate sound stream that mpv plays together.
class YouTubeSource {
  final String video;
  final String? audio;
  final String label;
  const YouTubeSource(this.video, {this.audio, required this.label});
  @override
  String toString() => label;
}

/// The ways YouTube offers to play [key], best first. YouTube answers differently depending on which
/// kind of player asks, so if one kind gives nothing usable the next is asked. Sources are produced
/// lazily: the player takes the next one only when the previous one fails to start.
Stream<YouTubeSource> youTubeSources(String key, {int maxHeight = 1080}) async* {
  final yt = YoutubeExplode();
  final seen = <String>{};
  try {
    for (final clients in <List<YoutubeApiClient>?>[
      null, // the library's own choice, which follows YouTube's changes
      [YoutubeApiClient.androidVr],
      [YoutubeApiClient.tv],
      [YoutubeApiClient.safari],
    ]) {
      StreamManifest manifest;
      try {
        manifest = await yt.videos.streams.getManifest(key, ytClients: clients).timeout(const Duration(seconds: 20));
      } catch (_) {
        continue;
      }
      for (final s in pickYouTubeSources(manifest, maxHeight: maxHeight)) {
        if (seen.add('${s.video}|${s.audio}')) yield s;
      }
    }
  } finally {
    yt.close();
  }
}

/// Orders a manifest's streams for playback: a ready-combined HLS stream, then the best H.264 picture
/// with AAC sound, then any picture with any sound, then the plain combined file (360p).
List<YouTubeSource> pickYouTubeSources(StreamManifest m, {int maxHeight = 1080}) {
  int height(VideoStreamInfo v) => v.videoResolution.height;
  bool avc(String codec) => codec.startsWith('avc1') || codec.startsWith('h264');
  bool aac(String codec) => codec.startsWith('mp4a');

  final out = <YouTubeSource>[];
  final hls = m.hls.whereType<HlsMuxedStreamInfo>().where((s) => height(s) <= maxHeight).toList()
    ..sort((a, b) {
      final byAvc = (avc(b.videoCodec) ? 1 : 0) - (avc(a.videoCodec) ? 1 : 0);
      return byAvc != 0 ? byAvc : height(b) - height(a);
    });
  if (hls.isNotEmpty) out.add(YouTubeSource(hls.first.url.toString(), label: 'YouTube HLS ${height(hls.first)}p'));

  final videos = m.videoOnly.where((v) => height(v) <= maxHeight).toList()
    ..sort((a, b) {
      final h = height(b) - height(a);
      return h != 0 ? h : b.bitrate.bitsPerSecond - a.bitrate.bitsPerSecond;
    });
  // Prefer the original-language sound track when YouTube offers dubs.
  final audios = m.audioOnly.toList()
    ..sort((a, b) {
      final o = ((b.audioTrack?.audioIsDefault ?? false) ? 1 : 0) - ((a.audioTrack?.audioIsDefault ?? false) ? 1 : 0);
      return o != 0 ? o : b.bitrate.bitsPerSecond - a.bitrate.bitsPerSecond;
    });
  final vAvc = videos.where((v) => avc(v.videoCodec)).firstOrNull;
  final aAac = audios.where((a) => aac(a.audioCodec)).firstOrNull;
  if (vAvc != null && aAac != null) {
    out.add(YouTubeSource(vAvc.url.toString(), audio: aAac.url.toString(), label: 'YouTube ${height(vAvc)}p'));
  }
  final vAny = videos.firstOrNull;
  final aAny = audios.firstOrNull;
  if (vAny != null && aAny != null && (vAny != vAvc || aAny != aAac)) {
    out.add(YouTubeSource(vAny.url.toString(), audio: aAny.url.toString(), label: 'YouTube ${height(vAny)}p'));
  }
  final muxed = m.muxed.toList()..sort((a, b) => height(b) - height(a));
  if (muxed.isNotEmpty) out.add(YouTubeSource(muxed.first.url.toString(), label: 'YouTube ${height(muxed.first)}p'));
  return out;
}
