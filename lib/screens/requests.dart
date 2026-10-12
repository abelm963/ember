import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:provider/provider.dart';

import '../api/seerr.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'nav.dart';
import 'settings.dart';

class _Row {
  final SeerrRequest req;
  final SeerrMedia? media;
  _Row(this.req, this.media);
}

/// Every Seerr request on the server, with approve / decline for admins.
class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key});
  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen> {
  String _filter = 'All';
  int _reload = 0;
  static final Map<String, SeerrMedia> _cache = {};

  Future<List<_Row>> _load(AppState app) async {
    final reqs = await app.seerr!.requests(take: 40);
    return Future.wait(reqs.map((r) async {
      if (r.tmdbId == null) return _Row(r, null);
      final key = '${r.mediaType}/${r.tmdbId}';
      try {
        _cache[key] ??= await app.seerr!.details(r.mediaType, r.tmdbId!);
      } catch (_) {}
      return _Row(r, _cache[key]);
    }));
  }

  Future<void> _act(Future<void> Function() f) async {
    try {
      await f();
      setState(() => _reload++);
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pad = context.px(gutter(context));
    if (!app.seerrConfigured) {
      return Padding(
        padding: EdgeInsets.fromLTRB(pad, context.px(app.isTv || app.isDesktop ? 60 : 30), pad, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Requests', style: display(context.px(72))),
          SizedBox(height: context.px(24)),
          Text(
              app.seerrUrl == null
                  ? 'Connect Seerr to request movies and shows that are not on your server, and to see everyone\'s requests here.'
                  : 'Ember couldn\'t sign in to Seerr${app.seerrError != null ? ':\n${app.seerrError}' : '.'}',
              style: body(context.px(25), color: C.muted, height: 1.5)),
          SizedBox(height: context.px(28)),
          if (app.seerrUrl != null) ...[
            EmberButton(label: 'Try again', icon: Icons.refresh, kind: BtnKind.accent, autofocus: app.isTv, onTap: () => app.refreshSeerr()),
            SizedBox(height: context.px(14)),
          ],
          EmberButton(
            label: app.seerrUrl == null ? 'Set up Seerr' : 'Seerr settings',
            icon: Icons.settings_outlined,
            kind: app.seerrUrl == null ? BtnKind.accent : BtnKind.ghost,
            autofocus: app.isTv && app.seerrUrl == null,
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const Scaffold(body: SafeArea(child: SettingsScreen(initialCategory: 'Seerr requests'))))),
          ),
        ]),
      );
    }
    return Loader<List<_Row>>(
      deps: '$_reload-${app.revision}',
      load: () => _load(app),
      builder: (context, rows) {
        final shown = rows.where((r) => _filter == 'All' || r.req.filterKey == _filter).toList();
        return ListView(
          scrollCacheExtent: const ScrollCacheExtent.pixels(3000),
          padding: EdgeInsets.fromLTRB(pad, context.px(app.isTv ? 60 : 30), pad, context.px(80)),
          children: [
            Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: context.px(24), children: [
              Text('Requests', style: display(context.px(72))),
              Padding(
                padding: EdgeInsets.only(bottom: context.px(8)),
                child: Text('From Seerr · everyone on this server', style: body(context.px(22), color: C.faint)),
              ),
            ]),
            SizedBox(height: context.px(24)),
            FocusTraversalGroup(
              child: Wrap(spacing: context.px(12), runSpacing: context.px(12), children: [
                for (final f in const ['All', 'Pending', 'Approved', 'Available', 'Declined'])
                  Chip2(label: f, selected: _filter == f, onTap: () => setState(() => _filter = f)),
              ]),
            ),
            SizedBox(height: context.px(28)),
            if (shown.isEmpty) Text('No requests here.', style: body(context.px(24), color: C.faint)),
            for (final r in shown) _RequestRow(row: r, canManage: app.canManageRequests, onAct: _act),
          ],
        );
      },
    );
  }
}

class _RequestRow extends StatelessWidget {
  final _Row row;
  final bool canManage;
  final Future<void> Function(Future<void> Function()) onAct;
  const _RequestRow({required this.row, required this.canManage, required this.onAct});

  (Color, Color) _colors(String label) => switch (label) {
        'Pending approval' => (const Color(0xFF3A3016), C.warn),
        'Downloading' => (C.accentDark, const Color(0xFFFF9A5C)),
        'Available' || 'Partly available' => (const Color(0xFF1B3322), C.good),
        'Declined' => (const Color(0xFF3A1C1C), C.bad),
        _ => (const Color(0xFF1B2B40), C.blue),
      };

