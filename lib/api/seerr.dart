import 'dart:convert';

import 'package:http/http.dart' as http;

import 'jellyfin.dart' show ApiException;

/// Seerr media availability (shared by Overseerr / Jellyseerr / Seerr).
enum MediaStatus { unknown, pending, processing, partiallyAvailable, available, other }

MediaStatus mediaStatusFrom(int? v) => switch (v) {
      1 => MediaStatus.unknown,
      2 => MediaStatus.pending,
      3 => MediaStatus.processing,
      4 => MediaStatus.partiallyAvailable,
      5 => MediaStatus.available,
      null => MediaStatus.unknown,
      _ => MediaStatus.other,
    };

/// A movie or series as Seerr describes it (from TMDB).
class SeerrMedia {
  final Map<String, dynamic> raw;
  SeerrMedia(this.raw);

  int get id => (raw['id'] as num).toInt();
  String get mediaType => raw['mediaType'] as String? ?? (raw['firstAirDate'] != null || raw['name'] != null ? 'tv' : 'movie');
  bool get isTv => mediaType == 'tv';
  String get title => (raw['title'] ?? raw['name'] ?? raw['originalTitle'] ?? '') as String;
  String? get overview => raw['overview'] as String?;
  String? get posterPath => raw['posterPath'] as String?;
  String? get backdropPath => raw['backdropPath'] as String?;
  String? get date => (raw['releaseDate'] ?? raw['firstAirDate']) as String?;
  int? get year => (date != null && date!.length >= 4) ? int.tryParse(date!.substring(0, 4)) : null;
  double? get voteAverage => (raw['voteAverage'] as num?)?.toDouble();
  Map<String, dynamic>? get mediaInfo => (raw['mediaInfo'] as Map?)?.cast<String, dynamic>();
  MediaStatus get status => mediaStatusFrom((mediaInfo?['status'] as num?)?.toInt());
  List<Map<String, dynamic>> get requests =>
      (mediaInfo?['requests'] as List?)?.map((e) => (e as Map).cast<String, dynamic>()).toList() ?? const [];
  bool get isAvailable => status == MediaStatus.available;
  bool get isRequested =>
      status == MediaStatus.pending || status == MediaStatus.processing || (requests.isNotEmpty && !isAvailable);

  // Details-only fields.
  List<String> get genres =>
      (raw['genres'] as List?)?.map((g) => (g as Map)['name'] as String).toList() ?? const [];
  int? get runtime => (raw['runtime'] as num?)?.toInt();
  int? get numberOfSeasons => (raw['numberOfSeasons'] as num?)?.toInt();
  List<Map<String, dynamic>> get seasons =>
      (raw['seasons'] as List?)?.map((e) => (e as Map).cast<String, dynamic>()).where((s) => (s['seasonNumber'] as num? ?? 0) > 0).toList() ??
      const [];
  List<Map<String, dynamic>> get cast =>
      ((raw['credits'] as Map?)?['cast'] as List?)?.map((e) => (e as Map).cast<String, dynamic>()).toList() ?? const [];
  List<Map<String, dynamic>> get crew =>
      ((raw['credits'] as Map?)?['crew'] as List?)?.map((e) => (e as Map).cast<String, dynamic>()).toList() ?? const [];
  List<Map<String, dynamic>> get videos =>
      (raw['relatedVideos'] as List?)?.map((e) => (e as Map).cast<String, dynamic>()).toList() ?? const [];
  String? get certification {
    final rel = (raw['releases'] as Map?)?['results'] as List?;
    if (rel != null) {
      for (final r in rel) {
        final dates = (r as Map)['release_dates'] as List? ?? const [];
        for (final d in dates) {
          final c = (d as Map)['certification'] as String?;
          if (c != null && c.isNotEmpty) return c;
        }
      }
    }
    final ratings = (raw['contentRatings'] as Map?)?['results'] as List?;
    if (ratings != null && ratings.isNotEmpty) return (ratings.first as Map)['rating'] as String?;
    return null;
  }

