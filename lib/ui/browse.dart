import 'package:flutter/foundation.dart' show ValueListenable;
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
        decoration: BoxDecoration(color: active ? C.text : const Color(0x40FFFFFF), borderRadius: BorderRadius.circular(999)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, color: fg, size: context.px(compact ? 24 : 28)), SizedBox(width: context.px(8))],
            Text(
              label,
              style: body(context.px(compact ? 19 : 22), color: fg, weight: FontWeight.w600),
            ),
          ],
        ),
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
          child: Row(
            children: [
              Icon(icon, color: fg, size: context.px(26)),
              SizedBox(width: context.px(16)),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: body(context.px(21), color: fg, weight: active ? FontWeight.w600 : FontWeight.w500),
                ),
              ),
              if (progress != null)
                Container(
                  width: context.px(110),
                  height: context.px(4),
                  decoration: BoxDecoration(color: const Color(0x55888888), borderRadius: BorderRadius.circular(9)),
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: progress!.clamp(0.04, 1.0),
                    child: Container(
                      decoration: BoxDecoration(color: C.accent, borderRadius: BorderRadius.circular(9)),
                    ),
                  ),
                ),
            ],
          ),
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

  /// The big picture behind the page while this title has focus (see [Billboard]).
  final String? backdrop;

  /// Its place in a Top 10 row: the number is drawn beside the poster.
  final int? rank;
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
    this.backdrop,
    this.rank,
  });
}

/// A titled row of posters. The focused poster widens into the title's picture, and its details
/// appear under the row; the row keeps the focused poster at its left edge.
class PosterRow extends StatefulWidget {
  final String title;
  final List<PosterEntry> entries;
  final bool autofocusFirst;

  /// Poster height in design pixels; inside a [Billboard] the billboard's row height is used.
  final double? height;
  const PosterRow({super.key, required this.title, required this.entries, this.autofocusFirst = false, this.height});
  @override
  State<PosterRow> createState() => _PosterRowState();
}

class _PosterRowState extends State<PosterRow> {
  final _ctrl = ScrollController();
  int? _focused;

  static const _gap = 14.0;
  static const _pad = 60.0;

  BillboardScope? get _scope => BillboardScope.maybeOf(context);
  double get _h => _scope?.rowHeight ?? widget.height ?? 420.0;
  double get _posterW => _h * 2 / 3;
  double get _wideW => _h * 16 / 9;

  /// Room for a Top 10 number beside the poster.
  double _rankW(PosterEntry e) => e.rank == null ? 0 : (e.rank! >= 10 ? _h * 0.62 : _h * 0.4);

  void _onFocus(int i, bool f) {
    if (f) {
      setState(() => _focused = i);
      _scope?.onFocus(widget.entries[i]);
      if (_ctrl.hasClients) {
        var x = 0.0;
        for (var j = 0; j < i; j++) {
          x += _posterW + _gap + _rankW(widget.entries[j]);
        }
        final target = context.px(x).clamp(0.0, _ctrl.position.maxScrollExtent + context.px(_wideW));
        _ctrl.animateTo(target, duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
      }
      // Bring the row near the top of the page (in a billboard, to the top of the rows), with
      // room for the details under it.
      Scrollable.ensureVisible(
        context,
        alignment: _scope != null ? 0 : 0.12,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
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
    // In a billboard the focused title's details are shown at the top of the page instead.
    final shown = _focused == null || _scope != null ? null : widget.entries[_focused!];
    return Padding(
      padding: EdgeInsets.only(bottom: context.px(26)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.title.isNotEmpty)
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
                  // Top-aligned, so a poster without a progress line isn't stretched to the row's height.
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: _Poster(
                      entry: widget.entries[i],
                      height: h,
                      rankW: context.px(_rankW(widget.entries[i])),
                      posterW: context.px(_posterW),
                      wideW: context.px(_wideW),
                      autofocus: widget.autofocusFirst && i == 0,
                      onFocusChange: (f) => _onFocus(i, f),
                    ),
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
                    child: SizedBox(
                      width: context.px(900),
                      child: _Details(entry: shown),
                    ),
                  ),
          ),
        ],
      ),
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
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (e.subtitle != null)
            Text(
              e.subtitle!,
              style: body(context.px(20), color: C.soft, weight: FontWeight.w600),
            ),
          if (e.note != null) Text(e.note!, style: body(context.px(21), weight: FontWeight.w700)),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        MetaDots(parts: e.meta, rating: e.rating, size: 19),
        if (e.overview != null) ...[
          SizedBox(height: context.px(6)),
          Text(
            e.overview!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: body(context.px(21), color: C.text, height: 1.3),
          ),
        ],
      ],
    );
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
        if (i > 0)
          Text(
            '·',
            style: body(context.px(size), color: C.muted, weight: FontWeight.w700),
          ),
        Text(parts[i], style: body(context.px(size), weight: FontWeight.w600)),
      ],
      if (rating != null) ...[
        if (parts.isNotEmpty)
          Text(
            '·',
            style: body(context.px(size), color: C.muted, weight: FontWeight.w700),
          ),
        Badge2(rating!),
      ],
    ],
  );
}

