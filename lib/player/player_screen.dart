import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import '../api/jellyfin.dart';
import '../platform.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import '../screens/nav.dart' show openYouTube;
import '../ui/widgets.dart';
import 'engine.dart';

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

  /// Finds the trailer's stream address after the player is already on screen, so the Trailer
  /// button responds at once. Throws with a readable reason when there's nothing to play.
  final Future<String> Function()? resolveUrl;

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
    this.resolveUrl,
    this.youtubeKey,
    this.backdropUrl,
  });
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

enum _Panel { none, controls, tracks }

class _MenuOption {
  final String label;
  final bool selected;
  final Future<void> Function() onPick;
  _MenuOption(this.label, this.selected, this.onPick);
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final PlaybackEngine _engine = PlaybackEngine(title: 'Ember');

  /// The mpv player, when that's what is playing (everywhere but Apple TV).
  Player? get _mpv => switch (_engine) { MpvEngine e => e.player, _ => null };
  late JellyfinClient _jf;
  late AppState _app;

  late JfItem _item = widget.item;
  PlaybackSource? _src;
  String? _sessionQuality; // overrides the saved quality for this session
  String? _error;
  Timer? _trailerWatchdog;
  String? _status;

  bool get _isStream => widget.directUrl != null || widget.resolveUrl != null;

