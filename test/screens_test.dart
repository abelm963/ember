import 'dart:convert';

import 'package:ember/main.dart';
import 'package:ember/ui/browse.dart' show FilterButton;
import 'package:ember/screens/details.dart';
import 'package:ember/screens/discover.dart';
import 'package:ember/screens/preview.dart';
import 'package:ember/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> movie(String id, String name) => {
      'Id': id,
      'Name': name,
      'Type': 'Movie',
      'ProductionYear': 2024,
      'OfficialRating': 'PG-13',
      'CommunityRating': 7.8,
      'RunTimeTicks': 72000000000,
      'Overview': 'A long overview of the film that goes on for a while so we can see wrapping behaviour on screen.',
      'Genres': ['Drama', 'Sci-Fi'],
      'ImageTags': {'Primary': 'p'},
      'BackdropImageTags': ['b'],
      'UserData': {
        'PlaybackPositionTicks': 18000000000,
        'Played': false,
        'IsFavorite': false,
        'LastPlayedDate': DateTime.now().subtract(const Duration(days: 3)).toUtc().toIso8601String(),
      },
      'ProviderIds': {'Tmdb': '100'},
      'People': [
        {'Id': 'p1', 'Name': 'Ada Actor', 'Role': 'Lead', 'Type': 'Actor'},
        {'Id': 'p2', 'Name': 'Dee Director', 'Type': 'Director'},
      ],
      'RemoteTrailers': [
        {'Url': 'https://www.youtube.com/watch?v=abc'}
      ],
      'LocalTrailerCount': 0,
    };

Map<String, dynamic> series(String id, String name) => {
      ...movie(id, name),
      'Type': 'Series',
      'ChildCount': 2,
      'UserData': {'UnplayedItemCount': 3},
    };

Map<String, dynamic> episode(String id, int s, int e) => {
      'Id': id,
      'Name': 'Episode $e title',
      'Type': 'Episode',
      'SeriesId': 's1',
      'SeriesName': 'Harbor Lights',
      'SeasonId': 'season$s',
      'IndexNumber': e,
      'ParentIndexNumber': s,
      'RunTimeTicks': 30000000000,
      'Overview': 'Something happens in this episode.',
      'ImageTags': {'Primary': 'p'},
      'UserData': {'PlaybackPositionTicks': 0},
    };

