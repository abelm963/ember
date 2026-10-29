import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Where a trailer stream came from, in the order they're tried.
enum TrailerSource {
  /// YouTube's Vision Pro app: an HLS playlist with every quality up to 4K.
  visionOs,

  /// YouTube's iPhone app: an HLS playlist up to 1080p.
  ios,

  /// YouTube's Android app: one MP4 with picture and sound, at most 360p.
  android,

  /// A plain MP4 found by youtube_explode_dart (picture and sound sometimes as two files).
  mp4,
}

/// A trailer the player can open: an HLS playlist (all qualities, picture and sound together),
/// or a plain video file with, when YouTube keeps them apart, a separate sound file.
class TrailerStream {
  final String url;
  final String? audioUrl;
  final bool isHls;

  /// The trailer's own soundtrack language when YouTube also lists machine dubbed ones.
  /// Nothing in the playlist marks the original, so players left alone often pick a dub.
  final String? audioLanguage;

  /// The YouTube video, and how this stream was found: lets the player ask for the next way
  /// when this one won't play.
  final String key;
  final TrailerSource source;

  const TrailerStream(
    this.url, {
    this.audioUrl,
    this.isHls = false,
    this.audioLanguage,
    this.key = '',
    this.source = TrailerSource.mp4,
  });

  /// Sent with every request for the video itself. The iPhone app's playlist (and anything
  /// not from YouTube) plays as it is; the others are fetched the way a browser on youtube.com would.
  Map<String, String> get headers => source == TrailerSource.ios || key.isEmpty
      ? const {}
      : const {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0',
          'Referer': 'https://www.youtube.com/',
        };

  @override
  String toString() => '${source.name}: ${isHls ? 'HLS' : (audioUrl == null ? 'MP4' : 'MP4 + separate audio')}';
}

class _Client {
  final String name;
  final String id;
  final String version;
  final String userAgent;
  final Map<String, Object> extra;

  /// Turns away a request without a visitor id (and hands a fresh one back with the refusal).
  final bool needsVisitor;

  const _Client(this.name, this.id, this.version, this.userAgent, this.extra, {this.needsVisitor = false});
}

/// Finds the stream of a YouTube trailer on this device, with no help from the server.
///
/// YouTube's stream addresses only work from the address that asked for them, so asking from
/// the device that plays is what makes this work everywhere (at home, away, behind Tailscale).
///
/// YouTube is asked the way its own apps ask, several ways in turn, because it regularly turns
/// one of them away for a while:
///  1. as the Vision Pro and the iPhone app at the same time; whichever hands over a playlist
///     first wins. Apple TV's player and mpv both play these natively, up to 1080p and beyond,
///     and they start in a second or two.
///  2. as the Android app, whose single MP4 stops at 360p but almost always comes.
///  3. through youtube_explode_dart, which finds a plain MP4.
/// Every answer is checked before it's used (the playlist opens, the file answers), so a
/// refusal moves on to the next way instead of reaching the player. A way that fails to play
/// is tried last for the rest of the session. Results are kept for an hour, so a trailer looked
/// up when a title page opens plays at once when the Trailer button is pressed.
class YouTubeTrailers {
  YouTubeTrailers._();

  static const _visionOs = _Client(
    'VISIONOS',
    '101',
    '1.02',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15',
    {'deviceMake': 'Apple', 'deviceModel': 'RealityDevice17,1', 'osName': 'visionOS', 'osVersion': '26.5.23O471'},
    needsVisitor: true,
  );
  static const _ios = _Client(
    'IOS',
    '5',
    '20.10.4',
    'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
    {'deviceMake': 'Apple', 'deviceModel': 'iPhone16,2', 'osName': 'iPhone', 'osVersion': '18.3.2.22D82'},
  );
  static const _android = _Client(
    'ANDROID',
    '3',
    '20.10.41',
    'com.google.android.youtube/20.10.41 (Linux; U; Android 11) gzip',
    {
      'deviceMake': 'Google',
      'deviceModel': 'Pixel 5',
      'osName': 'Android',
      'osVersion': '11',
      'androidSdkVersion': 30,
      'platform': 'MOBILE',
    },
  );

  static const _requestTimeout = Duration(seconds: 6);

  static final Map<String, (DateTime, Future<TrailerStream?>)> _cache = {};
  static final Map<TrailerSource, int> _failures = {};
  static String? _visitor;
  static YoutubeExplode? _explode;

  @visibleForTesting
  static void reset() {
    _cache.clear();
    _failures.clear();
    _visitor = null;
  }

