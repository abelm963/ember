import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'home.dart';
import 'library.dart';
import 'mylist.dart';
import 'newhot.dart';
import 'profiles.dart';
import 'requests.dart';
import 'search.dart';
import 'settings.dart';

enum Section { search, home, shows, movies, newHot, myList, requests, settings }

class _NavEntry {
  final Section section;
  final String label;
  final IconData icon;
  const _NavEntry(this.section, this.label, this.icon);
}

const _entries = [
  _NavEntry(Section.search, 'Search', Icons.search),
  _NavEntry(Section.home, 'Home', Icons.home_outlined),
  _NavEntry(Section.shows, 'Shows', Icons.tv),
  _NavEntry(Section.movies, 'Movies', Icons.movie_outlined),
  _NavEntry(Section.newHot, 'New & Hot', Icons.local_fire_department),
  _NavEntry(Section.myList, 'My List', Icons.add),
  _NavEntry(Section.requests, 'Requests', Icons.download_outlined),
  _NavEntry(Section.settings, 'Settings', Icons.settings_outlined),
];

/// The signed-in app. The same sections are reached three different ways:
///  - TV: a side menu that expands when the remote moves onto it.
///  - Desktop: a top bar with links, search and profile, driven by the mouse.
///  - Phone: a bottom tab bar.
class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  Section _section = Section.home;
  bool _menuOpen = false;

  // After a menu pick the menu closes, and the mouse resting on it doesn't reopen it until it moves
  // away (or leaves the menu); otherwise the open menu covers the page and swallows the next click.
  bool _hoverSuppressed = false;
  Offset? _suppressedAt;
  Offset? _pointer;
  final _menuFocus = FocusNode(canRequestFocus: false, skipTraversal: true, debugLabel: 'menu');
  final _pageFocus = FocusNode(canRequestFocus: false, skipTraversal: true, debugLabel: 'page');

  void _go(Section s) => setState(() => _section = s);

  /// A section picked in the side menu: switch to it and get the menu out of the way.
  void _pick(Section s) {
    // A mouse click doesn't focus the menu; the remote or keyboard does, and then lands on the page.
    final fromRemote = _menuFocus.hasFocus;
    setState(() {
      _section = s;
      _menuOpen = false;
      _hoverSuppressed = true;
      _suppressedAt = _pointer;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !fromRemote) return;
      final target = _pageFocus.traversalDescendants.where((n) => n.canRequestFocus && !n.skipTraversal).firstOrNull;
      if (target != null) {
        target.requestFocus();
      } else {
        FocusManager.instance.primaryFocus?.unfocus();
      }
    });
  }

  void _hoverMenu(Offset at) {
    _pointer = at;
    if (_hoverSuppressed && _suppressedAt != null && (at - _suppressedAt!).distance < 48) return;
    _hoverSuppressed = false;
    if (!_menuOpen) setState(() => _menuOpen = true);
  }

  @override
  void dispose() {
    _menuFocus.dispose();
    _pageFocus.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Offer admins the one-time trailer setup shortly after they arrive.
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) offerTrailerSetup(context);
    });
  }

  Widget _page() {
    switch (_section) {
      case Section.home:
        return HomeScreen(onNavigate: _go);
      case Section.search:
        return const SearchScreen();
      case Section.shows:
        return const LibraryScreen(kind: LibraryKind.shows);
      case Section.movies:
        return const LibraryScreen(kind: LibraryKind.movies);
      case Section.newHot:
        return const NewHotScreen();
      case Section.myList:
        return const MyListScreen();
      case Section.requests:
        return const RequestsScreen();
      case Section.settings:
        return const SettingsScreen();
    }
  }

  List<_NavEntry> _visible(AppState app) => _entries;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final page = KeyedSubtree(key: ValueKey('${_section.name}-${app.revision}-${app.currentUserId}'), child: _page());

    // Back on a section other than Home returns to Home before leaving the app.
    final body = PopScope(
      canPop: _section == Section.home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _go(Section.home);
      },
      child: page,
    );

    switch (app.formFactor) {
      case FormFactor.tv:
        return Scaffold(body: _tvLayout(context, app, body));
      case FormFactor.desktop:
        // Same look as the TV design; the menu also opens when the mouse moves onto it.
        return Scaffold(body: _tvLayout(context, app, body));
      case FormFactor.phone:
        return _phoneLayout(context, app, body);
    }
  }

  // ------------------------------------------------------------------ TV

  Widget _tvLayout(BuildContext context, AppState app, Widget body) {
    final collapsed = context.px(112);
    final open = context.px(470);
    return Stack(children: [
      Positioned.fill(left: collapsed, child: FocusTraversalGroup(child: Focus(focusNode: _pageFocus, child: body))),
      // Dim the page while the menu is open, like the design.
      if (_menuOpen)
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(colors: [Color(0xF5050506), Color(0xCC050506), Color(0x66050506)]),
              ),
            ),
          ),
        ),
      Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        child: FocusTraversalGroup(
          child: MouseRegion(
            onEnter: (e) => _hoverMenu(e.position),
            onHover: (e) => _hoverMenu(e.position),
            onExit: (_) => setState(() {
              _menuOpen = false;
              _hoverSuppressed = false;
            }),
            child: Focus(
            focusNode: _menuFocus,
            onFocusChange: (f) => setState(() => _menuOpen = f),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: _menuOpen ? open : collapsed,
              padding: EdgeInsets.fromLTRB(context.px(24), context.px(48), context.px(24), context.px(40)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _ProfileButton(expanded: _menuOpen),
                SizedBox(height: context.px(28)),
                for (final e in _visible(app).where((e) => e.section != Section.settings))
                  _TvMenuItem(entry: e, selected: e.section == _section, expanded: _menuOpen, onTap: () => _pick(e.section)),
                const Spacer(),
                _TvMenuItem(
                  entry: _entries.last,
                  selected: _section == Section.settings,
                  expanded: _menuOpen,
                  onTap: () => _pick(Section.settings),
                ),
              ]),
            ),
          ),
          ),
        ),
      ),
    ]);
  }

  // ------------------------------------------------------------------ Phone

  Widget _phoneLayout(BuildContext context, AppState app, Widget body) {
    final tabs = [Section.home, Section.search, Section.myList, if (app.seerrConfigured) Section.requests, Section.settings];
    final idx = tabs.contains(_section) ? tabs.indexOf(_section) : 0;
    return Scaffold(
      body: SafeArea(bottom: false, child: body),
      bottomNavigationBar: NavigationBar(
        backgroundColor: C.surface,
        indicatorColor: C.accentDark,
        selectedIndex: idx,
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (i) => _go(tabs[i]),
        destinations: [
          for (final s in tabs)
            NavigationDestination(
              icon: Icon(_entries.firstWhere((e) => e.section == s).icon, color: C.muted),
              selectedIcon: Icon(_entries.firstWhere((e) => e.section == s).icon, color: C.accent),
              label: _entries.firstWhere((e) => e.section == s).label,
            ),
        ],
      ),
    );
  }
}