  static String _left(DateTime eta) {
    final d = eta.difference(DateTime.now());
    if (d.inSeconds <= 60) return 'almost done';
    if (d.inMinutes < 60) return 'about ${d.inMinutes} min left';
    if (d.inHours < 24) return 'about ${d.inHours} h ${d.inMinutes % 60} min left';
    return 'about ${d.inDays} days left';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final r = row.req;
    final m = row.media;
    final (bg, fg) = _colors(r.label);
    final when = r.createdAt == null ? '' : _ago(r.createdAt!);
    final what = [
      m?.isTv == true || r.mediaType == 'tv' ? 'Series' : 'Movie',
      if (r.seasonNumbers.isNotEmpty) _seasons(r.seasonNumbers),
      r.is4k ? '4K' : 'HD',
      r.requestedBy,
      when,
    ].where((s) => s.isNotEmpty).join(' · ');
    final progress = r.downloadProgress;
    final eta = r.downloadEta;

    final thumb = ClipRRect(
      borderRadius: BorderRadius.circular(context.px(8)),
      child: SizedBox(
        width: context.px(192),
        height: context.px(108),
        child: NetImage(m?.backdropUrl, fallback: TitleCard(m?.title ?? '')),
      ),
    );

    final status = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Container(
        height: context.px(40),
        padding: EdgeInsets.symmetric(horizontal: context.px(16)),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(r.label, style: body(context.px(19), color: fg, weight: FontWeight.w700)),
      ),
      if (progress != null) ...[
        SizedBox(height: context.px(12)),
        Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: context.px(app.isPhone ? 200 : 360),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(context.px(4)),
              child: LinearProgressIndicator(
                  value: progress, minHeight: context.px(8), backgroundColor: C.surface3, color: C.accent),
            ),
          ),
          SizedBox(width: context.px(16)),
          Flexible(
            child: Text('${(progress * 100).round()}%${eta != null ? ' · ${_left(eta)}' : ''}',
                overflow: TextOverflow.ellipsis, style: body(context.px(20), color: C.muted)),
          ),
        ]),
      ],
    ]);

    final info = Focusable(
      onTap: m == null ? null : () => openSeerr(context, m),
      semanticLabel: m?.title ?? 'Request',
      builder: (context, active) => Row(children: [
        thumb,
        SizedBox(width: context.px(30)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(m?.title ?? 'Unknown title',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: body(context.px(30), weight: FontWeight.w700, color: active ? C.accent : C.text)),
            SizedBox(height: context.px(8)),
            Text(what, maxLines: 2, style: body(context.px(21), color: C.faint)),
            if (app.isPhone) ...[SizedBox(height: context.px(12)), status],
          ]),
        ),
      ]),
    );

    return Container(
      margin: EdgeInsets.only(bottom: context.px(12)),
      padding: EdgeInsets.symmetric(horizontal: context.px(22), vertical: context.px(16)),
      decoration: BoxDecoration(color: const Color(0xFF121214), borderRadius: BorderRadius.circular(context.px(16))),
      child: FocusTraversalGroup(
        child: app.isPhone
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [info, _actions(context)])
            : Row(children: [
                SizedBox(width: context.px(192 + 30 + 520), child: info),
                SizedBox(width: context.px(30)),
                Expanded(child: Align(alignment: Alignment.centerLeft, child: status)),
                _actions(context),
              ]),
      ),
    );
  }

  static String _seasons(List<int> s) {
    final sorted = [...s]..sort();
    final run = sorted.length > 1 && sorted.last - sorted.first == sorted.length - 1;
    if (sorted.length == 1) return 'Season ${sorted.first}';
    return run ? 'Seasons ${sorted.first}–${sorted.last}' : 'Seasons ${sorted.join(', ')}';
  }

  Widget _actions(BuildContext context) {
    final app = context.read<AppState>();
    final r = row.req;
    final playable = r.jellyfinId != null && (r.label == 'Available' || r.label == 'Partly available');
    final buttons = <Widget>[
      if (canManage && r.status == 1) ...[
        EmberButton(label: 'Approve', kind: BtnKind.accent, compact: true, onTap: () => onAct(() => app.seerr!.approve(r.id))),
        EmberButton(label: 'Decline', kind: BtnKind.secondary, compact: true, onTap: () => onAct(() => app.seerr!.decline(r.id))),
      ],
      if (playable)
        EmberButton(
          label: 'Play',
          icon: Icons.play_arrow_rounded,
          kind: BtnKind.primary,
          compact: true,
          onTap: () async {
            try {
              final item = await app.jf!.item(r.jellyfinId!);
              if (!context.mounted) return;
              if (item.isSeries) {
                await playSeries(context, app.jf!, item);
              } else {
                await play(context, item);
              }
            } catch (e) {
              if (context.mounted) toast(context, 'Couldn\'t open it on your server: $e');
            }
          },
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: app.isPhone ? context.px(14) : 0),
      child: Wrap(spacing: context.px(12), children: buttons),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 2) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    if (d.inDays < 14) return '${d.inDays} days ago';
    return '${(d.inDays / 7).floor()} weeks ago';
  }
}
