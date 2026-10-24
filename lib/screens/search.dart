import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:provider/provider.dart';

import '../api/jellyfin.dart';
import '../api/seerr.dart';
import '../platform.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'nav.dart';

/// One search box, two kinds of result: what's on the server, and (from Seerr) what isn't yet.
/// Typing uses each platform's own keyboard: the physical keyboard on Windows, the
/// on-screen keyboard (and voice dictation) on Apple TV, Android TV and phones.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _q = TextEditingController();
  final _debounce = Debouncer(const Duration(milliseconds: 400));
  String _term = '';
  List<JfItem> _lib = [];
  List<SeerrMedia> _ext = [];
  bool _busy = false;
  int _seq = 0;

  @override
  void dispose() {
    _debounce.dispose();
    super.dispose();
  }

  void _changed(String v) => _debounce(() => _run(v.trim()));

  Future<void> _run(String term) async {
    final app = context.read<AppState>();
    final seq = ++_seq;
    setState(() {
      _term = term;
      _busy = term.isNotEmpty;
    });
    if (term.isEmpty) {
      setState(() {
        _lib = [];
        _ext = [];
      });
      return;
    }
    final lib = app.jf!.search(term).catchError((_) => <JfItem>[]);
    final ext = app.seerrConfigured ? app.seerr!.search(term).catchError((_) => <SeerrMedia>[]) : Future.value(<SeerrMedia>[]);
    final r = await Future.wait<Object>([lib, ext]);
    if (seq != _seq || !mounted) return;
    final libItems = r[0] as List<JfItem>;
    final libTmdb = libItems.map((i) => i.tmdbId).whereType<String>().toSet();
    setState(() {
      _busy = false;
      _lib = libItems;
      _ext = (r[1] as List<SeerrMedia>).where((m) => !m.isAvailable && !libTmdb.contains('${m.id}')).toList();
    });
  }

  void _key(String k) {
    final t = _q.text;
    final next = k == '⌫' ? (t.isEmpty ? t : t.substring(0, t.length - 1)) : t + k;
    _q.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: next.length));
    _changed(next);
  }

  // On Apple TV the box only shows what the on-screen keyboard typed: tvOS's own keyboard would
  // leave the remote stuck in it.
  Widget _field(BuildContext context, AppState app) => ExcludeFocus(
        excluding: isAppleTv,
        child: FieldFocusEscape(
        child: TextField(
          controller: _q,
          autofocus: !app.isTv,
          onChanged: _changed,
          onSubmitted: (v) => _run(v.trim()),
          textInputAction: TextInputAction.search,
          style: body(context.px(44), weight: FontWeight.w700),
          decoration: InputDecoration(
            hintText: app.isPhone ? 'Titles, people, genres' : 'Search',
            hintStyle: body(context.px(40), color: C.faint, weight: FontWeight.w600),
            prefixIcon: app.isPhone ? Icon(Icons.search, color: C.faint, size: context.px(44)) : null,
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: C.surface3, width: context.px(3))),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: C.accent, width: context.px(3))),
          ),
        ),
        ),
      );

  /// The on-screen keyboard from the design, so a remote can type without the system keyboard.
  Widget _keyboard(BuildContext context, AppState app) {
    const keys = 'abcdefghijklmnopqrstuvwxyz1234567890';
    Widget key(String label, String value, {bool wide = false, bool first = false}) => Focusable(
          onTap: () => _key(value),
          autofocus: first && app.isTv,
          semanticLabel: label,
          scrollIntoView: false,
          builder: (context, active) => Container(
            height: context.px(60),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? C.text : (wide ? C.surface : Colors.transparent),
              borderRadius: BorderRadius.circular(context.px(10)),
            ),
            child: Text(label, style: body(context.px(28), weight: FontWeight.w600, color: active ? const Color(0xFF111111) : C.muted)),
          ),
        );
    return FocusTraversalGroup(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GridView.count(
          crossAxisCount: 6,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: context.px(6),
          crossAxisSpacing: context.px(6),
          childAspectRatio: 1.25,
          children: [for (var i = 0; i < keys.length; i++) key(keys[i], keys[i], first: i == 0)],
        ),
        SizedBox(height: context.px(10)),
        Row(children: [
          Expanded(child: key('Space', ' ', wide: true)),
          SizedBox(width: context.px(10)),
          Expanded(child: key('Delete', '⌫', wide: true)),
        ]),
        SizedBox(height: context.px(22)),
        Row(children: [
          Icon(app.isTv ? Icons.mic_none : Icons.keyboard_outlined, color: C.faint, size: context.px(28)),
          SizedBox(width: context.px(12)),
          Expanded(
            child: Text(app.isTv ? 'Hold the voice button on your remote to dictate' : 'You can also just type on your keyboard',
                style: body(context.px(21), color: C.faint)),
          ),
        ]),
      ]),
    );
  }

  List<Widget> _results(BuildContext context, AppState app, double tileW) {
    final jf = app.jf!;
    return [
      if (_busy) const Loading(),
      if (!_busy && _term.isNotEmpty && _lib.isEmpty && _ext.isEmpty)
        Text('Nothing found for "$_term".', style: body(context.px(26), color: C.muted)),
      if (_term.isEmpty && !_busy)
        Text(app.seerrConfigured ? 'Find anything in your library, or anything to request.' : 'Find anything in your library.',
            style: body(context.px(24), color: C.faint)),
      if (_lib.isNotEmpty) ...[
        Text('In your library', style: body(context.px(30), weight: FontWeight.w700)),
        SizedBox(height: context.px(20)),
        Wrap(spacing: context.px(24), runSpacing: context.px(28), children: [
          for (final it in _lib)
            MediaTile(title: it.name, imageUrl: jf.landscapeImage(it), width: tileW, onTap: () => openItem(context, it)),
        ]),
        SizedBox(height: context.px(44)),
      ],
      if (_ext.isNotEmpty) ...[
        Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: context.px(16), children: [
          Text('Not in your library', style: body(context.px(30), weight: FontWeight.w700)),
          Text('Open one to preview it, then request', style: body(context.px(21), color: C.faint)),
        ]),
        SizedBox(height: context.px(20)),
        Wrap(spacing: context.px(24), runSpacing: context.px(28), children: [
          for (final m in _ext)
            MediaTile(
              title: m.title,
              imageUrl: m.backdropUrl ?? m.posterUrl,
              width: tileW,
              badge: m.isRequested ? 'Requested' : 'Not on server',
              badgeAlt: m.isRequested,
              onTap: () => openSeerr(context, m),
            ),
        ]),
      ],
      if (_term.isEmpty && !app.seerrConfigured) ...[
        SizedBox(height: context.px(20)),
        Text('Connect Seerr in Settings to also find titles that are not on your server.',
            style: body(context.px(22), color: C.faint)),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pad = context.px(gutter(context));
    if (app.isPhone) {
      return ListView(
        scrollCacheExtent: const ScrollCacheExtent.pixels(3000),
        padding: EdgeInsets.fromLTRB(pad, context.px(30), pad, context.px(80)),
        children: [_field(context, app), SizedBox(height: context.px(36)), ..._results(context, app, 420)],
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, context.px(60), 0, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: context.px(460),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Search titles, people, genres', style: body(context.px(22), color: C.faint, weight: FontWeight.w600)),
              SizedBox(height: context.px(10)),
              _field(context, app),
              SizedBox(height: context.px(24)),
              _keyboard(context, app),
            ]),
          ),
        ),
        SizedBox(width: context.px(80)),
        Expanded(
          child: ListView(
            scrollCacheExtent: const ScrollCacheExtent.pixels(3000),
            padding: EdgeInsets.only(right: pad, bottom: context.px(80)),
            children: _results(context, app, 300),
          ),
        ),
      ]),
    );
  }
}
