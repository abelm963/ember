import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../api/jellyfin.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

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
  Player? _player;
  VideoController? _video;
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

  Future<String?> _url(AppState app) async {
    final jf = app.jf!;
    if (widget.item.localTrailerCount > 0) {
      final local = await jf.localTrailers(widget.item.id);
      if (local.isNotEmpty) {
        try {
          return (await jf.playbackSource(local.first.id)).url;
        } catch (_) {}
      }
    }
    if (!app.trailerServiceOk || widget.item.remoteTrailers.isEmpty) return null;
    final key = await jf.trailerKeyForItem(widget.item.id);
    return key == null ? null : jf.trailerStreamUrl(key);
  }

  Future<void> _start() async {
    final app = context.read<AppState>();
    final url = await _url(app);
    if (url == null || !mounted) return;
    final p = Player(configuration: const PlayerConfiguration(title: 'Ember preview', bufferSize: 16 * 1024 * 1024));
    _player = p;
    _video = VideoController(p);
    await p.setVolume(_muted ? 0 : 100);
    _subs.add(p.stream.position.listen((pos) {
      if (!_visible && pos > const Duration(milliseconds: 300) && mounted) setState(() => _visible = true);
    }));
    _subs.add(p.stream.completed.listen((done) {
      if (done && mounted) {
        setState(() {
          _visible = false;
          _finished = true;
        });
      }
    }));
    await p.open(Media(url));
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
    if (_video == null) return widget.overlay;
    return Stack(fit: StackFit.expand, children: [
      IgnorePointer(
        child: AnimatedOpacity(
          opacity: _visible ? 1 : 0,
          duration: const Duration(milliseconds: 700),
          child: ExcludeFocus(child: Video(controller: _video!, controls: NoVideoControls, fit: BoxFit.cover, fill: Colors.transparent)),
        ),
      ),
      widget.overlay,
      if (_visible)
        Positioned(
          right: context.px(80),
          bottom: context.px(120),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: EdgeInsets.symmetric(horizontal: context.px(16), vertical: context.px(10)),
              decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(999)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: context.px(10),
                  height: context.px(10),
                  decoration: const BoxDecoration(color: C.accent, shape: BoxShape.circle),
                ),
                SizedBox(width: context.px(10)),
                Text('Official trailer · preview', style: body(context.px(19), color: C.soft, weight: FontWeight.w600)),
              ]),
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
                child: Icon(_muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                    color: active ? const Color(0xFF111111) : C.text, size: context.px(28)),
              ),
            ),
          ]),
        ),
    ]);
  }
}
