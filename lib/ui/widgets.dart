import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'theme.dart';

// ======================================================================
// Scale: every size in the app is written for a 1920×1080 TV screen and
// multiplied by this factor, so TV, desktop windows and phones all fit.
// ======================================================================

double scaleOf(BuildContext context) {
  final state = context.read<AppState>();
  final size = MediaQuery.sizeOf(context);
  switch (state.formFactor) {
    // Fit the 1920×1080 design inside the window: on ultra-wide screens the height decides,
    // so nothing is pushed off the bottom; extra width just shows more of each row.
    case FormFactor.tv:
      return min(size.width / 1920, size.height / 1080).clamp(0.3, 3.0);
    case FormFactor.desktop:
      return min(size.width / 1920, size.height / 1080).clamp(0.4, 2.0);
    case FormFactor.phone:
      return (size.shortestSide / 900).clamp(0.4, 1.0);
  }
}

extension Px on BuildContext {
  /// Converts a design size (1920-wide TV units) into this screen's pixels.
  double px(double v) => v * scaleOf(this);
  AppState get app => read<AppState>();
}

bool isActivateKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.enter ||
    k == LogicalKeyboardKey.numpadEnter ||
    k == LogicalKeyboardKey.select ||
    k == LogicalKeyboardKey.space ||
    k == LogicalKeyboardKey.gameButtonA;

bool isBackKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.escape ||
    k == LogicalKeyboardKey.goBack ||
    k == LogicalKeyboardKey.browserBack ||
    k == LogicalKeyboardKey.gameButtonB;

// ======================================================================
// Focusable: the one interactive building block.
//  - TV: reacts to D-pad focus and the Select button, scrolls itself into view.
//  - Desktop: reacts to mouse hover and click, plus keyboard focus.
//  - Phone: reacts to taps.
// ======================================================================

typedef FocusBuilder = Widget Function(BuildContext context, bool active);

class Focusable extends StatefulWidget {
  final FocusBuilder builder;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onFocusChange;
  final bool autofocus;
  final FocusNode? focusNode;
  final String? semanticLabel;
  final bool scrollIntoView;

  const Focusable({
    super.key,
    required this.builder,
    this.onTap,
    this.onLongPress,
    this.onFocusChange,
    this.autofocus = false,
    this.focusNode,
    this.semanticLabel,
    this.scrollIntoView = true,
  });

  @override
  State<Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<Focusable> {
  bool _focused = false;
  bool _hovered = false;

  void _setFocus(bool f) {
    setState(() => _focused = f);
    widget.onFocusChange?.call(f);
    if (f && widget.scrollIntoView) {
      Scrollable.ensureVisible(context,
          alignment: 0.5,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _focused || _hovered;
    return Semantics(
      button: widget.onTap != null,
      label: widget.semanticLabel,
      child: Focus(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        onFocusChange: _setFocus,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent && isActivateKey(event.logicalKey) && widget.onTap != null) {
            widget.onTap!();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: widget.builder(context, active),
          ),
        ),
      ),
    );
  }
}

// ======================================================================
// Buttons
// ======================================================================

enum BtnKind { primary, secondary, accent, ghost }

class EmberButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final BtnKind kind;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool compact;

