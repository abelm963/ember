import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import '../api/jellyfin.dart';
import '../api/youtube.dart';
import '../platform.dart';
import '../state/app_state.dart';
import '../ui/browse.dart' show MetaDots;
import '../ui/theme.dart';
import '../screens/nav.dart' show openYouTube;
import '../ui/widgets.dart';
import 'engine.dart';
import 'segments.dart';
import 'tracks.dart';

/// Full-screen player. Built on mpv (via media_kit), which plays every common container,
/// codec, audio format and subtitle type itself — so files are streamed untouched and the
/// server only transcodes when the connection is too slow. On Apple TV it uses Apple's own
/// player instead, and audio and subtitle choices go through the server (see [_serverTracks]).
class PlayerScreen extends StatefulWidget {
  final JfItem item;
  final Duration? start;
  final bool isTrailer;

  /// Plays this URL directly (a trailer streamed by the server) instead of asking Jellyfin how to play [item].
  final String? directUrl;

  /// Finds the trailer's stream after the player is already on screen, so the Trailer button
  /// responds at once. Throws with a readable reason when there's nothing to play.
  final TrailerResolver? resolveTrailer;

  /// The trailer's YouTube id, for "Open on YouTube" when the server can't play it.
  final String? youtubeKey;

  /// Shown behind the "getting the trailer" message.
  final String? backdropUrl;

  const PlayerScreen({
    super.key,
    required this.item,
    this.start,
    this.isTrailer = false,
    this.directUrl,
    this.resolveTrailer,
    this.youtubeKey,
    this.backdropUrl,
  });
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

enum _Panel { none, controls, tracks, quality, episodes }

class _MenuOption {
  final String label;
  final bool selected;
  final Future<void> Function() onPick;
  _MenuOption(this.label, this.selected, this.onPick);
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final PlaybackEngine _engine = PlaybackEngine(title: 'Ember');

  /// The mpv player, when that's what is playing (everywhere but Apple TV).
  Player? get _mpv => switch (_engine) {
    MpvEngine e => e.player,
    _ => null,
  };
  late JellyfinClient _jf;
  late AppState _app;

  late JfItem _item = widget.item;
  PlaybackSource? _src;
  String? _sessionQuality; // overrides the saved quality for this session
  String? _error;
  Timer? _trailerWatchdog;
  String? _status;

  bool get _isStream => widget.directUrl != null || widget.resolveTrailer != null;

  static String _clean(Object e) {
    var m = '$e'.replaceAll(RegExp(r'(api_key|ApiKey)=[^&\s]+'), r'$1=…');
    if (m.contains('Failed to open')) m = 'YouTube didn\'t start sending the trailer.';
    return m;
  }

  bool _loading = true;

  _Panel _panel = _Panel.none;
  Timer? _hideTimer;
  Timer? _reportTimer;
  final _rootFocus = FocusNode();
  final _playFocus = FocusNode();
  final _skipFocus = FocusNode();
  final _nextFocus = FocusNode();
  final _scrubFocus = FocusNode();

  /// Where left/right on the remote is moving to; the jump happens a moment after the last press
  /// (or at once on select), with the picture at that point shown above the bar.
  Duration? _scrubTarget;
  Timer? _scrubTimer;

  /// After a while paused, the controls give way to a dimmed "You're watching" screen.
  Timer? _pauseTimer;
  bool _pauseInfo = false;

  /// Episodes that started on their own one after another with nothing pressed, for
  /// "Are you still watching?".
  int _autoAdvanced = 0;
  bool _askStillWatching = false;

  // The Episodes panel.
  List<JfItem>? _seasons;
  String? _panelSeasonId;
  List<JfItem>? _panelEpisodes;

  bool _playing = false;
  bool _buffering = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  Tracks _tracks = const Tracks();
  Track _track = const Track();

  List<MediaSegment> _rawSegments = [];
  List<Chapter> _chapters = const [];

  /// The intro, recap and credits times, checked against the episode's length (`segments.dart`).
  List<MediaSegment> get _segments => tidySegments(
    _rawSegments,
    _duration > Duration.zero ? _duration : (_item.runtime ?? Duration.zero),
    chapters: _chapters,
  );
  TrickplayInfo? _trick;
  JfItem? _next;
  bool _upNextDismissed = false;
  int? _countdown;
  Timer? _countdownTimer;
  DateTime? _bufferingSince;
  bool _defaultsApplied = false;
  bool _autoDowngraded = false;
  bool _introSkippedAuto = false;

  // Audio and subtitles picked through the server (Apple TV, or while transcoding).
  int? _audioIndex;
  int? _subIndex;
  String? _mediaSourceId;
  bool _subBurnedIn = false;
  bool _serverDefaultsDone = false;
  final List<StreamSubscription> _subs = [];

  TrailerStream? _trailer;

  Future<void> _openTrailer(TrailerStream t) async {
    _trailer = t;
    setState(() => _status = 'Starting the trailer…');
    final p = _mpv?.platform;
    if (p is NativePlayer) {
      // The trailer's own soundtrack rather than one of YouTube's machine dubs.
      await p.setProperty('alang', t.audioLanguage ?? '');
    }
    await _engine.open(t.url, headers: t.headers);
    // YouTube sometimes keeps the sharpest picture and the sound in separate files; mpv joins them.
    if (t.audioUrl != null) await _mpv?.setAudioTrack(AudioTrack.uri(t.audioUrl!));
    if (!mounted) return;
    setState(() => _loading = false);
    _showControls();
    // A trailer that hasn't started after 12 s isn't going to: try it another way.
    _trailerWatchdog?.cancel();
    _trailerWatchdog = Timer(const Duration(seconds: 12), () {
      if (mounted && _position == Duration.zero && _error == null) {
        _trailerFailed('YouTube didn\'t start sending the trailer.');
      }
    });
  }

  /// The trailer wouldn't open or start: find it another way, or say why it can't play.
  Future<void> _trailerFailed(String reason) async {
    final failed = _trailer;
    if (failed == null) return;
    _trailer = null;
    _trailerWatchdog?.cancel();
    setState(() {
      _loading = true;
      _status = 'Trying another way…';
    });
    final next = await widget.resolveTrailer!(failed).catchError((_) => null);
    if (!mounted) return;
    if (next == null) {
      setState(() {
        _loading = false;
        _error = reason;
      });
      return;
    }
    await _openTrailer(next);
  }

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _jf = _app.jf!;
    _configureMpv();
    final mpv = _mpv;
    _subs.addAll([
      _engine.playing.listen(_onPlaying),
      _engine.position.listen(_onPosition),
      _engine.duration.listen((v) => setState(() => _duration = v)),
      _engine.buffer.listen((v) => _buffered = v),
      _engine.buffering.listen(_onBuffering),
      if (mpv != null) ...[
        mpv.stream.tracks.listen((t) {
          setState(() => _tracks = t);
          _applyDefaultTracks();
        }),
        mpv.stream.track.listen((t) => setState(() => _track = t)),
      ],
      _engine.completed.listen((done) {
        if (done) _onCompleted();
      }),
      _engine.error.listen((e) {
        // A trailer that won't open is asked for another way before showing an error.
        if (_trailer != null && _position == Duration.zero) {
          _trailerFailed(_clean(e));
        } else if (_loading || (_isStream && _position == Duration.zero)) {
          setState(() => _error = _isStream ? _clean(e) : 'Playback failed: $e');
        }
      }),
    ]);
    _open(_item, widget.start);
  }

  Future<void> _configureMpv() async {
    final p = _mpv?.platform;
    if (p is NativePlayer) {
      // A large read-ahead cache rides out short network drops without stalling.
      await p.setProperty('cache', 'yes');
      await p.setProperty('cache-secs', '120');
      await p.setProperty('demuxer-max-bytes', '400MiB');
      await p.setProperty('demuxer-max-back-bytes', '50MiB');
      await p.setProperty('demuxer-readahead-secs', '60');
      await p.setProperty('network-timeout', '30');

      // HDR10 / HDR10+ / HLG / Dolby Vision: mpv reads the HDR metadata (including Dolby Vision
      // profile 5 and 8 colour data), asks the display for HDR when it can, and otherwise
      // tone-maps to SDR so colours never look washed out or purple.
      await p.setProperty('target-colorspace-hint', _app.hdrOutput ? 'yes' : 'no');
      await p.setProperty('tone-mapping', 'auto');
      await p.setProperty('hdr-compute-peak', 'yes');

      // Surround: either send Dolby Digital(+), TrueHD (incl. Atmos) and DTS / DTS-HD / DTS:X
      // untouched to an AV receiver or soundbar, or decode them to multichannel PCM.
      if (_app.audioPassthrough) {
        await p.setProperty('audio-spdif', 'ac3,eac3,dts,dts-hd,truehd');
        await p.setProperty('audio-exclusive', 'yes');
      } else {
        await p.setProperty('audio-spdif', '');
        await p.setProperty('audio-channels', 'auto');
      }
    }
  }

  // ------------------------------------------------------------------ opening

  QualityOption get _quality {
    final key = _sessionQuality ?? _app.quality;
    return qualityOptions.firstWhere((o) => o.key == key, orElse: () => qualityOptions.first);
  }

