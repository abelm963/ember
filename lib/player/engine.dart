import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../platform.dart';

/// The video player behind the player screen and the hero previews.
///
/// Windows, Mac and phones use mpv ([MpvEngine]), which plays every container, codec and
/// subtitle itself. Apple TV can't run mpv, so it uses Apple's own player ([AvEngine]) and the
/// server takes care of anything AVPlayer can't open (see `JellyfinClient.playbackSource`).
abstract class PlaybackEngine {
  factory PlaybackEngine({required String title, int bufferSize = 64 * 1024 * 1024}) =>
      isAppleTv ? AvEngine() : MpvEngine(title: title, bufferSize: bufferSize);

  Stream<bool> get playing;
  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<Duration> get buffer;
  Stream<bool> get buffering;
  Stream<bool> get completed;
  Stream<String> get error;

  /// [headers] go with every request for the video (YouTube trailers need some).
  Future<void> open(String url, {Duration? start, Map<String, String> headers = const {}});
  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause();
  Future<void> seek(Duration to);

  /// 0 to 100.
  Future<void> setVolume(double volume);

  /// Shows a WebVTT subtitle file from [url] on top of the video, or none when null.
  /// Only used by [AvEngine]; mpv loads subtitles as tracks of its own.
  Future<void> setTextSubtitles(String? url);

  /// The picture, with the current subtitle line drawn over it.
  Widget view({BoxFit fit = BoxFit.contain, Color fill = Colors.black});

  Future<void> dispose();
}

class MpvEngine implements PlaybackEngine {
  final Player player;
  late final VideoController _video = VideoController(player);

  MpvEngine({required String title, required int bufferSize})
    : player = Player(
        configuration: PlayerConfiguration(title: title, bufferSize: bufferSize, logLevel: MPVLogLevel.warn),
      );

  @override
  Stream<bool> get playing => player.stream.playing;
  @override
  Stream<Duration> get position => player.stream.position;
  @override
  Stream<Duration> get duration => player.stream.duration;
  @override
  Stream<Duration> get buffer => player.stream.buffer;
  @override
  Stream<bool> get buffering => player.stream.buffering;
  @override
  Stream<bool> get completed => player.stream.completed;
  @override
  Stream<String> get error => player.stream.error;

  @override
  Future<void> open(String url, {Duration? start, Map<String, String> headers = const {}}) =>
      player.open(Media(url, start: start, httpHeaders: headers));
  @override
  Future<void> play() => player.play();
  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> playOrPause() => player.playOrPause();
  @override
  Future<void> seek(Duration to) => player.seek(to);
  @override
  Future<void> setVolume(double volume) => player.setVolume(volume);
  @override
  Future<void> setTextSubtitles(String? url) =>
      player.setSubtitleTrack(url == null ? SubtitleTrack.no() : SubtitleTrack.uri(url));

  @override
  Widget view({BoxFit fit = BoxFit.contain, Color fill = Colors.black}) =>
      Video(controller: _video, controls: NoVideoControls, fit: fit, fill: fill);

  @override
  Future<void> dispose() => player.dispose();
}

/// Apple's AVPlayer, through video_player (video_player_tvos on Apple TV).
class AvEngine implements PlaybackEngine {
  VideoPlayerController? _c;
  final _changed = ValueNotifier<int>(0);
  double _volume = 100;
  bool _wasPlaying = false, _wasBuffering = false, _wasCompleted = false;
  Duration _lastDuration = Duration.zero;
  String? _lastError;

  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _buffer = StreamController<Duration>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();

  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<Duration> get duration => _duration.stream;
  @override
  Stream<Duration> get buffer => _buffer.stream;
  @override
  Stream<bool> get buffering => _buffering.stream;
  @override
  Stream<bool> get completed => _completed.stream;
  @override
  Stream<String> get error => _error.stream;