  const EmberButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.kind = BtnKind.secondary,
    this.autofocus = false,
    this.focusNode,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final h = context.px(compact ? 60 : 72);
    return Focusable(
      autofocus: autofocus,
      focusNode: focusNode,
      onTap: onTap,
      semanticLabel: label,
      builder: (context, active) {
        Color bg, fg;
        switch (kind) {
          case BtnKind.primary:
            bg = C.text;
            fg = const Color(0xFF111111);
            break;
          case BtnKind.accent:
            bg = active ? C.text : C.accent;
            fg = active ? const Color(0xFF111111) : C.accentInk;
            break;
          case BtnKind.secondary:
            bg = active ? C.text : const Color(0x66787880);
            fg = active ? const Color(0xFF111111) : Colors.white;
            break;
          case BtnKind.ghost:
            bg = active ? C.text : C.surface3;
            fg = active ? const Color(0xFF111111) : C.text;
            break;
        }
        return AnimatedScale(
          scale: active ? 1.05 : 1,
          duration: const Duration(milliseconds: 150),
          child: Container(
            height: h,
            padding: EdgeInsets.symmetric(horizontal: context.px(icon != null && label.isEmpty ? 0 : 34)),
            width: label.isEmpty ? h : null,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(context.px(12)),
              border: active && kind == BtnKind.primary ? Border.all(color: C.accent, width: context.px(3)) : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) Icon(icon, color: fg, size: context.px(30)),
                if (icon != null && label.isNotEmpty) SizedBox(width: context.px(12)),
                if (label.isNotEmpty)
                  Text(label, style: body(context.px(compact ? 22 : 25), color: fg, weight: FontWeight.w700)),
              ],
            ),
          ),
        );
      },
    );
  }
}

class Chip2 extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const Chip2({super.key, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onTap: onTap,
      semanticLabel: label,
      builder: (context, active) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: context.px(54),
        padding: EdgeInsets.symmetric(horizontal: context.px(26)),
        decoration: BoxDecoration(
          color: active ? C.text : (selected ? C.accentDark : C.surface),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
            style: body(context.px(22),
                weight: FontWeight.w600, color: active ? const Color(0xFF111111) : (selected ? C.accent : C.muted))),
        ]),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  const Pill(this.text, {super.key, this.bg = C.accent, this.fg = C.accentInk});
  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: context.px(12), vertical: context.px(5)),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: body(context.px(15), color: fg, weight: FontWeight.w700)),
      );
}

class Badge2 extends StatelessWidget {
  final String text;
  const Badge2(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: context.px(8), vertical: context.px(1)),
        decoration: BoxDecoration(
            border: Border.all(color: C.faint, width: context.px(2)), borderRadius: BorderRadius.circular(context.px(4))),
        child: Text(text, style: body(context.px(18), color: C.muted, weight: FontWeight.w700)),
      );
}

// ======================================================================
// Images
// ======================================================================

class NetImage extends StatelessWidget {
  final String? url;
  final BoxFit fit;
  /// Shown when there is no image or it fails to load.
  final Widget? fallback;
  /// Shown while the image is still downloading (defaults to [fallback]).
  final Widget? loading;
  final Alignment alignment;
  final Map<String, String>? headers;
  const NetImage(this.url,
      {super.key, this.fit = BoxFit.cover, this.fallback, this.loading, this.alignment = Alignment.center, this.headers});

  @override
  Widget build(BuildContext context) {
    final fb = fallback ?? Container(color: C.surface2);
    if (url == null) return fb;
    return Image.network(
      url!,
      fit: fit,
      alignment: alignment,
      headers: headers,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => fb,
      frameBuilder: (context, child, frame, sync) {
        if (sync) return child;
        // Fade in once the first frame arrives instead of popping in.
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: frame != null ? KeyedSubtree(key: const ValueKey('img'), child: child) : (loading ?? fb),
        );
      },
    );
  }
}

/// Downloads images ahead of time so a page appears complete, not piece by piece.
/// Gives up after [timeout] so a slow image never blocks the page.
Future<void> warmImages(BuildContext context, Iterable<String?> urls, {Duration timeout = const Duration(seconds: 4)}) async {
  final jobs = [
    for (final u in urls)
      if (u != null && context.mounted) precacheImage(NetworkImage(u), context, onError: (_, _) {}),
  ];
  try {
    await Future.wait(jobs).timeout(timeout);
  } catch (_) {}
}

/// Gently pulsing grey blocks shown while a page loads.
class SkeletonPulse extends StatefulWidget {
  final Widget child;
  const SkeletonPulse({super.key, required this.child});
  @override
  State<SkeletonPulse> createState() => _SkeletonPulseState();
}

class _SkeletonPulseState extends State<SkeletonPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100), lowerBound: 0.45, upperBound: 1)
        ..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(opacity: _c, child: widget.child);
}

