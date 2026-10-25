import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// A trailer the player can open: an HLS playlist (all qualities, picture and sound together),
/// or a plain video file with, when YouTube keeps them apart, a separate sound file.
class TrailerStream {
  final String url;
  final String? audioUrl;
  final bool isHls;
  const TrailerStream(this.url, {this.audioUrl, this.isHls = false});

  @override
  String toString() => isHls ? 'HLS' : (audioUrl == null ? 'MP4' : 'MP4 + separate audio');
}

/// Finds the stream of a YouTube trailer on this device, with no help from the server.
///
/// YouTube's stream addresses only work from the address that asked for them, so asking from
/// the device that plays is what makes this work everywhere (at home, away, behind Tailscale).
/// First choice is the HLS playlist YouTube gives its own iPhone app: Apple TV's player and mpv
/// both play it natively, it adapts up to 1080p and starts in a second or two. If that isn't
/// offered, youtube_explode_dart finds a plain MP4. Results are kept for an hour, so a trailer
/// looked up when a title page opens plays at once when the Trailer button is pressed.
class YouTubeTrailers {
  YouTubeTrailers._();

  static const _iosVersion = '20.10.4';
  static const _iosAgent = 'com.google.ios.youtube/$_iosVersion (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)';

  static final Map<String, (DateTime, Future<TrailerStream?>)> _cache = {};
  static YoutubeExplode? _explode;

  /// The stream for YouTube video [key], or null when it can't be played here.
  static Future<TrailerStream?> resolve(String key) {
    final hit = _cache[key];
    if (hit != null && DateTime.now().difference(hit.$1) < const Duration(hours: 1)) return hit.$2;
    final f = _resolve(key);
    _cache[key] = (DateTime.now(), f);
    // A failure isn't kept: the next try asks again.
    f.then((s) {
      if (s == null) _cache.remove(key);
    }, onError: (_) {
      _cache.remove(key);
    });
    return f;
  }

  static Future<TrailerStream?> _resolve(String key) async {
    try {
      final hls = await iosHls(key).timeout(const Duration(seconds: 12));
      if (hls != null) return TrailerStream(hls, isHls: true);
    } catch (_) {}
    try {
      return await _mp4(key).timeout(const Duration(seconds: 25));
    } catch (_) {
      return null;
    }
  }

  /// YouTube's HLS playlist for [key], as given to the YouTube iPhone app.
  static Future<String?> iosHls(String key, {http.Client? client}) async {
    final body = {
      'context': {
        'client': {
          'clientName': 'IOS',
          'clientVersion': _iosVersion,
          'deviceMake': 'Apple',
          'deviceModel': 'iPhone16,2',
          'userAgent': _iosAgent,
          'osName': 'iPhone',
          'osVersion': '18.3.2.22D82',
          'hl': 'en',
          'timeZone': 'UTC',
          'utcOffsetMinutes': 0,
        },
      },
      'videoId': key,
      'playbackContext': {
        'contentPlaybackContext': {'html5Preference': 'HTML5_PREF_WANTS'},
      },
      'contentCheckOk': true,
      'racyCheckOk': true,
    };
    final c = client ?? http.Client();
    try {
      final res = await c.post(
        Uri.parse('https://www.youtube.com/youtubei/v1/player?prettyPrint=false'),
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': _iosAgent,
          'X-YouTube-Client-Name': '5',
          'X-YouTube-Client-Version': _iosVersion,
          'Origin': 'https://www.youtube.com',
        },
        body: jsonEncode(body),
      );
      if (res.statusCode != 200) return null;
      final m = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
      if ((m['playabilityStatus'] as Map?)?['status'] != 'OK') return null;
      return (m['streamingData'] as Map?)?['hlsManifestUrl'] as String?;
    } finally {
      if (client == null) c.close();
    }
  }

  /// A plain MP4: the best H.264 picture up to 1080p with the best AAC sound, or one file
  /// holding both when that's all there is.
  static Future<TrailerStream?> _mp4(String key) async {
    final manifest = await (_explode ??= YoutubeExplode()).videos.streamsClient.getManifest(key);
    return pickMp4(manifest.videoOnly.toList(), manifest.audioOnly.toList(), manifest.muxed.toList());
  }

  static TrailerStream? pickMp4(List<VideoOnlyStreamInfo> video, List<AudioOnlyStreamInfo> audio, List<MuxedStreamInfo> muxed) {
    bool h264(String codec) => codec.toLowerCase().startsWith('avc1');
    final pictures = video
        .where((s) => s.container == StreamContainer.mp4 && h264(s.videoCodec) && s.videoResolution.height <= 1080)
        .toList()
      ..sort((a, b) => b.videoResolution.height.compareTo(a.videoResolution.height));
    final sounds = audio.where((s) => s.container == StreamContainer.mp4).toList()
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
    final both = muxed.where((s) => s.container == StreamContainer.mp4).toList()
      ..sort((a, b) => b.videoResolution.height.compareTo(a.videoResolution.height));
    // Separate picture and sound only when it's clearly sharper than the combined file.
    if (pictures.isNotEmpty &&
        sounds.isNotEmpty &&
        (both.isEmpty || pictures.first.videoResolution.height > both.first.videoResolution.height)) {
      return TrailerStream(pictures.first.url.toString(), audioUrl: sounds.first.url.toString());
    }
    if (both.isNotEmpty) return TrailerStream(both.first.url.toString());
    return null;
  }
}
