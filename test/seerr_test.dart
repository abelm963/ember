import 'dart:convert';

import 'package:ember/api/jellyfin.dart';
import 'package:ember/api/seerr.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Quick Connect sign-in keeps the session and re-signs in when it expires', () async {
    var authorized = '';
    var sessions = 0;
    String? valid;
    final mock = MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/quickconnect/initiate')) return http.Response(jsonEncode({'code': '123456', 'secret': 's$sessions'}), 200);
      if (p.endsWith('/quickconnect/check')) return http.Response(jsonEncode({'authenticated': authorized.isNotEmpty}), 200);
      if (p.endsWith('/quickconnect/authenticate')) {
        sessions++;
        valid = 'sid$sessions';
        return http.Response(jsonEncode({'id': 1}), 200, headers: {'set-cookie': 'connect.sid=$valid; Path=/; HttpOnly'});
      }
      final ok = req.headers['cookie']?.contains('connect.sid=$valid') ?? false;
      if (!ok) return http.Response(jsonEncode({'message': 'Unauthorized'}), 401);
      return http.Response(jsonEncode({'results': [{'id': 1, 'mediaType': 'movie', 'title': 'Dune'}]}), 200);
    });
    await http.runWithClient(() async {
      final s = SeerrClient(baseUrl: 'https://seerr.test/login');
      expect(s.baseUrl, 'https://seerr.test');
      await s.signInWithQuickConnect((code) async => authorized = code);
      expect(authorized, '123456');
      expect(s.cookie, 'connect.sid=sid1');
      expect((await s.trending()).single.title, 'Dune');
      // Server forgets the session; the client signs in again by itself and retries.
      valid = 'gone';
      s.reauth = () async {
        await s.signInWithQuickConnect((code) async {});
        return true;
      };
      expect((await s.trending()).single.title, 'Dune');
      expect(s.cookie, 'connect.sid=sid2');
    }, () => mock);
  });

  test('finds Seerr next to Jellyfin and reads recommendations', () async {
    final mock = MockClient((req) async {
      final u = req.url;
      if (u.port != 5055 || u.host != 'media.example') throw Exception('nothing here');
      if (u.path == '/api/v1/status') return http.Response(jsonEncode({'version': '3.5.0'}), 200);
      if (u.path == '/api/v1/movie/438631/recommendations') {
        return http.Response(jsonEncode({'results': [{'id': 693134, 'title': 'Dune: Part Two'}]}), 200);
      }
      return http.Response('{}', 404);
    });
    await http.runWithClient(() async {
      // Linked in a Jellyfin plugin as a Docker name: the same port on Jellyfin's host answers.
      final known = JellyfinClient.seerrUrlsIn({
        'TmdbApiKey': 'x',
        'Jellyseerr': {'Enabled': true, 'JellyseerrUrls': 'http://jellyseerr:5055\nhttps://outside.example'},
        'HomepageUrl': 'https://not-this.example',
      });
      expect(known, ['http://jellyseerr:5055', 'https://outside.example']);
      expect(await SeerrClient.findNear('http://media.example:8096', known: known), 'http://media.example:5055');
      final found = await SeerrClient.findNear('https://media.example:8920/web');
      expect(found, 'https://media.example:5055');
      final recs = await SeerrClient(baseUrl: found!).recommendations('movie', 438631);
      expect(recs.single.title, 'Dune: Part Two');
      expect(recs.single.mediaType, 'movie');
    }, () => mock);
  });
}
