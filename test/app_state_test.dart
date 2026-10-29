import 'dart:convert';

import 'package:ember/api/jellyfin.dart';
import 'package:ember/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> account(String userId, {String server = 'http://jf.local:8096'}) => {
  'serverUrl': server,
  'serverName': 'Test Server',
  'userId': userId,
  'name': 'User $userId',
  'token': 'token-$userId',
  'isAdmin': false,
};

/// AppState as Ember starts it, from what was saved last time.
Future<AppState> start(Map<String, Object> saved) async {
  SharedPreferences.setMockInitialValues(saved);
  final s = AppState();
  await s.init();
  return s;
}

/// Starts Ember again on the same saved settings, as after a restart.
Future<AppState> restart() async {
  final s = AppState();
  await s.init();
  return s;
}

void main() {
  // Nothing here talks to a server; anything that tries gets an empty answer.
  final offline = MockClient((_) async => http.Response('', 204));

  test('first start: no server, a new device id that is kept', () async {
    await http.runWithClient(() async {
      final s = await start({});
      expect(s.ready, isTrue);
      expect(s.serverUrl, isNull);
      expect(s.account, isNull);
      expect(s.deviceId, matches(RegExp(r'^[0-9a-f]{32}$')));
      final again = await restart();
      expect(again.deviceId, s.deviceId);
    }, () => offline);
  });

  test('settings survive a restart', () async {
    await http.runWithClient(() async {
      final s = await start({});
      await s.update((a) {
        a.autoSkipIntro = true;
        a.audioPassthrough = true;
        a.quality = '8m';
        a.subtitleMode = 'always';
        a.preferredAudioLanguage = 'eng';
        a.preferredSubtitleLanguage = 'fre';
        a.useApplePlayer = true;
        a.stillWatchingEpisodes = 5;
        a.interfaceMode = InterfaceMode.tv;
        a.showRecommendations = false;
      });
      final r = await restart();
      expect(r.autoSkipIntro, isTrue);
      expect(r.audioPassthrough, isTrue);
      expect(r.quality, '8m');
      expect(r.subtitleMode, 'always');
      expect(r.preferredAudioLanguage, 'eng');
      expect(r.preferredSubtitleLanguage, 'fre');
      expect(r.useApplePlayer, isTrue);
      expect(r.stillWatchingEpisodes, 5);
      expect(r.interfaceMode, InterfaceMode.tv);
      expect(r.isTv, isTrue);
      expect(r.showRecommendations, isFalse);
    }, () => offline);
  });

  test('defaults when nothing was saved', () async {
    await http.runWithClient(() async {
      final s = await start({});
      expect(s.quality, 'auto');
      expect(s.subtitleMode, 'foreign');
      expect(s.autoplayNext, isTrue);
      expect(s.trailersInApp, isTrue);
      expect(s.useApplePlayer, isFalse);
      expect(s.stillWatching, isTrue);
      expect(s.stillWatchingEpisodes, 3);
      expect(s.interfaceMode, InterfaceMode.auto);
    }, () => offline);
  });

  test('a saved profile signs straight back in', () async {
    await http.runWithClient(() async {
      final s = await start({
        'serverUrl': 'http://jf.local:8096',
        'currentUserId': 'u1',
        'accounts': jsonEncode([account('u1'), account('u2')]),
      });
      expect(s.account?.userId, 'u1');
      expect(s.jf?.token, 'token-u1');
      expect(s.jf?.userId, 'u1');
      expect(s.serverAccounts.map((a) => a.userId), ['u1', 'u2']);
    }, () => offline);
  });

  test('switching, leaving and signing out of profiles', () async {
    await http.runWithClient(() async {
      final s = await start({
        'serverUrl': 'http://jf.local:8096',
        'currentUserId': 'u1',
        'accounts': jsonEncode([account('u1'), account('u2'), account('x', server: 'http://other:8096')]),
      });
      final before = s.revision;
      await s.switchTo(s.serverAccounts.firstWhere((a) => a.userId == 'u2'));
      expect(s.account?.userId, 'u2');
      expect(s.jf?.token, 'token-u2');
      expect(s.revision, greaterThan(before));

      // Leaving keeps the profile saved for one-press switching.
      await s.leaveProfile();
      expect(s.account, isNull);
      expect(s.accounts.length, 3);
      expect((await restart()).currentUserId, isNull);

      // Signing out forgets it.
      await s.switchTo(s.accounts.firstWhere((a) => a.userId == 'u2'));
      await s.signOut();
      expect(s.account, isNull);
      expect(s.accounts.map((a) => a.userId), ['u1', 'x']);
      expect((await restart()).accounts.map((a) => a.userId), ['u1', 'x']);
    }, () => offline);
  });

  test('a new sign-in replaces the old one for the same person', () async {
    await http.runWithClient(() async {
      final s = await start({
        'serverUrl': 'http://jf.local:8096',
        'serverName': 'Test Server',
        'accounts': jsonEncode([account('u1')]),
      });
      await s.signedIn(
        AuthResult('fresh', {
          'Id': 'u1',
          'Name': 'Alex',
          'Policy': {'IsAdministrator': true},
        }),
      );
      expect(s.accounts.length, 1);
      expect(s.account?.token, 'fresh');
      expect(s.account?.isAdmin, isTrue);
      expect((await restart()).account?.token, 'fresh');
    }, () => offline);
  });

  test('a damaged saved account list does not stop Ember from starting', () async {
    await http.runWithClient(() async {
      final s = await start({'serverUrl': 'http://jf.local:8096', 'accounts': '{not json'});
      expect(s.ready, isTrue);
      expect(s.accounts, isEmpty);
    }, () => offline);
  });

  test('forgetting the server goes back to Connect', () async {
    await http.runWithClient(() async {
      final s = await start({
        'serverUrl': 'http://jf.local:8096',
        'currentUserId': 'u1',
        'accounts': jsonEncode([account('u1')]),
      });
      await s.forgetServer();
      expect(s.serverUrl, isNull);
      expect(s.jf, isNull);
      expect((await restart()).serverUrl, isNull);
    }, () => offline);
  });

  test('setServer tidies the address', () async {
    await http.runWithClient(() async {
      final s = await start({});
      await s.setServer('hearth:8096/web/', 'Hearth');
      expect(s.serverUrl, 'http://hearth:8096');
      expect(s.jf?.baseUrl, 'http://hearth:8096');
    }, () => offline);
  });

  group('maxBitrateFor', () {
    test('a fixed quality is used as chosen', () async {
      await http.runWithClient(() async {
        final s = await start({});
        expect(await s.maxBitrateFor(30000000, qualityKey: '8m'), 8000000);
        expect(await s.maxBitrateFor(30000000, qualityKey: 'original'), isNull);
        expect(await s.maxBitrateFor(null, qualityKey: '2m'), 2000000);
      }, () => offline);
    });

    test('Auto plays the original when the file size is unknown', () async {
      await http.runWithClient(() async {
        final s = await start({});
        expect(await s.maxBitrateFor(null), isNull);
      }, () => offline);
    });
  });
}