  Future<void> _open(JfItem item, Duration? start, {int? audioStreamIndex, int? subtitleStreamIndex}) async {
    await _stopReporting();
    if (item.id != _item.id) {
      _position = Duration.zero;
      _duration = Duration.zero;
      _audioIndex = null;
      _subIndex = null;
      _subBurnedIn = false;
      _serverDefaultsDone = false;
      _mediaSourceId = null;
    }
    _audioIndex = audioStreamIndex ?? _audioIndex;
    if (audioStreamIndex != null) _rememberLanguage(audioStreamIndex);
    // -1 turns burned-in subtitles off again.
    if (subtitleStreamIndex != null) {
      _subIndex = subtitleStreamIndex >= 0 ? subtitleStreamIndex : null;
      _subBurnedIn = _subIndex != null;
    }
    setState(() {
      _item = item;
      _loading = true;
      _error = null;
      _defaultsApplied = false;
      _upNextDismissed = false;
      _countdown = null;
      _introSkippedAuto = false;
      _rawSegments = [];
      _chapters = const [];
      _next = null;
      _askStillWatching = false;
      _pauseInfo = false;
    });
    if (_isStream) {
      try {
        final url = widget.directUrl;
        if (url != null) {
          await _engine.open(url);
          setState(() => _loading = false);
          _showControls();
        } else {
          setState(() => _status = 'Finding the official trailer…');
          final t = await widget.resolveTrailer!();
          if (!mounted) return;
          if (t == null) throw ApiException(0, 'YouTube didn\'t hand this trailer over.');
          await _openTrailer(t);
        }
      } catch (e) {
        if (!mounted) return;
        if (_trailer != null) return _trailerFailed(_clean(e));
        setState(() {
          _loading = false;
          _error = _clean(e);
        });
      }
      return;
    }
    try {
      int? bitrate;
      var sized = true;
      if (isAppleTv && !_serverDefaultsDone) {
        // Apple TV: pick the version, the person's soundtrack and subtitles first, so the server
        // is asked once and sends exactly that soundtrack (instead of the file's default).
        _serverDefaultsDone = true;
        final plan = await planPlayback(_app, item, qualityKey: _quality.key);
        _mediaSourceId = plan.mediaSourceId;
        _audioIndex = plan.audioIndex;
        final sub = plan.streams.where((s) => (s['Index'] as num?)?.toInt() == plan.subtitleIndex).firstOrNull;
        _subIndex = sub == null ? null : plan.subtitleIndex;
        // Picture-based subtitles (PGS, VobSub) are drawn into the video by the server.
        _subBurnedIn = sub != null && sub['IsTextSubtitleStream'] != true;
        bitrate = plan.maxBitrate;
      } else {
        // Auto quality: the original file unless the connection (tested once and remembered)
        // can't carry it comfortably.
        final sizeOf =
            item.mediaSources.where((s) => s['Id'] == _mediaSourceId).firstOrNull ?? item.mediaSources.firstOrNull;
        final size = (sizeOf?['Bitrate'] as num?)?.toInt();
        sized = size != null;
        bitrate = await _app.maxBitrateFor(size, qualityKey: _quality.key);
      }
      Future<PlaybackSource> ask() => _jf.playbackSource(
        item.id,
        maxBitrate: bitrate,
        audioStreamIndex: _audioIndex,
        subtitleStreamIndex: _subBurnedIn ? _subIndex : null,
        mediaSourceId: _mediaSourceId,
      );
      var src = await ask();
      if (!sized && bitrate == null) {
        // The file's size wasn't known until now: check it fits the connection.
        bitrate = await _app.maxBitrateFor(src.bitrate, qualityKey: _quality.key);
        if (bitrate != null) src = await ask();
      }
      _src = src;
      await _engine.open(src.url, start: start);
      // Text subtitles (picked now, or before a reopen for another quality or soundtrack) come on.
      if (_serverTracks && _subIndex != null && !_subBurnedIn) unawaited(_showServerSubtitle(_subIndex!));
      if (!widget.isTrailer) {
        unawaited(
          _jf.reportStart(item.id, src.mediaSourceId, src.playSessionId, start ?? Duration.zero, src.transcoding),
        );
        _reportTimer = Timer.periodic(const Duration(seconds: 10), (_) {
          final s = _src;
          if (s != null) {
            _jf.reportProgress(_item.id, s.mediaSourceId, s.playSessionId, _position, !_playing, s.transcoding);
          }
        });
        // Answers for an episode that is no longer playing (Next Episode was quick) are dropped.
        _jf
            .mediaSegments(item.id)
            .then((s) => mounted && _item.id == item.id ? setState(() => _rawSegments = s) : null);
        _jf
            .item(item.id)
            .then((full) {
              if (mounted && _item.id == item.id) {
                setState(() {
                  _trick = TrickplayInfo.fromItem(full);
                  _chapters = chaptersOf(full);
                });
              }
            })
            .catchError((_) {});
        if (item.isEpisode) {
          _jf
              .nextEpisode(item)
              .then((n) => mounted && _item.id == item.id ? setState(() => _next = n) : null)
              .catchError((_) => null);
        }
      }
      setState(() => _loading = false);
      _showControls();
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _reopenAtCurrent({int? audioStreamIndex, int? subtitleStreamIndex}) =>
      _open(_item, _position, audioStreamIndex: audioStreamIndex, subtitleStreamIndex: subtitleStreamIndex);

  Future<void> _stopReporting() async {
    _reportTimer?.cancel();
    _reportTimer = null;
    final s = _src;
    if (s != null && !widget.isTrailer) {
      await _jf.reportStopped(_item.id, s.mediaSourceId, s.playSessionId, _position);
    }
  }

  // ------------------------------------------------------------------ tracks

  /// Audio and subtitles go through the server when it's transcoding, and always on Apple TV
  /// (AVPlayer's own track switching isn't available there).
  bool get _serverTracks => isAppleTv || (_src?.transcoding ?? false);

  List<Map<String, dynamic>> _streamsOf(String type) => _src?.streams.where((s) => s['Type'] == type).toList() ?? [];

  int? _defaultIndexOf(String type) {
    final streams = _streamsOf(type);
    final d = streams.where((s) => s['IsDefault'] == true).toList();
    final s = d.isNotEmpty ? d.first : (streams.isNotEmpty ? streams.first : null);
    return (s?['Index'] as num?)?.toInt();
  }

  Future<void> _showServerSubtitle(int index) async {
    final src = _src;
    if (src == null) return;
    final s = _streamsOf('Subtitle').where((s) => (s['Index'] as num?)?.toInt() == index).toList();
    if (s.isEmpty) return;
    setState(() => _subIndex = index);
    try {
      await _engine.setTextSubtitles(
        _jf.subtitleUrl(_item.id, src.mediaSourceId, s.first, format: isAppleTv ? 'vtt' : null),
      );
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  /// A soundtrack picked in the player becomes the preferred language, so the next film starts in it.
  void _rememberLanguage(int index) {
    final s = _streamsOf('Audio').where((x) => (x['Index'] as num?)?.toInt() == index).firstOrNull;
    final lang = s == null ? null : trackLanguage(s);
    if (lang != null && !langMatch(lang, _app.preferredAudioLanguage)) {
      _app.update((a) => a.preferredAudioLanguage = preferredCode(lang));
    }
  }

  /// The language of the soundtrack playing now.
  String? get _audioLanguage {
    final player = _mpv;
    if (!_serverTracks && player != null) return _track.audio.language;
    final current = _audioIndex ?? _defaultIndexOf('Audio');
    final s = _streamsOf('Audio').where((x) => (x['Index'] as num?)?.toInt() == current).firstOrNull;
    return s == null ? null : trackLanguage(s);
  }

  /// Subtitles turned on or off in the player are remembered for the next title, as streaming
  /// apps do: the language, and whether they're wanted over this kind of soundtrack.
  void _rememberSubtitles({required bool on, String? language}) {
    final own = _app.preferredAudioLanguage ?? 'eng';
    final ownAudio = langMatch(_audioLanguage, own);
    _app.update((a) {
      a.subtitleMode = rememberedSubtitleMode(a.subtitleMode, on: on, ownLanguageAudio: ownAudio);
      if (on && language != null) {
        a.preferredSubtitleLanguage = langMatch(language, own) ? null : preferredCode(language);
      }
    });
  }

  void _applyDefaultTracks() {
    final player = _mpv;
    if (player == null || _defaultsApplied || _src == null || _serverTracks) return;
    final audio = _tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
    if (audio.isEmpty) return;
    _defaultsApplied = true;
    final pref = _app.preferredAudioLanguage;
    AudioTrack? chosenAudio;
    if (pref != null) {
      for (final t in audio) {
        if (langMatch(t.language, pref)) {
          chosenAudio = t;
          break;
        }
      }
      if (chosenAudio != null) player.setAudioTrack(chosenAudio);
    }
    final subs = _tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();
    final audioLang = (chosenAudio ?? audio.first).language;
    final subLang = _app.preferredSubtitleLanguage ?? pref ?? 'eng';
    switch (_app.subtitleMode) {
      case 'off':
        player.setSubtitleTrack(SubtitleTrack.no());
        break;
      case 'always':
        final s = subs.where((t) => langMatch(t.language, subLang)).toList();
        if (s.isNotEmpty) player.setSubtitleTrack(s.first);
        break;
      default: // only when the audio isn't in the person's language
        if (audioLang != null && !langMatch(audioLang, pref ?? subLang)) {
          final s = subs.where((t) => langMatch(t.language, subLang)).toList();
          if (s.isNotEmpty) player.setSubtitleTrack(s.first);
        } else {
          player.setSubtitleTrack(SubtitleTrack.no());
        }
    }
  }

  static Map<String, dynamic> _mpvAudio(AudioTrack t) => {
    'Language': t.language,
    'Title': t.title,
    'Codec': t.codec,
    'Channels': t.channelscount,
    'Index': t.id,
  };
  static Map<String, dynamic> _mpvSub(SubtitleTrack t) => {'Language': t.language, 'Title': t.title, 'Index': t.id};

  /// "English 5.1", "French", "English – Audio Description": languages first, as in the menus of
  /// streaming apps, with repeats told apart.
  static List<String> _labels(List<Map<String, dynamic>> streams, String Function(Map<String, dynamic>) label) =>
      distinctLabels([for (final s in streams) label(s)], streams);

  List<_MenuOption> _audioOptions() {
    final src = _src;
    if (src == null) return [];
    final player = _mpv;
    if (!_serverTracks && player != null) {
      final tracks = _tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
      final labels = _labels([for (final t in tracks) _mpvAudio(t)], audioLabel);
      return [
        for (var i = 0; i < tracks.length; i++)
          _MenuOption(labels[i], _track.audio.id == tracks[i].id, () async {
            await player.setAudioTrack(tracks[i]);
            final lang = tracks[i].language;
            if (lang != null && !langMatch(lang, _app.preferredAudioLanguage)) {
              _app.update((a) => a.preferredAudioLanguage = preferredCode(lang));
            }
          }),
      ];
    }
    final current = _audioIndex ?? _defaultIndexOf('Audio');
    final streams = _streamsOf('Audio');
    final labels = _labels(streams, audioLabel);
    return [
      for (var i = 0; i < streams.length; i++)
        _MenuOption(
          labels[i],
          (streams[i]['Index'] as num?)?.toInt() == current,
          () => _reopenAtCurrent(audioStreamIndex: (streams[i]['Index'] as num).toInt()),
        ),
    ];
  }

  List<_MenuOption> _subtitleOptions() {
    final src = _src;
    if (src == null) return [];
    final player = _mpv;
    _MenuOption remembered(String label, bool selected, String? language, bool on, Future<void> Function() pick) =>
        _MenuOption(label, selected, () async {
          await pick();
          _rememberSubtitles(on: on, language: language);
        });
    if (!_serverTracks && player != null) {
      final external = src.streams.where((s) => s['Type'] == 'Subtitle' && s['IsExternal'] == true).toList();
      final tracks = _tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no' && !t.uri).toList();
      final labels = _labels([for (final t in tracks) _mpvSub(t), ...external], subtitleLabel);
      return [
        remembered(
          'Off',
          _track.subtitle.id == 'no' || _track.subtitle.id == 'auto',
          null,
          false,
          () => player.setSubtitleTrack(SubtitleTrack.no()),
        ),
        for (var i = 0; i < tracks.length; i++)
          remembered(
            labels[i],
            _track.subtitle.id == tracks[i].id,
            tracks[i].language,
            true,
            () => player.setSubtitleTrack(tracks[i]),
          ),
        for (var i = 0; i < external.length; i++)
          remembered(
            labels[tracks.length + i],
            _track.subtitle.title == external[i]['DisplayTitle'],
            trackLanguage(external[i]),
            true,
            () => player.setSubtitleTrack(
              SubtitleTrack.uri(
                _jf.subtitleUrl(_item.id, src.mediaSourceId, external[i]),
                title: external[i]['DisplayTitle'] as String?,
                language: external[i]['Language'] as String?,
              ),
            ),
          ),
      ];
    }
    final streams = _streamsOf('Subtitle');
    final labels = _labels(streams, subtitleLabel);
    return [
      remembered('Off', _subIndex == null, null, false, () async {
        if (_subBurnedIn) {
          await _reopenAtCurrent(subtitleStreamIndex: -1);
        } else {
          setState(() => _subIndex = null);
          await _engine.setTextSubtitles(null);
        }
      }),
      for (var i = 0; i < streams.length; i++)
        remembered(
          labels[i],
          _subIndex == (streams[i]['Index'] as num?)?.toInt(),
          trackLanguage(streams[i]),
          true,
          () async {
            final s = streams[i];
            if (s['IsTextSubtitleStream'] == true) {
              if (_subBurnedIn) await _reopenAtCurrent(subtitleStreamIndex: -1);
              await _showServerSubtitle((s['Index'] as num).toInt());
            } else {
              // Picture-based subtitles (PGS, VobSub) are drawn into the video by the server.
              await _reopenAtCurrent(subtitleStreamIndex: (s['Index'] as num).toInt());
            }
          },
        ),
    ];
  }

  List<_MenuOption> _qualityMenu() => [
    for (final o in qualityOptions)
      _MenuOption(o.label, o.key == _quality.key, () async {
        _sessionQuality = o.key;
        await _reopenAtCurrent();
      }),
  ];

  // ------------------------------------------------------------------ events

  void _onPosition(Duration p) {
    if (!mounted) return;
    setState(() => _position = p);
    final intro = _activeSegment('Intro');
    if (intro != null && _app.autoSkipIntro && !_introSkippedAuto) {
      _introSkippedAuto = true;
      _engine.seek(intro.end);
      toast(context, 'Intro skipped');
    }
    if (_showUpNext && _countdown == null && _app.autoplayNext && !_upNextDismissed && !_askStillWatching) {
      _startCountdown();
    }
  }

  void _onPlaying(bool v) {
    if (!mounted) return;
    setState(() {
      _playing = v;
      if (v) _pauseInfo = false;
    });
    _pauseTimer?.cancel();
    if (!v && !_isStream) {
      _pauseTimer = Timer(const Duration(seconds: 12), () {
        if (!mounted || _playing || _loading || _error != null || _askStillWatching) return;
        if (_panel != _Panel.none && _panel != _Panel.controls) return;
        _hideTimer?.cancel();
        setState(() {
          _panel = _Panel.none;
          _pauseInfo = true;
        });
        _rootFocus.requestFocus();
      });
    }
  }

  void _onBuffering(bool b) {
    setState(() => _buffering = b);
    if (b) {
      _bufferingSince = DateTime.now();
      // If the original file keeps stalling, step down once instead of buffering forever.
      Future.delayed(const Duration(seconds: 6), () {
        if (!mounted || !_buffering || _bufferingSince == null || _autoDowngraded) return;
        if (DateTime.now().difference(_bufferingSince!) < const Duration(seconds: 6)) return;
        if (_quality.key == 'auto' && _src != null && !_src!.transcoding && _position > const Duration(seconds: 5)) {
          _autoDowngraded = true;
          _sessionQuality = '8m';
          toast(context, 'Network is slow, switched to 720p');
          _reopenAtCurrent();
        }
      });
    } else {
      _bufferingSince = null;
    }
  }

  void _onCompleted() {
    if (widget.isTrailer) {
      Navigator.of(context).maybePop();
      return;
    }
    if (_askStillWatching) return;
    if (_next != null && _app.autoplayNext) {
      _autoNext();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  MediaSegment? _activeSegment(String type) {
    for (final s in _segments) {
      if (s.type == type && _position >= s.start && _position < s.end - const Duration(seconds: 1)) return s;
    }
    return null;
  }

  /// The parts of an episode a button can skip, and what the button says.
  static const _skipLabels = {'Intro': 'Skip Intro', 'Recap': 'Skip Recap', 'Preview': 'Skip Preview'};

  MediaSegment? get _skippable {
    for (final type in _skipLabels.keys) {
      final s = _activeSegment(type);
      if (s != null) return s;
    }
    return null;
  }

  bool get _showUpNext {
    if (_next == null || _upNextDismissed || _duration == Duration.zero) return false;
    // From the credits (or the preview of the next episode, when only that is marked).
    final end = _segments.where((s) => s.type == 'Outro' || s.type == 'Preview').toList();
    if (end.isNotEmpty) return _position >= end.first.start;
    return _duration - _position <= const Duration(seconds: 25);
  }

  static const _countdownSeconds = 8;

  void _startCountdown() {
    setState(() => _countdown = _countdownSeconds);
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _upNextDismissed) {
        t.cancel();
        return;
      }
      if (_countdown! <= 1) {
        t.cancel();
        _autoNext();
      } else {
        setState(() => _countdown = _countdown! - 1);
      }
    });
    if (_app.isTv) WidgetsBinding.instance.addPostFrameCallback((_) => _nextFocus.requestFocus());
  }

  /// The next episode starting by itself: after a few in a row with nothing pressed, ask first.
  void _autoNext() {
    _countdownTimer?.cancel();
    if (_next == null) return;
    if (_app.stillWatching && _autoAdvanced >= _app.stillWatchingEpisodes) {
      _engine.pause();
      _hideTimer?.cancel();
      setState(() {
        _askStillWatching = true;
        _countdown = null;
        _upNextDismissed = true;
        _panel = _Panel.none;
        _pauseInfo = false;
      });
      return;
    }
    _autoAdvanced++;
    _playNext();
  }

  Future<void> _playNext() async {
    _countdownTimer?.cancel();
    final n = _next;
    if (n == null) return;
    await _open(n, null);
  }

  /// Something was pressed, clicked or touched: the person is still there.
  void _acted() => _autoAdvanced = 0;

  // ------------------------------------------------------------------ controls

  void _showControls({bool focus = false}) {
    _hideTimer?.cancel();
    if (_pauseInfo) setState(() => _pauseInfo = false);
    if (_panel == _Panel.none) setState(() => _panel = _Panel.controls);
    if (focus) {
      WidgetsBinding.instance.addPostFrameCallback((_) => (_app.isPhone ? _playFocus : _scrubFocus).requestFocus());
    }
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _panel == _Panel.controls && _playing && _scrubTarget == null) {
        setState(() => _panel = _Panel.none);
        _rootFocus.requestFocus();
      }
    });
  }

