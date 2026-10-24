import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../platform.dart';

const String kClientName = 'Ember';
const String kClientVersion = '0.1.0';

/// Thrown when the server answers with an error status.
class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => message;
}

/// A Jellyfin item (movie, series, season, episode, person, library…).
/// Wraps the raw JSON so new fields are always available.
class JfItem {
  final Map<String, dynamic> raw;
  JfItem(this.raw);

  String get id => raw['Id'] as String? ?? '';
  String get name => raw['Name'] as String? ?? '';
  String get type => raw['Type'] as String? ?? '';
  bool get isSeries => type == 'Series';
  bool get isEpisode => type == 'Episode';
  bool get isMovie => type == 'Movie';
  bool get isSeason => type == 'Season';
  String? get overview => raw['Overview'] as String?;
  int? get year => (raw['ProductionYear'] as num?)?.toInt();
  String? get officialRating => raw['OfficialRating'] as String?;
  double? get communityRating => (raw['CommunityRating'] as num?)?.toDouble();
  int? get runTimeTicks => (raw['RunTimeTicks'] as num?)?.toInt();
  Duration? get runtime => runTimeTicks == null ? null : Duration(microseconds: runTimeTicks! ~/ 10);
  List<String> get genres => (raw['Genres'] as List?)?.cast<String>() ?? const [];
  String? get collectionType => raw['CollectionType'] as String?;
  String? get status => raw['Status'] as String?;
  String? get endDate => raw['EndDate'] as String?;

  Map<String, dynamic> get userData => (raw['UserData'] as Map?)?.cast<String, dynamic>() ?? const {};
  int get positionTicks => (userData['PlaybackPositionTicks'] as num?)?.toInt() ?? 0;
  bool get played => userData['Played'] == true;
  bool get isFavorite => userData['IsFavorite'] == true;
  double? get playedPercentage => (userData['PlayedPercentage'] as num?)?.toDouble();
  int? get unplayedCount => (userData['UnplayedItemCount'] as num?)?.toInt();

  String? get seriesId => raw['SeriesId'] as String?;
  String? get seriesName => raw['SeriesName'] as String?;
  DateTime? get premiereDate => DateTime.tryParse(raw['PremiereDate'] as String? ?? '')?.toLocal();
  String? get seasonId => raw['SeasonId'] as String?;
  int? get indexNumber => (raw['IndexNumber'] as num?)?.toInt();
  int? get parentIndexNumber => (raw['ParentIndexNumber'] as num?)?.toInt();
  int? get childCount => (raw['ChildCount'] as num?)?.toInt();

  Map<String, String> get imageTags =>
      (raw['ImageTags'] as Map?)?.map((k, v) => MapEntry(k as String, v as String)) ?? const {};
  List<String> get backdropTags => (raw['BackdropImageTags'] as List?)?.cast<String>() ?? const [];
  List<String> get parentBackdropTags => (raw['ParentBackdropImageTags'] as List?)?.cast<String>() ?? const [];
  String? get parentBackdropItemId => raw['ParentBackdropItemId'] as String?;
  String? get parentThumbItemId => raw['ParentThumbItemId'] as String?;
  String? get parentThumbTag => raw['ParentThumbImageTag'] as String?;
  String? get parentLogoItemId => raw['ParentLogoItemId'] as String?;
  String? get parentLogoTag => raw['ParentLogoImageTag'] as String?;
  String? get seriesPrimaryTag => raw['SeriesPrimaryImageTag'] as String?;

  Map<String, String> get providerIds =>
      (raw['ProviderIds'] as Map?)?.map((k, v) => MapEntry(k as String, '$v')) ?? const {};
  String? get tmdbId => providerIds['Tmdb'];

  List<Map<String, dynamic>> get people =>
      (raw['People'] as List?)?.map((e) => (e as Map).cast<String, dynamic>()).toList() ?? const [];
  List<Map<String, dynamic>> get mediaSources =>
      (raw['MediaSources'] as List?)?.map((e) => (e as Map).cast<String, dynamic>()).toList() ?? const [];
  List<Map<String, dynamic>> get remoteTrailers =>
      (raw['RemoteTrailers'] as List?)?.map((e) => (e as Map).cast<String, dynamic>()).toList() ?? const [];
  int get localTrailerCount => (raw['LocalTrailerCount'] as num?)?.toInt() ?? 0;

  /// Video and audio streams of the main version of this file.
  List<Map<String, dynamic>> get mediaStreams {
    final direct = raw['MediaStreams'] as List?;
    final list = direct ?? (mediaSources.isNotEmpty ? mediaSources.first['MediaStreams'] as List? : null);
    return list?.map((e) => (e as Map).cast<String, dynamic>()).toList() ?? const [];
  }

  /// "S2 : E4" style label for episodes.
  String get episodeLabel {
    final s = parentIndexNumber, e = indexNumber;
    if (s == null && e == null) return '';
    return 'S${s ?? '?'} : E${e ?? '?'}';
  }

  /// Resume progress 0..1, or null when not started.
  double? get progress {
    final rt = runTimeTicks;
    if (rt == null || rt == 0 || positionTicks == 0) return null;
    return (positionTicks / rt).clamp(0.0, 1.0);
  }
}

class AuthResult {
  final String token;
  final Map<String, dynamic> user;
  AuthResult(this.token, this.user);
  String get userId => user['Id'] as String;
  String get userName => user['Name'] as String? ?? '';
  bool get isAdmin => (user['Policy'] as Map?)?['IsAdministrator'] == true;
  String? get primaryImageTag => user['PrimaryImageTag'] as String?;
}

class DiscoveredServer {
  final String name;
  final String address;
  final String id;
  DiscoveredServer(this.name, this.address, this.id);
}

class PlaybackSource {
  final String url;
  final String mediaSourceId;
  final String playSessionId;
  final bool transcoding;
  final List<Map<String, dynamic>> streams;
  final int? bitrate;
  PlaybackSource({
    this.bitrate,
    required this.url,
    required this.mediaSourceId,
    required this.playSessionId,
    required this.transcoding,
    required this.streams,
  });
}