class _TvMenuItem extends StatelessWidget {
  final _NavEntry entry;
  final bool selected;
  final bool expanded;
  final VoidCallback onTap;
  const _TvMenuItem({required this.entry, required this.selected, required this.expanded, required this.onTap});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: context.px(8)),
        child: Focusable(
          onTap: onTap,
          semanticLabel: entry.label,
          builder: (context, active) {
            final fg = active ? const Color(0xFF111111) : (selected ? C.accent : C.faint);
            return AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: context.px(68),
              padding: EdgeInsets.symmetric(horizontal: context.px(16)),
              decoration: BoxDecoration(
                color: active ? C.text : Colors.transparent,
                borderRadius: BorderRadius.circular(context.px(14)),
              ),
              child: Row(children: [
                Icon(entry.icon, color: fg, size: context.px(32)),
                if (expanded) ...[
                  SizedBox(width: context.px(24)),
                  Flexible(
                    child: Text(entry.label,
                        overflow: TextOverflow.clip,
                        softWrap: false,
                        style: body(context.px(28), weight: FontWeight.w600, color: active ? fg : (selected ? C.accent : C.muted))),
                  ),
                ],
              ]),
            );
          },
        ),
      );
}

class _ProfileButton extends StatelessWidget {
  final bool expanded;
  const _ProfileButton({required this.expanded});
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final a = app.account!;
    final img = a.imageTag == null ? null : app.jf!.userImage(a.userId, a.imageTag!);
    return Focusable(
      onTap: () => app.leaveProfile(),
      semanticLabel: 'Switch profile',
      builder: (context, active) => Container(
        padding: EdgeInsets.all(context.px(6)),
        decoration: BoxDecoration(
          color: active && expanded ? C.text : Colors.transparent,
          borderRadius: BorderRadius.circular(context.px(14)),
          border: active && !expanded ? Border.all(color: C.text, width: context.px(3)) : null,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Avatar(name: a.name, imageUrl: img, size: 48),
          if (expanded) ...[
            SizedBox(width: context.px(18)),
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(a.name, style: body(context.px(26), weight: FontWeight.w700, color: active ? const Color(0xFF111111) : C.text)),
              Text('Switch profile', style: body(context.px(17), color: active ? const Color(0xFF444444) : C.faint)),
            ]),
          ],
        ]),
      ),
    );
  }
}
