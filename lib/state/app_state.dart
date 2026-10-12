import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/jellyfin.dart';
import '../api/seerr.dart';

/// How the person is using Ember. Decides layout and navigation style.
///  - tv: remote / D-pad, focus highlight always on, side menu, 10-foot sizes.
///  - desktop: mouse + keyboard, hover states, resizable window, visible Back button.
///  - phone: touch, bottom tab bar (layouts arrive in the phone phase).
enum FormFactor { tv, desktop, phone }

enum InterfaceMode { auto, tv, desktop, phone }

class Account {
  final String serverUrl;
  final String serverName;
  final String userId;
  final String name;
  final String token;
  final bool isAdmin;
  final String? imageTag;
  String? seerrCookie;

  Account({
    required this.serverUrl,
    required this.serverName,
    required this.userId,
    required this.name,
    required this.token,
    required this.isAdmin,
    this.imageTag,
    this.seerrCookie,
  });

  Map<String, dynamic> toJson() => {
        'serverUrl': serverUrl,
        'serverName': serverName,
        'userId': userId,
        'name': name,
        'token': token,
        'isAdmin': isAdmin,
        'imageTag': imageTag,
        'seerrCookie': seerrCookie,
      };

  factory Account.fromJson(Map<String, dynamic> j) => Account(
        serverUrl: j['serverUrl'] as String,
        serverName: j['serverName'] as String? ?? 'Jellyfin',
        userId: j['userId'] as String,
        name: j['name'] as String? ?? '',
        token: j['token'] as String,
        isAdmin: j['isAdmin'] == true,
        imageTag: j['imageTag'] as String?,
        seerrCookie: j['seerrCookie'] as String?,
      );
}

/// Streaming quality choices. null bitrate = original file (direct play).
class QualityOption {
  final String key;
  final String label;
  final int? bitrate;
  const QualityOption(this.key, this.label, this.bitrate);
}

const qualityOptions = <QualityOption>[
  QualityOption('auto', 'Auto (original when the connection allows)', null),
  QualityOption('original', 'Original · Direct Play', null),
  QualityOption('20m', '1080p · 20 Mbps', 20000000),
  QualityOption('8m', '720p · 8 Mbps', 8000000),
  QualityOption('4m', '720p · 4 Mbps', 4000000),
  QualityOption('2m', '480p · 2 Mbps', 2000000),
];

class AppState extends ChangeNotifier {
  late SharedPreferences _prefs;
  bool ready = false;

  late String deviceId;
  late String deviceName;
  FormFactor detectedFormFactor = FormFactor.desktop;
  InterfaceMode interfaceMode = InterfaceMode.auto;

  String? serverUrl;
  String? serverName;
  List<Account> accounts = [];
  String? currentUserId;

  String? seerrUrl;
  String? seerrApiKey;
  Map<String, dynamic>? seerrUser;
  /// Why Seerr isn't working right now (shown in Settings and on the Requests screen).
  String? seerrError;
  Future<bool>? _seerrSigningIn;

  // Preferences
  bool autoSkipIntro = false;
  bool trailersInApp = true;
  bool autoplayPreviews = true;
  bool previewsMuted = true;
  /// Status from the server's Ember Trailers plugin; null = not installed / unreachable.
  Map<String, dynamic>? trailerService;
  bool get trailerServiceOk => trailerService?['status'] == 'Online' || trailerService?['status'] == 'Degraded';
  bool audioPassthrough = false; // send Dolby / DTS bitstreams untouched to an AV receiver or soundbar
  bool hdrOutput = true; // ask the display for HDR when the video is HDR
  bool autoplayNext = true;
  bool showTrendingRow = true;
  bool addRequestsToMyList = true;
  String quality = 'auto';
  String? preferredAudioLanguage;
  String subtitleMode = 'foreign'; // off, foreign, always

  JellyfinClient? jf;
  SeerrClient? seerr;

  /// Bumped whenever library data may have changed, so screens reload.
  int revision = 0;