class _Poster extends StatelessWidget {
  final PosterEntry entry;
  final double height;
  final double rankW;
  final double posterW;
  final double wideW;
  final bool autofocus;
  final ValueChanged<bool> onFocusChange;
  const _Poster({
    required this.entry,
    required this.height,
    this.rankW = 0,
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
            child: Stack(
              fit: StackFit.expand,
              children: [
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
                        ? NetImage(
                            e.logo,
                            fit: BoxFit.contain,
                            alignment: Alignment.bottomLeft,
                            loading: const SizedBox.shrink(),
                            fallback: _wideTitle(context),
                          )
                        : _wideTitle(context),
                  ),
                if (e.badge != null)
                  Positioned(
                    top: context.px(10),
                    right: context.px(10),
                    child: Pill(e.badge!, bg: e.badgeAlt ? C.text : C.accent, fg: e.badgeAlt ? const Color(0xFF141414) : C.accentInk),
                  ),
              ],
            ),
          ),
        );
        if (e.rank != null) {
          // Top 10: a big outlined number beside the poster.
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SizedBox(
                width: rankW,
                height: height,
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: Text(
                    '${e.rank}',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                    style: display(height * 0.72, height: 0.82).copyWith(
                      letterSpacing: -height * 0.05,
                      foreground: Paint()
                        ..style = PaintingStyle.stroke
                        ..strokeWidth = context.px(4)
                        ..color = active ? C.text : const Color(0xFF6E6A64),
                    ),
                  ),
                ),
              ),
              card,
            ],
          );
        }
        if (e.progress == null) return card;
        // Progress sits as a thin line under the picture rather than on it.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
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
                child: Container(
                  decoration: BoxDecoration(color: C.accent, borderRadius: BorderRadius.circular(4)),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _wideTitle(BuildContext context) => Align(
    alignment: Alignment.bottomLeft,
    child: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: display(context.px(40), height: 1.0)),
  );
}

/// Lets the [PosterRow]s inside a [Billboard] tell it which title has focus.
class BillboardScope extends InheritedWidget {
  final ValueChanged<PosterEntry> onFocus;
  final double rowHeight;
  const BillboardScope({super.key, required this.onFocus, required this.rowHeight, required super.child});

  static BillboardScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<BillboardScope>();

  @override
  bool updateShouldNotify(BillboardScope old) => old.rowHeight != rowHeight;
}

/// Browsing on TV and desktop, laid out like the big streaming apps: the picture of the title in
/// focus fills the top of the screen, with its logo, details and story at the left; the rows sit
/// underneath, one at a time, the focused row at the top of its area. Until a row has focus, the
/// [featured] title is shown with its buttons ([actions]) and its muted preview ([preview]).
class Billboard extends StatefulWidget {
  final PosterEntry? featured;
  final List<Widget> actions;
  final Widget Function(ValueListenable<bool> active)? preview;

  /// Shown above the details, e.g. a page title with a genre picker.
  final Widget? header;
  final List<Widget> rows;
  const Billboard({super.key, required this.rows, this.featured, this.actions = const [], this.preview, this.header});

  @override
  State<Billboard> createState() => _BillboardState();
}

class _BillboardState extends State<Billboard> {
  PosterEntry? _spot;
  final _rows = ScrollController();
  final _featuredActive = ValueNotifier<bool>(true);

  @override
  void dispose() {
    _rows.dispose();
    _featuredActive.dispose();
    super.dispose();
  }

  void _focusRows(PosterEntry e) {
    if (identical(e, _spot)) return;
    _featuredActive.value = false;
    setState(() => _spot = e);
  }