  void _hideControls() {
    _hideTimer?.cancel();
    setState(() => _panel = _Panel.none);
    _rootFocus.requestFocus();
  }

  void _openPanel(_Panel p) {
    _hideTimer?.cancel();
    setState(() => _panel = p);
  }

  void _seekBy(Duration d) {
    var t = _position + d;
    if (t < Duration.zero) t = Duration.zero;
    if (_duration > Duration.zero && t > _duration) t = _duration - const Duration(seconds: 1);
    _engine.seek(t);
  }

  /// Left/right: moves the scrub point 10 seconds (bigger steps while held), showing the picture
  /// there; the jump happens when the presses stop, or at once on select.
  void _scrub(int direction, {bool held = false}) {
    final step = held && _duration > Duration.zero
        ? Duration(seconds: (_duration.inSeconds / 120).clamp(10, 60).round())
        : const Duration(seconds: 10);
    var t = (_scrubTarget ?? _position) + step * direction;
    if (t < Duration.zero) t = Duration.zero;
    if (_duration > Duration.zero && t > _duration - const Duration(seconds: 2)) {
      t = _duration - const Duration(seconds: 2);
    }
    setState(() => _scrubTarget = t);
    _showControls(focus: !_scrubFocus.hasFocus && !_app.isPhone);
    _scrubTimer?.cancel();
    _scrubTimer = Timer(const Duration(milliseconds: 900), _commitScrub);
  }