  /// The best official trailer (YouTube), following the rules in the trailer spec.
  Map<String, dynamic>? get bestTrailer {
    final vids = videos.where((v) => (v['site'] as String?)?.toLowerCase() == 'youtube').toList();
    for (final t in ['Trailer', 'Teaser']) {
      final m = vids.where((v) => v['type'] == t).toList();
      if (m.isNotEmpty) return m.first;
    }
    return null;
  }

  static String? image(String? path, {String size = 'w780'}) =>
      path == null ? null : 'https://image.tmdb.org/t/p/$size$path';
  String? get posterUrl => image(posterPath, size: 'w500');
  String? get backdropUrl => image(backdropPath, size: 'w1280');
}

class SeerrRequest {
  final Map<String, dynamic> raw;
  SeerrRequest(this.raw);
  int get id => (raw['id'] as num).toInt();

  /// 1 pending, 2 approved, 3 declined.
  int get status => (raw['status'] as num?)?.toInt() ?? 1;
  Map<String, dynamic> get media => (raw['media'] as Map?)?.cast<String, dynamic>() ?? const {};
  MediaStatus get mediaStatus => mediaStatusFrom((media['status'] as num?)?.toInt());
  int? get tmdbId => (media['tmdbId'] as num?)?.toInt();
  String get mediaType => media['mediaType'] as String? ?? raw['type'] as String? ?? 'movie';
  bool get is4k => raw['is4k'] == true;
  String get requestedBy =>
      ((raw['requestedBy'] as Map?)?['displayName'] ?? (raw['requestedBy'] as Map?)?['jellyfinUsername'] ?? 'Someone') as String;
  DateTime? get createdAt => DateTime.tryParse(raw['createdAt'] as String? ?? '');
  List<int> get seasonNumbers =>
      (raw['seasons'] as List?)?.map((s) => ((s as Map)['seasonNumber'] as num).toInt()).toList() ?? const [];

