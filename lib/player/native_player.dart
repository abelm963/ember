import 'dart:async';

import 'package:flutter/services.dart';

import '../api/jellyfin.dart';
import '../api/youtube.dart';
import '../state/app_state.dart';
import 'segments.dart';
import 'tracks.dart';

/// Apple TV: full-screen playback with Apple's own player (`tvos/Runner/NativePlayer.swift`).
///
/// Flutter draws video through a texture, which is always SDR. Apple's player shows HDR10,
/// Dolby Vision and Dolby Atmos as they are, switches the TV's mode with Match Content, and
/// brings the Siri Remote gestures, the Info panel and Enhance Dialogue with it.
///
/// This side asks Jellyfin what to play (the original file when Apple TV can open it, otherwise
/// a stream the server repackages or converts), picks the audio and subtitles, and reports
/// progress. The native side shows the player, Skip Intro, Next Episode and "Are you still
/// watching?", and says what happened.
class NativePlayer {
  static const _channel = MethodChannel('ember/player');
  static NativePlayer? _current;

  final AppState app;
  final bool isTrailer;
  JfItem? _item;
  PlaybackSource? _src;
  JfItem? _next;
  int? _audioIndex;
  int? _subIndex;
  bool _defaultsDone = false;
  Duration _position = Duration.zero;
  final _done = Completer<void>();

  NativePlayer._(this.app, {this.isTrailer = false});

  JellyfinClient get _jf => app.jf!;

  /// Plays [item], resuming at [start]. Completes when the player closes.
  static Future<void> play(AppState app, JfItem item, {Duration? start}) async {
    final p = NativePlayer._(app);
    await p._begin(item);
    unawaited(p._load(item, start));
    return p._done.future;
  }

  /// Plays a trailer. The player appears at once; [resolve] finds the stream meanwhile, and
  /// finds it another way when Apple's player can't open it. Returns false (with the player
  /// closed again) when nothing would play, so the caller can hand the trailer to the YouTube
  /// app instead.
  static Future<bool> playTrailer(AppState app,
      {required String title, String? artwork, required TrailerResolver resolve}) async {
    final p = NativePlayer._(app, isTrailer: true)
      .._resolveTrailer = resolve
      .._trailerTitle = title
      .._trailerArtwork = artwork;
    _bind(p);
    await p._invoke('open', {'title': title, 'artwork': artwork, 'isTrailer': true});
    final first = await resolve().catchError((_) => null);
    // Closed while it was being found: nothing more to do.
    if (p._done.isCompleted) return true;
    if (first == null) {
      await p._giveUp();
      return false;
    }
    await p._loadTrailer(first);
    await p._done.future;
    return !p._gaveUp;
  }

  TrailerResolver? _resolveTrailer;
  TrailerStream? _trailer;
  String? _trailerTitle;
  String? _trailerArtwork;
  bool _gaveUp = false;

  Future<void> _loadTrailer(TrailerStream t) async {
    _trailer = t;
    await _invoke('load', {
      'url': t.url,
      'audioUrl': t.audioUrl,
      'audioLanguage': t.audioLanguage,
      'headers': t.headers,
      'title': _trailerTitle,
      'artwork': _trailerArtwork,
      'isTrailer': true,
    });
  }

  /// The trailer wouldn't open or start: try the next way, or close so the YouTube app takes over.
  Future<void> _trailerFailed() async {
    final failed = _trailer, resolve = _resolveTrailer;
    if (failed == null || resolve == null || _gaveUp) return;
    _trailer = null;
    final next = await resolve(failed).catchError((_) => null);
    if (_done.isCompleted) return;
    if (next == null) return _giveUp();
    await _loadTrailer(next);
  }

  Future<void> _giveUp() async {
    _gaveUp = true;
    await _invoke('close', {});
    await _done.future.timeout(const Duration(seconds: 3), onTimeout: () {});
  }

  static void _bind(NativePlayer p) {
    _current = p;
    _channel.setMethodCallHandler(
      (call) async => _current?._onEvent(call.method, (call.arguments as Map?) ?? const {}),
    );
  }

  Future<void> _invoke(String method, Map<String, dynamic> args) =>
      _channel.invokeMethod(method, args..removeWhere((k, v) => v == null)).catchError((_) {});

  Future<void> _begin(JfItem item) async {
    _bind(this);
    await _invoke('open', {..._describe(item), 'itemId': item.id});
  }

  // ------------------------------------------------------------------ choosing what to play

  Future<PlaybackSource> _source(JfItem item) => _jf.playbackSource(
        item.id,
        maxBitrate: _maxBitrate,
        audioStreamIndex: _audioIndex,
        subtitleStreamIndex: _subIndex,
        mediaSourceId: _mediaSourceId,
      );

  String? _mediaSourceId;
  int? _maxBitrate;

  static List<Map<String, dynamic>> _of(PlaybackSource s, String type) =>
      s.streams.where((x) => x['Type'] == type).toList();

  static int? _indexOf(Map<String, dynamic>? s) => (s?['Index'] as num?)?.toInt();

  /// Picks the version, soundtrack, subtitles and quality before the server is asked, so it's
  /// asked once, for exactly that (see `planPlayback`).
  Future<void> _pickDefaults(JfItem item) async {
    _defaultsDone = true;
    final plan = await planPlayback(app, item);
    _mediaSourceId = plan.mediaSourceId;
    _audioIndex = plan.audioIndex;
    _subIndex = plan.subtitleIndex;
    _maxBitrate = isTrailer ? null : plan.maxBitrate;
  }