class Bone extends StatelessWidget {
  final double width;
  final double height;
  final double radius;
  const Bone(this.width, this.height, {super.key, this.radius = 10});
  @override
  Widget build(BuildContext context) => Container(
        width: context.px(width),
        height: context.px(height),
        decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(context.px(radius))),
      );
}

/// The shape of a movie / series / preview page, shown while it loads.
class TitlePageSkeleton extends StatelessWidget {
  const TitlePageSkeleton({super.key});
  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < 700;
    final pad = context.px(phone ? 40 : 120);
    final gap = SizedBox(height: context.px(22));
    return SkeletonPulse(
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(pad, context.px(phone ? 100 : 110), pad, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Bone(560, 140, radius: 14),
          gap,
          Row(children: [
            for (final w in const [70.0, 70.0, 64.0, 110.0, 220.0]) ...[Bone(w, 30, radius: 8), SizedBox(width: context.px(14))],
          ]),
          SizedBox(height: context.px(30)),
          const Bone(900, 24),
          SizedBox(height: context.px(14)),
          const Bone(860, 24),
          SizedBox(height: context.px(14)),
          const Bone(620, 24),
          SizedBox(height: context.px(34)),
          Wrap(spacing: context.px(16), runSpacing: context.px(14), children: const [
            Bone(230, 72, radius: 14),
            Bone(190, 72, radius: 14),
            Bone(72, 72, radius: 14),
            Bone(72, 72, radius: 14),
          ]),
          SizedBox(height: context.px(70)),
          Row(children: [const Bone(200, 34), SizedBox(width: context.px(30)), const Bone(170, 34)]),
          SizedBox(height: context.px(30)),
          ClipRect(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: Row(children: [
                for (var i = 0; i < 6; i++) ...[const Bone(340, 192, radius: 12), SizedBox(width: context.px(18))],
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

/// A placeholder that shows a title on a coloured card when there is no artwork.
class TitleCard extends StatelessWidget {
  final String title;
  const TitleCard(this.title, {super.key});
  @override
  Widget build(BuildContext context) {
    final hue = (title.hashCode % 360).abs().toDouble();
    return Container(
      color: HSLColor.fromAHSL(1, hue, 0.35, 0.22).toColor(),
      alignment: Alignment.bottomLeft,
      padding: EdgeInsets.all(context.px(18)),
      child: Text(title, maxLines: 3, overflow: TextOverflow.ellipsis, style: display(context.px(26), height: 1.0)),
    );
  }
}

// ======================================================================
// Tiles and rows
// ======================================================================

class MediaTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final double width;
  final double aspect; // width / height
  final double? progress;
  final String? badge;
  final bool badgeAlt;
  final VoidCallback onTap;
  final bool autofocus;
  final bool showTitle;
  final ValueChanged<bool>? onFocusChange;

  const MediaTile({
    super.key,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.imageUrl,
    this.width = 384,
    this.aspect = 16 / 9,
    this.progress,
    this.badge,
    this.badgeAlt = false,
    this.autofocus = false,
    this.showTitle = true,
    this.onFocusChange,
  });

  @override
  Widget build(BuildContext context) {
    final w = context.px(width);
    final h = w / aspect;
    final r = BorderRadius.circular(context.px(10));
    return Focusable(
      onTap: onTap,
      autofocus: autofocus,
      onFocusChange: onFocusChange,
      semanticLabel: title,
      builder: (context, active) => AnimatedScale(
        scale: active ? 1.07 : 1,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            borderRadius: r,
            border: Border.all(color: active ? C.text : Colors.transparent, width: context.px(4)),
          ),
          child: ClipRRect(
            borderRadius: r,
            child: Stack(fit: StackFit.expand, children: [
              NetImage(imageUrl, fallback: TitleCard(title)),
              if (showTitle && imageUrl != null)
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment(0, 0.1),
                      colors: [Color(0xCC000000), Color(0x00000000)],
                    ),
                  ),
                ),
              // Episode / time-left label in the top-left corner, as in the design.
              if (showTitle && subtitle != null)
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment(0, -0.3),
                      colors: [Color(0x99000000), Color(0x00000000)],
                    ),
                  ),
                ),
              if (showTitle && subtitle != null)
                Positioned(
                  left: context.px(18),
                  top: context.px(14),
                  right: context.px(badge != null ? 140 : 18),
                  child: Text(subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: body(context.px(18), color: Colors.white, weight: FontWeight.w600)),
                ),
              if (showTitle && imageUrl != null)
                Positioned(
                  left: context.px(18),
                  right: context.px(18),
                  bottom: context.px(progress != null ? 22 : 16),
                  child: Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: body(context.px(25), weight: FontWeight.w700)),
                ),
              if (badge != null)
                Positioned(
                  top: context.px(12),
                  right: context.px(12),
                  child: Pill(badge!, bg: badgeAlt ? C.text : C.accent, fg: badgeAlt ? const Color(0xFF141414) : C.accentInk),
                ),
              if (progress != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: context.px(6),
                  child: Container(
                    color: Colors.white24,
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(widthFactor: progress!.clamp(0.02, 1.0), child: Container(color: C.accent)),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A titled horizontal row of tiles. On desktop it shows scroll arrows on hover;
/// on TV the focused tile scrolls itself into view; on phones it swipes.
class MediaRow extends StatefulWidget {
  final String title;
  final String? note;
  final List<Widget> children;
  final double tileHeight;

  /// Left/right margin in design units; defaults to the page gutter.
  final double? inset;

  const MediaRow({super.key, required this.title, required this.children, required this.tileHeight, this.note, this.inset});

  @override
  State<MediaRow> createState() => _MediaRowState();
}

class _MediaRowState extends State<MediaRow> {
  final _ctrl = ScrollController();
  bool _hover = false;

  void _page(int dir) {
    final w = MediaQuery.sizeOf(context).width * 0.8;
    _ctrl.animateTo((_ctrl.offset + dir * w).clamp(0, _ctrl.position.maxScrollExtent),
        duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) return const SizedBox.shrink();
    final app = context.watch<AppState>();
    final pad = context.px(widget.inset ?? gutter(context));
    final h = context.px(widget.tileHeight) + context.px(40);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: EdgeInsets.only(bottom: context.px(28)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.title.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(left: pad, right: pad, bottom: context.px(6)),
            child: Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: context.px(16), children: [
              Text(widget.title, style: body(context.px(30), weight: FontWeight.w700)),
              if (widget.note != null) Text(widget.note!, style: body(context.px(21), color: C.faint)),
            ]),
          ),
          SizedBox(
            height: h,
            child: Stack(children: [
              FocusTraversalGroup(
                child: ListView.separated(
                  controller: _ctrl,
                  scrollDirection: Axis.horizontal,
                  scrollCacheExtent: const ScrollCacheExtent.pixels(3000),
                  clipBehavior: Clip.none,
                  padding: EdgeInsets.symmetric(horizontal: pad, vertical: context.px(20)),
                  itemCount: widget.children.length,
                  separatorBuilder: (_, _) => SizedBox(width: context.px(24)),
                  itemBuilder: (_, i) => widget.children[i],
                ),
              ),
              if (app.isDesktop && _hover) ...[
                _arrow(context, Alignment.centerLeft, Icons.chevron_left, () => _page(-1)),
                _arrow(context, Alignment.centerRight, Icons.chevron_right, () => _page(1)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _arrow(BuildContext context, Alignment a, IconData icon, VoidCallback onTap) => Align(
        alignment: a,
        child: ExcludeFocus(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onTap,
              child: Container(
                width: context.px(64),
                height: double.infinity,
                color: const Color(0x99000000),
                child: Icon(icon, color: C.text, size: context.px(48)),
              ),
            ),
          ),
        ),
      );
}

/// Left/right page margin in design units, per form factor.
double gutter(BuildContext context) {
  final app = context.read<AppState>();
  return switch (app.formFactor) { FormFactor.tv => 160, FormFactor.desktop => 160, FormFactor.phone => 40 };
}

// ======================================================================
// Misc
// ======================================================================

class Loading extends StatelessWidget {
  const Loading({super.key});
  @override
  Widget build(BuildContext context) => const Center(child: CircularProgressIndicator(color: C.accent));
}

class ErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback? onRetry;
  const ErrorView(this.error, {super.key, this.onRetry});
  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_off, color: C.faint, size: context.px(64)),
          SizedBox(height: context.px(16)),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: context.px(900)),
            child: Text('$error', textAlign: TextAlign.center, style: body(context.px(24), color: C.muted)),
          ),
          if (onRetry != null) ...[
            SizedBox(height: context.px(24)),
            EmberButton(label: 'Try again', icon: Icons.refresh, onTap: onRetry, autofocus: true, kind: BtnKind.ghost),
          ],
        ]),
      );
}

/// Loads a future once (and again when [deps] change) and shows loading / error states.
class Loader<T> extends StatefulWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext, T) builder;
  final Object? deps;
  /// Shown while loading (a spinner if not given).
  final Widget? placeholder;
  const Loader({super.key, required this.load, required this.builder, this.deps, this.placeholder});
  @override
  State<Loader<T>> createState() => _LoaderState<T>();
}