http.Client mockClient() => MockClient((req) async {
      final p = req.url.path;
      Object body;
      if (p.endsWith('/UserViews')) {
        body = {
          'Items': [
            {'Id': 'lib1', 'Name': 'Movies', 'CollectionType': 'movies', 'Type': 'CollectionFolder'},
            {'Id': 'lib2', 'Name': 'Shows', 'CollectionType': 'tvshows', 'Type': 'CollectionFolder'},
          ]
        };
      } else if (p.endsWith('/UserItems/Resume')) {
        body = {'Items': [movie('m1', 'The Quiet Orbit'), episode('e1', 1, 2)]};
      } else if (p.endsWith('/Shows/NextUp')) {
        body = {'Items': [episode('e3', 1, 3)]};
      } else if (p.endsWith('/Items/Latest')) {
        body = [movie('m2', 'Paper Wolves'), series('s1', 'Harbor Lights')];
      } else if (p.endsWith('/Shows/s1/Seasons')) {
        body = {
          'Items': [
            {'Id': 'season1', 'Name': 'Season 1', 'Type': 'Season', 'IndexNumber': 1, 'SeriesId': 's1'},
          ]
        };
      } else if (p.endsWith('/Shows/s1/Episodes')) {
        body = {'Items': [episode('e1', 1, 1), episode('e2', 1, 2)]};
      } else if (p.endsWith('/Similar')) {
        body = {'Items': [movie('m3', 'Glasshouse')]};
      } else if (p.endsWith('/Genres')) {
        body = {'Items': [{'Name': 'Drama'}, {'Name': 'Comedy'}]};
      } else if (RegExp(r'/Items/(m\d|s1)$').hasMatch(p)) {
        final id = p.split('/').last;
        body = id == 's1' ? series('s1', 'Harbor Lights') : movie(id, 'The Quiet Orbit');
      } else if (p.endsWith('/Items')) {
        body = {'Items': [movie('m1', 'The Quiet Orbit'), series('s1', 'Harbor Lights')]};
      } else if (p.endsWith('/api/v1/discover/movies') || p.endsWith('/api/v1/discover/tv')) {
        final soon = DateTime.now().add(const Duration(days: 9)).toIso8601String().substring(0, 10);
        body = {
          'results': [
            if (p.endsWith('movies')) {'id': 7, 'mediaType': 'movie', 'title': 'Copper Coast', 'releaseDate': soon, 'genreIds': [18, 53], 'overview': 'A storm is coming.'},
            if (p.endsWith('tv')) {'id': 8, 'mediaType': 'tv', 'name': 'Low Tide', 'firstAirDate': soon, 'mediaInfo': {'status': 2}},
          ]
        };
      } else if (p.endsWith('/EmberTrailers/Calendar')) {
        final d = DateTime.now().add(const Duration(days: 12)).toIso8601String().substring(0, 10);
        final later = DateTime.now().add(const Duration(days: 60)).toIso8601String().substring(0, 10);
        body = {
          'items': [
            {'mediaType': 'movie', 'tmdbId': 7, 'title': 'Copper Coast', 'date': d, 'kind': 'cinema', 'cinemaDate': d, 'digitalDate': later, 'genres': ['Drama']},
            {'mediaType': 'tv', 'tmdbId': 8, 'title': 'Low Tide', 'date': d, 'kind': 'season', 'seasonNumber': 2, 'genres': ['Drama']},
          ]
        };
      } else if (p.endsWith('/Shows/Upcoming')) {
        body = {
          'Items': [
            {'Id': 'e9', 'Type': 'Episode', 'Name': 'Return', 'SeriesName': 'Harbor Lights', 'SeriesId': 's1', 'ParentIndexNumber': 2, 'IndexNumber': 1,
             'PremiereDate': DateTime.now().add(const Duration(days: 3)).toUtc().toIso8601String(), 'ImageTags': {}},
          ]
        };
      } else if (p.endsWith('/api/v1/discover/watchlist')) {
        body = {
          'page': 1,
          'totalPages': 1,
          'results': [
            {'tmdbId': 5, 'mediaType': 'tv', 'title': 'Kingfisher'},
          ]
        };
      } else if (p.endsWith('/api/v1/discover/trending')) {
        body = {
          'results': [
            {'id': 5, 'mediaType': 'tv', 'name': 'Kingfisher', 'backdropPath': '/x.jpg'},
            {'id': 6, 'mediaType': 'movie', 'title': 'Ashfall', 'mediaInfo': {'status': 2}},
          ]
        };
      } else if (p.endsWith('/recommendations')) {
        body = {
          'results': [
            for (var i = 0; i < 5; i++) {'id': 40 + i, 'title': 'Pick $i', 'backdropPath': '/p$i.jpg'},
            {'id': 49, 'title': 'Already Here', 'mediaInfo': {'status': 5}},
          ]
        };
      } else if (p.endsWith('/api/v1/auth/me')) {
        body = {'id': 1, 'displayName': 'Alex', 'permissions': 2};
      } else if (p.endsWith('/api/v1/tv/5')) {
        body = {
          'id': 5,
          'name': 'Kingfisher',
          'overview': 'A river warden logs boats that do not exist.',
          'firstAirDate': '2024-01-01',
          'voteAverage': 7.9,
          'numberOfSeasons': 2,
          'genres': [{'name': 'Thriller'}],
          'seasons': [
            {'seasonNumber': 1, 'name': 'Season 1', 'episodeCount': 10, 'airDate': '2024-01-01'},
            {'seasonNumber': 2, 'name': 'Season 2', 'episodeCount': 8, 'airDate': '2025-01-01'},
          ],
          'credits': {
            'cast': [
              {'name': 'Hana L', 'character': 'Iris'}
            ],
            'crew': []
          },
          'relatedVideos': [
            {'site': 'YouTube', 'type': 'Trailer', 'key': 'xyz'}
          ],
        };
      } else if (p.contains('/api/v1/tv/5/similar') || p.contains('/api/v1/search')) {
        body = {'results': []};
      } else if (p.endsWith('/api/v1/request')) {
        body = {'results': []};
      } else {
        body = {'Items': []};
      }
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    });