  // ------------------------------------------------------------------ loading

  Map<String, dynamic> _describe(JfItem item) => {
    'title': item.isEpisode ? (item.seriesName ?? item.name) : item.name,
    'subtitle': item.isEpisode ? '${item.episodeLabel} · ${item.name}' : item.year?.toString(),
    'overview': item.overview,
    'artwork': _jf.backdropImage(item, maxWidth: 1280),
    'seriesName': item.seriesName,
  };

  Future<void> _load(JfItem item, Duration? start) async {
    _item = item;
    try {
      final results = await Future.wait<Object?>([
        _defaultsDone ? Future.value(null) : _pickDefaults(item),
        _jf.mediaSegments(item.id),
        item.isEpisode ? _jf.nextEpisode(item).catchError((_) => null) : Future.value(null),
        _jf.item(item.id).then<JfItem?>((f) => f).catchError((_) => null),
      ]);
      final full = results[3] as JfItem?;
      // Checked against the episode's length, with the file's chapter names when the server has none.
      final segments = tidySegments(results[1] as List<MediaSegment>, (full ?? item).runtime ?? Duration.zero,
          chapters: full == null ? const [] : chaptersOf(full));
      _next = results[2] as JfItem?;
      final src = await _source(item);
      _src = src;
      _position = start ?? Duration.zero;

      final audio = _of(src, 'Audio');
      final currentAudio =
          _audioIndex ??
          _indexOf(audio.firstWhere((s) => s['IsDefault'] == true, orElse: () => audio.isEmpty ? {} : audio.first));
      await _invoke('load', {
        ..._describe(item),
        'itemId': item.id,
        'url': src.url,
        'start': start?.inMilliseconds == null ? 0.0 : start!.inMilliseconds / 1000,
        'segments': [
          for (final s in segments)
            {'type': s.type, 'start': s.start.inMilliseconds / 1000, 'end': s.end.inMilliseconds / 1000},
        ],
        'hasNext': _next != null,
        'serverTracks': src.transcoding,
        'audio': [
          for (final s in audio) {'index': _indexOf(s), 'label': _label(s), 'selected': _indexOf(s) == currentAudio},
        ],
        'subtitles': [
          for (final s in _of(src, 'Subtitle'))
            {'index': _indexOf(s), 'label': _label(s), 'selected': _indexOf(s) == _subIndex},
        ],
        'showSubtitles': _subIndex != null,
        'autoSkipIntro': app.autoSkipIntro,
        'autoplayNext': app.autoplayNext,
        'stillWatching': app.stillWatching,
        'stillWatchingAfter': app.stillWatchingEpisodes,
      });
      unawaited(_jf.reportStart(item.id, src.mediaSourceId, src.playSessionId, _position, src.transcoding));
    } catch (e) {
      await _invoke('failed', {'message': '$e'});
    }
  }

  /// A soundtrack picked in the player becomes the preferred language, so the next film starts in it.
  void _rememberLanguage(int index) {
    final s = _src?.streams.where((x) => x['Type'] == 'Audio' && _indexOf(x) == index).firstOrNull;
    final lang = s == null ? null : trackLanguage(s);
    if (lang != null && !langMatch(lang, app.preferredAudioLanguage)) {
      app.update((a) => a.preferredAudioLanguage = preferredCode(lang));
    }
  }

  static String _label(Map<String, dynamic> s) {
    final t = s['DisplayTitle'] as String?;
    if (t != null && t.isNotEmpty) return t;
    return [s['Language'], (s['Codec'] as String?)?.toUpperCase()].whereType<String>().join(' · ');
  }

  Future<void> _stopped() async {
    final s = _src, item = _item;
    if (s == null || item == null || isTrailer) return;
    _src = null;
    await _jf.reportStopped(item.id, s.mediaSourceId, s.playSessionId, _position);
  }

  // ------------------------------------------------------------------ events from the player

  Future<void> _onEvent(String method, Map args) async {
    final pos = (args['position'] as num?)?.toDouble();
    if (pos != null) _position = Duration(milliseconds: (pos * 1000).round());
    switch (method) {
      case 'progress':
        final s = _src, item = _item;
        if (s != null && item != null && !isTrailer) {
          await _jf.reportProgress(
            item.id,
            s.mediaSourceId,
            s.playSessionId,
            _position,
            args['paused'] == true,
            s.transcoding,
          );
        }
      case 'next':
        final n = _next;
        await _stopped();
        if (n == null) return;
        _audioIndex = null;
        _subIndex = null;
        _mediaSourceId = null;
        _defaultsDone = false;
        await _load(n, n.positionTicks > 0 ? ticksToDuration(n.positionTicks) : null);
      case 'track':
        final index = (args['index'] as num?)?.toInt() ?? -1;
        if (args['kind'] == 'audio') {
          _audioIndex = index >= 0 ? index : null;
          _rememberLanguage(index);
        } else {
          _subIndex = index >= 0 ? index : null;
        }
        final item = _item;
        await _stopped();
        if (item != null) await _load(item, _position);
      case 'failed':
        if (isTrailer) await _trailerFailed();
      case 'closed':
        await _stopped();
        if (_current == this) _current = null;
        if (!isTrailer) app.bumpRevision();
        if (!_done.isCompleted) _done.complete();
    }
  }
}
