/// Title cards, tiles and horizontally scrolling rows of them.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'buttons.dart';
import 'focusable.dart';
import 'images.dart';
import 'scale.dart';
import 'theme.dart';

/// A placeholder that shows a title on a coloured card when there is no artwork.
class TitleCard extends StatelessWidget {
  final String title;
  final bool label;
  const TitleCard(this.title, {super.key, this.label = true});
  @override
  Widget build(BuildContext context) {
    final hue = (title.hashCode % 360).abs().toDouble();
    return Container(
      color: HSLColor.fromAHSL(1, hue, 0.35, 0.22).toColor(),
      alignment: Alignment.bottomLeft,
      padding: EdgeInsets.all(context.px(18)),
      child: label
          ? Text(title, maxLines: 3, overflow: TextOverflow.ellipsis, style: display(context.px(26), height: 1.0))
          : null,
    );
  }
}

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
            child: Stack(
              fit: StackFit.expand,
              children: [
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
                    child: Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: body(context.px(18), color: Colors.white, weight: FontWeight.w600),
                    ),
                  ),
                if (showTitle && imageUrl != null)
                  Positioned(
                    left: context.px(18),
                    right: context.px(18),
                    bottom: context.px(progress != null ? 22 : 16),
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: body(context.px(25), weight: FontWeight.w700),
                    ),
                  ),
                if (badge != null)
                  Positioned(
                    top: context.px(12),
                    right: context.px(12),
                    child: Pill(
                      badge!,
                      bg: badgeAlt ? C.text : C.accent,
                      fg: badgeAlt ? const Color(0xFF141414) : C.accentInk,
                    ),
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
                      child: FractionallySizedBox(
                        widthFactor: progress!.clamp(0.02, 1.0),
                        child: Container(color: C.accent),
                      ),
                    ),
                  ),
              ],
            ),
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

  const MediaRow({
    super.key,
    required this.title,
    required this.children,
    required this.tileHeight,
    this.note,
    this.inset,
  });

  @override
  State<MediaRow> createState() => _MediaRowState();
}

class _MediaRowState extends State<MediaRow> {
  final _ctrl = ScrollController();
  bool _hover = false;

  void _page(int dir) {
    final w = MediaQuery.sizeOf(context).width * 0.8;
    _ctrl.animateTo(
      (_ctrl.offset + dir * w).clamp(0, _ctrl.position.maxScrollExtent),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
    );
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.title.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(left: pad, right: pad, bottom: context.px(6)),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.end,
                  spacing: context.px(16),
                  children: [
                    Text(widget.title, style: body(context.px(30), weight: FontWeight.w700)),
                    if (widget.note != null) Text(widget.note!, style: body(context.px(21), color: C.faint)),
                  ],
                ),
              ),
            SizedBox(
              height: h,
              child: Stack(
                children: [
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
                ],
              ),
            ),
          ],
        ),
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
