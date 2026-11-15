// The things that used to leave Ember stuck: a session the server no longer accepts, Seerr not
// answering, and pages being thrown away when nothing they show had changed.
import 'dart:convert';

import 'package:ember/api/jellyfin.dart';
import 'package:ember/api/seerr.dart';
import 'package:ember/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const server = 'http://jf.local:8096';

Map<String, Object> saved({String? seerrCookie}) => {
  'serverUrl': server,
  'serverName': 'Test Server',
  'currentUserId': 'u1',
  'seerrUrl': 'http://jf.local:5055',
  'accounts': jsonEncode([
    {
      'serverUrl': server,
      'serverName': 'Test Server',
      'userId': 'u1',
      'name': 'Abel',
      'token': 'token-u1',
      'isAdmin': true,
      'seerrCookie': seerrCookie,
    },
  ]),
};

Future<AppState> start(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  final s = AppState();
  await s.init();
  return s;
}

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  test('a session the server no longer accepts takes the person back to the profiles', () async {
    var meCalls = 0;
    final client = MockClient((req) async {
      if (req.url.port == 5055) return json({'id': 1, 'permissions': 2});
      if (req.url.path == '/Users/Me') meCalls++;
      return http.Response('', 401);
    });
    await http.runWithClient(() async {
      final app = await start(saved(seerrCookie: 'connect.sid=abc'));
      String? told;
      app.onSignedOut = (m) => told = m;
      expect(app.account, isNotNull);
      // Two pages asking at once lead to one check, not two.
      await Future.wait([
        app.jf!.views().then<void>((_) {}, onError: (_) {}),
        app.jf!.resume().then<void>((_) {}, onError: (_) {}),
      ]);
      await pumpEventQueue();
      expect(meCalls, 1);
      expect(app.account, isNull);
      expect(app.accounts, isEmpty);
      expect(told, contains('Abel'));
      // And it stays that way after a restart.
      final again = AppState();
      await again.init();
      expect(again.account, isNull);
    }, () => client);
  });

  test('a 401 that is not about the session leaves the person signed in', () async {
    final client = MockClient((req) async {
      if (req.url.port == 5055) return json({'id': 1, 'permissions': 2});
      if (req.url.path == '/Users/Me') return json({'Id': 'u1'});
      if (req.url.path == '/UserViews') return http.Response('', 401);
      return http.Response('', 204);
    });
    await http.runWithClient(() async {
      final app = await start(saved(seerrCookie: 'connect.sid=abc'));
      var told = false;
      app.onSignedOut = (_) => told = true;
      await expectLater(app.jf!.views(), throwsA(isA<ApiException>()));
      await pumpEventQueue();
      expect(app.account, isNotNull);
      expect(told, isFalse);
    }, () => client);
  });

  test('a wrong password does not count as an expired session', () async {
    final client = MockClient(
      (req) async => http.Response('', req.url.path == '/Users/AuthenticateByName' ? 401 : 204),
    );
    await http.runWithClient(() async {
      final app = await start(saved(seerrCookie: 'connect.sid=abc'));
      await expectLater(app.jf!.authenticateByName('abel', 'nope'), throwsA(isA<ApiException>()));
      await pumpEventQueue();
      expect(app.accounts, hasLength(1));
    }, () => client);
  });

  test('Seerr not answering: asked once, then left alone instead of holding every page up', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      throw http.ClientException('Connection refused');
    });
    await http.runWithClient(() async {
      final seerr = SeerrClient(baseUrl: 'http://jf.local:5055', cookie: 'connect.sid=abc');
      await expectLater(seerr.trending(), throwsA(isA<ApiException>()));
      expect(seerr.unreachable, isTrue);
      await expectLater(seerr.details('movie', 1), throwsA(isA<ApiException>()));
      await expectLater(seerr.recommendations('movie', 1), throwsA(isA<ApiException>()));
      expect(calls, 1);
      // Settings › Check connection asks again straight away.
      seerr.tryAgain();
      await expectLater(seerr.trending(), throwsA(isA<ApiException>()));
      expect(calls, 2);
      expect(requestErrorText(ApiException(-1, "Seerr isn't answering right now.")), contains("couldn't reach Seerr"));
    }, () => client);
  });

  test('an error answer from Seerr is not "unreachable"', () async {
    final client = MockClient((req) async => json({'message': 'nope'}, 500));
    await http.runWithClient(() async {
      final seerr = SeerrClient(baseUrl: 'http://jf.local:5055', cookie: 'connect.sid=abc');
      await expectLater(seerr.trending(), throwsA(isA<ApiException>()));
      expect(seerr.unreachable, isFalse);
    }, () => client);
  });

  test('starting with a saved Seerr session does not make every page load twice', () async {
    final client = MockClient((req) async {
      if (req.url.port == 5055) {
        if (req.url.path.endsWith('/auth/me')) return json({'id': 1, 'permissions': 2});
        return json({});
      }
      return http.Response('', 204);
    });
    await http.runWithClient(() async {
      final app = await start(saved(seerrCookie: 'connect.sid=abc'));
      expect(app.seerrConfigured, isTrue);
      final before = app.revision;
      await app.refreshSeerr();
      expect(app.seerrUser, isNotNull);
      expect(app.revision, before);
    }, () => client);
  });
}
