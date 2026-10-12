import 'dart:convert';

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
}