  /// The stream for YouTube video [key], or null when it can't be played here. [skip] leaves
  /// out ways already tried for this trailer (see [nextAfter]).
  static Future<TrailerStream?> resolve(String key, {Set<TrailerSource> skip = const {}}) {
    if (skip.isNotEmpty) return _resolve(key, skip);
    final hit = _cache[key];
    if (hit != null && DateTime.now().difference(hit.$1) < const Duration(hours: 1)) return hit.$2;
    final f = _resolve(key, const {});
    _cache[key] = (DateTime.now(), f);
    // A failure isn't kept: the next try asks again.
    f.then(
      (s) {
        if (s == null) _cache.remove(key);
      },
      onError: (_) {
        _cache.remove(key);
      },
    );
    return f;
  }

  /// [failed] wouldn't play: notes it, and finds the same trailer another way, skipping every
  /// way in [tried] (which gets [failed]'s way added). Null when nothing is left.
  static Future<TrailerStream?> nextAfter(TrailerStream failed, Set<TrailerSource> tried) {
    tried.add(failed.source);
    _failures[failed.source] = (_failures[failed.source] ?? 0) + 1;
    _cache.remove(failed.key);
    return _resolve(failed.key, tried);
  }

  static Future<TrailerStream?> _resolve(String key, Set<TrailerSource> skip) async {
    // Ways that failed to play earlier this session are taken out of their place and tried
    // last, the fewest failures first.
    bool fine(TrailerSource x) => !skip.contains(x) && (_failures[x] ?? 0) == 0;
    final order = <List<TrailerSource>>[
      for (final stage in const [
        [TrailerSource.visionOs, TrailerSource.ios],
        [TrailerSource.android],
        [TrailerSource.mp4],
      ])
        if (stage.where(fine).isNotEmpty) stage.where(fine).toList(),
      for (final x
          in TrailerSource.values.where((x) => !skip.contains(x) && !fine(x)).toList()
            ..sort((a, b) => _failures[a]!.compareTo(_failures[b]!)))
        [x],
    ];

    for (final stage in order) {
      final found = await _firstOf(stage.map((s) => _try(key, s)));
      if (found != null) return found;
    }
    return null;
  }

  /// The first of [futures] to finish with a stream, or null when none does.
  static Future<TrailerStream?> _firstOf(Iterable<Future<TrailerStream?>> futures) {
    final list = futures.toList();
    final done = Completer<TrailerStream?>();
    var left = list.length;
    for (final f in list) {
      f.catchError((_) => null).then((s) {
        left--;
        if (done.isCompleted) return;
        if (s != null) {
          done.complete(s);
        } else if (left == 0) {
          done.complete(null);
        }
      });
    }
    return done.future;
  }

