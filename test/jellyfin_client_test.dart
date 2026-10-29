import 'dart:convert';

import 'package:ember/api/jellyfin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A signed-in client; requests go to [server] through http.runWithClient.
JellyfinClient fake({bool appleTv = false}) {
  return JellyfinClient(
    baseUrl: 'http://jf.local:8096',
    deviceId: 'dev1',
    deviceName: 'Test',
    token: 'secret-token',
    userId: 'u1',
    appleTv: appleTv,
  );
}

/// A fake Jellyfin that records each request ([log]) and answers PlaybackInfo with [source].
http.Client server(List<http.Request> log, {Map<String, dynamic>? source, int status = 200}) => MockClient((req) async {
  log.add(req);
  if (status != 200) return http.Response('', status);
  if (req.url.path.endsWith('/PlaybackInfo')) {
    return http.Response(
      jsonEncode({
        'PlaySessionId': 'ps1',
        'MediaSources': [
          source ??
              {
                'Id': 'ms1',
                'SupportsDirectPlay': true,
                'Bitrate': 8000000,
                'MediaStreams': [
                  {'Index': 1, 'Type': 'Audio', 'Language': 'eng'},
                ],
              },
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
  return http.Response('', 204);
});

void main() {
  group('normalizeUrl', () {
    test('adds http and drops the web app path, query and slashes', () {
      expect(JellyfinClient.normalizeUrl('hearth:8096'), 'http://hearth:8096');
      expect(JellyfinClient.normalizeUrl(' https://host/web/#/home '), 'https://host');
      expect(JellyfinClient.normalizeUrl('https://host/web/index.html?x=1'), 'https://host');
      expect(JellyfinClient.normalizeUrl('http://host:8096///'), 'http://host:8096');
    });

    test('keeps a reverse-proxy base path', () {
      expect(JellyfinClient.normalizeUrl('https://host/jellyfin/web/'), 'https://host/jellyfin');
      expect(JellyfinClient.normalizeUrl('https://host/jellyfin'), 'https://host/jellyfin');
    });

    test('leaves an empty address empty', () {
      expect(JellyfinClient.normalizeUrl('   '), '');
    });
  });

  test('the sign-in header is plain ASCII and carries the token', () {
    final c = JellyfinClient(
      baseUrl: 'http://h',
      deviceId: 'd1',
      deviceName: 'Abel’s "TV" ✓',
      token: 'tok',
      appleTv: false,
    );
    final h = c.authHeader;
    expect(h, startsWith('MediaBrowser '));
    expect(h, contains('Token="tok"'));
    expect(RegExp(r'^[\x20-\x7E]+$').hasMatch(h), isTrue, reason: h);
  });

  test('an expired session says so in plain words', () async {
    final log = <http.Request>[];
    final c = fake();
    await http.runWithClient(() async {
      await expectLater(
        c.views(),
        throwsA(
          isA<ApiException>().having((e) => e.status, 'status', 401).having((e) => '$e', 'text', contains('sign in')),
        ),
      );
    }, () => server(log, status: 401));
  });

  group('playbackSource', () {
    test('desktop: direct play of the original file', () async {
      final log = <http.Request>[];
      final c = fake();
      final src = await http.runWithClient(
        () => c.playbackSource('m1', start: const Duration(seconds: 90)),
        () => server(log),
      );
      final body = jsonDecode(log.single.body) as Map;
      expect(body['EnableDirectPlay'], isTrue);
      expect(body['EnableTranscoding'], isFalse);
      expect(body['StartTimeTicks'], 900000000);
      expect(body['DeviceProfile']['Name'], 'Ember');
      expect(src.transcoding, isFalse);
      expect(src.mediaSourceId, 'ms1');
      expect(src.playSessionId, 'ps1');
      expect(src.url, contains('/Videos/m1/stream'));
      expect(src.url, contains('static=true'));
    });

    test('desktop: a lower quality asks the server to convert', () async {
      final log = <http.Request>[];
      final c = fake();
      final src = await http.runWithClient(
        () => c.playbackSource('m1', maxBitrate: 4000000),
        () => server(log, source: {'Id': 'ms1', 'TranscodingUrl': '/videos/m1/master.m3u8?x=1'}),
      );
      final body = jsonDecode(log.single.body) as Map;
      expect(body['EnableDirectPlay'], isFalse);
      expect(body['MaxStreamingBitrate'], 4000000);
      expect(src.transcoding, isTrue);
      expect(src.url, 'http://jf.local:8096/videos/m1/master.m3u8?x=1');
    });

    test('Apple TV: a chosen soundtrack always goes through the server', () async {
      // The "Frozen in French" fix: with several soundtracks, Apple's player can't be left to pick.
      final log = <http.Request>[];
      final c = fake(appleTv: true);
      final src = await http.runWithClient(
        () => c.playbackSource('m1', audioStreamIndex: 2, mediaSourceId: 'ms1'),
        () => server(log, source: {'Id': 'ms1', 'SupportsDirectPlay': true, 'TranscodingUrl': '/videos/m1/main.m3u8'}),
      );
      final body = jsonDecode(log.single.body) as Map;
      expect(body['DeviceProfile']['Name'], 'Ember Apple TV');
      expect(body['AudioStreamIndex'], 2);
      expect(body['EnableDirectPlay'], isFalse);
      expect(src.transcoding, isTrue);
      expect(src.url, endsWith('/videos/m1/main.m3u8'));
    });

    test('Apple TV: declares HDR and Dolby Vision so they pass through', () async {
      final log = <http.Request>[];
      final c = fake(appleTv: true);
      await http.runWithClient(() => c.playbackSource('m1'), () => server(log));
      final profile = (jsonDecode(log.single.body) as Map)['DeviceProfile'] as Map;
      final hevc = (profile['CodecProfiles'] as List).firstWhere((p) => p['Codec'] == 'hevc') as Map;
      final ranges = (hevc['Conditions'] as List).first['Value'] as String;
      for (final r in ['HDR10', 'HDR10Plus', 'HLG', 'DOVI']) {
        expect(ranges.split('|'), contains(r));
      }
      final subs = profile['SubtitleProfiles'] as List;
      expect(subs.firstWhere((s) => s['Format'] == 'pgssub')['Method'], 'Encode');
      expect(subs.firstWhere((s) => s['Format'] == 'vtt')['Method'], 'Hls');
    });

    test('Apple TV: an untouched MP4 plays directly', () async {
      final log = <http.Request>[];
      final c = fake(appleTv: true);
      final src = await http.runWithClient(() => c.playbackSource('m1'), () => server(log));
      expect((jsonDecode(log.single.body) as Map)['EnableDirectPlay'], isTrue);
      expect(src.transcoding, isFalse);
      expect(src.url, contains('static=true'));
    });
  });

  test('progress reports carry the position in ticks and the pause state', () async {
    final log = <http.Request>[];
    final c = fake();
    await http.runWithClient(
      () => c.reportProgress('m1', 'ms1', 'ps1', const Duration(minutes: 1), true, false),
      () => server(log),
    );
    final r = log.single;
    expect(r.url.path, '/Sessions/Playing/Progress');
    final body = jsonDecode(r.body) as Map;
    expect(body['ItemId'], 'm1');
    expect(body['PositionTicks'], 600000000);
    expect(body['IsPaused'], isTrue);
  });

  test('ticks convert both ways', () {
    expect(durationToTicks(const Duration(seconds: 1)), 10000000);
    expect(ticksToDuration(10000000), const Duration(seconds: 1));
  });
}