  static String _clean(Object e) {
    var m = '$e'.replaceAll(RegExp(r'(api_key|ApiKey)=[^&\s]+'), r'$1=…');
    if (m.contains('Failed to open')) m = 'Your server couldn\'t start the trailer stream.';
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

  bool _playing = false;
  bool _buffering = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  Tracks _tracks = const Tracks();
  Track _track = const Track();

  List<MediaSegment> _segments = [];
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
  bool _subBurnedIn = false;
  bool _serverDefaultsDone = false;
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _jf = _app.jf!;
    _configureMpv();
    final mpv = _mpv;
    _subs.addAll([
      _engine.playing.listen((v) => setState(() => _playing = v)),
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
        if (_loading || (_isStream && _position == Duration.zero)) {
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
      _audioIndex = null;
      _subIndex = null;
      _subBurnedIn = false;
      _serverDefaultsDone = false;
    }
    _audioIndex = audioStreamIndex ?? _audioIndex;
    // -1 turns burned-in subtitles off again.
    if (subtitleStreamIndex != null) {
      _subIndex = subtitleStreamIndex >= 0 ? subtitleStreamIndex : null;
      _subBurnedIn = _subIndex != null;
    }
    final burnIn = _subBurnedIn ? _subIndex : null;
    setState(() {
      _item = item;
      _loading = true;
      _error = null;
      _defaultsApplied = false;
      _upNextDismissed = false;
      _countdown = null;
      _introSkippedAuto = false;
      _segments = [];
      _next = null;
    });
    if (_isStream) {
      try {
        var url = widget.directUrl;
        if (url == null) {
          setState(() => _status = 'Finding the official trailer…');
          url = await widget.resolveUrl!();
          if (!mounted) return;
        }
        setState(() => _status = 'Starting the trailer…');
        await _engine.open(url);
        setState(() => _loading = false);
        _showControls();
        // A trailer that hasn't started after 45 s isn't going to: say so instead of spinning forever.
        _trailerWatchdog?.cancel();
        _trailerWatchdog = Timer(const Duration(seconds: 45), () {
          if (mounted && _position == Duration.zero && _error == null) {
            setState(() => _error = 'Your server didn\'t start sending the trailer. '
                'An admin can run Settings › Trailers & calendar › Test trailer playback to see why.');
          }
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = _clean(e);
        });
      }
      return;
    }
    try {
      final q = _quality;
      int? bitrate = q.bitrate;
      var src = await _jf.playbackSource(item.id,
          maxBitrate: bitrate, audioStreamIndex: _audioIndex, subtitleStreamIndex: burnIn);

      // Auto quality: test the connection, and if it can't carry the original file
      // comfortably, ask the server for a lower bitrate instead of buffering.
      if (q.key == 'auto' && src.bitrate != null) {
        final bps = await _jf.measureBitrate();
        if (bps != null && bps < src.bitrate! * 1.1) {
          final target = (bps * 0.8).round();
          bitrate = qualityOptions
              .where((o) => o.bitrate != null && o.bitrate! <= target)
              .map((o) => o.bitrate!)
              .fold<int>(2000000, (a, b) => b > a ? b : a);
          src = await _jf.playbackSource(item.id,
              maxBitrate: bitrate, audioStreamIndex: _audioIndex, subtitleStreamIndex: burnIn);
        }
      }
      _src = src;
      await _engine.open(src.url, start: start);
      // Text subtitles picked before a reopen (quality change, new audio track) come back on.
      if (_serverTracks && _subIndex != null && !_subBurnedIn) unawaited(_showServerSubtitle(_subIndex!));
      if (isAppleTv && !_serverDefaultsDone) _applyServerDefaults(start);
      if (!widget.isTrailer) {
        unawaited(_jf.reportStart(item.id, src.mediaSourceId, src.playSessionId, start ?? Duration.zero, src.transcoding));
        _reportTimer = Timer.periodic(const Duration(seconds: 10), (_) {
          final s = _src;
          if (s != null) _jf.reportProgress(_item.id, s.mediaSourceId, s.playSessionId, _position, !_playing, s.transcoding);
        });
        _jf.mediaSegments(item.id).then((s) => mounted ? setState(() => _segments = s) : null);
        _jf.item(item.id).then((full) {
          if (mounted) setState(() => _trick = TrickplayInfo.fromItem(full));
        }).catchError((_) {});
        if (item.isEpisode) _jf.nextEpisode(item).then((n) => mounted ? setState(() => _next = n) : null).catchError((_) => null);
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

  bool _langMatch(String? a, String? b) {
    if (a == null || b == null) return false;
    a = a.toLowerCase();
    b = b.toLowerCase();
    return a == b || a.startsWith(b.substring(0, 2)) || b.startsWith(a.substring(0, 2));
  }

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
      await _engine.setTextSubtitles(_jf.subtitleUrl(_item.id, src.mediaSourceId, s.first, format: isAppleTv ? 'vtt' : null));
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  /// Apple TV: the person's preferred audio language and subtitle setting, picked from the
  /// server's list of streams once the title opens.
  void _applyServerDefaults(Duration? start) {
    _serverDefaultsDone = true;
    final pref = _app.preferredAudioLanguage;
    final audio = _streamsOf('Audio');
    if (audio.isEmpty) return;
    var chosen = audio.firstWhere((s) => (s['Index'] as num?)?.toInt() == _defaultIndexOf('Audio'), orElse: () => audio.first);
    if (pref != null) {
      for (final s in audio) {
        if (_langMatch(s['Language'] as String?, pref)) {
          chosen = s;
          break;
        }
      }
    }
    final subLang = pref ?? 'eng';
    final audioLang = chosen['Language'] as String?;
    final wantSubs = switch (_app.subtitleMode) {
      'off' => false,
      'always' => true,
      _ => audioLang != null && !_langMatch(audioLang, subLang),
    };
    final subs = wantSubs ? _streamsOf('Subtitle').where((s) => _langMatch(s['Language'] as String?, subLang)).toList() : const [];
    final sub = subs.isEmpty ? null : subs.first;

    final chosenIndex = (chosen['Index'] as num?)?.toInt();
    final needsAudio = chosenIndex != null && chosenIndex != _defaultIndexOf('Audio');
    final needsBurn = sub != null && sub['IsTextSubtitleStream'] != true;
    if (needsAudio || needsBurn) {
      _open(_item, start,
          audioStreamIndex: needsAudio ? chosenIndex : null,
          subtitleStreamIndex: needsBurn ? (sub['Index'] as num).toInt() : null);
    } else if (sub != null) {
      _showServerSubtitle((sub['Index'] as num).toInt());
    }
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
        if (_langMatch(t.language, pref)) {
          chosenAudio = t;
          break;
        }
      }
      if (chosenAudio != null) player.setAudioTrack(chosenAudio);
    }
    final subs = _tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();
    final audioLang = (chosenAudio ?? audio.first).language;
    final subLang = pref ?? 'eng';
    switch (_app.subtitleMode) {
      case 'off':
        player.setSubtitleTrack(SubtitleTrack.no());
        break;
      case 'always':
        final s = subs.where((t) => _langMatch(t.language, subLang)).toList();
        if (s.isNotEmpty) player.setSubtitleTrack(s.first);
        break;
      default: // only when the audio isn't in the person's language
        if (audioLang != null && !_langMatch(audioLang, subLang)) {
          final s = subs.where((t) => _langMatch(t.language, subLang)).toList();
          if (s.isNotEmpty) player.setSubtitleTrack(s.first);
        } else {
          player.setSubtitleTrack(SubtitleTrack.no());
        }
    }
  }

  String _describeAudio(AudioTrack t) {
    final parts = <String>[
      if (t.title != null && t.title!.isNotEmpty) t.title! else if (t.language != null) _langName(t.language!) else 'Track ${t.id}',
      if (t.title != null && t.language != null && !t.title!.toLowerCase().contains(_langName(t.language!).toLowerCase()))
        _langName(t.language!),
      if (t.codec != null) t.codec!.toUpperCase(),
      if (t.channelscount != null) t.channelscount! > 2 ? '${t.channelscount! - 1}.1' : (t.channelscount == 2 ? 'Stereo' : 'Mono'),
    ];
    return parts.join(' · ');
  }

  String _describeSub(SubtitleTrack t) {
    final name = (t.title != null && t.title!.isNotEmpty) ? t.title! : (t.language != null ? _langName(t.language!) : 'Track ${t.id}');
    final extra = t.language != null && t.title != null && t.title!.isNotEmpty ? ' · ${_langName(t.language!)}' : '';
    return '$name$extra';
  }

  static const _langs = {
    'eng': 'English', 'en': 'English', 'afr': 'Afrikaans', 'af': 'Afrikaans', 'fre': 'French', 'fra': 'French', 'fr': 'French',
    'spa': 'Spanish', 'es': 'Spanish', 'ger': 'German', 'deu': 'German', 'de': 'German', 'ita': 'Italian', 'it': 'Italian',
    'por': 'Portuguese', 'pt': 'Portuguese', 'jpn': 'Japanese', 'ja': 'Japanese', 'kor': 'Korean', 'ko': 'Korean',
    'chi': 'Chinese', 'zho': 'Chinese', 'zh': 'Chinese', 'rus': 'Russian', 'ru': 'Russian', 'hin': 'Hindi', 'hi': 'Hindi',
    'zul': 'Zulu', 'zu': 'Zulu', 'xho': 'Xhosa', 'xh': 'Xhosa', 'dut': 'Dutch', 'nld': 'Dutch', 'nl': 'Dutch', 'ara': 'Arabic',
  };
  static String _langName(String code) => _langs[code.toLowerCase()] ?? code.toUpperCase();

  List<_MenuOption> _audioOptions() {
    final src = _src;
    if (src == null) return [];
    final player = _mpv;
    if (!_serverTracks && player != null) {
      return [
        for (final t in _tracks.audio.where((t) => t.id != 'auto' && t.id != 'no'))
          _MenuOption(_describeAudio(t), _track.audio.id == t.id, () => player.setAudioTrack(t)),
      ];
    }
    final current = _audioIndex ?? _defaultIndexOf('Audio');
    return [
      for (final s in _streamsOf('Audio'))
        _MenuOption(s['DisplayTitle'] as String? ?? 'Audio ${s['Index']}', (s['Index'] as num?)?.toInt() == current,
            () => _reopenAtCurrent(audioStreamIndex: (s['Index'] as num).toInt())),
    ];
  }

  List<_MenuOption> _subtitleOptions() {
    final src = _src;
    if (src == null) return [];
    final player = _mpv;
    final external = src.streams.where((s) => s['Type'] == 'Subtitle' && s['IsExternal'] == true).toList();
    if (!_serverTracks && player != null) {
      final off = _MenuOption('Off', _track.subtitle.id == 'no' || _track.subtitle.id == 'auto', () => player.setSubtitleTrack(SubtitleTrack.no()));
      return [
        off,
        for (final t in _tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no' && !t.uri))
          _MenuOption(_describeSub(t), _track.subtitle.id == t.id, () => player.setSubtitleTrack(t)),
        for (final s in external)
          _MenuOption('${s['DisplayTitle'] ?? 'Subtitle'} · external', _track.subtitle.title == s['DisplayTitle'],
              () => player.setSubtitleTrack(SubtitleTrack.uri(_jf.subtitleUrl(_item.id, src.mediaSourceId, s),
                  title: s['DisplayTitle'] as String?, language: s['Language'] as String?))),
      ];
    }
    return [
      _MenuOption('Off', _subIndex == null, () async {
        if (_subBurnedIn) {
          await _reopenAtCurrent(subtitleStreamIndex: -1);
        } else {
          setState(() => _subIndex = null);
          await _engine.setTextSubtitles(null);
        }
      }),
      for (final s in _streamsOf('Subtitle'))
        _MenuOption(
          '${s['DisplayTitle'] ?? 'Subtitle'}${s['IsTextSubtitleStream'] == true ? '' : ' · burned in'}',
          _subIndex == (s['Index'] as num?)?.toInt(),
          () async {
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
    if (_showUpNext && _countdown == null && _app.autoplayNext && !_upNextDismissed) {
      _startCountdown();
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
    if (_next != null && _app.autoplayNext) {
      _playNext();
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

  bool get _showUpNext {
    if (_next == null || _upNextDismissed || _duration == Duration.zero) return false;
    final outro = _segments.where((s) => s.type == 'Outro').toList();
    if (outro.isNotEmpty) return _position >= outro.first.start;
    return _duration - _position <= const Duration(seconds: 25);
  }

  void _startCountdown() {
    setState(() => _countdown = 8);
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _upNextDismissed) {
        t.cancel();
        return;
      }
      if (_countdown! <= 1) {
        t.cancel();
        _playNext();
      } else {
        setState(() => _countdown = _countdown! - 1);
      }
    });
    if (_app.isTv) WidgetsBinding.instance.addPostFrameCallback((_) => _nextFocus.requestFocus());
  }

  Future<void> _playNext() async {
    _countdownTimer?.cancel();
    final n = _next;
    if (n == null) return;
    await _open(n, null);
  }

  // ------------------------------------------------------------------ controls

  void _showControls({bool focusPlay = false}) {
    _hideTimer?.cancel();
    if (_panel == _Panel.none) setState(() => _panel = _Panel.controls);
    if (focusPlay) WidgetsBinding.instance.addPostFrameCallback((_) => _playFocus.requestFocus());
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _panel == _Panel.controls && _playing) {
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

  void _seekBy(Duration d) {
    var t = _position + d;
    if (t < Duration.zero) t = Duration.zero;
    if (_duration > Duration.zero && t > _duration) t = _duration - const Duration(seconds: 1);
    _engine.seek(t);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (isBackKey(k)) {
      if (_panel == _Panel.tracks || (_panel == _Panel.controls && _app.isTv)) {
        _hideControls();
      } else {
        Navigator.of(context).pop();
      }
      return KeyEventResult.handled;
    }
    if (_panel != _Panel.none) {
      _showControls();
      return KeyEventResult.ignored; // let focused buttons handle it
    }
    if (isActivateKey(k) || k == LogicalKeyboardKey.mediaPlayPause) {
      _engine.playOrPause();
      _showControls(focusPlay: true);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.mediaRewind) {
      _seekBy(const Duration(seconds: -10));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.mediaFastForward) {
      _seekBy(const Duration(seconds: 10));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      final skip = _activeSegment('Intro') != null;
      _showControls(focusPlay: !skip);
      if (skip) WidgetsBinding.instance.addPostFrameCallback((_) => _skipFocus.requestFocus());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _trailerWatchdog?.cancel();
    _hideTimer?.cancel();
    _countdownTimer?.cancel();
    _stopReporting();
    for (final s in _subs) {
      s.cancel();
    }
    _engine.dispose();
    _rootFocus.dispose();
    _playFocus.dispose();
    _skipFocus.dispose();
    _nextFocus.dispose();
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
    final intro = _activeSegment('Intro');

    return PopScope(
      canPop: _panel == _Panel.none,
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
            onHover: (_) => _showControls(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (app.isPhone) {
                  showUi ? _hideControls() : _showControls();
                } else {
                  _engine.playOrPause();
                  _showControls();
                }
              },
              onDoubleTapDown: app.isPhone
                  ? (d) => _seekBy(Duration(seconds: d.localPosition.dx < MediaQuery.sizeOf(context).width / 2 ? -10 : 10))
                  : null,
              onDoubleTap: app.isPhone ? () {} : null,
              child: Stack(fit: StackFit.expand, children: [
                // The video surface must never take keyboard focus: it would swallow Esc / arrow keys.
                ExcludeFocus(child: _engine.view()),
                if (_isStream && _position == Duration.zero && _error == null) _trailerLoading(context)
                else if (_loading || _buffering) const Center(child: CircularProgressIndicator(color: C.accent)),
                if (_error != null) _errorView(context),
                AnimatedOpacity(
                  opacity: showUi ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(ignoring: !showUi, child: _controls(context, app)),
                ),
                if (intro != null && !_showUpNext)
                  Positioned(
                    right: context.px(90),
                    bottom: context.px(showUi ? 260 : 120),
                    child: EmberButton(
                      label: 'Skip Intro',
                      icon: Icons.fast_forward_rounded,
                      kind: BtnKind.ghost,
                      focusNode: _skipFocus,
                      onTap: () => _engine.seek(intro.end),
                    ),
                  ),
                if (_showUpNext) _upNext(context),
                if (_panel == _Panel.tracks) app.isPhone ? _tracksPanel(context) : _sidePanel(context),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  /// What a trailer shows while the server fetches it: the title's artwork, dimmed, and what's happening.
  Widget _trailerLoading(BuildContext context) => Positioned.fill(
        child: IgnorePointer(
          child: Stack(fit: StackFit.expand, children: [
            if (widget.backdropUrl != null) Opacity(opacity: 0.35, child: NetImage(widget.backdropUrl)),
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  width: context.px(56),
                  height: context.px(56),
                  child: const CircularProgressIndicator(color: C.accent, strokeWidth: 4),
                ),
                SizedBox(height: context.px(22)),
                Text(_status ?? 'Getting the trailer…', style: body(context.px(26), weight: FontWeight.w600)),
                SizedBox(height: context.px(8)),
                Text('Streaming from ${_app.serverName ?? 'your server'}', style: body(context.px(20), color: C.faint)),
              ]),
            ),
          ]),
        ),
      );

  Widget _errorView(BuildContext context) => Center(
        child: Container(
          padding: EdgeInsets.all(context.px(40)),
          decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(context.px(20))),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text("Couldn't play this", style: display(context.px(44))),
            SizedBox(height: context.px(14)),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: context.px(800)),
              child: Text(_error!, textAlign: TextAlign.center, style: body(context.px(22), color: C.muted)),
            ),
            SizedBox(height: context.px(26)),
            Wrap(spacing: context.px(14), children: [
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
            ]),
          ]),
        ),
      );

  /// TV and desktop: round buttons at the top left (back, restart, next episode), the title at the
  /// top right, a play button with the progress bar along the bottom, and the subtitle choices
  /// underneath with "Other…" opening the side panel.
  Widget _tvControls(BuildContext context, AppState app) {
    final pad = context.px(80);
    final subs = _subtitleOptions();
    final chips = subs.take(3).toList();
    void openPanel() {
      _hideTimer?.cancel();
      setState(() => _panel = _Panel.tracks);
    }

    return FocusTraversalGroup(
      child: Stack(fit: StackFit.expand, children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xB3000000), Color(0x00000000), Color(0x00000000), Color(0xE6000000)],
              stops: [0, 0.25, 0.55, 1],
            ),
          ),
        ),
        Positioned(
          left: pad,
          top: context.px(56),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _RoundIcon(icon: Icons.arrow_back_rounded, label: 'Back', onTap: () => Navigator.of(context).pop()),
            SizedBox(width: context.px(18)),
            _RoundIcon(icon: Icons.replay_rounded, label: 'Restart', onTap: () => _engine.seek(Duration.zero)),
            if (_next != null) ...[
              SizedBox(width: context.px(18)),
              _RoundIcon(icon: Icons.skip_next_rounded, label: 'Next Episode', onTap: _playNext),
            ],
          ]),
        ),
        Positioned(
          right: pad,
          top: context.px(60),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: context.px(900)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
              Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis, style: display(context.px(40))),
              if (_item.isEpisode)
                Text('${_item.episodeLabel} "${_item.name}"',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: body(context.px(24), color: C.soft, weight: FontWeight.w600))
              else if (_subtitle != null)
                Text(_subtitle!, style: body(context.px(24), color: C.soft, weight: FontWeight.w600)),
              if (_isStream) ...[
                SizedBox(height: context.px(8)),
                Text(_methodLabel, style: body(context.px(18), color: C.faint)),
              ],
            ]),
          ),
        ),
        Positioned(
          left: pad,
          right: pad,
          bottom: context.px(50),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Focusable(
                focusNode: _playFocus,
                semanticLabel: _playing ? 'Pause' : 'Play',
                scrollIntoView: false,
                onTap: () {
                  _engine.playOrPause();
                  _showControls();
                },
                builder: (context, active) => AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: context.px(72),
                  height: context.px(72),
                  decoration: BoxDecoration(color: active ? C.text : const Color(0x33FFFFFF), shape: BoxShape.circle),
                  child: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: context.px(44), color: active ? const Color(0xFF111111) : C.text),
                ),
              ),
              SizedBox(width: context.px(26)),
              Text(formatClock(_position), style: body(context.px(24), weight: FontWeight.w600)),
              SizedBox(width: context.px(22)),
              Expanded(
                child: _Scrubber(
                  position: _position,
                  duration: _duration,
                  buffered: _buffered,
                  onSeek: _engine.seek,
                  preview: _trick == null ? null : (t) => _TrickThumb(info: _trick!, jf: _jf, at: t),
                ),
              ),
              SizedBox(width: context.px(22)),
              Text(formatClock(_duration), style: body(context.px(24), color: C.muted, weight: FontWeight.w600)),
            ]),
            if (!_isStream) ...[
              SizedBox(height: context.px(26)),
              Row(children: [
                for (final o in chips) ...[
                  _Chip(
                    label: o.label == 'Off' ? 'Subtitles off' : o.label,
                    selected: o.selected,
                    onTap: () async {
                      await o.onPick();
                      if (mounted) setState(() {});
                      _showControls();
                    },
                  ),
                  SizedBox(width: context.px(14)),
                ],
                _Chip(label: 'Other…', selected: false, onTap: openPanel),
              ]),
            ],
          ]),
        ),
      ]),
    );
  }

  /// The side panel "Other…" opens on TV and desktop: subtitles, audio and quality, top to bottom.
  Widget _sidePanel(BuildContext context) {
    Widget section(String title, List<_MenuOption> opts, {bool first = false}) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(context.px(20), context.px(first ? 0 : 30), 0, context.px(10)),
              child: Text(title, style: body(context.px(28), weight: FontWeight.w700)),
            ),
            if (opts.isEmpty)
              Padding(
                padding: EdgeInsets.only(left: context.px(20)),
                child: Text('None', style: body(context.px(22), color: C.faint)),
              ),
            for (var i = 0; i < opts.length; i++)
              Focusable(
                autofocus: first && (opts[i].selected || (i == 0 && !opts.any((o) => o.selected))),
                semanticLabel: opts[i].label,
                onTap: () async {
                  await opts[i].onPick();
                  if (mounted) setState(() {});
                },
                builder: (context, active) => AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  margin: EdgeInsets.only(bottom: context.px(4)),
                  padding: EdgeInsets.symmetric(horizontal: context.px(20), vertical: context.px(14)),
                  decoration: BoxDecoration(color: active ? C.text : Colors.transparent, borderRadius: BorderRadius.circular(999)),
                  child: Row(children: [
                    Expanded(
                      child: Text(opts[i].label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: body(context.px(23), weight: FontWeight.w600, color: active ? const Color(0xFF111111) : C.soft)),
                    ),
                    if (opts[i].selected) Icon(Icons.check_rounded, size: context.px(28), color: active ? const Color(0xFF111111) : C.text),
                  ]),
                ),
              ),
          ],
        );

    return Positioned(
      top: 0,
      bottom: 0,
      right: 0,
      width: context.px(620),
      child: FocusScope(
        autofocus: true,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0x00000000), Color(0xF0000000)], stops: [0, 0.18]),
          ),
          padding: EdgeInsets.fromLTRB(context.px(110), context.px(70), context.px(50), context.px(40)),
          child: ListView(children: [
            section('Subtitles', _subtitleOptions(), first: true),
            section('Audio', _audioOptions()),
            section('Quality', _qualityMenu()),
            Padding(
              padding: EdgeInsets.fromLTRB(context.px(20), context.px(8), 0, 0),
              child: Text('Lower settings ask the server to transcode.', style: body(context.px(18), color: C.faint)),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _controls(BuildContext context, AppState app) {
    if (!app.isPhone) return _tvControls(context, app);
    final pad = context.px(app.isPhone ? 32 : 90);
    return FocusTraversalGroup(
      child: Stack(fit: StackFit.expand, children: [
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
          child: Row(children: [
            if (!app.isTv) ...[
              EmberButton(label: '', icon: Icons.arrow_back, kind: BtnKind.ghost, onTap: () => Navigator.of(context).pop()),
              SizedBox(width: context.px(22)),
            ],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis, style: display(context.px(40))),
                if (_subtitle != null) Text(_subtitle!, style: body(context.px(22), color: C.muted)),
              ]),
            ),
            if (_methodLabel.isNotEmpty && !app.isPhone)
              Container(
                padding: EdgeInsets.symmetric(horizontal: context.px(18), vertical: context.px(10)),
                decoration: BoxDecoration(color: const Color(0xCC17171A), borderRadius: BorderRadius.circular(999)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: context.px(12),
                    height: context.px(12),
                    decoration: BoxDecoration(color: _src?.transcoding == true ? C.warn : C.good, shape: BoxShape.circle),
                  ),
                  SizedBox(width: context.px(10)),
                  Text(_methodLabel, style: body(context.px(19), color: C.muted, weight: FontWeight.w600)),
                ]),
              ),
          ]),
        ),
        Positioned(
          left: pad,
          right: pad,
          bottom: context.px(app.isPhone ? 30 : 56),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
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
              Text(formatClock(_position - _duration), style: body(context.px(24), color: C.muted, weight: FontWeight.w600)),
            ]),
            SizedBox(height: context.px(22)),
            Row(children: [
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
              EmberButton(label: '', icon: Icons.replay_10_rounded, kind: BtnKind.ghost, onTap: () => _seekBy(const Duration(seconds: -10))),
              SizedBox(width: context.px(12)),
              EmberButton(label: '', icon: Icons.forward_10_rounded, kind: BtnKind.ghost, onTap: () => _seekBy(const Duration(seconds: 10))),
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
                EmberButton(label: app.isPhone ? '' : 'Next Episode', icon: Icons.skip_next_rounded, kind: BtnKind.ghost, onTap: _playNext),
              ],
            ]),
          ]),
        ),
      ]),
    );
  }

  Widget _upNext(BuildContext context) {
    final n = _next!;
    return Positioned(
      right: context.px(90),
      bottom: context.px(120),
      child: FocusTraversalGroup(
        child: Container(
          width: context.px(620),
          padding: EdgeInsets.all(context.px(26)),
          decoration: BoxDecoration(color: const Color(0xF0141416), borderRadius: BorderRadius.circular(context.px(18))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('UP NEXT', style: body(context.px(19), color: C.accent, weight: FontWeight.w700).copyWith(letterSpacing: 3)),
            SizedBox(height: context.px(14)),
            ClipRRect(
              borderRadius: BorderRadius.circular(context.px(10)),
              child: AspectRatio(aspectRatio: 16 / 9, child: NetImage(_jf.landscapeImage(n, maxWidth: 640), fallback: TitleCard(n.name))),
            ),
            SizedBox(height: context.px(14)),
            Text('${n.episodeLabel} · ${n.name}', maxLines: 2, style: body(context.px(26), weight: FontWeight.w700)),
            SizedBox(height: context.px(18)),
            Wrap(spacing: context.px(12), runSpacing: context.px(12), children: [
              EmberButton(
                label: _countdown != null ? 'Next Episode in $_countdown' : 'Next Episode',
                icon: Icons.play_arrow_rounded,
                kind: BtnKind.primary,
                focusNode: _nextFocus,
                onTap: _playNext,
              ),
              EmberButton(
                label: 'Watch Credits',
                kind: BtnKind.ghost,
                onTap: () {
                  _countdownTimer?.cancel();
                  setState(() {
                    _upNextDismissed = true;
                    _countdown = null;
                  });
                  _rootFocus.requestFocus();
                },
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _tracksPanel(BuildContext context) {
    final app = context.read<AppState>();
    Widget column(String title, List<_MenuOption> opts, {String? note}) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: body(context.px(22), color: C.faint, weight: FontWeight.w700).copyWith(letterSpacing: 3)),
            SizedBox(height: context.px(14)),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
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
                      decoration: BoxDecoration(color: active ? C.text : Colors.transparent, borderRadius: BorderRadius.circular(context.px(12))),
                      child: Row(children: [
                        SizedBox(
                          width: context.px(40),
                          child: opts[i].selected ? Icon(Icons.check, color: active ? const Color(0xFF111111) : C.accent, size: context.px(28)) : null,
                        ),
                        Expanded(
                          child: Text(opts[i].label,
                              style: body(context.px(23), weight: FontWeight.w600, color: active ? const Color(0xFF111111) : C.soft)),
                        ),
                      ]),
                    ),
                  ),
              ]),
            ),
            if (note != null) ...[
              SizedBox(height: context.px(10)),
              Text(note, style: body(context.px(19), color: C.faint)),
            ],
          ]),
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
          decoration: BoxDecoration(color: const Color(0xF5121214), borderRadius: BorderRadius.circular(context.px(24))),
          child: Column(children: [
            Expanded(child: app.isPhone ? Column(children: cols) : Row(crossAxisAlignment: CrossAxisAlignment.start, children: cols)),
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
          ]),
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
          width: context.px(120),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: context.px(64),
              height: context.px(64),
              decoration: BoxDecoration(color: active ? C.text : const Color(0x33FFFFFF), shape: BoxShape.circle),
              child: Icon(icon, size: context.px(34), color: active ? const Color(0xFF111111) : C.text),
            ),
            SizedBox(height: context.px(10)),
            Opacity(
              opacity: active ? 1 : 0,
              child: Text(label, textAlign: TextAlign.center, style: body(context.px(18), weight: FontWeight.w600)),
            ),
          ]),
        ),
      );
}

