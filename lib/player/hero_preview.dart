import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' show AudioTrack;
import 'package:provider/provider.dart';

import '../api/jellyfin.dart';
import '../api/youtube.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'engine.dart';
import 'trailers.dart';

/// Lets previews pause when another screen opens on top and resume on return.
final RouteObserver<ModalRoute<void>> routeObserver = RouteObserver<ModalRoute<void>>();

/// A Netflix-style muted trailer that fades in over the backdrop after a short pause.
/// Uses a trailer file on the server if there is one, otherwise the Ember Trailers plugin.
/// TV and desktop only; on phones the still backdrop stays.
class HeroPreview extends StatefulWidget {
  final JfItem item;

  /// False while the hero is scrolled away; the preview pauses.
  final ValueListenable<bool>? active;

  /// Drawn between the video and the preview's own controls (the page's gradients).
  final Widget overlay;
  const HeroPreview({super.key, required this.item, required this.overlay, this.active});
  @override
  State<HeroPreview> createState() => _HeroPreviewState();
}

class _HeroPreviewState extends State<HeroPreview> with RouteAware {
  PlaybackEngine? _player;
  Timer? _delay;
  bool _visible = false;
  bool _finished = false;
  bool _covered = false;
  late bool _muted;
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _muted = app.previewsMuted;
    if (!app.isPhone && app.autoplayPreviews && app.trailersInApp) {
      _delay = Timer(const Duration(seconds: 2), _start);
    }
    widget.active?.addListener(_syncPlaying);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  /// A trailer file stored with the title, otherwise the official YouTube trailer, found on
  /// this device (the same lookup the Trailer button uses, so it's shared and kept).
  Future<TrailerStream?> _trailer(AppState app) async {
    final jf = app.jf!;
    if (widget.item.localTrailerCount > 0) {
      final local = await jf.localTrailers(widget.item.id);
      if (local.isNotEmpty) {
        try {
          return TrailerStream((await jf.playbackSource(local.first.id)).url);
        } catch (_) {}
      }
    }
    return (await findTrailer(app, item: widget.item)).$2;
  }

  Future<void> _start() async {
    final app = context.read<AppState>();
    final trailer = await _trailer(app);
    if (trailer == null || !mounted) return;
    final url = trailer.url;
    final p = PlaybackEngine(title: 'Ember preview', bufferSize: 16 * 1024 * 1024);
    _player = p;
    await p.setVolume(_muted ? 0 : 100);
    _subs.add(
      p.position.listen((pos) {
        if (!_visible && pos > const Duration(milliseconds: 300) && mounted) setState(() => _visible = true);
      }),
    );
    _subs.add(
      p.completed.listen((done) {
        if (done && mounted) {
          setState(() {
            _visible = false;
            _finished = true;
          });
        }
      }),
    );
    try {
      await p.open(url, headers: trailer.headers);
      // Picture and sound in separate files: mpv joins them (Apple TV previews show the picture).
      if (trailer.audioUrl != null && p is MpvEngine) await p.player.setAudioTrack(AudioTrack.uri(trailer.audioUrl!));
    } catch (_) {
      return; // no preview; the still backdrop stays
    }
    _syncPlaying();
    if (mounted) setState(() {});
  }

  void _syncPlaying() {
    final p = _player;
    if (p == null || _finished) return;
    final active = (widget.active?.value ?? true) && !_covered;
    if (active) {
      p.play();
    } else {
      p.pause();
    }
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _player?.setVolume(_muted ? 0 : 100);
  }

  @override
  void didPushNext() {
    _covered = true;
    _syncPlaying();
  }

  @override
  void didPopNext() {
    _covered = false;
    _syncPlaying();
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    widget.active?.removeListener(_syncPlaying);
    _delay?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    if (player == null) return widget.overlay;
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: _visible ? 1 : 0,
            duration: const Duration(milliseconds: 700),
            child: ExcludeFocus(
              child: player.view(fit: BoxFit.cover, fill: Colors.transparent),
            ),
          ),
        ),
        widget.overlay,
        if (_visible)
          Positioned(
            right: context.px(80),
            bottom: context.px(120),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: context.px(16), vertical: context.px(10)),
                  decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(999)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: context.px(10),
                        height: context.px(10),
                        decoration: const BoxDecoration(color: C.accent, shape: BoxShape.circle),
                      ),
                      SizedBox(width: context.px(10)),
                      Text(
                        'Official trailer · preview',
                        style: body(context.px(19), color: C.soft, weight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: context.px(14)),
                Focusable(
                  onTap: _toggleMute,
                  semanticLabel: _muted ? 'Unmute preview' : 'Mute preview',
                  scrollIntoView: false,
                  builder: (context, active) => Container(
                    width: context.px(56),
                    height: context.px(56),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: active ? C.text : const Color(0x80000000),
                      border: Border.all(color: const Color(0xB3F4F1EC), width: context.px(2)),
                    ),
                    child: Icon(
                      _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                      color: active ? const Color(0xFF111111) : C.text,
                      size: context.px(28),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