Future<AppState> signedInState(String mode) async {
  SharedPreferences.setMockInitialValues({
    'interfaceMode': mode,
    'serverUrl': 'http://jf.local:8096',
    'serverName': 'Test Server',
    'currentUserId': 'u1',
    'seerrUrl': 'http://seerr.local:5055',
    'accounts': jsonEncode([
      {
        'serverUrl': 'http://jf.local:8096',
        'serverName': 'Test Server',
        'userId': 'u1',
        'name': 'Alex',
        'token': 't',
        'isAdmin': true,
        'seerrCookie': 'connect.sid=abc',
      }
    ]),
  });
  final s = AppState();
  await s.init();
  return s;
}

void main() {
  final sizes = {'tv': const Size(1920, 1080), 'desktop': const Size(1280, 800), 'phone': const Size(412, 915)};

  for (final mode in sizes.keys) {
    testWidgets('signed-in screens render without errors ($mode)', (tester) async {
      await http.runWithClient(() async {
        tester.view.physicalSize = sizes[mode]!;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = await signedInState(mode);
        await tester.pumpWidget(ChangeNotifierProvider.value(value: state, child: const EmberApp()));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('Continue Watching'), findsOneWidget);
        expect(find.text('Trending — not in your library yet', skipOffstage: false), findsOneWidget);
        expect(find.text('Because you watched The Quiet Orbit', skipOffstage: false), findsOneWidget);

        // Each section of the menu.
        for (final label in ['Shows', 'Movies', 'Discover', 'My List', 'Requests', 'Search', 'Settings']) {
          final target = find.bySemanticsLabel(label);
          if (target.evaluate().isEmpty) continue;
          await tester.tap(target.first, warnIfMissed: false);
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          // My List: the Seerr watchlist has its own part.
          if (label == 'My List') {
            expect(find.text('Watchlist', skipOffstage: false), findsOneWidget);
            expect(find.text('Kingfisher', skipOffstage: false), findsWidgets);
          }
        }

        // Discover: Recommended, Explore (Seerr titles not on the server) and the Coming Soon calendar.
        {
          navigatorKey.currentState!.push(MaterialPageRoute(builder: (_) => const Scaffold(body: DiscoverScreen())));
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          // Recommended: ranked picks, the featured one saying why it's there.
          expect(find.text('Top picks for you', skipOffstage: false), findsWidgets);
          expect(find.textContaining(RegExp(r'^(Because you watched|Like) '), skipOffstage: false), findsWidgets);
          await tester.tap(find.text('Explore').first, warnIfMissed: false);
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(find.text('Trending now', skipOffstage: false), findsOneWidget);
          expect(find.text('Popular', skipOffstage: false), findsOneWidget);
          // TV and desktop: Explore's filters live in the filter panel at the right of the header.
          if (find.byType(FilterButton).evaluate().isNotEmpty) {
            await tester.tap(find.byType(FilterButton));
            for (var i = 0; i < 4; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(find.text('GENRE'), findsOneWidget);
            await tester.tap(find.text('Shows').last);
            for (var i = 0; i < 6; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(find.text('Popular shows', skipOffstage: false), findsOneWidget);
            Navigator.of(tester.element(find.text('GENRE'))).pop();
            for (var i = 0; i < 4; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(find.text('GENRE'), findsNothing);
          }
          await tester.tap(find.text('Coming Soon').first, warnIfMissed: false);
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(find.text('Harbor Lights', skipOffstage: false), findsWidgets);
          expect(find.text('Copper Coast', skipOffstage: false), findsWidgets);
          expect(find.text('Request Season 2', skipOffstage: false), findsWidgets);
          debugPrint('coming-soon-checked');
        }

        // Details pages and the Seerr preview.
        navigatorKey.currentState!.push(MaterialPageRoute(builder: (_) => const DetailsScreen(itemId: 'm1')));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.textContaining('Resume', skipOffstage: false), findsWidgets);
        navigatorKey.currentState!.push(MaterialPageRoute(builder: (_) => const DetailsScreen(itemId: 's1')));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('Cast & Crew', skipOffstage: false), findsWidgets);
        navigatorKey.currentState!.push(MaterialPageRoute(builder: (_) => const PreviewScreen(mediaType: 'tv', tmdbId: 5)));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('Kingfisher'), findsWidgets);
        await tester.tap(find.text('Request').first, warnIfMissed: false);
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('REQUEST WITH SEERR'), findsOneWidget);
      }, mockClient);
    });
  }
}