  void _commitScrub() {
    _scrubTimer?.cancel();
    final t = _scrubTarget;
    if (t == null || !mounted) return;
    _engine.seek(t);
    setState(() {
      _position = t;
      _scrubTarget = null;
    });
    _showControls();
  }

  void _cancelScrub() {
    _scrubTimer?.cancel();
    setState(() => _scrubTarget = null);
  }

  void _selectOnBar() {
    if (_scrubTarget != null) {
      _commitScrub();
    } else {
      _engine.playOrPause();
      _showControls();
    }
  }

  void _skip(MediaSegment s) {
    _acted();
    _engine.seek(s.end);
    _rootFocus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    _acted();
    final k = e.logicalKey;
    if (_askStillWatching) {
      if (isBackKey(k)) {
        Navigator.of(context).pop();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // its buttons handle the rest
    }
    if (_pauseInfo) {
      // Any press brings the controls back; play/select also resumes.
      if (isActivateKey(k) || k == LogicalKeyboardKey.mediaPlayPause) _engine.play();
      _showControls(focus: true);
      return KeyEventResult.handled;
    }
    if (isBackKey(k)) {
      if (_scrubTarget != null) {
        _cancelScrub();
      } else if (_panel == _Panel.tracks ||
          _panel == _Panel.quality ||
          _panel == _Panel.episodes ||
          (_panel == _Panel.controls && _app.isTv)) {
        _hideControls();
      } else {
        Navigator.of(context).pop();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPlayPause) {
      _engine.playOrPause();
      _showControls();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaRewind || k == LogicalKeyboardKey.mediaFastForward) {
      _scrub(k == LogicalKeyboardKey.mediaRewind ? -1 : 1, held: e is KeyRepeatEvent);
      return KeyEventResult.handled;
    }
    if (_panel != _Panel.none && !_rootFocus.hasPrimaryFocus) {
      _showControls();
      return KeyEventResult.ignored; // let focused buttons handle it
    }
    if (isActivateKey(k)) {
      final seg = _skippable;
      if (_scrubTarget != null) {
        _commitScrub();
      } else if (seg != null && _panel == _Panel.none && !_showUpNext) {
        _skip(seg);
      } else {
        _engine.playOrPause();
        _showControls(focus: true);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
      _scrub(k == LogicalKeyboardKey.arrowLeft ? -1 : 1, held: e is KeyRepeatEvent);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      final skip = _skippable != null && !_showUpNext;
      _showControls(focus: !skip);
      if (skip) WidgetsBinding.instance.addPostFrameCallback((_) => _skipFocus.requestFocus());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ------------------------------------------------------------------ episodes panel

  Future<void> _openEpisodes() async {
    _openPanel(_Panel.episodes);
    final sid = _item.seriesId;
    if (sid == null) return;
    _seasons ??= await _jf.seasons(sid).catchError((_) => <JfItem>[]);
    if (!mounted) return;
    setState(() {});
    await _loadSeason(_item.seasonId ?? _seasons!.firstOrNull?.id);
  }

  Future<void> _loadSeason(String? seasonId) async {
    final sid = _item.seriesId;
    if (seasonId == null || sid == null || seasonId == _panelSeasonId && _panelEpisodes != null) return;
    setState(() {
      _panelSeasonId = seasonId;
      _panelEpisodes = null;
    });
    final list = await _jf.episodes(sid, seasonId: seasonId).catchError((_) => <JfItem>[]);
    if (mounted && _panelSeasonId == seasonId) setState(() => _panelEpisodes = list);
  }

  Future<void> _playEpisode(JfItem ep) async {
    _acted();
    _hideControls();
    final resume = ep.positionTicks > 0 && !ep.played ? ticksToDuration(ep.positionTicks) : null;
    await _open(ep, resume);
  }

  @override
  void dispose() {
    _trailerWatchdog?.cancel();
    _hideTimer?.cancel();
    _countdownTimer?.cancel();
    _scrubTimer?.cancel();
    _pauseTimer?.cancel();
    _stopReporting();
    for (final s in _subs) {
      s.cancel();
    }
    _engine.dispose();
    _rootFocus.dispose();
    _playFocus.dispose();
    _skipFocus.dispose();
    _nextFocus.dispose();
    _scrubFocus.dispose();
    final app = _app;
    Future.microtask(app.bumpRevision);
    super.dispose();
  }

  // ------------------------------------------------------------------ UI

  String get _title => _item.isEpisode ? (_item.seriesName ?? _item.name) : _item.name;
  String? get _subtitle => _item.isEpisode ? '${_item.episodeLabel} · ${_item.name}' : (_item.year?.toString());

  String get _methodLabel {
    if (_isStream) return 'Trailer · streamed by your server';
    final s = _src;
    if (s == null) return '';
    final fmt = FormatInfo.fromStreams(s.streams);
    if (!s.transcoding) {
      final parts = <String>['Direct Play', ...fmt.badges.take(3)];
      if (_app.audioPassthrough) parts.add('passthrough');
      return parts.join(' · ');
    }
    return 'Transcoding · ${_quality.key == 'auto' ? 'auto' : _quality.label}';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final showUi = _panel != _Panel.none;
    final skip = _skippable;

    return PopScope(
      canPop: _panel == _Panel.none && !_pauseInfo,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _hideControls();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _rootFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: MouseRegion(
            cursor: showUi ? MouseCursor.defer : SystemMouseCursors.none,
            onHover: (_) {
              _acted();
              _showControls();
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _acted();
                if (app.isPhone) {
                  showUi ? _hideControls() : _showControls();
                } else {
                  _engine.playOrPause();
                  _showControls();
                }
              },
              onDoubleTapDown: app.isPhone
                  ? (d) =>
                        _seekBy(Duration(seconds: d.localPosition.dx < MediaQuery.sizeOf(context).width / 2 ? -10 : 10))
                  : null,
              onDoubleTap: app.isPhone ? () {} : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // The video surface must never take keyboard focus: it would swallow Esc / arrow keys.
                  ExcludeFocus(child: _engine.view()),
                  if (_isStream && _position == Duration.zero && _error == null)
                    _trailerLoading(context)
                  else if (_loading && _position == Duration.zero && _error == null)
                    _startScreen(context)
                  else if (_loading || _buffering)
                    const Center(child: CircularProgressIndicator(color: C.accent)),
                  if (_error != null) _errorView(context),
                  if (_pauseInfo) _pauseScreen(context),
                  AnimatedOpacity(
                    opacity: showUi && _panel != _Panel.episodes ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: IgnorePointer(ignoring: !showUi, child: _controls(context, app)),
                  ),
                  if (skip != null &&
                      !_showUpNext &&
                      !_pauseInfo &&
                      !_askStillWatching &&
                      (_panel == _Panel.none || _panel == _Panel.controls))
                    Positioned(
                      right: context.px(80),
                      bottom: context.px(showUi && !app.isPhone ? 290 : 110),
                      child: _SkipButton(
                        label: _skipLabels[skip.type]!,
                        focusNode: _skipFocus,
                        onTap: () => _skip(skip),
                      ),
                    ),
                  if (_showUpNext && !_askStillWatching && (_panel == _Panel.none || _panel == _Panel.controls))
                    _upNext(context),
                  if (_panel == _Panel.tracks) app.isPhone ? _tracksPanel(context) : _languagePanel(context),
                  if (_panel == _Panel.quality) _qualityPanel(context),
                  if (_panel == _Panel.episodes) _episodesPanel(context),
                  if (_askStillWatching) _stillWatchingPrompt(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// While a film or episode gets ready: its picture, dimmed, with its logo (or name) and a spinner.
  Widget _startScreen(BuildContext context) {
    final logo = _jf.logoImage(_item);
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Opacity(opacity: 0.3, child: NetImage(_jf.backdropImage(_item))),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (logo != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: context.px(150), maxWidth: context.px(560)),
                      child: NetImage(
                        logo,
                        fit: BoxFit.contain,
                        loading: const SizedBox.shrink(),
                        fallback: Text(_title, style: display(context.px(64))),
                      ),
                    )
                  else
                    Text(_title, textAlign: TextAlign.center, style: display(context.px(64))),
                  if (_item.isEpisode) ...[
                    SizedBox(height: context.px(14)),
                    Text(
                      _episodeLine,
                      style: body(context.px(24), color: C.soft, weight: FontWeight.w600),
                    ),
                  ],
                  SizedBox(height: context.px(34)),
                  SizedBox(
                    width: context.px(56),
                    height: context.px(56),
                    child: const CircularProgressIndicator(color: C.accent, strokeWidth: 4),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "S1:E3 "The Climb"" for an episode.
  String get _episodeLine => '${_item.episodeLabel.replaceAll(' : ', ':').replaceAll(' ', '')} "${_item.name}"';

  /// After a while paused: the picture dims and says what's on, with the episode's story.
  Widget _pauseScreen(BuildContext context) {
    final logo = _jf.logoImage(_item);
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xE6000000), Color(0x99000000), Color(0x66000000)],
                  stops: [0, 0.5, 1],
                ),
              ),
            ),
            Positioned(
              left: context.px(120),
              top: 0,
              bottom: 0,
              width: context.px(900),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "You're watching",
                    style: body(context.px(24), color: C.muted, weight: FontWeight.w600),
                  ),
                  SizedBox(height: context.px(16)),
                  if (logo != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: context.px(150), maxWidth: context.px(600)),
                      child: NetImage(
                        logo,
                        fit: BoxFit.contain,
                        alignment: Alignment.centerLeft,
                        loading: const SizedBox.shrink(),
                        fallback: Text(_title, style: display(context.px(72))),
                      ),
                    )
                  else
                    Text(_title, maxLines: 2, style: display(context.px(72))),
                  SizedBox(height: context.px(20)),
                  if (_item.isEpisode)
                    Text(_episodeLine, style: body(context.px(28), weight: FontWeight.w700))
                  else
                    MetaDots(
                      parts: [
                        if (_item.year != null) '${_item.year}',
                        if (_item.runtime != null) formatRuntime(_item.runtime),
                      ],
                      rating: _item.officialRating,
                      size: 24,
                    ),
                  if ((_item.overview ?? '').isNotEmpty) ...[
                    SizedBox(height: context.px(14)),
                    Text(
                      _item.overview!,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: body(context.px(24), color: C.soft, height: 1.4),
                    ),
                  ],
                ],
              ),
            ),
            Positioned(
              right: context.px(80),
              bottom: context.px(70),
              child: Text(
                'Paused',
                style: body(context.px(30), color: C.muted, weight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// After several episodes in a row with nothing pressed: check someone is still there.
  Widget _stillWatchingPrompt(BuildContext context) => Positioned.fill(
    child: Container(
      color: const Color(0xD9000000),
      alignment: Alignment.center,
      child: FocusScope(
        autofocus: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Are you still watching?', style: display(context.px(64))),
            SizedBox(height: context.px(14)),
            Text(
              _title,
              style: body(context.px(26), color: C.muted, weight: FontWeight.w600),
            ),
            SizedBox(height: context.px(40)),
            Wrap(
              spacing: context.px(16),
              children: [
                EmberButton(
                  label: 'Continue Watching',
                  icon: Icons.play_arrow_rounded,
                  kind: BtnKind.primary,
                  autofocus: true,
                  onTap: () {
                    _acted();
                    setState(() => _askStillWatching = false);
                    _rootFocus.requestFocus();
                    _playNext();
                  },
                ),
                EmberButton(label: 'Back to Browse', kind: BtnKind.ghost, onTap: () => Navigator.of(context).pop()),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  /// What a trailer shows while the server fetches it: the title's artwork, dimmed, and what's happening.
  Widget _trailerLoading(BuildContext context) => Positioned.fill(
    child: IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.backdropUrl != null) Opacity(opacity: 0.35, child: NetImage(widget.backdropUrl)),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: context.px(56),
                  height: context.px(56),
                  child: const CircularProgressIndicator(color: C.accent, strokeWidth: 4),
                ),
                SizedBox(height: context.px(22)),
                Text(_status ?? 'Getting the trailer…', style: body(context.px(26), weight: FontWeight.w600)),
                SizedBox(height: context.px(8)),
                Text('Streaming from ${_app.serverName ?? 'your server'}', style: body(context.px(20), color: C.faint)),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _errorView(BuildContext context) => Center(
    child: Container(
      padding: EdgeInsets.all(context.px(40)),
      decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(context.px(20))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text("Couldn't play this", style: display(context.px(44))),
          SizedBox(height: context.px(14)),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: context.px(800)),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: body(context.px(22), color: C.muted),
            ),
          ),
          SizedBox(height: context.px(26)),
          Wrap(
            spacing: context.px(14),
            children: [
              EmberButton(label: 'Try again', kind: BtnKind.accent, autofocus: true, onTap: () => _reopenAtCurrent()),
              if (_isStream && (widget.youtubeKey ?? '').isNotEmpty)
                EmberButton(
                  label: 'Open on YouTube',
                  kind: BtnKind.ghost,
                  onTap: () => openYouTube(context, widget.youtubeKey!),
                ),
              if (!_isStream)
                EmberButton(
                  label: 'Try at 720p',
                  kind: BtnKind.ghost,
                  onTap: () {
                    _sessionQuality = '8m';
                    _reopenAtCurrent();
                  },
                ),
              EmberButton(label: 'Close', kind: BtnKind.ghost, onTap: () => Navigator.of(context).pop()),
            ],
          ),
        ],
      ),
    ),
  );

  /// TV and desktop, laid out like the big streaming apps: everything along the bottom. The
  /// title, then the progress bar with the time left, then a row of buttons (Episodes, Next
  /// Episode, Audio & Subtitles…). The remote's select plays and pauses, left/right scrub.
  Widget _tvControls(BuildContext context, AppState app) {
    final pad = context.px(80);
    final shown = _scrubTarget ?? _position;
    final buttons = <Widget>[
      if (!app.isTv)
        _BarButton(
          icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          label: _playing ? 'Pause' : 'Play',
          focusNode: _playFocus,
          onTap: () {
            _engine.playOrPause();
            _showControls();
          },
        ),
      if (_item.isEpisode && _item.seriesId != null && !_isStream)
        _BarButton(icon: Icons.video_library_outlined, label: 'Episodes', onTap: _openEpisodes),
      if (_next != null)
        _BarButton(
          icon: Icons.skip_next_rounded,
          label: 'Next Episode',
          onTap: () {
            _acted();
            _playNext();
          },
        ),
      if (!_isStream)
        _BarButton(icon: Icons.subtitles_outlined, label: 'Audio & Subtitles', onTap: () => _openPanel(_Panel.tracks)),
      _BarButton(icon: Icons.replay_rounded, label: 'Restart', onTap: () => _engine.seek(Duration.zero)),
      if (!_isStream) _BarButton(icon: Icons.tune_rounded, label: 'Quality', onTap: () => _openPanel(_Panel.quality)),
    ];

    return FocusTraversalGroup(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x80000000), Color(0x00000000), Color(0x00000000), Color(0xF2000000)],
                stops: [0, 0.18, 0.5, 1],
              ),
            ),
          ),
          if (!app.isTv)
            Positioned(
              left: context.px(50),
              top: context.px(46),
              child: _RoundIcon(
                icon: Icons.arrow_back_rounded,
                label: 'Back',
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
          Positioned(
            left: pad,
            right: pad,
            bottom: context.px(44),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: body(context.px(32), weight: FontWeight.w800),
                ),
                if (_item.isEpisode)
                  Padding(
                    padding: EdgeInsets.only(top: context.px(4)),
                    child: Text(
                      _episodeLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: body(context.px(23), color: C.soft, weight: FontWeight.w600),
                    ),
                  ),
                if (_isStream)
                  Padding(
                    padding: EdgeInsets.only(top: context.px(6)),
                    child: Text(_methodLabel, style: body(context.px(18), color: C.faint)),
                  ),
                SizedBox(height: context.px(14)),
                Row(
                  children: [
                    Expanded(
                      child: _Scrubber(
                        position: shown,
                        duration: _duration,
                        buffered: _buffered,
                        focusNode: _scrubFocus,
                        scrubbing: _scrubTarget != null,
                        onSeek: _engine.seek,
                        onStep: (dir, held) => _scrub(dir, held: held),
                        onSelect: _selectOnBar,
                        preview: _trick == null ? null : (t) => _TrickThumb(info: _trick!, jf: _jf, at: t),
                      ),
                    ),
                    SizedBox(width: context.px(26)),
                    Text(
                      formatClock(_duration > shown ? _duration - shown : Duration.zero),
                      style: body(context.px(23), weight: FontWeight.w600),
                    ),
                  ],
                ),
                SizedBox(height: context.px(10)),
                Wrap(spacing: context.px(6), runSpacing: context.px(6), children: buttons),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The Audio & Subtitles menu: two lists side by side over the bottom of the picture, which
  /// keeps playing. Picks are remembered for the next title.
  Widget _languagePanel(BuildContext context) {
    final audio = _audioOptions();
    final subs = _subtitleOptions();
    Widget column(String title, List<_MenuOption> opts, {bool first = false}) => SizedBox(
      width: context.px(560),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.only(left: context.px(20), bottom: context.px(14)),
            child: Text(title, style: body(context.px(30), weight: FontWeight.w800)),
          ),
          if (opts.isEmpty)
            Padding(
              padding: EdgeInsets.only(left: context.px(20)),
              child: Text('None', style: body(context.px(22), color: C.faint)),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (var i = 0; i < opts.length; i++)
                  _MenuRow(
                    option: opts[i],
                    autofocus: first && (opts[i].selected || (i == 0 && !opts.any((o) => o.selected))),
                    onPicked: () {
                      _acted();
                      if (mounted) setState(() {});
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    return Positioned.fill(
      child: FocusScope(
        autofocus: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _hideControls,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x33000000), Color(0xE6000000), Color(0xF5000000)],
                stops: [0, 0.4, 1],
              ),
            ),
            padding: EdgeInsets.fromLTRB(context.px(120), context.px(100), context.px(120), context.px(70)),
            alignment: Alignment.bottomLeft,
            child: GestureDetector(
              onTap: () {},
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.62),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (audio.isNotEmpty) ...[column('Audio', audio, first: true), SizedBox(width: context.px(60))],
                    column('Subtitles', subs, first: audio.isEmpty),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Quality, in a panel at the right.
  Widget _qualityPanel(BuildContext context) {
    final opts = _qualityMenu();
    return Positioned(
      top: 0,
      bottom: 0,
      right: 0,
      width: MediaQuery.sizeOf(context).width * (context.read<AppState>().isPhone ? 0.8 : 0.36),
      child: FocusScope(
        autofocus: true,
        child: Container(
          color: const Color(0xF5000000),
          padding: EdgeInsets.fromLTRB(context.px(50), context.px(70), context.px(60), context.px(40)),
          child: ListView(
            children: [
              Padding(
                padding: EdgeInsets.only(left: context.px(20), bottom: context.px(14)),
                child: Text('Quality', style: body(context.px(30), weight: FontWeight.w800)),
              ),
              for (var i = 0; i < opts.length; i++)
                _MenuRow(
                  option: opts[i],
                  autofocus: opts[i].selected || (i == 0 && !opts.any((o) => o.selected)),
                  onPicked: () {
                    if (mounted) setState(() {});
                  },
                ),
              Padding(
                padding: EdgeInsets.fromLTRB(context.px(20), context.px(12), 0, 0),
                child: Text(
                  'Lower settings ask the server to transcode. Auto plays the original file when the connection allows.',
                  style: body(context.px(18), color: C.faint, height: 1.4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The Episodes panel: seasons down the left (moving onto one shows it), its episodes on the
  /// right with their picture, progress and story. Picking one plays it.
  Widget _episodesPanel(BuildContext context) {
    final seasons = _seasons;
    final eps = _panelEpisodes;
    return Positioned.fill(
      child: FocusScope(
        autofocus: true,
        child: Container(
          color: const Color(0xF2000000),
          padding: EdgeInsets.fromLTRB(context.px(100), context.px(70), context.px(80), 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_title, style: display(context.px(52))),
              SizedBox(height: context.px(30)),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: context.px(300),
                      child: seasons == null
                          ? const SizedBox.shrink()
                          : FocusTraversalGroup(
                              child: ListView(
                                children: [
                                  for (final se in seasons)
                                    _SeasonRow(
                                      label: se.name,
                                      selected: se.id == _panelSeasonId,
                                      onFocus: () => _loadSeason(se.id),
                                    ),
                                ],
                              ),
                            ),
                    ),
                    SizedBox(width: context.px(40)),
                    Expanded(
                      child: eps == null
                          ? const Align(
                              alignment: Alignment.topLeft,
                              child: CircularProgressIndicator(color: C.accent),
                            )
                          : FocusTraversalGroup(
                              child: ListView(
                                padding: EdgeInsets.only(bottom: context.px(60)),
                                children: [
                                  for (var i = 0; i < eps.length; i++)
                                    _EpisodeRow(
                                      episode: eps[i],
                                      image: _jf.landscapeImage(eps[i], maxWidth: 480),
                                      current: eps[i].id == _item.id,
                                      autofocus: eps[i].id == _item.id || (i == 0 && !eps.any((e) => e.id == _item.id)),
                                      onTap: () => _playEpisode(eps[i]),
                                    ),
                                ],
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls(BuildContext context, AppState app) {
    if (!app.isPhone) return _tvControls(context, app);
    final pad = context.px(app.isPhone ? 32 : 90);
    return FocusTraversalGroup(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xBF000000), Color(0x00000000), Color(0x00000000), Color(0xE6000000)],
                stops: [0, 0.22, 0.6, 1],
              ),
            ),
          ),
          Positioned(
            left: pad,
            right: pad,
            top: context.px(50),
            child: Row(
              children: [
                if (!app.isTv) ...[
                  EmberButton(
                    label: '',
                    icon: Icons.arrow_back,
                    kind: BtnKind.ghost,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  SizedBox(width: context.px(22)),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis, style: display(context.px(40))),
                      if (_subtitle != null) Text(_subtitle!, style: body(context.px(22), color: C.muted)),
                    ],
                  ),
                ),
                if (_methodLabel.isNotEmpty && !app.isPhone)
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: context.px(18), vertical: context.px(10)),
                    decoration: BoxDecoration(color: const Color(0xCC17171A), borderRadius: BorderRadius.circular(999)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: context.px(12),
                          height: context.px(12),
                          decoration: BoxDecoration(
                            color: _src?.transcoding == true ? C.warn : C.good,
                            shape: BoxShape.circle,
                          ),
                        ),
                        SizedBox(width: context.px(10)),
                        Text(
                          _methodLabel,
                          style: body(context.px(19), color: C.muted, weight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Positioned(
            left: pad,
            right: pad,
            bottom: context.px(app.isPhone ? 30 : 56),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(formatClock(_position), style: body(context.px(24), weight: FontWeight.w600)),
                    SizedBox(width: context.px(24)),
                    Expanded(
                      child: _Scrubber(
                        position: _position,
                        duration: _duration,
                        buffered: _buffered,
                        onSeek: _engine.seek,
                        preview: _trick == null ? null : (t) => _TrickThumb(info: _trick!, jf: _jf, at: t),
                      ),
                    ),
                    SizedBox(width: context.px(24)),
                    Text(
                      formatClock(_position - _duration),
                      style: body(context.px(24), color: C.muted, weight: FontWeight.w600),
                    ),
                  ],
                ),
                SizedBox(height: context.px(22)),
                Row(
                  children: [
                    EmberButton(
                      label: '',
                      icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      kind: BtnKind.ghost,
                      focusNode: _playFocus,
                      onTap: () {
                        _engine.playOrPause();
                        _showControls();
                      },
                    ),
                    SizedBox(width: context.px(12)),
                    EmberButton(
                      label: '',
                      icon: Icons.replay_10_rounded,
                      kind: BtnKind.ghost,
                      onTap: () => _seekBy(const Duration(seconds: -10)),
                    ),
                    SizedBox(width: context.px(12)),
                    EmberButton(
                      label: '',
                      icon: Icons.forward_10_rounded,
                      kind: BtnKind.ghost,
                      onTap: () => _seekBy(const Duration(seconds: 10)),
                    ),
                    const Spacer(),
                    EmberButton(
                      label: app.isPhone ? '' : 'Audio & Subtitles',
                      icon: Icons.subtitles_outlined,
                      kind: BtnKind.ghost,
                      onTap: () {
                        _hideTimer?.cancel();
                        setState(() => _panel = _Panel.tracks);
                      },
                    ),
                    SizedBox(width: context.px(12)),
                    EmberButton(
                      label: app.isPhone ? '' : 'Quality',
                      icon: Icons.settings,
                      kind: BtnKind.ghost,
                      onTap: () {
                        _hideTimer?.cancel();
                        setState(() => _panel = _Panel.tracks);
                      },
                    ),
                    if (_next != null) ...[
                      SizedBox(width: context.px(12)),
                      EmberButton(
                        label: app.isPhone ? '' : 'Next Episode',
                        icon: Icons.skip_next_rounded,
                        kind: BtnKind.ghost,
                        onTap: _playNext,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Near the end of an episode: Watch Credits, and Next Episode filling up as it counts down.
  Widget _upNext(BuildContext context) {
    final n = _next!;
    final counting = _countdown != null;
    return Positioned(
      right: context.px(80),
      bottom: context.px(_panel == _Panel.controls && !context.read<AppState>().isPhone ? 290 : 110),
      child: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Next: ${n.episodeLabel.replaceAll(' : ', ':').replaceAll(' ', '')} "${n.name}"',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: body(context.px(21), color: C.soft, weight: FontWeight.w600),
            ),
            SizedBox(height: context.px(14)),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SkipButton(
                  label: 'Watch Credits',
                  onTap: () {
                    _acted();
                    _countdownTimer?.cancel();
                    setState(() {
                      _upNextDismissed = true;
                      _countdown = null;
                    });
                    _rootFocus.requestFocus();
                  },
                ),
                SizedBox(width: context.px(14)),
                _NextEpisodeButton(
                  key: ValueKey('next-${n.id}-$counting'),
                  focusNode: _nextFocus,
                  countdown: counting ? const Duration(seconds: _countdownSeconds) : null,
                  onTap: () {
                    _acted();
                    _playNext();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _tracksPanel(BuildContext context) {
    final app = context.read<AppState>();
    Widget column(String title, List<_MenuOption> opts, {String? note}) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: body(context.px(22), color: C.faint, weight: FontWeight.w700).copyWith(letterSpacing: 3),
          ),
          SizedBox(height: context.px(14)),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                if (opts.isEmpty) Text('None', style: body(context.px(22), color: C.faint)),
                for (var i = 0; i < opts.length; i++)
                  Focusable(
                    autofocus: title == 'AUDIO' && (opts[i].selected || (i == 0 && !opts.any((o) => o.selected))),
                    onTap: () async {
                      await opts[i].onPick();
                      if (mounted) setState(() {});
                    },
                    semanticLabel: opts[i].label,
                    builder: (context, active) => Container(
                      margin: EdgeInsets.only(bottom: context.px(6)),
                      padding: EdgeInsets.symmetric(horizontal: context.px(16), vertical: context.px(14)),
                      decoration: BoxDecoration(
                        color: active ? C.text : Colors.transparent,
                        borderRadius: BorderRadius.circular(context.px(12)),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: context.px(40),
                            child: opts[i].selected
                                ? Icon(
                                    Icons.check,
                                    color: active ? const Color(0xFF111111) : C.accent,
                                    size: context.px(28),
                                  )
                                : null,
                          ),
                          Expanded(
                            child: Text(
                              opts[i].label,
                              style: body(
                                context.px(23),
                                weight: FontWeight.w600,
                                color: active ? const Color(0xFF111111) : C.soft,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (note != null) ...[
            SizedBox(height: context.px(10)),
            Text(note, style: body(context.px(19), color: C.faint)),
          ],
        ],
      ),
    );

    final cols = [
      column('AUDIO', _audioOptions()),
      SizedBox(width: context.px(48), height: context.px(30)),
      column('SUBTITLES', _subtitleOptions()),
      SizedBox(width: context.px(48), height: context.px(30)),
      column('QUALITY', _qualityMenu(), note: 'Lower settings ask the server to transcode.'),
    ];

    return Positioned(
      left: context.px(app.isPhone ? 20 : 90),
      right: context.px(app.isPhone ? 20 : 90),
      bottom: context.px(app.isPhone ? 20 : 60),
      top: context.px(app.isPhone ? 80 : 300),
      child: FocusScope(
        autofocus: true,
        child: Container(
          padding: EdgeInsets.all(context.px(44)),
          decoration: BoxDecoration(
            color: const Color(0xF5121214),
            borderRadius: BorderRadius.circular(context.px(24)),
          ),
          child: Column(
            children: [
              Expanded(
                child: app.isPhone
                    ? Column(children: cols)
                    : Row(crossAxisAlignment: CrossAxisAlignment.start, children: cols),
              ),
              SizedBox(height: context.px(20)),
              Align(
                alignment: Alignment.centerLeft,
                child: EmberButton(
                  label: 'Back to video',
                  icon: Icons.arrow_back,
                  kind: BtnKind.ghost,
                  onTap: () => _hideControls(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A round icon button for the top of the player; its name shows underneath while it has focus.
class _RoundIcon extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _RoundIcon({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => Focusable(
    onTap: onTap,
    semanticLabel: label,
    scrollIntoView: false,
    builder: (context, active) => SizedBox(
      width: context.px(100),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: context.px(56),
            height: context.px(56),
            decoration: BoxDecoration(color: active ? C.text : Colors.transparent, shape: BoxShape.circle),
            child: Icon(icon, size: context.px(32), color: active ? const Color(0xFF111111) : C.text),
          ),
          SizedBox(height: context.px(8)),
          Opacity(
            opacity: active ? 1 : 0,
            child: Text(
              label.toUpperCase(),
              textAlign: TextAlign.center,
              style: body(context.px(15), weight: FontWeight.w700).copyWith(letterSpacing: 1),
            ),
          ),
        ],
      ),
    ),
  );
}

/// A button in the row under the progress bar: an icon and a word, white when focused.
class _BarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  const _BarButton({required this.icon, required this.label, required this.onTap, this.focusNode});

  @override
  Widget build(BuildContext context) => Focusable(
    onTap: onTap,
    focusNode: focusNode,
    semanticLabel: label,
    scrollIntoView: false,
    builder: (context, active) {
      final fg = active ? const Color(0xFF111111) : C.text;
      return AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: context.px(52),
        padding: EdgeInsets.symmetric(horizontal: context.px(18)),
        decoration: BoxDecoration(
          color: active ? C.text : Colors.transparent,
          borderRadius: BorderRadius.circular(context.px(8)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: context.px(28), color: fg),
            SizedBox(width: context.px(10)),
            Text(
              label,
              style: body(context.px(21), weight: FontWeight.w700, color: fg),
            ),
          ],
        ),
      );
    },
  );
}

/// Skip Intro / Skip Recap / Watch Credits: an outlined box at the bottom right.
class _SkipButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  const _SkipButton({required this.label, required this.onTap, this.focusNode});

  @override
  Widget build(BuildContext context) => Focusable(
    onTap: onTap,
    focusNode: focusNode,
    semanticLabel: label,
    scrollIntoView: false,
    builder: (context, active) => AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      height: context.px(60),
      padding: EdgeInsets.symmetric(horizontal: context.px(28)),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active ? C.text : const Color(0x99000000),
        borderRadius: BorderRadius.circular(context.px(6)),
        border: Border.all(color: active ? C.text : const Color(0xCCFFFFFF), width: context.px(2)),
      ),
      child: Text(
        label,
        style: body(context.px(23), weight: FontWeight.w700, color: active ? const Color(0xFF111111) : C.text),
      ),
    ),
  );
}

/// Next Episode: a light button whose white fill grows while it counts down ([countdown]).
class _NextEpisodeButton extends StatelessWidget {
  final FocusNode? focusNode;
  final Duration? countdown;
  final VoidCallback onTap;
  const _NextEpisodeButton({super.key, required this.onTap, this.focusNode, this.countdown});

  @override
  Widget build(BuildContext context) => Focusable(
    onTap: onTap,
    focusNode: focusNode,
    semanticLabel: 'Next Episode',
    scrollIntoView: false,
    builder: (context, active) => Container(
      height: context.px(60),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(context.px(6)),
        border: Border.all(color: active ? C.text : Colors.transparent, width: context.px(2)),
        boxShadow: active ? [BoxShadow(color: const Color(0x55FFFFFF), blurRadius: context.px(14))] : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(context.px(5)),
        child: Stack(
          children: [
            Positioned.fill(child: Container(color: const Color(0xFF9A9A9A))),
            Positioned.fill(
              child: countdown == null
                  ? Container(color: C.text)
                  : TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: countdown!,
                      builder: (context, v, _) => FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: v,
                        child: Container(color: C.text),
                      ),
                    ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.px(26)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.play_arrow_rounded, size: context.px(32), color: const Color(0xFF111111)),
                  SizedBox(width: context.px(8)),
                  Text(
                    'Next Episode',
                    style: body(context.px(23), weight: FontWeight.w800, color: const Color(0xFF111111)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// One choice in the Audio & Subtitles or Quality lists, with a tick when it's the current one.
class _MenuRow extends StatelessWidget {
  final _MenuOption option;
  final bool autofocus;
  final VoidCallback onPicked;
  const _MenuRow({required this.option, required this.onPicked, this.autofocus = false});

  @override
  Widget build(BuildContext context) => Focusable(
    autofocus: autofocus,
    semanticLabel: option.label,
    onTap: () async {
      await option.onPick();
      onPicked();
    },
    builder: (context, active) => AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      margin: EdgeInsets.only(bottom: context.px(4)),
      padding: EdgeInsets.symmetric(horizontal: context.px(20), vertical: context.px(11)),
      decoration: BoxDecoration(
        color: active ? C.text : Colors.transparent,
        borderRadius: BorderRadius.circular(context.px(8)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: context.px(40),
            child: option.selected
                ? Icon(Icons.check_rounded, size: context.px(28), color: active ? const Color(0xFF111111) : C.text)
                : null,
          ),
          Expanded(
            child: Text(
              option.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: body(
                context.px(24),
                weight: option.selected || active ? FontWeight.w700 : FontWeight.w500,
                color: active ? const Color(0xFF111111) : (option.selected ? C.text : C.muted),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// A season in the Episodes panel; moving onto it shows its episodes.
class _SeasonRow extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onFocus;
  const _SeasonRow({required this.label, required this.selected, required this.onFocus});

  @override
  Widget build(BuildContext context) => Focusable(
    semanticLabel: label,
    onTap: onFocus,
    onFocusChange: (f) {
      if (f) onFocus();
    },
    builder: (context, active) => AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      margin: EdgeInsets.only(bottom: context.px(4)),
      padding: EdgeInsets.symmetric(horizontal: context.px(20), vertical: context.px(12)),
      decoration: BoxDecoration(
        color: active ? C.text : Colors.transparent,
        borderRadius: BorderRadius.circular(context.px(8)),
      ),
      child: Text(
        label,
        style: body(
          context.px(24),
          weight: selected || active ? FontWeight.w800 : FontWeight.w500,
          color: active ? const Color(0xFF111111) : (selected ? C.text : C.muted),
        ),
      ),
    ),
  );
}

/// An episode in the Episodes panel: its picture (with progress), number, name, length and story.
class _EpisodeRow extends StatelessWidget {
  final JfItem episode;
  final String? image;
  final bool current;
  final bool autofocus;
  final VoidCallback onTap;
  const _EpisodeRow({
    required this.episode,
    required this.image,
    required this.current,
    required this.autofocus,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final e = episode;
    final r = BorderRadius.circular(context.px(8));
    return Focusable(
      autofocus: autofocus,
      semanticLabel: e.name,
      onTap: onTap,
      builder: (context, active) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: EdgeInsets.only(bottom: context.px(10)),
        padding: EdgeInsets.all(context.px(12)),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF2A2A2F) : Colors.transparent,
          borderRadius: BorderRadius.circular(context.px(12)),
          border: Border.all(color: active ? C.text : Colors.transparent, width: context.px(2)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: context.px(280),
              child: ClipRRect(
                borderRadius: r,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      NetImage(image, fallback: TitleCard(e.name, label: false)),
                      if (e.progress != null && !e.played)
                        Align(
                          alignment: Alignment.bottomLeft,
                          child: FractionallySizedBox(
                            widthFactor: e.progress!.clamp(0.03, 1.0),
                            child: Container(height: context.px(5), color: C.accent),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(width: context.px(24)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${e.indexNumber ?? ''}${e.indexNumber == null ? '' : '. '}${e.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: body(context.px(25), weight: FontWeight.w700),
                        ),
                      ),
                      if (current)
                        Text(
                          'Now playing',
                          style: body(context.px(19), color: C.accent, weight: FontWeight.w700),
                        )
                      else if (e.runtime != null)
                        Text(
                          formatRuntime(e.runtime),
                          style: body(context.px(20), color: C.muted, weight: FontWeight.w600),
                        ),
                    ],
                  ),
                  if ((e.overview ?? '').isNotEmpty) ...[
                    SizedBox(height: context.px(8)),
                    Text(
                      e.overview!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: body(context.px(20), color: C.soft, height: 1.35),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The progress bar. Click or drag with a mouse or finger; with a remote, focus it and press left/right.
class _Scrubber extends StatefulWidget {
  final Duration position, duration, buffered;
  final ValueChanged<Duration> onSeek;

  /// Left/right with the remote (-1 or 1, and whether the button is held), when the player
  /// scrubs before it jumps; without it, each press jumps 10 seconds.
  final void Function(int direction, bool held)? onStep;

  /// Select with the remote while the bar has focus.
  final VoidCallback? onSelect;
  final FocusNode? focusNode;

  /// A scrub point is being chosen: the picture there shows above the bar.
  final bool scrubbing;

  /// Builds the thumbnail shown above the bar for a time (trickplay), if available.
  final Widget Function(Duration at)? preview;
  const _Scrubber({
    required this.position,
    required this.duration,
    required this.buffered,
    required this.onSeek,
    this.preview,
    this.onStep,
    this.onSelect,
    this.focusNode,
    this.scrubbing = false,
  });
  @override
  State<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<_Scrubber> {
  double? _drag;
  double? _hover;
  bool _focused = false;

  double _frac(Duration d) =>
      widget.duration.inMilliseconds == 0 ? 0 : (d.inMilliseconds / widget.duration.inMilliseconds).clamp(0.0, 1.0);

  void _seekFrac(double f) =>
      widget.onSeek(Duration(milliseconds: (widget.duration.inMilliseconds * f.clamp(0.0, 1.0)).round()));

  @override
  Widget build(BuildContext context) {
    final f = _drag ?? _frac(widget.position);
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (node, e) {
        if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
        final k = e.logicalKey;
        if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
          final dir = k == LogicalKeyboardKey.arrowLeft ? -1 : 1;
          if (widget.onStep != null) {
            widget.onStep!(dir, e is KeyRepeatEvent);
          } else {
            widget.onSeek(widget.position + const Duration(seconds: 10) * dir);
          }
          return KeyEventResult.handled;
        }
        if (widget.onSelect != null && isActivateKey(k)) {
          widget.onSelect!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final h = context.px(_focused ? 14 : 10);
          final previewFrac = _drag ?? _hover ?? (_focused || widget.scrubbing ? f : null);
          final thumbW = context.px(240);
          return MouseRegion(
            onHover: (e) => setState(() => _hover = (e.localPosition.dx / w).clamp(0.0, 1.0)),
            onExit: (_) => setState(() => _hover = null),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _seekFrac(d.localPosition.dx / w),
              onHorizontalDragUpdate: (d) => setState(() => _drag = (d.localPosition.dx / w).clamp(0.0, 1.0)),
              onHorizontalDragEnd: (_) {
                if (_drag != null) _seekFrac(_drag!);
                setState(() => _drag = null);
              },
              child: SizedBox(
                height: context.px(40),
                child: Stack(
                  alignment: Alignment.centerLeft,
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      height: h,
                      decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(h)),
                    ),
                    Container(
                      width: w * _frac(widget.buffered),
                      height: h,
                      decoration: BoxDecoration(color: Colors.white38, borderRadius: BorderRadius.circular(h)),
                    ),
                    Container(
                      width: w * f,
                      height: h,
                      decoration: BoxDecoration(color: C.accent, borderRadius: BorderRadius.circular(h)),
                    ),
                    Positioned(
                      left: w * f - context.px(15),
                      child: Container(
                        width: context.px(30),
                        height: context.px(30),
                        decoration: BoxDecoration(
                          color: C.accent,
                          shape: BoxShape.circle,
                          border: Border.all(color: _focused ? C.text : Colors.transparent, width: context.px(4)),
                        ),
                      ),
                    ),
                    if (widget.preview != null && previewFrac != null && widget.duration > Duration.zero)
                      Positioned(
                        left: (w * previewFrac - thumbW / 2).clamp(0.0, w - thumbW),
                        bottom: context.px(44),
                        child: IgnorePointer(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: thumbW,
                                decoration: BoxDecoration(
                                  border: Border.all(color: C.text, width: context.px(3)),
                                  borderRadius: BorderRadius.circular(context.px(10)),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(context.px(8)),
                                  child: AspectRatio(
                                    aspectRatio: 16 / 9,
                                    child: widget.preview!(
                                      Duration(milliseconds: (widget.duration.inMilliseconds * previewFrac).round()),
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(height: context.px(6)),
                              Text(
                                formatClock(
                                  Duration(milliseconds: (widget.duration.inMilliseconds * previewFrac).round()),
                                ),
                                style: body(context.px(22), weight: FontWeight.w700),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One frame from Jellyfin's trickplay sheets, for the scrubber preview.
class _TrickThumb extends StatelessWidget {
  final TrickplayInfo info;
  final JellyfinClient jf;
  final Duration at;
  const _TrickThumb({required this.info, required this.jf, required this.at});

  @override
  Widget build(BuildContext context) {
    final n = (at.inMilliseconds ~/ max(info.interval.inMilliseconds, 1)).clamp(0, max(info.count - 1, 0));
    final sheet = n ~/ info.perSheet;
    final within = n % info.perSheet;
    final col = within % info.tileWidth;
    final row = within ~/ info.tileWidth;
    return LayoutBuilder(
      builder: (context, c) {
        final tw = c.maxWidth, th = c.maxHeight;
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: tw * info.tileWidth,
            maxWidth: tw * info.tileWidth,
            minHeight: th * info.tileHeight,
            maxHeight: th * info.tileHeight,
            child: Transform.translate(
              offset: Offset(-col * tw, -row * th),
              child: Image.network(
                jf.trickplaySheetUrl(info, sheet),
                width: tw * info.tileWidth,
                height: th * info.tileHeight,
                fit: BoxFit.fill,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => Container(color: C.surface2),
              ),
            ),
          ),
        );
      },
    );
  }
}
