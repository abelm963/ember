import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import 'theme.dart';
import 'widgets.dart';

// The TV / desktop browsing pieces: pill buttons, the vertical action list on title pages, and
// poster rows whose focused poster widens into a picture with its details underneath.

/// A rounded button: translucent when idle, white when focused or hovered.
class PillButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final bool autofocus;
  final bool compact;
  final bool scrollIntoView;
  const PillButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.autofocus = false,
    this.compact = false,
    this.scrollIntoView = true,
  });

  @override
  Widget build(BuildContext context) => Focusable(
        onTap: onTap,
        autofocus: autofocus,
        semanticLabel: label,
        scrollIntoView: scrollIntoView,
        builder: (context, active) {
          final fg = active ? const Color(0xFF111111) : Colors.white;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            height: context.px(compact ? 48 : 56),
            padding: EdgeInsets.symmetric(horizontal: context.px(compact ? 20 : 26)),
            decoration: BoxDecoration(
              color: active ? C.text : const Color(0x40FFFFFF),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[Icon(icon, color: fg, size: context.px(compact ? 24 : 28)), SizedBox(width: context.px(8))],
              Text(label, style: body(context.px(compact ? 19 : 22), color: fg, weight: FontWeight.w600)),
            ]),
          );
        },
      );
}

/// One line of the action list on a title page (Play, More episodes, My List…): plain text with an
/// icon, which becomes a white pill when focused.
class ActionItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool autofocus;
  /// Shows a small progress bar inside the pill (for Resume).
  final double? progress;
  final double width;
  const ActionItem({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.autofocus = false,
    this.progress,
    this.width = 520,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: context.px(6)),
        child: Focusable(
          onTap: onTap,
          autofocus: autofocus,
          semanticLabel: label,
          builder: (context, active) {
            final fg = active ? const Color(0xFF111111) : C.soft;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: context.px(width),
              height: context.px(54),
              padding: EdgeInsets.symmetric(horizontal: context.px(22)),
              decoration: BoxDecoration(color: active ? C.text : Colors.transparent, borderRadius: BorderRadius.circular(999)),
              child: Row(children: [
                Icon(icon, color: fg, size: context.px(26)),
                SizedBox(width: context.px(16)),
                Expanded(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: body(context.px(21), color: fg, weight: active ? FontWeight.w600 : FontWeight.w500)),
                ),
                if (progress != null)
                  Container(
                    width: context.px(110),
                    height: context.px(4),
                    decoration: BoxDecoration(color: const Color(0x55888888), borderRadius: BorderRadius.circular(9)),
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: progress!.clamp(0.04, 1.0),
                      child: Container(decoration: BoxDecoration(color: C.accent, borderRadius: BorderRadius.circular(9))),
                    ),
                  ),
              ]),
            );
          },
        ),
      );
}

/// What a [PosterRow] shows for one title.
class PosterEntry {
  final String title;
  final String? poster;
  final String? wide;
  final String? logo;
  /// "S1 E3 · The Climb": shown under the focused poster instead of the meta line.
  final String? subtitle;
  /// "15m left"
  final String? note;
  final double? progress;
  final List<String> meta;
  final String? rating;
  final String? overview;
  final String? badge;
  final bool badgeAlt;
  final VoidCallback onTap;
  const PosterEntry({
    required this.title,
    required this.onTap,
    this.poster,
    this.wide,
    this.logo,
    this.subtitle,
    this.note,
    this.progress,
    this.meta = const [],
    this.rating,
    this.overview,
    this.badge,
    this.badgeAlt = false,
  });
}

/// A titled row of posters. The focused poster widens into the title's picture, and its details
/// appear under the row; the row keeps the focused poster at its left edge.
class PosterRow extends StatefulWidget {
  final String title;
  final List<PosterEntry> entries;
  final bool autofocusFirst;
  const PosterRow({super.key, required this.title, required this.entries, this.autofocusFirst = false});
  @override
  State<PosterRow> createState() => _PosterRowState();
}

class _PosterRowState extends State<PosterRow> {
  final _ctrl = ScrollController();
  int? _focused;

  static const _h = 420.0;
  static const _gap = 14.0;
  static const _pad = 60.0;

  double get _posterW => _h * 2 / 3;
  double get _wideW => _h * 16 / 9;