  static Future<TrailerStream?> _try(String key, TrailerSource source) async {
    try {
      switch (source) {
        case TrailerSource.visionOs:
        case TrailerSource.ios:
          final client = source == TrailerSource.visionOs ? _visionOs : _ios;
          final data = await _player(key, client);
          final hls = hlsOf(data);
          if (hls == null) return null;
          final s = TrailerStream(
            hls,
            isHls: true,
            audioLanguage: originalAudioLanguage(data),
            key: key,
            source: source,
          );
          return await _playlistOpens(s) ? s : null;
        case TrailerSource.android:
          final data = await _player(key, _android);
          final file = muxedOf(data);
          if (file == null) return null;
          final s = TrailerStream(file, key: key, source: source);
          return await _fileAnswers(s) ? s : null;
        case TrailerSource.mp4:
          final found = await _mp4(key).timeout(const Duration(seconds: 20));
          if (found == null) return null;
          final s = TrailerStream(found.url, audioUrl: found.audioUrl, key: key, source: source);
          return await _fileAnswers(s) ? s : null;
      }
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------ YouTube's player API

  /// YouTube's answer for [key] when asked as [client], or null. A client that needs a visitor
  /// id and has none (or a stale one) gets a fresh id with its refusal, and asks once more.
  static Future<Map<String, dynamic>?> _player(String key, _Client client) async {
    final sent = client.needsVisitor ? _visitor : null;
    final data = await _ask(key, client, sent);
    if (!client.needsVisitor || data == null || statusOf(data) == 'OK') return data;
    final fresh = (data['responseContext'] as Map?)?['visitorData'] as String?;
    if (fresh == null || fresh.isEmpty || fresh == sent) {
      // YouTube handed the same id back: it won't take it any more.
      if (sent != null) _visitor = null;
      return data;
    }
    _visitor = fresh;
    return _ask(key, client, fresh);
  }

  static Future<Map<String, dynamic>?> _ask(String key, _Client client, String? visitor) async {
    final extra = Map<String, Object>.of(client.extra);
    final platform = extra.remove('platform');
    final body = {
      'videoId': key,
      'context': {
        'client': {
          'clientName': client.name,
          'clientVersion': client.version,
          'hl': 'en',
          'gl': 'US',
          'platform': ?platform,
          'visitorData': ?visitor,
          ...extra,
        },
      },
      if (client.name == 'IOS')
        'playbackContext': {
          'contentPlaybackContext': {'html5Preference': 'HTML5_PREF_WANTS'},
        },
      'contentCheckOk': true,
      'racyCheckOk': true,
    };
    final c = http.Client();
    try {
      final res = await c
          .post(
            Uri.parse('https://www.youtube.com/youtubei/v1/player?prettyPrint=false'),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': client.userAgent,
              'X-YouTube-Client-Name': client.id,
              'X-YouTube-Client-Version': client.version,
              'Origin': 'https://www.youtube.com',
              'Referer': 'https://www.youtube.com/',
              'X-Goog-Visitor-Id': ?visitor,
            },
            body: jsonEncode(body),
          )
          .timeout(_requestTimeout);
      if (res.statusCode != 200) return null;
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } finally {
      c.close();
    }
  }

  @visibleForTesting
  static String? statusOf(Map<String, dynamic>? data) => (data?['playabilityStatus'] as Map?)?['status'] as String?;

  /// The HLS playlist in a player answer, when YouTube agreed to play.
  @visibleForTesting
  static String? hlsOf(Map<String, dynamic>? data) {
    if (statusOf(data) != 'OK') return null;
    final url = (data!['streamingData'] as Map?)?['hlsManifestUrl'] as String?;
    return url == null || url.isEmpty ? null : url;
  }

  /// The sharpest H.264 MP4 holding picture and sound together in a player answer.
  @visibleForTesting
  static String? muxedOf(Map<String, dynamic>? data) {
    if (statusOf(data) != 'OK') return null;
    final formats = ((data!['streamingData'] as Map?)?['formats'] as List?)?.whereType<Map>() ?? const [];
    final usable = formats.where((f) {
      final mime = (f['mimeType'] as String? ?? '').toLowerCase();
      return f['url'] is String && mime.startsWith('video/mp4') && mime.contains('avc1') && mime.contains('mp4a');
    }).toList()..sort((a, b) => ((b['height'] as num?) ?? 0).compareTo((a['height'] as num?) ?? 0));
    return usable.isEmpty ? null : usable.first['url'] as String;
  }

  /// The language YouTube marks as the trailer's own soundtrack, or null when it lists no dubs.
  @visibleForTesting
  static String? originalAudioLanguage(Map<String, dynamic>? data) {
    final formats = ((data?['streamingData'] as Map?)?['adaptiveFormats'] as List?)?.whereType<Map>() ?? const [];
    for (final f in formats) {
      final track = f['audioTrack'] as Map?;
      if (track == null || track['audioIsDefault'] != true) continue;
      final lang = (track['id'] as String? ?? '').split('.').first;
      if (lang.isNotEmpty) return lang;
    }
    return null;
  }

  // ------------------------------------------------------------------ checking before playing

  /// The playlist opens and lists an H.264 picture (which every player here can show).
  static Future<bool> _playlistOpens(TrailerStream s) async {
    final c = http.Client();
    try {
      final r = await c.get(Uri.parse(s.url), headers: s.headers).timeout(_requestTimeout);
      return r.statusCode == 200 && r.body.startsWith('#EXTM3U') && r.body.contains('avc1');
    } catch (_) {
      return false;
    } finally {
      c.close();
    }
  }

  /// The file's first bytes come back (YouTube answers 403 when it won't serve this device).
  static Future<bool> _fileAnswers(TrailerStream s) async {
    final c = http.Client();
    try {
      final r = await c
          .get(Uri.parse(s.url), headers: {...s.headers, 'Range': 'bytes=0-1023'})
          .timeout(_requestTimeout);
      return r.statusCode == 200 || r.statusCode == 206;
    } catch (_) {
      return false;
    } finally {
      c.close();
    }
  }

  // ------------------------------------------------------------------ youtube_explode_dart

  /// A plain MP4: the best H.264 picture up to 1080p with the best AAC sound, or one file
  /// holding both when that's all there is.
  static Future<TrailerStream?> _mp4(String key) async {
    final manifest = await (_explode ??= YoutubeExplode()).videos.streamsClient.getManifest(key);
    return pickMp4(manifest.videoOnly.toList(), manifest.audioOnly.toList(), manifest.muxed.toList());
  }

  static TrailerStream? pickMp4(
    List<VideoOnlyStreamInfo> video,
    List<AudioOnlyStreamInfo> audio,
    List<MuxedStreamInfo> muxed,
  ) {
    bool h264(String codec) => codec.toLowerCase().startsWith('avc1');
    final pictures =
        video
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

/// Finds a trailer's stream. Called again with a stream that wouldn't play, it finds the same
/// trailer another way. Null when there's nothing (more) to play.
typedef TrailerResolver = Future<TrailerStream?> Function([TrailerStream? failed]);
