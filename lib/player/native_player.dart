import 'dart:async';

import 'package:flutter/services.dart';

import '../api/jellyfin.dart';
import '../api/youtube.dart';
import '../state/app_state.dart';

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

  /// Plays a trailer. The player appears at once; [resolve] finds the stream meanwhile.
  /// Returns false (with the player closed again) when there was nothing to play, so the
  /// caller can hand the trailer to the YouTube app instead.
  static Future<bool> playTrailer(AppState app,
      {required String title, String? artwork, required Future<TrailerStream> Function() resolve}) async {
    final p = NativePlayer._(app, isTrailer: true);
    _bind(p);
    await p._invoke('open', {'title': title, 'artwork': artwork, 'isTrailer': true});
    try {
      final t = await resolve();
      await p._invoke('load', {'url': t.url, 'audioUrl': t.audioUrl, 'title': title, 'artwork': artwork, 'isTrailer': true});
    } catch (_) {
      await p._invoke('close', {});
      await p._done.future.timeout(const Duration(seconds: 3), onTimeout: () {});
      return false;
    }
    await p._done.future;
    return true;
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

  QualityOption get _quality =>
      qualityOptions.firstWhere((o) => o.key == app.quality, orElse: () => qualityOptions.first);

  Future<PlaybackSource> _source(JfItem item) async {
    var bitrate = _quality.bitrate;
    var src = await _jf.playbackSource(
      item.id,
      maxBitrate: bitrate,
      audioStreamIndex: _audioIndex,
      subtitleStreamIndex: _subIndex,
    );
    // Auto quality: if the connection can't carry the original comfortably, ask for less.
    if (_quality.key == 'auto' && src.bitrate != null && !isTrailer) {
      final bps = await _jf.measureBitrate();
      if (bps != null && bps < src.bitrate! * 1.1) {
        final target = (bps * 0.8).round();
        bitrate = qualityOptions
            .where((o) => o.bitrate != null && o.bitrate! <= target)
            .map((o) => o.bitrate!)
            .fold<int>(2000000, (a, b) => b > a ? b : a);
        src = await _jf.playbackSource(
          item.id,
          maxBitrate: bitrate,
          audioStreamIndex: _audioIndex,
          subtitleStreamIndex: _subIndex,
        );
      }
    }
    return src;
  }

  static List<Map<String, dynamic>> _of(PlaybackSource s, String type) =>
      s.streams.where((x) => x['Type'] == type).toList();

  static int? _indexOf(Map<String, dynamic>? s) => (s?['Index'] as num?)?.toInt();

  /// Languages with two three-letter codes (files use either; Settings stores the first).
  static const _sameLanguage = {
    'ger': 'deu',
    'fre': 'fra',
    'dut': 'nld',
    'chi': 'zho',
    'cze': 'ces',
    'gre': 'ell',
    'per': 'fas',
    'rum': 'ron',
    'slo': 'slk',
    'alb': 'sqi',
    'arm': 'hye',
    'baq': 'eus',
    'bur': 'mya',
    'geo': 'kat',
    'ice': 'isl',
    'mac': 'mkd',
    'mao': 'mri',
    'may': 'msa',
    'tib': 'bod',
    'wel': 'cym',
  };

  static bool _langMatch(String? a, String? b) {
    if (a == null || b == null || a.length < 2 || b.length < 2) return false;
    a = _sameLanguage[a.toLowerCase()] ?? a.toLowerCase();
    b = _sameLanguage[b.toLowerCase()] ?? b.toLowerCase();
    return a == b || a.startsWith(b.substring(0, 2)) || b.startsWith(a.substring(0, 2));
  }

  static String _describeStream(Map<String, dynamic> s) =>
      '${s['Profile'] ?? ''} ${s['DisplayTitle'] ?? ''} ${s['Title'] ?? ''}'.toLowerCase();

  static bool _isAtmos(Map<String, dynamic> s) => _describeStream(s).contains('atmos');

  /// How well Apple TV plays a soundtrack as it is: Dolby Digital Plus with Atmos is passed
  /// straight to the TV or receiver; TrueHD and DTS have to be converted by the server.
  static int _audioScore(Map<String, dynamic> s) {
    final codec = (s['Codec'] as String? ?? '').toLowerCase();
    final ch = (s['Channels'] as num?)?.toInt() ?? 2;
    var score = ch;
    if (codec == 'eac3' && _isAtmos(s)) score += 100;
    if (codec == 'eac3' || codec == 'ac3' || codec == 'aac' || codec == 'flac' || codec == 'alac') score += 20;
    return score;
  }

  /// Picks the defaults for [src] and returns true when the stream must be reopened with them.
  bool _pickDefaults(PlaybackSource src) {
    _defaultsDone = true;
    final (audio, sub, reopen) = chooseTracks(src.streams, app.preferredAudioLanguage, app.subtitleMode);
    _audioIndex = audio;
    _subIndex = sub;
    return reopen;
  }

  /// The person's language, the best soundtrack Apple TV can play in it (Atmos first, and
  /// never a commentary), and subtitles following Settings › Subtitles ('off', 'foreign',
  /// 'always'). Returns the audio index to ask for (null = the file's default), the subtitle
  /// index (null = none), and whether that differs from what the server sends by default.
  static (int?, int?, bool) chooseTracks(
    List<Map<String, dynamic>> streams,
    String? preferredLanguage,
    String subtitleMode,
  ) {
    final audio = streams.where((s) => s['Type'] == 'Audio').toList();
    if (audio.isEmpty) return (null, null, false);
    final defaultAudio = audio.firstWhere((s) => s['IsDefault'] == true, orElse: () => audio.first);
    var lang = defaultAudio['Language'] as String?;
    if (preferredLanguage != null && audio.any((s) => _langMatch(s['Language'] as String?, preferredLanguage))) {
      lang = preferredLanguage;
    }
    final sameLang = audio.where((s) => lang == null || _langMatch(s['Language'] as String?, lang)).toList();
    var chosen = sameLang.contains(defaultAudio) ? defaultAudio : sameLang.first;
    for (final s in sameLang) {
      if (_audioScore(s) > _audioScore(chosen) && !_describeStream(s).contains('comment')) chosen = s;
    }

    final subLang = preferredLanguage ?? 'eng';
    final wantSubs = switch (subtitleMode) {
      'off' => false,
      'always' => true,
      _ => chosen['Language'] != null && !_langMatch(chosen['Language'] as String?, subLang),
    };
    final subs = wantSubs
        ? streams
              .where(
                (s) =>
                    s['Type'] == 'Subtitle' && _langMatch(s['Language'] as String?, subLang) && s['IsForced'] != true,
              )
              .toList()
        : const <Map<String, dynamic>>[];

    final audioIndex = _indexOf(chosen) != _indexOf(defaultAudio) ? _indexOf(chosen) : null;
    final subIndex = subs.isEmpty ? null : _indexOf(subs.first);
    return (audioIndex, subIndex, audioIndex != null || subIndex != null);
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
        _source(item),
        _jf.mediaSegments(item.id),
        item.isEpisode ? _jf.nextEpisode(item).catchError((_) => null) : Future.value(null),
      ]);
      var src = results[0] as PlaybackSource;
      final segments = results[1] as List<MediaSegment>;
      _next = results[2] as JfItem?;
      if (!_defaultsDone && _pickDefaults(src)) src = await _source(item);
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
        _defaultsDone = false;
        await _load(n, n.positionTicks > 0 ? ticksToDuration(n.positionTicks) : null);
      case 'track':
        final index = (args['index'] as num?)?.toInt() ?? -1;
        if (args['kind'] == 'audio') {
          _audioIndex = index >= 0 ? index : null;
        } else {
          _subIndex = index >= 0 ? index : null;
        }
        final item = _item;
        await _stopped();
        if (item != null) await _load(item, _position);
      case 'closed':
        await _stopped();
        if (_current == this) _current = null;
        if (!isTrailer) app.bumpRevision();
        if (!_done.isCompleted) _done.complete();
    }
  }
}