  /// Downloads in progress for this request (from Radarr / Sonarr, via Seerr).
  List<Map<String, dynamic>> get downloads =>
      ((media[is4k ? 'downloadStatus4k' : 'downloadStatus'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();

  /// 0–1 across all of this request's downloads, or null when nothing is downloading.
  double? get downloadProgress {
    final d = downloads;
    if (d.isEmpty) return null;
    num size = 0, left = 0;
    for (final x in d) {
      size += (x['size'] as num?) ?? 0;
      left += (x['sizeLeft'] as num?) ?? 0;
    }
    if (size <= 0) return 0;
    return ((size - left) / size).clamp(0, 1).toDouble();
  }

  /// When the slowest download should finish.
  DateTime? get downloadEta {
    DateTime? latest;
    for (final x in downloads) {
      final t = DateTime.tryParse('${x['estimatedCompletionTime'] ?? ''}');
      if (t != null && (latest == null || t.isAfter(latest))) latest = t;
    }
    return latest;
  }

  /// The Jellyfin item, once it's on the server.
  String? get jellyfinId => media[is4k ? 'jellyfinMediaId4k' : 'jellyfinMediaId'] as String?;

  /// Plain-language status that combines approval and download state.
  String get label {
    if (status == 3) return 'Declined';
    if (mediaStatus == MediaStatus.available) return 'Available';
    if (mediaStatus == MediaStatus.partiallyAvailable) return downloads.isNotEmpty ? 'Downloading' : 'Partly available';
    if (status == 1) return 'Pending approval';
    if (downloads.isNotEmpty) return 'Downloading';
    if (mediaStatus == MediaStatus.processing) return 'Approved · waiting for release';
    return 'Approved';
  }

  String get filterKey {
    if (status == 3) return 'Declined';
    if (mediaStatus == MediaStatus.available || mediaStatus == MediaStatus.partiallyAvailable) return 'Available';
    if (status == 1) return 'Pending';
    return 'Approved';
  }
}

/// Seerr client. Signs in either with the user's Jellyfin credentials (session cookie, so
/// each person's requests are their own) or with an API key from Seerr's settings.
class SeerrClient {
  final String baseUrl;
  String? apiKey;

  SeerrClient({required String baseUrl, String? cookie, this.apiKey}) : baseUrl = _normalize(baseUrl) {
    this.cookie = cookie;
  }

  /// Accepts any link copied from Seerr in a browser (…/login, …/discover/movies, …/requests?x=1)
  /// and returns the base address. A reverse-proxy base path (e.g. /seerr) is kept.
  static String normalize(String url) {
    var u = url.trim();
    if (u.isEmpty) return u;
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'http://$u';
    for (final c in ['#', '?']) {
      final i = u.indexOf(c);
      if (i >= 0) u = u.substring(0, i);
    }
    final uri = Uri.tryParse(u);
    if (uri != null) {
      const pages = {
        'login', 'setup', 'discover', 'requests', 'request', 'movie', 'movies', 'tv', 'series', 'users',
        'settings', 'search', 'issues', 'profile', 'collection', 'person', 'api', 'watchlist', 'blacklist',
      };
      final segs = uri.pathSegments.where((x) => x.isNotEmpty).toList();
      final cut = segs.indexWhere((x) => pages.contains(x.toLowerCase()));
      final keep = cut < 0 ? segs : segs.sublist(0, cut);
      u = uri.replace(pathSegments: keep, query: null, fragment: null).toString();
      if (u.endsWith('?')) u = u.substring(0, u.length - 1);
      if (u.endsWith('#')) u = u.substring(0, u.length - 1);
    }
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  static String _normalize(String url) => normalize(url);

  // ---------------------------------------------------------------- session

  /// Cookies Seerr hands out: the session (connect.sid) and, when Seerr's CSRF protection
  /// is on, _csrf / XSRF-TOKEN. Saved as one "a=b; c=d" string per profile.
  final Map<String, String> _jar = {};

  String? get cookie => _jar.isEmpty ? null : _jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
  set cookie(String? v) {
    _jar.clear();
    if (v == null) return;
    for (final part in v.split(';')) {
      final i = part.indexOf('=');
      if (i > 0) _jar[part.substring(0, i).trim()] = part.substring(i + 1).trim();
    }
  }

  bool get hasSession => _jar.containsKey('connect.sid');

  /// Called when Seerr rejects the saved session; signs in again (without a password)
  /// and returns true if the request should be retried.
  Future<bool> Function()? reauth;
  bool get isSignedIn => hasSession || (apiKey != null && apiKey!.isNotEmpty);

  void _keepCookies(http.Response res) {
    final raw = res.headers['set-cookie'];
    if (raw == null) return;
    for (final m in RegExp(r'(connect\.sid|_csrf|XSRF-TOKEN)=([^;,\s]+)').allMatches(raw)) {
      _jar[m.group(1)!] = m.group(2)!;
    }
  }

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (_jar.isNotEmpty) 'Cookie': cookie!,
        if (_jar['XSRF-TOKEN'] != null) 'X-XSRF-TOKEN': Uri.decodeComponent(_jar['XSRF-TOKEN']!),
        if (!hasSession && apiKey != null && apiKey!.isNotEmpty) 'X-Api-Key': apiKey!,
      };

  Uri _uri(String path, [Map<String, String>? q]) {
    // Seerr is picky about encoding: spaces must be %20, not '+'.
    final query = q?.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
    return Uri.parse('$baseUrl/api/v1$path${query == null || query.isEmpty ? '' : '?$query'}');
  }

  static String _errorText(http.Response res) {
    try {
      final m = jsonDecode(res.body) as Map;
      final msg = m['message'] ?? m['error'];
      if (msg != null) return '$msg';
    } catch (_) {}
    return 'HTTP ${res.statusCode}';
  }

  Future<http.Response> _raw(String method, Uri uri, String? body) {
    const t = Duration(seconds: 20);
    switch (method) {
      case 'GET':
        return http.get(uri, headers: _headers).timeout(t);
      case 'POST':
        return http.post(uri, headers: _headers, body: body).timeout(t);
      case 'DELETE':
        return http.delete(uri, headers: _headers).timeout(t);
      default:
        throw ArgumentError(method);
    }
  }

  Future<dynamic> _send(String method, String path, {Map<String, String>? query, Object? body, bool retried = false}) async {
    final uri = _uri(path, query);
    final encoded = body == null ? null : jsonEncode(body);
    final res = await _raw(method, uri, encoded);
    _keepCookies(res);
    // With CSRF protection on, Seerr wants the token from a cookie echoed in a header.
    if (res.statusCode == 403 && method != 'GET' && !retried && res.body.toLowerCase().contains('csrf')) {
      _keepCookies(await http.get(_uri('/status'), headers: _headers).timeout(const Duration(seconds: 15)));
      return _send(method, path, query: query, body: body, retried: true);
    }
    if ((res.statusCode == 401 || res.statusCode == 403) && !retried && reauth != null && !path.startsWith('/auth/')) {
      if (await reauth!()) return _send(method, path, query: query, body: body, retried: true);
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw ApiException(res.statusCode, 'Seerr refused the request (${_errorText(res)}). Sign in to Seerr again in Settings.');
    }
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, 'Seerr returned ${res.statusCode}: ${_errorText(res)}');
    }
    if (res.body.isEmpty) return null;
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  Future<Map<String, dynamic>> status() async => ((await _send('GET', '/status')) as Map).cast<String, dynamic>();

  /// Looks for Seerr on the same machine as Jellyfin (Seerr's usual port, 5055), so it works
  /// without typing an address. Returns the address that answered, or null.
  static Future<String?> findNear(String jellyfinUrl) async {
    final j = Uri.tryParse(normalize(jellyfinUrl));
    if (j == null || j.host.isEmpty) return null;
    final candidates = {'${j.scheme}://${j.host}:5055', 'http://${j.host}:5055'};
    for (final c in candidates) {
      final ok = await SeerrClient(baseUrl: c).ping().timeout(const Duration(seconds: 4), onTimeout: () => false);
      if (ok) return c;
    }
    return null;
  }

  /// Checks the address points at a Seerr server.
  Future<bool> ping() async {
    try {
      final json = await _send('GET', '/status');
      return json is Map && json['version'] != null;
    } catch (_) {
      return false;
    }
  }

  /// Signs in with Jellyfin credentials. Stores the session cookie on success.
  Future<Map<String, dynamic>> signInWithJellyfin(String username, String password) async {
    _jar.remove('connect.sid');
    try {
      final json = await _send('POST', '/auth/jellyfin', body: {'username': username, 'password': password});
      if (!hasSession) throw ApiException(0, 'Seerr accepted the sign-in but sent no session.');
      return (json as Map).cast<String, dynamic>();
    } on ApiException catch (e) {
      throw ApiException(e.status, 'Seerr sign-in failed: ${e.message}');
    }
  }

  /// Signs in without a password using Jellyfin Quick Connect: Seerr asks Jellyfin for a code,
  /// and [authorize] approves that code with the Jellyfin session Ember already has.
  Future<Map<String, dynamic>> signInWithQuickConnect(Future<void> Function(String code) authorize) async {
    _jar.remove('connect.sid');
    final init = (await _send('POST', '/auth/jellyfin/quickconnect/initiate')) as Map;
    final code = '${init['code']}';
    final secret = '${init['secret']}';
    await authorize(code);
    for (var i = 0; i < 10; i++) {
      final check = await _send('GET', '/auth/jellyfin/quickconnect/check', query: {'secret': secret});
      if (check is Map && check['authenticated'] == true) break;
      await Future.delayed(const Duration(milliseconds: 700));
    }
    final json = await _send('POST', '/auth/jellyfin/quickconnect/authenticate', body: {'secret': secret});
    if (!hasSession) throw ApiException(0, 'Seerr accepted the sign-in but sent no session.');
    return (json as Map).cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> me() async => ((await _send('GET', '/auth/me')) as Map).cast<String, dynamic>();

  /// Seerr permission bits: ADMIN = 2, MANAGE_REQUESTS = 16.
  static bool canManageRequests(Map<String, dynamic> user) {
    final p = (user['permissions'] as num?)?.toInt() ?? 0;
    return (p & 2) != 0 || (p & 16) != 0;
  }

  List<SeerrMedia> _results(dynamic json) {
    final list = (json as Map)['results'] as List? ?? const [];
    return list
        .map((e) => SeerrMedia((e as Map).cast<String, dynamic>()))
        .where((m) => m.raw['mediaType'] == null || m.raw['mediaType'] == 'movie' || m.raw['mediaType'] == 'tv')
        .toList();
  }

  Future<List<SeerrMedia>> trending({int page = 1}) async =>
      _results(await _send('GET', '/discover/trending', query: {'page': '$page'}));

  Future<List<SeerrMedia>> upcoming(String mediaType, {int page = 1}) async {
    final json = await _send('GET', mediaType == 'tv' ? '/discover/tv/upcoming' : '/discover/movies/upcoming', query: {'page': '$page'});
    return _results(json).map((m) {
      m.raw['mediaType'] ??= mediaType;
      return m;
    }).toList();
  }

  /// Titles releasing between [from] and [to] (movies by release date, shows by first air date),
  /// most popular first.
  Future<List<SeerrMedia>> releasing(String mediaType, DateTime from, DateTime to, {int page = 1}) async {
    String d(DateTime t) => '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    final tv = mediaType == 'tv';
    final json = await _send('GET', tv ? '/discover/tv' : '/discover/movies', query: {
      'page': '$page',
      'sortBy': 'popularity.desc',
      if (tv) 'firstAirDateGte': d(from) else 'primaryReleaseDateGte': d(from),
      if (tv) 'firstAirDateLte': d(to) else 'primaryReleaseDateLte': d(to),
    });
    return _results(json).map((m) {
      m.raw['mediaType'] ??= mediaType;
      return m;
    }).toList();
  }

  /// Everything Seerr knows about (requested, processing, available…), keyed "movie:123" / "tv:456".
  Future<Map<String, Map<String, dynamic>>> allMedia({int max = 2000}) async {
    final out = <String, Map<String, dynamic>>{};
    for (var skip = 0; skip < max; skip += 100) {
      final json = await _send('GET', '/media', query: {'take': '100', 'skip': '$skip', 'sort': 'modified'});
      final list = (json as Map)['results'] as List? ?? const [];
      for (final e in list) {
        final m = (e as Map).cast<String, dynamic>();
        out['${m['mediaType']}:${m['tmdbId']}'] = m;
      }
      if (list.length < 100) break;
    }
    return out;
  }

  Future<List<SeerrMedia>> search(String query, {int page = 1}) async =>
      _results(await _send('GET', '/search', query: {'query': query, 'page': '$page'}));

  Future<SeerrMedia> details(String mediaType, int tmdbId) async {
    final json = await _send('GET', mediaType == 'tv' ? '/tv/$tmdbId' : '/movie/$tmdbId');
    final m = (json as Map).cast<String, dynamic>();
    m['mediaType'] = mediaType;
    return SeerrMedia(m);
  }

  Future<List<SeerrMedia>> similar(String mediaType, int tmdbId) async {
    final json = await _send('GET', mediaType == 'tv' ? '/tv/$tmdbId/similar' : '/movie/$tmdbId/similar');
    return _results(json).map((m) {
      m.raw['mediaType'] ??= mediaType;
      return m;
    }).toList();
  }

  /// TMDB's "if you liked this" picks for a title, with Seerr's availability and request status.
  Future<List<SeerrMedia>> recommendations(String mediaType, int tmdbId) async {
    final json = await _send('GET', mediaType == 'tv' ? '/tv/$tmdbId/recommendations' : '/movie/$tmdbId/recommendations');
    return _results(json).map((m) {
      m.raw['mediaType'] ??= mediaType;
      return m;
    }).toList();
  }

  Future<void> request({required String mediaType, required int tmdbId, List<int>? seasons, bool is4k = false}) async {
    await _send('POST', '/request', body: {
      'mediaType': mediaType,
      'mediaId': tmdbId,
      if (mediaType == 'tv') 'seasons': seasons ?? 'all',
      'is4k': is4k,
    });
  }

  Future<List<SeerrRequest>> requests({int take = 40}) async {
    final json = await _send('GET', '/request', query: {'take': '$take', 'skip': '0', 'sort': 'added', 'filter': 'all'});
    final list = (json as Map)['results'] as List? ?? const [];
    return list.map((e) => SeerrRequest((e as Map).cast<String, dynamic>())).toList();
  }

  Future<void> approve(int requestId) => _send('POST', '/request/$requestId/approve');
  Future<void> decline(int requestId) => _send('POST', '/request/$requestId/decline');
}