/// A language choice under the progress bar. The current one has an outline.
class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => Focusable(
        onTap: onTap,
        semanticLabel: label,
        scrollIntoView: false,
        builder: (context, active) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: EdgeInsets.symmetric(horizontal: context.px(24), vertical: context.px(12)),
          decoration: BoxDecoration(
            color: active ? C.text : const Color(0x26FFFFFF),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: selected && !active ? C.text : Colors.transparent, width: context.px(2)),
          ),
          child: Text(label,
              style: body(context.px(21), weight: FontWeight.w600, color: active ? const Color(0xFF111111) : C.text)),
        ),
      );
}

/// The progress bar. Click or drag with a mouse or finger; with a remote, focus it and press left/right.
class _Scrubber extends StatefulWidget {
  final Duration position, duration, buffered;
  final ValueChanged<Duration> onSeek;

  /// Builds the thumbnail shown above the bar for a time (trickplay), if available.
  final Widget Function(Duration at)? preview;
  const _Scrubber({required this.position, required this.duration, required this.buffered, required this.onSeek, this.preview});
  @override
  State<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<_Scrubber> {
  double? _drag;
  double? _hover;
  bool _focused = false;

  double _frac(Duration d) => widget.duration.inMilliseconds == 0 ? 0 : (d.inMilliseconds / widget.duration.inMilliseconds).clamp(0.0, 1.0);

  void _seekFrac(double f) => widget.onSeek(Duration(milliseconds: (widget.duration.inMilliseconds * f.clamp(0.0, 1.0)).round()));

  @override
  Widget build(BuildContext context) {
    final f = _drag ?? _frac(widget.position);
    return Focus(
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (node, e) {
        if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
        if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
          widget.onSeek(widget.position - const Duration(seconds: 10));
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
          widget.onSeek(widget.position + const Duration(seconds: 10));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth;
        final h = context.px(_focused ? 14 : 10);
        final previewFrac = _drag ?? _hover ?? (_focused ? f : null);
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
            child: Stack(alignment: Alignment.centerLeft, clipBehavior: Clip.none, children: [
              Container(height: h, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(h))),
              Container(width: w * _frac(widget.buffered), height: h, decoration: BoxDecoration(color: Colors.white38, borderRadius: BorderRadius.circular(h))),
              Container(width: w * f, height: h, decoration: BoxDecoration(color: C.accent, borderRadius: BorderRadius.circular(h))),
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
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
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
                            child: widget.preview!(Duration(milliseconds: (widget.duration.inMilliseconds * previewFrac).round())),
                          ),
                        ),
                      ),
                      SizedBox(height: context.px(6)),
                      Text(formatClock(Duration(milliseconds: (widget.duration.inMilliseconds * previewFrac).round())),
                          style: body(context.px(22), weight: FontWeight.w700)),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
        );
      }),
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
    return LayoutBuilder(builder: (context, c) {
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
    });
  }
}