class _LoaderState<T> extends State<Loader<T>> {
  late Future<T> _f;
  @override
  void initState() {
    super.initState();
    _f = widget.load();
  }

  @override
  void didUpdateWidget(covariant Loader<T> old) {
    super.didUpdateWidget(old);
    if (old.deps != widget.deps) _f = widget.load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: _f,
        builder: (context, snap) {
          if (snap.hasError) return ErrorView(snap.error!, onRetry: () => setState(() => _f = widget.load()));
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: !snap.hasData
                ? KeyedSubtree(key: const ValueKey('loading'), child: widget.placeholder ?? const Loading())
                : KeyedSubtree(key: const ValueKey('ready'), child: widget.builder(context, snap.data as T)),
          );
        },
      );
}

void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(message, style: body(context.px(22))),
    backgroundColor: C.surface3,
    behavior: SnackBarBehavior.floating,
    duration: const Duration(seconds: 3),
  ));
}

String formatRuntime(Duration? d) {
  if (d == null) return '';
  final h = d.inHours, m = d.inMinutes % 60;
  return h > 0 ? '${h}h ${m}m' : '${m}m';
}

String formatClock(Duration d) {
  final neg = d.isNegative;
  d = d.abs();
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  final body = h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}' : '$m:${s.toString().padLeft(2, '0')}';
  return neg ? '-$body' : body;
}