  void _onFocus(int i, bool f) {
    if (f) {
      setState(() => _focused = i);
      if (_ctrl.hasClients) {
        final target = (context.px(_posterW + _gap) * i).clamp(0.0, _ctrl.position.maxScrollExtent + context.px(_wideW));
        _ctrl.animateTo(target, duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
      }
      // Bring the row near the top of the page, with room for the details under it.
      Scrollable.ensureVisible(context, alignment: 0.12, duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
    } else if (_focused == i) {
      setState(() => _focused = null);
    }
  }

  bool get _hasProgress => widget.entries.any((e) => e.progress != null);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) return const SizedBox.shrink();
    final h = context.px(_h);
    final shown = _focused == null ? null : widget.entries[_focused!];
    return Padding(
      padding: EdgeInsets.only(bottom: context.px(26)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: EdgeInsets.only(left: context.px(_pad), bottom: context.px(10)),
          child: Text(widget.title, style: body(context.px(23), weight: FontWeight.w700)),
        ),
        SizedBox(
          height: h + context.px(_hasProgress ? 16 : 4),
          child: FocusTraversalGroup(
            child: ListView.builder(
              controller: _ctrl,
              scrollDirection: Axis.horizontal,
              scrollCacheExtent: const ScrollCacheExtent.pixels(2500),
              clipBehavior: Clip.none,
              padding: EdgeInsets.symmetric(horizontal: context.px(_pad)),
              itemCount: widget.entries.length,
              itemBuilder: (context, i) => Padding(
                padding: EdgeInsets.only(right: context.px(_gap)),
                child: _Poster(
                  entry: widget.entries[i],
                  height: h,
                  posterW: context.px(_posterW),
                  wideW: context.px(_wideW),
                  autofocus: widget.autofocusFirst && i == 0,
                  onFocusChange: (f) => _onFocus(i, f),
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topLeft,
          child: shown == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: EdgeInsets.fromLTRB(context.px(_pad), context.px(10), context.px(_pad), 0),
                  child: SizedBox(width: context.px(900), child: _Details(entry: shown)),
                ),
        ),
      ]),
    );
  }
}

class _Details extends StatelessWidget {
  final PosterEntry entry;
  const _Details({required this.entry});
  @override
  Widget build(BuildContext context) {
    final e = entry;
    if (e.subtitle != null || e.note != null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (e.subtitle != null) Text(e.subtitle!, style: body(context.px(20), color: C.soft, weight: FontWeight.w600)),
        if (e.note != null) Text(e.note!, style: body(context.px(21), weight: FontWeight.w700)),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      MetaDots(parts: e.meta, rating: e.rating, size: 19),
      if (e.overview != null) ...[
        SizedBox(height: context.px(6)),
        Text(e.overview!, maxLines: 3, overflow: TextOverflow.ellipsis, style: body(context.px(21), color: C.text, height: 1.3)),
      ],
    ]);
  }
}

/// "Series · Drama · 2026 · 5 Seasons" followed by the age rating in a small box.
class MetaDots extends StatelessWidget {
  final List<String> parts;
  final String? rating;
  final double size;
  const MetaDots({super.key, required this.parts, this.rating, this.size = 22});
  @override
  Widget build(BuildContext context) => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: context.px(10),
        runSpacing: context.px(6),
        children: [
          for (var i = 0; i < parts.length; i++) ...[
            if (i > 0) Text('·', style: body(context.px(size), color: C.muted, weight: FontWeight.w700)),
            Text(parts[i], style: body(context.px(size), weight: FontWeight.w600)),
          ],
          if (rating != null) ...[
            if (parts.isNotEmpty) Text('·', style: body(context.px(size), color: C.muted, weight: FontWeight.w700)),
            Badge2(rating!),
          ],
        ],
      );
}

class _Poster extends StatelessWidget {
  final PosterEntry entry;
  final double height;
  final double posterW;
  final double wideW;
  final bool autofocus;
  final ValueChanged<bool> onFocusChange;
  const _Poster({
    required this.entry,
    required this.height,
    required this.posterW,
    required this.wideW,
    required this.autofocus,
    required this.onFocusChange,
  });

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final r = BorderRadius.circular(context.px(10));
    return Focusable(
      onTap: e.onTap,
      autofocus: autofocus,
      scrollIntoView: false,
      onFocusChange: onFocusChange,
      semanticLabel: e.title,
      builder: (context, active) {
        final wide = active && (e.wide ?? e.poster) != null;
        final card = AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          width: wide ? wideW : posterW,
          height: height,
          decoration: BoxDecoration(
            borderRadius: r,
            border: Border.all(color: active ? C.text : Colors.transparent, width: context.px(3)),
          ),
          child: ClipRRect(
            borderRadius: r,
            child: Stack(fit: StackFit.expand, children: [
              if (wide)
                NetImage(e.wide ?? e.poster, fallback: TitleCard(e.title, label: false))
              else
                NetImage(e.poster ?? e.wide, fallback: TitleCard(e.title)),
              if (wide)
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomLeft,
                      end: Alignment(0.3, -0.2),
                      colors: [Color(0xCC000000), Color(0x00000000)],
                    ),
                  ),
                ),
              if (wide)
                Positioned(
                  left: context.px(22),
                  bottom: context.px(20),
                  width: wideW * 0.5,
                  height: height * 0.32,
                  child: e.logo != null
                      ? NetImage(e.logo,
                          fit: BoxFit.contain,
                          alignment: Alignment.bottomLeft,
                          loading: const SizedBox.shrink(),
                          fallback: _wideTitle(context))
                      : _wideTitle(context),
                ),
              if (e.badge != null)
                Positioned(
                  top: context.px(10),
                  right: context.px(10),
                  child: Pill(e.badge!, bg: e.badgeAlt ? C.text : C.accent, fg: e.badgeAlt ? const Color(0xFF141414) : C.accentInk),
                ),
            ]),
          ),
        );
        if (e.progress == null) return card;
        // Progress sits as a thin line under the picture rather than on it.
        return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          card,
          SizedBox(height: context.px(8)),
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            width: wide ? wideW : posterW,
            height: context.px(4),
            decoration: BoxDecoration(color: const Color(0x55A0A0A0), borderRadius: BorderRadius.circular(4)),
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: e.progress!.clamp(0.03, 1.0),
              child: Container(decoration: BoxDecoration(color: C.accent, borderRadius: BorderRadius.circular(4))),
            ),
          ),
        ]);
      },
    );
  }

  Widget _wideTitle(BuildContext context) => Align(
        alignment: Alignment.bottomLeft,
        child: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: display(context.px(40), height: 1.0)),
      );
}