  FormFactor get formFactor => switch (interfaceMode) {
        InterfaceMode.tv => FormFactor.tv,
        InterfaceMode.desktop => FormFactor.desktop,
        InterfaceMode.phone => FormFactor.phone,
        InterfaceMode.auto => detectedFormFactor,
      };
  bool get isTv => formFactor == FormFactor.tv;
  bool get isDesktop => formFactor == FormFactor.desktop;
  bool get isPhone => formFactor == FormFactor.phone;

  Account? get account {
    for (final a in accounts) {
      if (a.userId == currentUserId && a.serverUrl == serverUrl) return a;
    }
    return null;
  }

  List<Account> get serverAccounts => accounts.where((a) => a.serverUrl == serverUrl).toList();
  bool get seerrConfigured => seerr != null && seerr!.isSignedIn;
  bool get canManageRequests => seerrUser != null ? SeerrClient.canManageRequests(seerrUser!) : (account?.isAdmin ?? false);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    deviceId = _prefs.getString('deviceId') ?? _newId();
    await _prefs.setString('deviceId', deviceId);
    deviceName = _deviceName();
    detectedFormFactor = await _detectFormFactor();

    interfaceMode = InterfaceMode.values.firstWhere((m) => m.name == _prefs.getString('interfaceMode'),
        orElse: () => InterfaceMode.auto);
    serverUrl = _prefs.getString('serverUrl');
    serverName = _prefs.getString('serverName');
    currentUserId = _prefs.getString('currentUserId');
    seerrUrl = _prefs.getString('seerrUrl');
    seerrApiKey = _prefs.getString('seerrApiKey');
    autoSkipIntro = _prefs.getBool('autoSkipIntro') ?? false;
    audioPassthrough = _prefs.getBool('audioPassthrough') ?? false;
    trailersInApp = _prefs.getBool('trailersInApp') ?? true;
    autoplayPreviews = _prefs.getBool('autoplayPreviews') ?? true;
    previewsMuted = _prefs.getBool('previewsMuted') ?? true;
    hdrOutput = _prefs.getBool('hdrOutput') ?? true;
    autoplayNext = _prefs.getBool('autoplayNext') ?? true;
    showTrendingRow = _prefs.getBool('showTrendingRow') ?? true;
    addRequestsToMyList = _prefs.getBool('addRequestsToMyList') ?? true;
    quality = _prefs.getString('quality') ?? 'auto';
    preferredAudioLanguage = _prefs.getString('preferredAudioLanguage');
    subtitleMode = _prefs.getString('subtitleMode') ?? 'foreign';
    final raw = _prefs.getString('accounts');
    if (raw != null) {
      try {
        accounts = (jsonDecode(raw) as List).map((e) => Account.fromJson((e as Map).cast<String, dynamic>())).toList();
      } catch (_) {
        accounts = [];
      }
    }
    _rebuildClients();
    ready = true;
    notifyListeners();
    _refreshSeerrUser();
  }

  String _newId() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  String _deviceName() {
    try {
      if (Platform.isWindows) return 'Windows - ${Platform.localHostname}';
      if (Platform.isAndroid) return 'Android';
      if (Platform.isIOS) return 'iOS';
      if (Platform.isMacOS) return 'macOS';
      return Platform.operatingSystem;
    } catch (_) {
      return 'Ember';
    }
  }

  Future<FormFactor> _detectFormFactor() async {
    if (kIsWeb) return FormFactor.desktop;
    if (Platform.isAndroid) {
      try {
        final isTv = await const MethodChannel('ember/device').invokeMethod<bool>('isTv');
        if (isTv == true) return FormFactor.tv;
      } catch (_) {}
      return FormFactor.phone;
    }
    if (Platform.isIOS) return FormFactor.phone;
    return FormFactor.desktop;
  }

  void _rebuildClients() {
    final a = account;
    if (serverUrl != null) {
      jf = JellyfinClient(
        baseUrl: serverUrl!,
        deviceId: deviceId,
        deviceName: deviceName,
        token: a?.token,
        userId: a?.userId,
      );
    } else {
      jf = null;
    }
    if (seerrUrl != null && seerrUrl!.isNotEmpty) {
      seerr = SeerrClient(baseUrl: seerrUrl!, cookie: a?.seerrCookie, apiKey: seerrApiKey)
        ..reauth = () => seerrAutoSignIn(force: true);
    } else {
      seerr = null;
    }
  }

  Future<void> _save() async {
    await _prefs.setString('accounts', jsonEncode(accounts.map((a) => a.toJson()).toList()));
    _setOrRemove('serverUrl', serverUrl);
    _setOrRemove('serverName', serverName);
    _setOrRemove('currentUserId', currentUserId);
    _setOrRemove('seerrUrl', seerrUrl);
    _setOrRemove('seerrApiKey', seerrApiKey);
    _setOrRemove('preferredAudioLanguage', preferredAudioLanguage);
    await _prefs.setString('interfaceMode', interfaceMode.name);
    await _prefs.setBool('autoSkipIntro', autoSkipIntro);
    await _prefs.setBool('audioPassthrough', audioPassthrough);
    await _prefs.setBool('trailersInApp', trailersInApp);
    await _prefs.setBool('autoplayPreviews', autoplayPreviews);
    await _prefs.setBool('previewsMuted', previewsMuted);
    await _prefs.setBool('hdrOutput', hdrOutput);
    await _prefs.setBool('autoplayNext', autoplayNext);
    await _prefs.setBool('showTrendingRow', showTrendingRow);
    await _prefs.setBool('addRequestsToMyList', addRequestsToMyList);
    await _prefs.setString('quality', quality);
    await _prefs.setString('subtitleMode', subtitleMode);
  }

  void _setOrRemove(String key, String? value) {
    if (value == null) {
      _prefs.remove(key);
    } else {
      _prefs.setString(key, value);
    }
  }

  // ------------------------------------------------------------ server + accounts

  Future<void> setServer(String url, String name) async {
    serverUrl = JellyfinClient.normalizeUrl(url);
    serverName = name;
    currentUserId = null;
    _rebuildClients();
    await _save();
    notifyListeners();
  }

  Future<void> forgetServer() async {
    serverUrl = null;
    serverName = null;
    currentUserId = null;
    _rebuildClients();
    await _save();
    notifyListeners();
  }

  /// Called after a successful Jellyfin sign-in. If a password was used and Seerr is set up,
  /// signs in to Seerr with the same credentials so requests are made as this person.
  Future<void> signedIn(AuthResult r, {String? username, String? password}) async {
    accounts.removeWhere((a) => a.userId == r.userId && a.serverUrl == serverUrl);
    final acc = Account(
      serverUrl: serverUrl!,
      serverName: serverName ?? 'Jellyfin',
      userId: r.userId,
      name: r.userName,
      token: r.token,
      isAdmin: r.isAdmin,
      imageTag: r.primaryImageTag,
    );
    accounts.add(acc);
    currentUserId = r.userId;
    _rebuildClients();
    if (password != null && seerr != null) {
      try {
        await seerr!.signInWithJellyfin(username ?? r.userName, password);
        acc.seerrCookie = seerr!.cookie;
      } catch (_) {
        // Falls back to the password-free sign-in in _refreshSeerrUser.
      }
    }
    revision++;
    await _save();
    notifyListeners();
    _refreshSeerrUser();
  }

  Future<void> switchTo(Account a) async {
    serverUrl = a.serverUrl;
    serverName = a.serverName;
    currentUserId = a.userId;
    _rebuildClients();
    revision++;
    await _save();
    notifyListeners();
    _refreshSeerrUser();
  }

  /// Leaves the current profile but keeps it saved for one-press switching.
  Future<void> leaveProfile() async {
    currentUserId = null;
    seerrUser = null;
    _rebuildClients();
    await _save();
    notifyListeners();
  }

  Future<void> signOut() async {
    final a = account;
    if (a != null) {
      await jf?.logout();
      accounts.remove(a);
    }
    currentUserId = null;
    seerrUser = null;
    _rebuildClients();
    await _save();
    notifyListeners();
  }

  // ------------------------------------------------------------ Seerr

  Future<void> setSeerr({required String url, String? apiKey}) async {
    seerrUrl = url.trim().isEmpty ? null : url.trim();
    seerrApiKey = (apiKey == null || apiKey.trim().isEmpty) ? null : apiKey.trim();
    seerrError = null;
    _rebuildClients();
    await _save();
    notifyListeners();
    _refreshSeerrUser();
  }

  Future<void> seerrSignIn(String username, String password) async {
    if (seerr == null) throw ApiException(0, 'Add your Seerr address first.');
    await seerr!.signInWithJellyfin(username, password);
    account?.seerrCookie = seerr!.cookie;
    seerrError = null;
    await _save();
    notifyListeners();
    _refreshSeerrUser();
  }

  /// Signs this profile in to Seerr without a password: Seerr starts a Jellyfin Quick Connect
  /// request and Ember approves it with the Jellyfin session it already has.
  /// Concurrent callers share one attempt. Returns true when Seerr has a session.
  Future<bool> seerrAutoSignIn({bool force = false}) {
    final s = seerr, j = jf;
    if (s == null || j == null || j.token == null || account == null) return Future.value(false);
    if (s.hasSession && !force) return Future.value(true);
    return _seerrSigningIn ??= () async {
      try {
        await s.signInWithQuickConnect((code) => j.authorizeQuickConnect(code));
        account?.seerrCookie = s.cookie;
        seerrError = null;
        await _save();
        return true;
      } catch (e) {
        seerrError = 'Automatic Seerr sign-in failed: $e';
        return false;
      } finally {
        _seerrSigningIn = null;
        notifyListeners();
      }
    }();
  }

  /// Progress text while Ember sets up the trailer service, or null.
  String? trailerSetupStep;

  /// Whether this admin has said "Later" to the trailer setup prompt on this server.
  bool get trailerPromptDismissed => _prefs.getBool('trailerPromptDismissed:$serverUrl') ?? false;
  Future<void> dismissTrailerPrompt() async {
    await _prefs.setBool('trailerPromptDismissed:$serverUrl', true);
    notifyListeners();
  }

  /// 'missing', 'restart' (installed, waiting for a restart), 'disabled', 'active', or 'unknown'.
  Future<String> trailerPluginState() async {
    final c = jf;
    if (c == null || !(account?.isAdmin ?? false)) return 'unknown';
    try {
      final p = await c.trailerPlugin();
      if (p == null) return 'missing';
      final st = '${p['Status']}'.toLowerCase();
      if (st == 'restart') return 'restart';
      if (st == 'disabled' || st == 'superceded' || st == 'malfunctioned' || st == 'notsupported') return 'disabled';
      return 'active';
    } catch (_) {
      return 'unknown';
    }
  }

  /// True when Ember should offer to set up trailers (admin, not installed, not dismissed).
  Future<bool> shouldOfferTrailerSetup() async {
    if (!(account?.isAdmin ?? false) || trailerPromptDismissed) return false;
    await refreshTrailerService();
    if (trailerService != null) return false;
    return await trailerPluginState() == 'missing';
  }

  /// Installs the Ember Trailers plugin on the server, restarts it and waits for trailers to work.
  /// Whether the running trailer plugin has everything this Ember needs.
  bool get trailerServiceCurrent => ((trailerService?['features'] as List?)?.contains('streamtest') ?? false);

  static const needsFullRestart =
      'The new version is installed, but Jellyfin keeps the old one loaded until it is fully restarted. '
      'Restart the Jellyfin container (or service) on your server, then tap "Check again".';

  /// The installed trailer plugin's version and status, e.g. "0.3.1.0 · Active" (admins only).
  String? trailerPluginVersion;

  Future<void> refreshTrailerPluginVersion() async {
    if (!(account?.isAdmin ?? false) || jf == null) return;
    try {
      final p = await jf!.trailerPlugin();
      trailerPluginVersion = p == null ? null : '${p['Version']}${p['Status'] != 'Active' ? ' · ${p['Status']}' : ''}';
      notifyListeners();
    } catch (_) {}
  }

  /// Installs (or updates) the Ember Trailers plugin, restarts the server, and only reports success
  /// once the server is really running the new version.
  Future<void> installTrailerService() async {
    final c = jf;
    if (c == null) return;
    void step(String? s) {
      trailerSetupStep = s;
      notifyListeners();
    }

    try {
      final before = await c.trailerPlugin().catchError((_) => null);
      final beforeVersion = before?['Version'] as String?;
      final outdated = trailerService != null && !trailerServiceCurrent;
      // Installed already, just not loaded yet: only a full restart helps.
      if (outdated && before != null && before['Status'] == 'Active' && await c.trailerPluginIsNewest(before['Version'] as String?)) {
        throw ApiException(0, needsFullRestart);
      }
      if (before == null || outdated || before['Status'] == 'Restart') {
        if (before?['Status'] != 'Restart') {
          step('Adding Ember\'s plugin source to your server…');
          await c.addTrailerRepository();
          step('Downloading the newest trailer plugin…');
          await c.installTrailerPlugin();
        }
        step('Restarting your server to switch it on…');
        await c.restartServer();
        // Wait until the server has really restarted with the new version (up to 4 minutes).
        final end = DateTime.now().add(const Duration(minutes: 4));
        var running = false;
        await Future.delayed(const Duration(seconds: 5));
        while (DateTime.now().isBefore(end)) {
          try {
            final now = await c.trailerPlugin();
            if (now != null && now['Status'] == 'Active' && now['Version'] != beforeVersion) {
              running = true;
              break;
            }
          } catch (_) {
            step('Waiting for your server to come back…');
          }
          await Future.delayed(const Duration(seconds: 3));
        }
        if (!running) {
          throw ApiException(0, 'The new version is installed but your server hasn\'t restarted to load it. '
              'Restart it from Jellyfin › Dashboard (or restart the container), then tap "Check again".');
        }
      }
      step('Getting the trailer player ready…');
      trailerService = null;
      for (var i = 0; i < 20 && !trailerServiceOk; i++) {
        await refreshTrailerService();
        if (!trailerServiceOk) await Future.delayed(const Duration(seconds: 3));
      }
      if (trailerService == null) {
        throw ApiException(0, 'The plugin is installed but didn\'t start. Open Dashboard › Plugins on your server to check it.');
      }
      if (!trailerServiceCurrent) throw ApiException(0, needsFullRestart);
    } finally {
      await refreshTrailerPluginVersion();
      step(null);
    }
  }

  Future<void> refreshTrailerService() async {
    final c = jf;
    if (c == null || c.token == null) {
      trailerService = null;
      return;
    }
    trailerService = await c.trailerHealth();
    notifyListeners();
    refreshTrailerPluginVersion();
  }

  Future<void> _refreshSeerrUser() async {
    refreshTrailerService();
    final s = seerr;
    final wasConnected = seerrUser != null;
    if (s == null || account == null) {
      seerrUser = null;
      return;
    }
    // No session yet (signed in to Ember with a saved session or Quick Connect): sign in now.
    if (!s.hasSession) await seerrAutoSignIn();
    if (!s.isSignedIn) {
      seerrUser = null;
      notifyListeners();
      return;
    }
    try {
      try {
        seerrUser = await s.me();
      } on ApiException catch (e) {
        // The saved session expired: get a fresh one and try once more.
        if ((e.status == 401 || e.status == 403) && await seerrAutoSignIn(force: true)) {
          seerrUser = await s.me();
        } else {
          rethrow;
        }
      }
      if (seerr == s) seerrError = null;
    } catch (e) {
      seerrUser = null;
      seerrError ??= '$e';
    }
    // Pages that show Seerr rows reload once Seerr becomes (un)available.
    if (wasConnected != (seerrUser != null)) revision++;
    notifyListeners();
  }

  /// Re-checks Seerr from scratch (used by Settings › Seerr › Check connection).
  Future<void> refreshSeerr() async {
    seerrError = null;
    await _refreshSeerrUser();
  }

  // ------------------------------------------------------------ preferences

  Future<void> update(void Function(AppState s) change) async {
    change(this);
    await _save();
    notifyListeners();
  }

  void bumpRevision() {
    revision++;
    notifyListeners();
  }
}