  void _backToFeatured() {
    _featuredActive.value = true;
    setState(() => _spot = null);
    if (_rows.hasClients) _rows.animateTo(0, duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final e = _spot ?? widget.featured;
    final topH = size.height * 0.56;
    final picture = e?.backdrop ?? e?.wide;
    final showFeatured = _spot == null && widget.featured != null;
    final pad = context.px(60);

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          right: 0,
          width: size.width * 0.78,
          height: size.height * 0.8,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            child: KeyedSubtree(
              key: ValueKey('${picture ?? ''}-$showFeatured'),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (picture != null) NetImage(picture, alignment: Alignment.topCenter, fallback: const SizedBox.shrink()),
                  if (showFeatured && widget.preview != null) widget.preview!(_featuredActive),
                ],
              ),
            ),
          ),
        ),
        // The picture fades into the page at the left and the bottom.
        Positioned(
          top: 0,
          right: 0,
          width: size.width * 0.78,
          height: size.height * 0.8,
          child: const IgnorePointer(
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [C.bg, Color(0xB30A0A0B), Color(0x000A0A0B)], stops: [0, 0.3, 0.65]),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [C.bg, Color(0x990A0A0B), Color(0x000A0A0B)],
                      stops: [0, 0.3, 0.6],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: topH,
          child: Padding(
            padding: EdgeInsets.fromLTRB(pad, context.px(110), pad, context.px(20)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.header != null) widget.header!,
                const Spacer(),
                if (e != null)
                  SizedBox(
                    width: context.px(820),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      layoutBuilder: (current, previous) => Stack(alignment: Alignment.bottomLeft, children: [...previous, ?current]),
                      child: KeyedSubtree(
                        key: ValueKey('${e.title}|${e.subtitle}|${e.poster}'),
                        child: _SpotDetails(entry: e),
                      ),
                    ),
                  ),
                // The featured buttons stay in place (hidden while a row has focus), so moving up out
                // of the rows lands on them and brings the featured title back.
                if (widget.featured != null && widget.actions.isNotEmpty) ...[
                  SizedBox(height: context.px(22)),
                  AnimatedOpacity(
                    opacity: showFeatured ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      onFocusChange: (f) {
                        if (f) _backToFeatured();
                      },
                      child: FocusTraversalGroup(
                        child: Wrap(spacing: context.px(14), children: widget.actions),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: topH,
          bottom: 0,
          child: BillboardScope(
            onFocus: _focusRows,
            rowHeight: (size.height - topH) / scaleOf(context) * 0.62,
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onFocusChange: (f) {
                // Moving up out of the rows brings the featured title back.
                if (!f && widget.featured != null && widget.actions.isEmpty) _backToFeatured();
              },
              child: ListView(
                controller: _rows,
                scrollCacheExtent: const ScrollCacheExtent.pixels(4000),
                padding: EdgeInsets.only(top: context.px(8), bottom: size.height * 0.5),
                clipBehavior: Clip.hardEdge,
                children: widget.rows,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The logo (or name), details and story of the title shown at the top of a [Billboard].
class _SpotDetails extends StatelessWidget {
  final PosterEntry entry;
  const _SpotDetails({required this.entry});

  @override
  Widget build(BuildContext context) {
    final e = entry;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (e.logo != null)
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: context.px(150), maxWidth: context.px(560)),
            child: NetImage(
              e.logo,
              fit: BoxFit.contain,
              alignment: Alignment.centerLeft,
              loading: SizedBox(height: context.px(120)),
              fallback: Text(e.title, maxLines: 2, style: display(context.px(76))),
            ),
          )
        else
          Text(e.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: display(context.px(76))),
        SizedBox(height: context.px(16)),
        if (e.subtitle != null || e.note != null) ...[
          if (e.subtitle != null) Text(e.subtitle!, style: body(context.px(22), weight: FontWeight.w700)),
          if (e.note != null)
            Text(
              e.note!,
              style: body(context.px(21), color: C.soft, weight: FontWeight.w600),
            ),
          if (e.progress != null) ...[
            SizedBox(height: context.px(10)),
            Container(
              width: context.px(320),
              height: context.px(5),
              decoration: BoxDecoration(color: const Color(0x55A0A0A0), borderRadius: BorderRadius.circular(4)),
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: e.progress!.clamp(0.03, 1.0),
                child: Container(
                  decoration: BoxDecoration(color: C.accent, borderRadius: BorderRadius.circular(4)),
                ),
              ),
            ),
          ],
        ] else
          MetaDots(parts: e.meta, rating: e.rating, size: 20),
        if ((e.overview ?? '').isNotEmpty) ...[
          SizedBox(height: context.px(12)),
          Text(
            e.overview!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: body(context.px(22), color: C.soft, height: 1.4),
          ),
        ],
      ],
    );
  }
}
