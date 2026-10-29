/// The player's buttons, menus, episode rows and scrubber (drawn by the player screen).
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/jellyfin.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

class PlayerMenuOption {
  final String label;
  final bool selected;
  final Future<void> Function() onPick;
  PlayerMenuOption(this.label, this.selected, this.onPick);
}

/// A round icon button for the top of the player; its name shows underneath while it has focus.
class PlayerRoundIcon extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const PlayerRoundIcon({super.key, required this.icon, required this.label, required this.onTap});

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
class PlayerBarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  const PlayerBarButton({super.key, required this.icon, required this.label, required this.onTap, this.focusNode});

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
class PlayerSkipButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  const PlayerSkipButton({super.key, required this.label, required this.onTap, this.focusNode});

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
class PlayerNextEpisodeButton extends StatelessWidget {
  final FocusNode? focusNode;
  final Duration? countdown;
  final VoidCallback onTap;
  const PlayerNextEpisodeButton({super.key, required this.onTap, this.focusNode, this.countdown});

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
class PlayerMenuRow extends StatelessWidget {
  final PlayerMenuOption option;
  final bool autofocus;
  final VoidCallback onPicked;
  const PlayerMenuRow({super.key, required this.option, required this.onPicked, this.autofocus = false});

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
class PlayerSeasonRow extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onFocus;
  const PlayerSeasonRow({super.key, required this.label, required this.selected, required this.onFocus});

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
class PlayerEpisodeRow extends StatelessWidget {
  final JfItem episode;
  final String? image;
  final bool current;
  final bool autofocus;
  final VoidCallback onTap;
  const PlayerEpisodeRow({
    super.key,
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
class PlayerScrubber extends StatefulWidget {
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
  const PlayerScrubber({
    super.key,
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
  State<PlayerScrubber> createState() => _PlayerScrubberState();
}

class _PlayerScrubberState extends State<PlayerScrubber> {
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
class PlayerTrickThumb extends StatelessWidget {
  final TrickplayInfo info;
  final JellyfinClient jf;
  final Duration at;
  const PlayerTrickThumb({super.key, required this.info, required this.jf, required this.at});

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