/// Jellyfin "trickplay" thumbnails: sheets of small frames used for the scrubber preview.
class TrickplayInfo {
  final String itemId;
  final String mediaSourceId;
  final int width, height, tileWidth, tileHeight, count;
  final Duration interval;
  TrickplayInfo({
    required this.itemId,
    required this.mediaSourceId,
    required this.width,
    required this.height,
    required this.tileWidth,
    required this.tileHeight,
    required this.count,
    required this.interval,
  });

  int get perSheet => tileWidth * tileHeight;

  static TrickplayInfo? fromItem(JfItem item) {
    final t = item.raw['Trickplay'] as Map?;
    if (t == null || t.isEmpty) return null;
    final source = t.entries.first;
    final res = (source.value as Map).cast<String, dynamic>();
    if (res.isEmpty) return null;
    // Pick the smallest resolution at least 300 px wide (or the largest available).
    final sizes = res.entries.toList()
      ..sort((a, b) => int.parse(a.key).compareTo(int.parse(b.key)));
    final pick = sizes.firstWhere((e) => int.parse(e.key) >= 300, orElse: () => sizes.last);
    final m = (pick.value as Map).cast<String, dynamic>();
    return TrickplayInfo(
      itemId: item.id,
      mediaSourceId: source.key as String,
      width: (m['Width'] as num).toInt(),
      height: (m['Height'] as num).toInt(),
      tileWidth: (m['TileWidth'] as num).toInt(),
      tileHeight: (m['TileHeight'] as num).toInt(),
      count: (m['ThumbnailCount'] as num).toInt(),
      interval: Duration(milliseconds: (m['Interval'] as num).toInt()),
    );
  }
}

class MediaSegment {
  final String type; // Intro, Outro, Recap, Preview, Commercial
  final Duration start;
  final Duration end;
  MediaSegment(this.type, this.start, this.end);
}

Duration ticksToDuration(int ticks) => Duration(microseconds: ticks ~/ 10);
int durationToTicks(Duration d) => d.inMicroseconds * 10;

/// Minimal Jellyfin REST client covering what Ember needs.
class JellyfinClient {
  final String baseUrl;
  final String deviceId;
  final String deviceName;
  String? token;
  String? userId;

  JellyfinClient({
    required String baseUrl,
    required this.deviceId,
    required this.deviceName,
    this.token,
    this.userId,
  }) : baseUrl = normalizeUrl(baseUrl);

