import 'dart:convert';

import 'package:ember/api/youtube.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A stand-in for YouTube: [answers] says what each app is told, by client name.
Future<T> withYouTube<T>(
  Map<String, Map<String, dynamic> Function(Map body, http.Request r)> answers,
  Future<T> Function() body, {
  Set<String> refusedFiles = const {},
  List<String>? asked,
}) {
  final client = MockClient((r) async {
    if (r.url.path == '/youtubei/v1/player') {
      final b = jsonDecode(r.body) as Map;
      final name = b['context']['client']['clientName'] as String;
      asked?.add(name);
      final answer = answers[name];
      if (answer == null) return http.Response('{}', 400);
      return http.Response(jsonEncode(answer(b, r)), 200);
    }
    if (refusedFiles.contains(r.url.toString())) return http.Response('', 403);
    if (r.url.path.endsWith('.m3u8')) {
      return http.Response('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="avc1.4d401f,mp4a.40.2"\nv.m3u8\n', 200);
    }
    if (r.url.host == 'video.test') return http.Response('x', 206);
    return http.Response('', 404);
  });
  return http.runWithClient(body, () => client);
}

Map<String, dynamic> ok({String? hls, List<Map>? formats, String? original}) => {
  'playabilityStatus': {'status': 'OK'},
  'streamingData': {
    'hlsManifestUrl': ?hls,
    'formats': ?formats,
    if (original != null)
      'adaptiveFormats': [
        {
          'audioTrack': {'id': 'de.3', 'audioIsDefault': false},
        },
        {
          'audioTrack': {'id': '$original.4', 'audioIsDefault': true},
        },
      ],
  },
};

Map<String, dynamic> refused({String? visitor}) => {
  'playabilityStatus': {'status': 'LOGIN_REQUIRED', 'reason': 'Sign in to confirm you\'re not a bot'},
  'responseContext': {'visitorData': ?visitor},
};

const androidFormats = [
  {'url': 'https://video.test/144.mp4', 'mimeType': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"', 'height': 144},
  {'url': 'https://video.test/360.mp4', 'mimeType': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"', 'height': 360},
  {'url': 'https://video.test/360.webm', 'mimeType': 'video/webm; codecs="vp9, opus"', 'height': 720},
];

void main() {
  setUp(YouTubeTrailers.reset);

  test('Vision Pro way asks again with the visitor id YouTube hands back', () async {
    final s = await withYouTube({
      'VISIONOS': (b, r) => b['context']['client']['visitorData'] == 'v1' && r.headers['X-Goog-Visitor-Id'] == 'v1'
          ? ok(hls: 'https://manifest.test/vision.m3u8', original: 'en')
          : refused(visitor: 'v1'),
      'IOS': (b, r) => refused(),
    }, () => YouTubeTrailers.resolve('abc'));
    expect(s?.source, TrailerSource.visionOs);
    expect(s?.isHls, isTrue);
    expect(s?.audioLanguage, 'en');
    expect(s?.headers['Referer'], 'https://www.youtube.com/');
  });

  test('the iPhone way wins when the Vision Pro way is turned away', () async {
    final s = await withYouTube({
      'VISIONOS': (b, r) => refused(visitor: 'same'),
      'IOS': (b, r) => ok(hls: 'https://manifest.test/ios.m3u8'),
    }, () => YouTubeTrailers.resolve('abc'));
    expect(s?.source, TrailerSource.ios);
    expect(s?.headers, isEmpty);
  });

  test('a playlist that will not open moves on to the Android file', () async {
    final s = await withYouTube(
      {
        'VISIONOS': (b, r) => refused(),
        'IOS': (b, r) => ok(hls: 'https://manifest.test/ios.m3u8'),
        'ANDROID': (b, r) => ok(formats: androidFormats),
      },
      () => YouTubeTrailers.resolve('abc'),
      refusedFiles: {'https://manifest.test/ios.m3u8'},
    );
    expect(s?.source, TrailerSource.android);
    expect(s?.url, 'https://video.test/360.mp4');
  });

  test('a stream that would not play is skipped, and tried last afterwards', () async {
    final asked = <String>[];
    final answers = {
      'VISIONOS': (Map b, http.Request r) => refused(),
      'IOS': (Map b, http.Request r) => ok(hls: 'https://manifest.test/ios.m3u8'),
      'ANDROID': (Map b, http.Request r) => ok(formats: androidFormats),
    };
    await withYouTube(answers, () async {
      final first = await YouTubeTrailers.resolve('abc');
      expect(first?.source, TrailerSource.ios);
      final tried = <TrailerSource>{};
      final second = await YouTubeTrailers.nextAfter(first!, tried);
      expect(second?.source, TrailerSource.android);
      // Another trailer: the iPhone way, which wouldn't play, is now only asked after the others.
      asked.clear();
      final other = await YouTubeTrailers.resolve('xyz');
      expect(other?.source, TrailerSource.android);
      expect(asked, isNot(contains('IOS')));
    }, asked: asked);
  });

  test('answers are read safely', () {
    expect(YouTubeTrailers.hlsOf(refused()), isNull);
    expect(YouTubeTrailers.muxedOf(ok(formats: [androidFormats[2]])), isNull);
    expect(YouTubeTrailers.originalAudioLanguage(ok()), isNull);
    expect(YouTubeTrailers.originalAudioLanguage(ok(original: 'ja')), 'ja');
  });
}