  void _onValue() {
    final c = _c;
    if (c == null) return;
    final v = c.value;
    _position.add(v.position);
    if (v.duration != _lastDuration) {
      _lastDuration = v.duration;
      _duration.add(v.duration);
    }
    if (v.buffered.isNotEmpty) _buffer.add(v.buffered.last.end);
    if (v.isPlaying != _wasPlaying) {
      _wasPlaying = v.isPlaying;
      _playing.add(v.isPlaying);
      // The Apple TV screensaver doesn't know Ember is playing video: keep it away while it is.
      WakelockPlus.toggle(enable: v.isPlaying).catchError((_) {});
    }
    if (v.isBuffering != _wasBuffering) {
      _wasBuffering = v.isBuffering;
      _buffering.add(v.isBuffering);
    }
    if (v.isCompleted != _wasCompleted) {
      _wasCompleted = v.isCompleted;
      _completed.add(v.isCompleted);
    }
    if (v.hasError && v.errorDescription != _lastError) {
      _lastError = v.errorDescription;
      _error.add(v.errorDescription ?? 'Playback failed');
    }
  }

  @override
  Future<void> open(String url, {Duration? start, Map<String, String> headers = const {}}) async {
    final old = _c;
    final c = VideoPlayerController.networkUrl(Uri.parse(url), httpHeaders: headers);
    _c = c;
    _wasPlaying = _wasBuffering = _wasCompleted = false;
    _lastDuration = Duration.zero;
    _lastError = null;
    c.addListener(_onValue);
    try {
      await c.initialize();
    } catch (e) {
      _error.add('$e');
      rethrow;
    } finally {
      old?.removeListener(_onValue);
      await old?.dispose();
    }
    await c.setVolume(_volume / 100);
    if (start != null && start > Duration.zero) await c.seekTo(start);
    await c.play();
    _changed.value++;
  }

  @override
  Future<void> play() async => _c?.play();
  @override
  Future<void> pause() async => _c?.pause();
  @override
  Future<void> playOrPause() async {
    final c = _c;
    if (c == null) return;
    c.value.isPlaying ? await c.pause() : await c.play();
  }

  @override
  Future<void> seek(Duration to) async => _c?.seekTo(to);

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    await _c?.setVolume(volume / 100);
  }

  @override
  Future<void> setTextSubtitles(String? url) async {
    final c = _c;
    if (c == null) return;
    if (url == null) {
      await c.setClosedCaptionFile(null);
      return;
    }
    final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw Exception('The server couldn\'t send these subtitles (${res.statusCode}).');
    await c.setClosedCaptionFile(Future.value(WebVTTCaptionFile(res.body)));
  }

  @override
  Widget view({BoxFit fit = BoxFit.contain, Color fill = Colors.black}) => ValueListenableBuilder<int>(
    valueListenable: _changed,
    builder: (context, _, _) {
      final c = _c;
      if (c == null || !c.value.isInitialized) return ColoredBox(color: fill);
      return ColoredBox(
        color: fill,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FittedBox(
              fit: fit,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(width: c.value.size.width, height: c.value.size.height, child: VideoPlayer(c)),
            ),
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: c,
              builder: (context, v, _) {
                if (v.caption.text.isEmpty) return const SizedBox.shrink();
                final h = MediaQuery.sizeOf(context).height;
                return Positioned(
                  left: 0,
                  right: 0,
                  bottom: h * 0.07,
                  child: Center(
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: h * 0.012, vertical: h * 0.004),
                      decoration: BoxDecoration(
                        color: const Color(0x99000000),
                        borderRadius: BorderRadius.circular(h * 0.006),
                      ),
                      child: Text(
                        v.caption.text.replaceAll(RegExp(r'<[^>]+>'), ''),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: h * 0.042,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      );
    },
  );

  @override
  Future<void> dispose() async {
    final c = _c;
    _c = null;
    c?.removeListener(_onValue);
    await c?.dispose();
    if (_wasPlaying) WakelockPlus.disable().catchError((_) {});
    for (final s in [_playing, _position, _duration, _buffer, _buffering, _completed, _error]) {
      await s.close();
    }
    _changed.dispose();
  }
}
