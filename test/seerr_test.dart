import 'dart:convert';

import 'package:ember/api/jellyfin.dart' show ApiException;
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

  SeerrRequest req(
    int status,
    Map<String, dynamic> media, {
    bool uhd = false,
    List<int>? seasons,
    String type = 'movie',
  }) => SeerrRequest({
    'id': 1,
    'status': status,
    'is4k': uhd,
    'type': type,
    if (seasons != null)
      'seasons': [
        for (final n in seasons) {'seasonNumber': n},
      ],
    'media': {'tmdbId': 10, 'mediaType': type, ...media},
  });

  test('request status: approval comes before availability', () {
    // Someone else's HD copy is on the server, but this request still waits or was declined.
    expect(req(1, {'status': 5}).label, 'Pending approval');
    expect(req(3, {'status': 4}).label, 'Declined');
    expect(req(4, {'status': 3}).filterKey, 'Declined');
    expect(req(2, {'status': 5}).label, 'Available');
    expect(req(2, {'status': 3}).label, 'Approved · waiting for release');
    expect(
      req(2, {
        'status': 3,
        'downloadStatus': [
          {'size': 100, 'sizeLeft': 25},
        ],
      }).label,
      'Downloading',
    );
    expect(
      req(2, {
        'status': 3,
        'downloadStatus': [
          {'size': 100, 'sizeLeft': 25},
        ],
      }).downloadProgress,
      0.75,
    );
  });

  test('a 4K request follows the 4K copy', () {
    final r = req(2, {'status': 5, 'status4k': 3, 'jellyfinMediaId': 'hd', 'jellyfinMediaId4k': null}, uhd: true);
    expect(r.label, 'Approved · waiting for release');
    expect(r.playable, isFalse);
    expect(r.arriving, isTrue);
    final done = req(2, {'status': 1, 'status4k': 5, 'jellyfinMediaId4k': 'uhd'}, uhd: true);
    expect(done.label, 'Available');
    expect(done.jellyfinId, 'uhd');
  });

  test('a series request only counts the seasons it asked for', () {
    final media = {
      'status': 4,
      'jellyfinMediaId': 'show',
      'seasons': [
        {'seasonNumber': 1, 'status': 5},
        {'seasonNumber': 2, 'status': 3},
        {'seasonNumber': 3, 'status': 3},
      ],
    };
    expect(req(2, media, seasons: [1], type: 'tv').label, 'Available');
    expect(req(2, media, seasons: [2, 3], type: 'tv').label, 'Approved · waiting for release');
    expect(req(2, media, seasons: [2, 3], type: 'tv').playable, isFalse);
    expect(req(2, media, seasons: [1, 2], type: 'tv').label, 'Partly available');
    expect(req(2, media, seasons: [1, 2], type: 'tv').playable, isTrue);
  });

  test('requests asks Seerr for one person\'s requests, and request returns the stored status', () async {
    Uri? asked;
    Object? sent;
    final mock = MockClient((r) async {
      if (r.method == 'GET' && r.url.path.endsWith('/request')) {
        asked = r.url;
        return http.Response(jsonEncode({'results': []}), 200);
      }
      if (r.method == 'POST' && r.url.path.endsWith('/request')) {
        sent = jsonDecode(r.body);
        return http.Response(jsonEncode({'id': 7, 'status': 1, 'media': {}}), 201);
      }
      return http.Response('{}', 404);
    });
    await http.runWithClient(() async {
      final s = SeerrClient(baseUrl: 'http://seerr.test', apiKey: 'k');
      await s.requests(take: 30, requestedBy: 4);
      final made = await s.request(mediaType: 'tv', tmdbId: 10, seasons: [2], is4k: true);
      expect(made?.status, 1);
    }, () => mock);
    expect(asked?.queryParameters['requestedBy'], '4');
    expect(asked?.queryParameters['take'], '30');
    expect(sent, {
      'mediaType': 'tv',
      'mediaId': 10,
      'seasons': [2],
      'is4k': true,
    });
  });

  test('request errors read as plain words', () {
    expect(requestErrorText(Exception('SocketException: failed')), contains("couldn't reach Seerr"));
    expect(requestErrorText(_api(403, 'Seerr refused the request (Movie Quota exceeded.)')), contains('request limit'));
    expect(
      requestErrorText(_api(403, 'Seerr refused the request (You do not have permission to make 4K requests.)')),
      contains('4K'),
    );
    expect(
      requestErrorText(_api(409, 'Seerr returned 409: Request for this media already exists.')),
      'This has already been requested.',
    );
  });
}

ApiException _api(int status, String message) => ApiException(status, message);