/// Runs [action] after [delay], cancelling any earlier pending call.
class Debouncer {
  final Duration delay;
  Timer? _t;
  Debouncer(this.delay);
  void call(VoidCallback action) {
    _t?.cancel();
    _t = Timer(delay, action);
  }

  void dispose() => _t?.cancel();
}

/// Lets the remote's / keyboard's Up and Down keys move focus out of a text field
/// (text fields otherwise keep those keys for moving the cursor).
class FieldFocusEscape extends StatelessWidget {
  final Widget child;
  const FieldFocusEscape({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(TraversalDirection.down),
          SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(TraversalDirection.up),
        },
        child: child,
      );
}


/// The small round back arrow in the top-left corner of detail pages (mouse and touch only;
/// a remote uses its Back button).
class BackArrow extends StatelessWidget {
  final VoidCallback onTap;
  const BackArrow({super.key, required this.onTap});
  @override
  Widget build(BuildContext context) => Focusable(
        onTap: onTap,
        semanticLabel: 'Back',
        scrollIntoView: false,
        builder: (context, active) => Container(
          width: context.px(64),
          height: context.px(64),
          decoration: BoxDecoration(
            color: active ? C.text : const Color(0xB32A2A2F),
            borderRadius: BorderRadius.circular(context.px(14)),
          ),
          child: Icon(Icons.arrow_back, color: active ? const Color(0xFF111111) : C.text, size: context.px(32)),
        ),
      );
}