  /// Accepts whatever people paste — `hearth:8096`, a full web-app link like
  /// `https://host/web/#/home` — and returns the server's base address.
  static String normalizeUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) return u;
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'http://$u';
    final hash = u.indexOf('#');
    if (hash >= 0) u = u.substring(0, hash);
    final q = u.indexOf('?');
    if (q >= 0) u = u.substring(0, q);
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    // Drop the web app's path (…/web, …/web/index.html) but keep a reverse-proxy base path.
    final web = RegExp(r'/web(/index\.html)?$', caseSensitive: false);
    u = u.replaceFirst(web, '');
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  /// HTTP header values must be plain ASCII.
  static String _ascii(String v) => v.replaceAll(RegExp(r'[^\x20-\x7E]'), '-').replaceAll('"', "'");

  String get authHeader {
    final parts = <String>[
      'Client="$kClientName"',
      'Device="${_ascii(deviceName)}"',
      'DeviceId="${_ascii(deviceId)}"',
      'Version="$kClientVersion"',
      if (token != null) 'Token="$token"',
    ];
    return 'MediaBrowser ${parts.join(', ')}';
  }

  Map<String, String> get _headers => {
        'Authorization': authHeader,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final q = <String, String>{};
    query?.forEach((k, v) {
      if (v == null) return;
      if (v is List) {
        if (v.isEmpty) return;
        q[k] = v.join(',');
      } else {
        q[k] = '$v';
      }
    });
    return Uri.parse('$baseUrl$path').replace(queryParameters: q.isEmpty ? null : q);
  }

  Future<dynamic> _send(String method, String path,
      {Map<String, dynamic>? query, Object? body, Duration timeout = const Duration(seconds: 20)}) async {
    final uri = _uri(path, query);
    late http.Response res;
    final encoded = body == null ? null : jsonEncode(body);
    switch (method) {
      case 'GET':
        res = await http.get(uri, headers: _headers).timeout(timeout);
        break;
      case 'POST':
        res = await http.post(uri, headers: _headers, body: encoded).timeout(timeout);
        break;
      case 'DELETE':
        res = await http.delete(uri, headers: _headers, body: encoded).timeout(timeout);
        break;
      default:
        throw ArgumentError(method);
    }
    if (res.statusCode == 401) throw ApiException(401, 'Your session has expired. Please sign in again.');
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, 'Server returned ${res.statusCode} for $path');
    }
    if (res.body.isEmpty) return null;
    final ct = res.headers['content-type'] ?? '';
    if (ct.contains('json')) return jsonDecode(utf8.decode(res.bodyBytes));
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      return res.body;
    }
  }

  List<JfItem> _items(dynamic json) {
    if (json is Map && json['Items'] is List) {
      return (json['Items'] as List).map((e) => JfItem((e as Map).cast<String, dynamic>())).toList();
    }
    if (json is List) {
      return json.map((e) => JfItem((e as Map).cast<String, dynamic>())).toList();
    }
    return [];
  }

  static const _fields =
      'Overview,Genres,PrimaryImageAspectRatio,ProductionYear,OfficialRating,CommunityRating,ProviderIds,ChildCount,RemoteTrailers,LocalTrailerCount,Status,EndDate';

  // ---------------------------------------------------------------- server

  /// Public server info; works without signing in. Used to validate an address.
  Future<Map<String, dynamic>> publicInfo() async {
    final json = await _send('GET', '/System/Info/Public', timeout: const Duration(seconds: 6));
    return (json as Map).cast<String, dynamic>();
  }

  /// Finds Jellyfin servers on the local network using Jellyfin's UDP discovery (port 7359).
  /// Asks on every network adapter (Wi-Fi, Ethernet…) rather than only the default one, and
  /// fixes up servers that report a loopback address such as 127.0.0.1.
  static Future<List<DiscoveredServer>> discover({Duration wait = const Duration(seconds: 3)}) async {
    final found = <String, DiscoveredServer>{};
    final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
    try {
      for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in nic.addresses) {
          final b = a.rawAddress;
          if (a.isLoopback || b[0] == 169) continue;
          targets.add(InternetAddress.fromRawAddress(Uint8List.fromList([b[0], b[1], b[2], 255])));
        }
      }
    } catch (_) {}

    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket!.receive();
        if (dg == null) return;
        try {
          final m = jsonDecode(utf8.decode(dg.data)) as Map;
          var address = m['Address'] as String? ?? '';
          final parsed = Uri.tryParse(address);
          if (parsed == null || parsed.host.isEmpty || parsed.host == '127.0.0.1' || parsed.host == 'localhost' || parsed.host == '0.0.0.0') {
            final port = (parsed != null && parsed.hasPort) ? parsed.port : 8096;
            address = 'http://${dg.address.address}:$port';
          }
          final id = m['Id'] as String? ?? address;
          found[id] = DiscoveredServer(m['Name'] as String? ?? 'Jellyfin', address, id);
        } catch (_) {}
      });
      final msg = utf8.encode('who is JellyfinServer?');
      for (var round = 0; round < 2; round++) {
        for (final t in targets) {
          try {
            socket.send(msg, t, 7359);
          } catch (_) {}
        }
        await Future.delayed(Duration(milliseconds: wait.inMilliseconds ~/ 2));
      }
    } catch (_) {
      // Discovery is best effort; typing the address always works.
    } finally {
      socket?.close();
    }
    return found.values.toList();
  }

  // ---------------------------------------------------------------- auth

  Future<List<Map<String, dynamic>>> publicUsers() async {
    final json = await _send('GET', '/Users/Public');
    return (json as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  Future<AuthResult> authenticateByName(String username, String password) async {
    final json = await _send('POST', '/Users/AuthenticateByName', body: {'Username': username, 'Pw': password});
    final m = (json as Map).cast<String, dynamic>();
    final r = AuthResult(m['AccessToken'] as String, (m['User'] as Map).cast<String, dynamic>());
    token = r.token;
    userId = r.userId;
    return r;
  }

  Future<bool> quickConnectEnabled() async {
    try {
      final json = await _send('GET', '/QuickConnect/Enabled');
      return json == true;
    } catch (_) {
      return false;
    }
  }

  /// Returns (secret, code).
  Future<(String, String)> quickConnectInitiate() async {
    final json = await _send('POST', '/QuickConnect/Initiate');
    final m = (json as Map).cast<String, dynamic>();
    return (m['Secret'] as String, m['Code'] as String);
  }

  Future<bool> quickConnectAuthorized(String secret) async {
    final json = await _send('GET', '/QuickConnect/Connect', query: {'Secret': secret});
    return (json as Map)['Authenticated'] == true;
  }

  Future<AuthResult> authenticateWithQuickConnect(String secret) async {
    final json = await _send('POST', '/Users/AuthenticateWithQuickConnect', body: {'Secret': secret});
    final m = (json as Map).cast<String, dynamic>();
    final r = AuthResult(m['AccessToken'] as String, (m['User'] as Map).cast<String, dynamic>());
    token = r.token;
    userId = r.userId;
    return r;
  }

  /// Approves a Quick Connect code typed on another device, using this signed-in session.
  Future<void> authorizeQuickConnect(String code) async {
    await _send('POST', '/QuickConnect/Authorize', query: {'code': code, 'userId': userId});
  }

  Future<Map<String, dynamic>> me() async {
    final json = await _send('GET', '/Users/Me');
    return (json as Map).cast<String, dynamic>();
  }

  Future<void> logout() async {
    try {
      await _send('POST', '/Sessions/Logout');
    } catch (_) {}
  }

  // ---------------------------------------------------------------- library

  Future<List<JfItem>> views() async => _items(await _send('GET', '/UserViews', query: {'userId': userId}));

  Future<List<JfItem>> resume({int limit = 16}) async => _items(await _send('GET', '/UserItems/Resume', query: {
        'userId': userId,
        'limit': limit,
        'mediaTypes': 'Video',
        'fields': _fields,
        'enableImageTypes': 'Primary,Backdrop,Thumb,Logo',
      }));

  /// Episodes of shows in the library that haven't aired yet.
  Future<List<JfItem>> upcomingEpisodes({int limit = 60}) async => _items(await _send('GET', '/Shows/Upcoming', query: {
        'userId': userId,
        'limit': limit,
        'fields': _fields,
        'enableImageTypes': 'Primary,Backdrop,Thumb',
      }));

  Future<List<JfItem>> nextUp({int limit = 16}) async => _items(await _send('GET', '/Shows/NextUp', query: {
        'userId': userId,
        'limit': limit,
        'fields': _fields,
        'enableResumable': false,
      }));

  Future<List<JfItem>> latest({String? parentId, List<String>? types, int limit = 20}) async =>
      _items(await _send('GET', '/Items/Latest', query: {
        'userId': userId,
        'parentId': parentId,
        'includeItemTypes': types,
        'limit': limit,
        'fields': _fields,
      }));

  Future<List<JfItem>> items({
    String? parentId,
    List<String>? types,
    String? genre,
    String? sortBy = 'SortName',
    String sortOrder = 'Ascending',
    String? filters,
    String? searchTerm,
    int? limit,
    int? startIndex,
    bool recursive = true,
  }) async =>
      _items(await _send('GET', '/Items', query: {
        'userId': userId,
        'parentId': parentId,
        'includeItemTypes': types,
        'genres': genre,
        'sortBy': sortBy,
        'sortOrder': sortOrder,
        'filters': filters,
        'searchTerm': searchTerm,
        'limit': limit,
        'startIndex': startIndex,
        'recursive': recursive,
        'fields': _fields,
        'enableImageTypes': 'Primary,Backdrop,Thumb,Logo',
      }));

  /// How many items of these types the library holds.
  Future<int> count(List<String> types) async {
    final json = await _send('GET', '/Items', query: {
      'userId': userId,
      'includeItemTypes': types,
      'recursive': true,
      'limit': 0,
    });
    return ((json as Map)['TotalRecordCount'] as num?)?.toInt() ?? 0;
  }

  Future<List<String>> genres({String? parentId, List<String>? types}) async {
    final json = await _send('GET', '/Genres', query: {
      'userId': userId,
      'parentId': parentId,
      'includeItemTypes': types,
      'sortBy': 'SortName',
    });
    return _items(json).map((e) => e.name).toList();
  }

  Future<JfItem> item(String id) async {
    final json = await _send('GET', '/Items/$id', query: {'userId': userId});
    return JfItem((json as Map).cast<String, dynamic>());
  }

  Future<List<JfItem>> seasons(String seriesId) async =>
      _items(await _send('GET', '/Shows/$seriesId/Seasons', query: {'userId': userId, 'fields': _fields}));

  Future<List<JfItem>> episodes(String seriesId, {String? seasonId, String? startItemId, int? limit}) async =>
      _items(await _send('GET', '/Shows/$seriesId/Episodes', query: {
        'userId': userId,
        'seasonId': seasonId,
        'startItemId': startItemId,
        'limit': limit,
        'fields': '$_fields,MediaSources',
      }));

  /// The episode after [episode] in the series, or null at the end.
  Future<JfItem?> nextEpisode(JfItem episode) async {
    final sid = episode.seriesId;
    if (sid == null) return null;
    final list = await episodes(sid, startItemId: episode.id, limit: 2);
    return list.length > 1 ? list[1] : null;
  }

  Future<List<JfItem>> similar(String id, {int limit = 12}) async =>
      _items(await _send('GET', '/Items/$id/Similar', query: {'userId': userId, 'limit': limit, 'fields': _fields}));

  Future<List<JfItem>> localTrailers(String id) async {
    try {
      return _items(await _send('GET', '/Items/$id/LocalTrailers', query: {'userId': userId}));
    } catch (_) {
      return [];
    }
  }

  /// Featurettes, behind-the-scenes and other extras stored with an item.
  Future<List<JfItem>> specialFeatures(String id) async {
    try {
      return _items(await _send('GET', '/Items/$id/SpecialFeatures', query: {'userId': userId}));
    } catch (_) {
      return [];
    }
  }

  Future<List<JfItem>> search(String term, {int limit = 24}) => items(
        searchTerm: term,
        types: const ['Movie', 'Series'],
        sortBy: null,
        limit: limit,
      );

  Future<List<JfItem>> favorites() => items(filters: 'IsFavorite', types: const ['Movie', 'Series'], sortBy: 'SortName');

  /// The movie or series in the library with this TMDB id, or null.
  /// Newer Jellyfin ignores the old provider-id filter, so every candidate is checked by its
  /// TMDB id; [title] narrows the search when it's known.
  Future<JfItem?> findByTmdb(String tmdbId, String mediaType, {String? title}) async {
    Future<JfItem?> look(Map<String, dynamic> extra) async {
      final list = _items(await _send('GET', '/Items', query: {
        'userId': userId,
        'recursive': true,
        'includeItemTypes': mediaType == 'tv' ? 'Series' : 'Movie',
        'limit': 50,
        'fields': _fields,
        ...extra,
      }));
      for (final it in list) {
        if (it.tmdbId == tmdbId) return it;
      }
      return null;
    }

    if (title != null && title.isNotEmpty) {
      final hit = await look({'searchTerm': title});
      if (hit != null) return hit;
    }
    return look({'hasTmdbId': true, 'anyProviderIdEquals': 'tmdb.$tmdbId'});
  }

  Future<void> setFavorite(String id, bool favorite) async {
    await _send(favorite ? 'POST' : 'DELETE', '/UserFavoriteItems/$id', query: {'userId': userId});
  }

  Future<void> setPlayed(String id, bool played) async {
    await _send(played ? 'POST' : 'DELETE', '/UserPlayedItems/$id', query: {'userId': userId});
  }

  // ---------------------------------------------------------------- images

  String imageUrl(String itemId, String type, {String? tag, int? maxWidth, int? maxHeight, int index = 0}) {
    final q = <String, String>{
      'quality': '90',
      if (tag != null) 'tag': tag,
      if (maxWidth != null) 'maxWidth': '$maxWidth',
      if (maxHeight != null) 'maxHeight': '$maxHeight',
    };
    final path = type == 'Backdrop' ? '/Items/$itemId/Images/Backdrop/$index' : '/Items/$itemId/Images/$type';
    return Uri.parse('$baseUrl$path').replace(queryParameters: q).toString();
  }

  /// Best wide (16:9) image for an item: episode still, thumb, backdrop, then the series' artwork.
  String? landscapeImage(JfItem it, {int maxWidth = 640}) {
    if (it.isEpisode && it.imageTags['Primary'] != null) {
      return imageUrl(it.id, 'Primary', tag: it.imageTags['Primary'], maxWidth: maxWidth);
    }
    if (it.imageTags['Thumb'] != null) return imageUrl(it.id, 'Thumb', tag: it.imageTags['Thumb'], maxWidth: maxWidth);
    if (it.backdropTags.isNotEmpty) return imageUrl(it.id, 'Backdrop', tag: it.backdropTags.first, maxWidth: maxWidth);
    if (it.parentThumbItemId != null && it.parentThumbTag != null) {
      return imageUrl(it.parentThumbItemId!, 'Thumb', tag: it.parentThumbTag, maxWidth: maxWidth);
    }
    if (it.parentBackdropItemId != null && it.parentBackdropTags.isNotEmpty) {
      return imageUrl(it.parentBackdropItemId!, 'Backdrop', tag: it.parentBackdropTags.first, maxWidth: maxWidth);
    }
    if (it.imageTags['Primary'] != null) return imageUrl(it.id, 'Primary', tag: it.imageTags['Primary'], maxWidth: maxWidth);
    return null;
  }

  String? backdropImage(JfItem it, {int maxWidth = 1920}) {
    if (it.backdropTags.isNotEmpty) return imageUrl(it.id, 'Backdrop', tag: it.backdropTags.first, maxWidth: maxWidth);
    if (it.parentBackdropItemId != null && it.parentBackdropTags.isNotEmpty) {
      return imageUrl(it.parentBackdropItemId!, 'Backdrop', tag: it.parentBackdropTags.first, maxWidth: maxWidth);
    }
    return landscapeImage(it, maxWidth: maxWidth);
  }

  String? posterImage(JfItem it, {int maxHeight = 480}) {
    if (it.imageTags['Primary'] != null && !it.isEpisode) {
      return imageUrl(it.id, 'Primary', tag: it.imageTags['Primary'], maxHeight: maxHeight);
    }
    if (it.seriesId != null && it.seriesPrimaryTag != null) {
      return imageUrl(it.seriesId!, 'Primary', tag: it.seriesPrimaryTag, maxHeight: maxHeight);
    }
    return null;
  }

  String? logoImage(JfItem it, {int maxWidth = 900}) {
    if (it.imageTags['Logo'] != null) return imageUrl(it.id, 'Logo', tag: it.imageTags['Logo'], maxWidth: maxWidth);
    if (it.parentLogoItemId != null && it.parentLogoTag != null) {
      return imageUrl(it.parentLogoItemId!, 'Logo', tag: it.parentLogoTag, maxWidth: maxWidth);
    }
    return null;
  }

  String? personImage(Map<String, dynamic> person, {int maxHeight = 300}) {
    final tag = person['PrimaryImageTag'] as String?;
    if (tag == null) return null;
    return imageUrl(person['Id'] as String, 'Primary', tag: tag, maxHeight: maxHeight);
  }

  String userImage(String userId, String tag) =>
      Uri.parse('$baseUrl/Users/$userId/Images/Primary').replace(queryParameters: {'tag': tag, 'maxHeight': '300'}).toString();

  // ---------------------------------------------------------------- playback

  /// Asks the server how to play [itemId].
  ///
  /// With [maxBitrate] null the original file is streamed untouched (mpv plays every codec,
  /// container, audio track and subtitle format itself). With a bitrate the server is asked
  /// to transcode to H.264/AAC HLS at that rate, for slow connections.
  ///
  /// On Apple TV the request describes what Apple's player can open instead (see
  /// [_appleTvProfile]), and the server repackages or converts anything else.
  Future<PlaybackSource> playbackSource(
    String itemId, {
    int? maxBitrate,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    Duration? start,
  }) async {
    final transcode = maxBitrate != null;
    if (isAppleTv) {
      return _appleTvSource(itemId,
          maxBitrate: maxBitrate, audioStreamIndex: audioStreamIndex, subtitleStreamIndex: subtitleStreamIndex, start: start);
    }
    final body = <String, dynamic>{
      'UserId': userId,
      'MaxStreamingBitrate': maxBitrate ?? 200000000,
      'StartTimeTicks': start == null ? 0 : durationToTicks(start),
      'AudioStreamIndex': audioStreamIndex,
      'SubtitleStreamIndex': subtitleStreamIndex,
      'EnableDirectPlay': !transcode,
      'EnableDirectStream': !transcode,
      'EnableTranscoding': transcode,
      'AutoOpenLiveStream': true,
      'DeviceProfile': {
        'Name': 'Ember',
        'MaxStreamingBitrate': maxBitrate ?? 200000000,
        'DirectPlayProfiles': transcode
            ? []
            : [
                {'Type': 'Video'},
                {'Type': 'Audio'},
              ],
        'TranscodingProfiles': [
          {
            'Container': 'ts',
            'Type': 'Video',
            'VideoCodec': 'h264',
            'AudioCodec': 'aac,mp3,ac3',
            'Protocol': 'hls',
            'Context': 'Streaming',
            'MaxAudioChannels': '6',
            'MinSegments': 1,
            'BreakOnNonKeyFrames': true,
          }
        ],
        'ContainerProfiles': [],
        'CodecProfiles': [],
        'SubtitleProfiles': [
          {'Format': 'srt', 'Method': 'External'},
          {'Format': 'subrip', 'Method': 'External'},
          {'Format': 'ass', 'Method': 'External'},
          {'Format': 'ssa', 'Method': 'External'},
          {'Format': 'vtt', 'Method': 'External'},
          {'Format': 'pgssub', 'Method': 'Encode'},
          {'Format': 'dvdsub', 'Method': 'Encode'},
          {'Format': 'dvbsub', 'Method': 'Encode'},
        ],
      },
    }..removeWhere((k, v) => v == null);

    final json = await _send('POST', '/Items/$itemId/PlaybackInfo', query: {'userId': userId}, body: body);
    final m = (json as Map).cast<String, dynamic>();
    final sources = (m['MediaSources'] as List? ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
    if (sources.isEmpty) throw ApiException(500, 'The server has no playable version of this title.');
    final src = sources.first;
    final playSessionId = m['PlaySessionId'] as String? ?? '';
    final msid = src['Id'] as String;
    final streams = (src['MediaStreams'] as List? ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();

    String url;
    if (transcode && src['TranscodingUrl'] != null) {
      url = '$baseUrl${src['TranscodingUrl']}';
    } else {
      url = _uri('/Videos/$itemId/stream', {
        'static': 'true',
        'mediaSourceId': msid,
        'playSessionId': playSessionId,
        'deviceId': deviceId,
        'api_key': token,
      }).toString();
    }
    return PlaybackSource(
      url: url,
      mediaSourceId: msid,
      playSessionId: playSessionId,
      transcoding: transcode,
      streams: streams,
      bitrate: (src['Bitrate'] as num?)?.toInt(),
    );
  }

  /// What Apple TV's player (AVPlayer) opens itself: MP4/MOV with H.264 or HEVC (including
  /// HDR10 and Dolby Vision) and AAC, Dolby Digital(+) incl. Atmos, ALAC or FLAC audio.
  /// Anything else (MKV, DTS, TrueHD…) is repackaged by the server into HLS, copying the video
  /// and audio untouched when it can and converting only what AVPlayer can't play.
  static Map<String, dynamic> _appleTvProfile(int maxBitrate, {required bool transcode}) => {
        'Name': 'Ember Apple TV',
        'MaxStreamingBitrate': maxBitrate,
        'DirectPlayProfiles': transcode
            ? []
            : [
                {'Container': 'mp4,m4v,mov', 'Type': 'Video', 'VideoCodec': 'h264,hevc', 'AudioCodec': 'aac,ac3,eac3,alac,flac,mp3'},
                {'Container': 'mp3,aac,m4a,m4b,flac,alac', 'Type': 'Audio'},
              ],
        'TranscodingProfiles': [
          {
            'Container': 'mp4',
            'Type': 'Video',
            'VideoCodec': transcode ? 'h264' : 'hevc,h264',
            'AudioCodec': 'eac3,ac3,aac,flac,alac',
            'Protocol': 'hls',
            'Context': 'Streaming',
            'MaxAudioChannels': '8',
            'MinSegments': 2,
            'BreakOnNonKeyFrames': true,
          },
          {'Container': 'aac', 'Type': 'Audio', 'AudioCodec': 'aac', 'Protocol': 'hls', 'Context': 'Streaming', 'MaxAudioChannels': '6'},
        ],
        'ContainerProfiles': [],
        'CodecProfiles': [],
        // Text subtitles come as WebVTT and Ember draws them; picture subtitles are burned in.
        'SubtitleProfiles': [
          for (final f in ['srt', 'subrip', 'ass', 'ssa', 'vtt', 'webvtt', 'mov_text', 'ttml'])
            {'Format': f, 'Method': 'External'},
          for (final f in ['pgssub', 'pgs', 'dvdsub', 'dvbsub', 'vobsub'])
            {'Format': f, 'Method': 'Encode'},
        ],
      };

  Future<PlaybackSource> _appleTvSource(
    String itemId, {
    int? maxBitrate,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    Duration? start,
  }) async {
    final transcode = maxBitrate != null;
    final bitrate = maxBitrate ?? 200000000;
    final body = <String, dynamic>{
      'UserId': userId,
      'MaxStreamingBitrate': bitrate,
      'StartTimeTicks': start == null ? 0 : durationToTicks(start),
      'AudioStreamIndex': audioStreamIndex,
      'SubtitleStreamIndex': subtitleStreamIndex,
      // A burned-in subtitle or a different audio track means the server has to build the stream.
      'EnableDirectPlay': !transcode && subtitleStreamIndex == null && audioStreamIndex == null,
      'EnableDirectStream': !transcode,
      'EnableTranscoding': true,
      'AutoOpenLiveStream': true,
      'DeviceProfile': _appleTvProfile(bitrate, transcode: transcode),
    }..removeWhere((k, v) => v == null);

    final json = await _send('POST', '/Items/$itemId/PlaybackInfo', query: {'userId': userId}, body: body);
    final m = (json as Map).cast<String, dynamic>();
    final sources = (m['MediaSources'] as List? ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
    if (sources.isEmpty) throw ApiException(500, 'The server has no playable version of this title.');
    final src = sources.first;
    final playSessionId = m['PlaySessionId'] as String? ?? '';
    final msid = src['Id'] as String;
    final streams = (src['MediaStreams'] as List? ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();

    final direct = src['SupportsDirectPlay'] == true && body['EnableDirectPlay'] == true;
    final transcodingUrl = src['TranscodingUrl'] as String?;
    if (!direct && transcodingUrl == null) {
      throw ApiException(500, 'The server couldn\'t prepare a version of this title that Apple TV can play.');
    }
    final url = direct
        ? _uri('/Videos/$itemId/stream', {
            'static': 'true',
            'mediaSourceId': msid,
            'playSessionId': playSessionId,
            'deviceId': deviceId,
            'api_key': token,
          }).toString()
        : '$baseUrl$transcodingUrl';
    return PlaybackSource(
      url: url,
      mediaSourceId: msid,
      playSessionId: playSessionId,
      transcoding: !direct,
      streams: streams,
      bitrate: (src['Bitrate'] as num?)?.toInt(),
    );
  }

  /// URL of a subtitle stream, converted by the server to a text format mpv understands,
  /// or to [format] (such as 'vtt' for Apple TV) when given.
  String subtitleUrl(String itemId, String mediaSourceId, Map<String, dynamic> stream, {String? format}) {
    final delivery = stream['DeliveryUrl'] as String?;
    if (delivery != null && delivery.isNotEmpty && (format == null || delivery.split('?').first.endsWith('.$format'))) {
      final sep = delivery.contains('?') ? '&' : '?';
      return delivery.contains('api_key') ? '$baseUrl$delivery' : '$baseUrl$delivery${sep}api_key=$token';
    }
    final codec = (stream['Codec'] as String? ?? 'srt').toLowerCase();
    final ext = format ?? switch (codec) { 'ass' || 'ssa' => 'ass', 'webvtt' || 'vtt' => 'vtt', _ => 'srt' };
    final index = stream['Index'];
    return '$baseUrl/Videos/$itemId/$mediaSourceId/Subtitles/$index/0/Stream.$ext?api_key=$token';
  }

  Future<void> reportStart(String itemId, String msid, String playSessionId, Duration position, bool transcoding) =>
      _report('/Sessions/Playing', itemId, msid, playSessionId, position, false, transcoding);

  Future<void> reportProgress(String itemId, String msid, String playSessionId, Duration position, bool paused,
          bool transcoding) =>
      _report('/Sessions/Playing/Progress', itemId, msid, playSessionId, position, paused, transcoding);

  Future<void> reportStopped(String itemId, String msid, String playSessionId, Duration position) =>
      _report('/Sessions/Playing/Stopped', itemId, msid, playSessionId, position, false, false);

  Future<void> _report(String path, String itemId, String msid, String playSessionId, Duration position, bool paused,
      bool transcoding) async {
    try {
      await _send('POST', path, body: {
        'ItemId': itemId,
        'MediaSourceId': msid,
        'PlaySessionId': playSessionId,
        'PositionTicks': durationToTicks(position),
        'IsPaused': paused,
        'CanSeek': true,
        'PlayMethod': transcoding ? 'Transcode' : 'DirectStream',
      });
    } catch (_) {
      // Progress reporting should never interrupt playback.
    }
  }

  String trickplaySheetUrl(TrickplayInfo t, int sheet) => _uri('/Videos/${t.itemId}/Trickplay/${t.width}/$sheet.jpg', {
        'mediaSourceId': t.mediaSourceId,
        'api_key': token,
      }).toString();

  /// Intro / outro markers (Jellyfin 10.10+ media segments, filled by e.g. Intro Skipper).
  Future<List<MediaSegment>> mediaSegments(String itemId) async {
    try {
      final json = await _send('GET', '/MediaSegments/$itemId');
      return _items(json)
          .map((e) => MediaSegment(
                e.raw['Type'] as String? ?? '',
                ticksToDuration((e.raw['StartTicks'] as num).toInt()),
                ticksToDuration((e.raw['EndTicks'] as num).toInt()),
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ---------------------------------------------------------------- Ember Trailers plugin

  /// Trailer service status, or null when the Ember Trailers plugin isn't installed.
  // ------------------------------------------------- trailer service setup (admin only)

  static const trailerRepoName = 'Ember';
  static const trailerRepoUrl = 'https://raw.githubusercontent.com/abelm963/ember-trailers/main/manifest.json';
  static const trailerPluginId = '6f1c8f2e6a434c4e9d555e2a7b3c9e11';

  /// The Ember Trailers plugin as Jellyfin lists it (Status: Active, Restart, Disabled…), or null.
  Future<Map<String, dynamic>?> trailerPlugin() async {
    final list = await _send('GET', '/Plugins');
    for (final p in (list as List? ?? const [])) {
      final m = (p as Map).cast<String, dynamic>();
      if ('${m['Id']}'.replaceAll('-', '').toLowerCase() == trailerPluginId) return m;
    }
    return null;
  }

  /// Whether [version] is the newest Ember Trailers the server's catalog offers.
  Future<bool> trailerPluginIsNewest(String? version) async {
    if (version == null) return false;
    try {
      final p = (await _send('GET', '/Packages/Ember%20Trailers', query: {'assemblyGuid': trailerPluginId})) as Map;
      final versions = ((p['versions'] as List?) ?? const []).map((v) => '${(v as Map)['version']}').toList();
      return versions.isNotEmpty && versions.first == version;
    } catch (_) {
      return false;
    }
  }

  /// Adds Ember's plugin source to the server (keeps any sources already there).
  Future<void> addTrailerRepository() async {
    final repos = ((await _send('GET', '/Repositories')) as List? ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    if (repos.any((r) => '${r['Url']}'.toLowerCase() == trailerRepoUrl.toLowerCase())) return;
    repos.add({'Name': trailerRepoName, 'Url': trailerRepoUrl, 'Enabled': true});
    await _send('POST', '/Repositories', body: repos);
  }

  /// Downloads and installs the plugin. Takes effect after a server restart.
  Future<void> installTrailerPlugin() async {
    try {
      await _send('POST', '/Packages/Installed/Ember%20Trailers',
          query: {'assemblyGuid': trailerPluginId, 'repositoryUrl': trailerRepoUrl}, timeout: const Duration(minutes: 2));
    } on ApiException catch (e) {
      if (e.status == 404) {
        throw ApiException(404, 'Your server couldn\'t find a version of Ember Trailers for its Jellyfin version.');
      }
      if (e.status == 403) throw ApiException(403, 'Only a server administrator can install the trailer service.');
      rethrow;
    }
  }

  Future<void> restartServer() => _send('POST', '/System/Restart');

  /// Waits for the server to go down and come back after a restart.
  Future<bool> waitForRestart({Duration limit = const Duration(minutes: 3)}) async {
    final end = DateTime.now().add(limit);
    var wentDown = false;
    final started = DateTime.now();
    while (DateTime.now().isBefore(end)) {
      await Future.delayed(const Duration(seconds: 2));
      try {
        await _send('GET', '/System/Info/Public', timeout: const Duration(seconds: 4));
        // Some servers restart faster than we poll; after 20 s assume it went round.
        if (wentDown || DateTime.now().difference(started) > const Duration(seconds: 20)) return true;
      } catch (_) {
        wentDown = true;
      }
    }
    return false;
  }

  Future<Map<String, dynamic>?> trailerHealth() async {
    try {
      final json = await _send('GET', '/EmberTrailers/Health', timeout: const Duration(seconds: 15));
      return (json as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// The release calendar built by the Ember plugin on the server (TMDB, plus Trakt if set up).
  /// Null when the plugin is missing or too old to have one.
  Future<List<Map<String, dynamic>>?> releaseCalendar({required String region, int days = 120}) async {
    try {
      final json = await _send('GET', '/EmberTrailers/Calendar',
          query: {'region': region, 'days': days}, timeout: const Duration(seconds: 90));
      final items = (json as Map)['items'] as List?;
      return items?.map((e) => (e as Map).cast<String, dynamic>()).toList();
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  /// Saves calendar keys in the plugin's settings on the server (admin only). They never come back to apps.
  Future<void> saveCalendarKeys({String? traktClientId}) =>
      _send('POST', '/EmberTrailers/CalendarKeys', body: {'TraktClientId': traktClientId});

  /// TMDB ids of every movie and series in the library, as "movie:123" / "tv:456".
  Future<Map<String, JfItem>> libraryByTmdb() async {
    final list = _items(await _send('GET', '/Items', query: {
      'userId': userId,
      'recursive': true,
      'includeItemTypes': 'Movie,Series',
      'fields': 'ProviderIds',
      'enableImages': false,
      'enableUserData': false,
    }, timeout: const Duration(seconds: 60)));
    return {
      for (final it in list)
        if (it.tmdbId != null) '${it.isSeries ? 'tv' : 'movie'}:${it.tmdbId}': it,
    };
  }

  /// The official trailer the server picked for a library item, or null.
  Future<String?> trailerKeyForItem(String itemId) async => (await trailerCheckForItem(itemId)).$1;

  final Map<String, (DateTime, Future<(String?, String?)>)> _trailerChecks = {};

  /// The trailer key the server can stream for a library item, or null plus the server's reason.
  /// Results are shared and kept for a while, so a check started when a page opens makes the
  /// Trailer button instant.
  Future<(String?, String?)> trailerCheckForItem(String itemId) {
    final hit = _trailerChecks[itemId];
    if (hit != null && DateTime.now().difference(hit.$1) < const Duration(minutes: 20)) return hit.$2;
    final f = _trailerCheck(itemId);
    _trailerChecks[itemId] = (DateTime.now(), f);
    f.then((r) {
      // Don't hold on to failures for long; the next tap tries again.
      if (r.$1 == null) _trailerChecks[itemId] = (DateTime.now().subtract(const Duration(minutes: 18)), f);
    });
    return f;
  }

  Future<(String?, String?)> _trailerCheck(String itemId) async {
    try {
      final json = await _send('GET', '/EmberTrailers/Items/$itemId/Info', timeout: const Duration(seconds: 90));
      final m = (json as Map).cast<String, dynamic>();
      if (m['available'] == true) return (m['key'] as String?, null);
      return (null, m['reason'] as String? ?? 'The server couldn\'t play this trailer.');
    } on TimeoutException {
      return (null, 'The server took too long to fetch the trailer.');
    } catch (e) {
      return (null, '$e');
    }
  }

  /// Checks a YouTube trailer (for titles not on the server). Returns the key if it may be played.
  Future<String?> trailerKeyChecked(String key) async {
    try {
      final json = await _send('GET', '/EmberTrailers/Videos/$key/Info', timeout: const Duration(seconds: 60));
      return (json as Map)['available'] == true ? key : null;
    } catch (_) {
      return null;
    }
  }

  /// URL the player opens to stream a trailer through the server.
  /// Admin diagnostics: Hearth runs the real trailer stream for up to 40 s and reports what happened.
  Future<Map<String, dynamic>> testTrailerStream(String key) async =>
      ((await _send('GET', '/EmberTrailers/Videos/$key/Test', timeout: const Duration(seconds: 120))) as Map).cast<String, dynamic>();

  String trailerStreamUrl(String key) => _uri('/EmberTrailers/Videos/$key/Stream', {'api_key': token}).toString();

  /// Speed test against the server (used to pick a streaming quality automatically). Returns bits per second.
  Future<double?> measureBitrate({int bytes = 4000000}) async {
    try {
      final sw = Stopwatch()..start();
      final res = await http
          .get(_uri('/Playback/BitrateTest', {'size': bytes}), headers: _headers)
          .timeout(const Duration(seconds: 10));
      sw.stop();
      if (res.statusCode >= 400 || sw.elapsedMilliseconds == 0) return null;
      return res.bodyBytes.length * 8 / (sw.elapsedMilliseconds / 1000);
    } catch (_) {
      return null;
    }
  }
}

/// What a file contains, in the terms people know: 4K, Dolby Vision, HDR10, Atmos, DTS:X…
class FormatInfo {
  final List<String> badges;
  final String? videoRange; // e.g. "Dolby Vision", "HDR10", "SDR"
  final bool isHdr;
  final bool isDolbyVision;
  FormatInfo(this.badges, this.videoRange, this.isHdr, this.isDolbyVision);

  static FormatInfo fromStreams(List<Map<String, dynamic>> streams) {
    final badges = <String>[];
    String? range;
    var hdr = false, dv = false;
    final video = streams.where((s) => s['Type'] == 'Video').toList();
    if (video.isNotEmpty) {
      final v = video.first;
      final w = (v['Width'] as num?)?.toInt() ?? 0;
      final h = (v['Height'] as num?)?.toInt() ?? 0;
      if (w >= 3200 || h >= 2000) {
        badges.add('4K');
      } else if (w >= 1800 || h >= 1000) {
        badges.add('HD');
      }
      final rt = (v['VideoRangeType'] as String? ?? v['VideoRange'] as String? ?? '').toUpperCase();
      if (rt.contains('DOVI')) {
        dv = true;
        hdr = true;
        range = 'Dolby Vision';
        badges.add('Dolby Vision');
        if (rt.contains('HDR10PLUS')) {
          badges.add('HDR10+');
        } else if (rt.contains('HDR10')) {
          badges.add('HDR10');
        }
      } else if (rt.contains('HDR10PLUS')) {
        hdr = true;
        range = 'HDR10+';
        badges.add('HDR10+');
      } else if (rt.contains('HDR')) {
        hdr = true;
        range = 'HDR10';
        badges.add('HDR10');
      } else if (rt.contains('HLG')) {
        hdr = true;
        range = 'HLG';
        badges.add('HLG');
      } else {
        range = 'SDR';
      }
    }
    // Best audio format across all tracks.
    var atmos = false, dtsx = false, dtshd = false, truehd = false, ddp = false, dts = false;
    var maxCh = 0;
    for (final a in streams.where((s) => s['Type'] == 'Audio')) {
      final codec = (a['Codec'] as String? ?? '').toLowerCase();
      final prof = '${a['Profile'] ?? ''} ${a['DisplayTitle'] ?? ''} ${a['Title'] ?? ''}'.toLowerCase();
      maxCh = [(a['Channels'] as num?)?.toInt() ?? 0, maxCh].reduce((x, y) => x > y ? x : y);
      if (prof.contains('atmos')) atmos = true;
      if (prof.contains('dts:x') || prof.contains('dts-x') || prof.contains('dts x')) dtsx = true;
      if (codec == 'dts' && (prof.contains('ma') || prof.contains('hd'))) dtshd = true;
      if (codec == 'dts') dts = true;
      if (codec == 'truehd') truehd = true;
      if (codec == 'eac3') ddp = true;
    }
    if (atmos) {
      badges.add('Dolby Atmos');
    } else if (dtsx) {
      badges.add('DTS:X');
    } else if (dtshd) {
      badges.add('DTS-HD MA');
    } else if (truehd) {
      badges.add('Dolby TrueHD');
    } else if (ddp) {
      badges.add('Dolby Digital+');
    } else if (dts) {
      badges.add('DTS');
    }
    if (maxCh >= 8) {
      badges.add('7.1');
    } else if (maxCh >= 6) {
      badges.add('5.1');
    }
    return FormatInfo(badges, range, hdr, dv);
  }
}
