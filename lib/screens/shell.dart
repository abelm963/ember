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

  void _go(Section s) => setState(() => _section = s);

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

  /// TV and desktop: a menu bar across the top (profile on the left, the sections in a pill in
  /// the middle, the Ember mark on the right), with the page underneath.
  Widget _tvLayout(BuildContext context, AppState app, Widget body) {
    final barH = context.px(100);
    final items = _visible(app).where((e) => e.section != Section.requests || app.seerrConfigured).toList();
    return Stack(children: [
      Positioned.fill(top: barH, child: FocusTraversalGroup(child: body)),
      Positioned(
        left: 0,
        right: 0,
        top: 0,
        height: barH,
        child: Container(
          color: C.bg,
          padding: EdgeInsets.symmetric(horizontal: context.px(60)),
          child: FocusTraversalGroup(
            child: Row(children: [
              const _ProfileButton(expanded: false),
              Expanded(
                child: Center(
                  child: Container(
                    padding: EdgeInsets.all(context.px(5)),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C20),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0xFF2E2E34), width: context.px(1)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      for (final e in items)
                        _TopItem(entry: e, selected: e.section == _section, onTap: () => _go(e.section)),
                    ]),
                  ),
                ),
              ),
              Icon(Icons.local_fire_department, color: C.accent, size: context.px(46)),
            ]),
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

/// One section in the top menu: the icon alone for Search and Settings, a word for the rest.
class _TopItem extends StatelessWidget {
  final _NavEntry entry;
  final bool selected;
  final VoidCallback onTap;
  const _TopItem({required this.entry, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final iconOnly = entry.section == Section.search || entry.section == Section.settings;
    return Focusable(
      onTap: onTap,
      semanticLabel: entry.label,
      scrollIntoView: false,
      builder: (context, active) {
        final fg = active ? const Color(0xFF111111) : (selected ? C.text : C.muted);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: context.px(46),
          padding: EdgeInsets.symmetric(horizontal: context.px(iconOnly ? 14 : 20)),
          decoration: BoxDecoration(
            color: active ? C.text : (selected ? const Color(0xFF3A3A40) : Colors.transparent),
            borderRadius: BorderRadius.circular(999),
          ),
          alignment: Alignment.center,
          child: iconOnly
              ? Icon(entry.icon, color: fg, size: context.px(26))
              : Text(entry.label, style: body(context.px(20), weight: FontWeight.w600, color: fg)),
        );
      },
    );
  }
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
        padding: EdgeInsets.all(context.px(4)),
        decoration: BoxDecoration(
          color: active && expanded ? C.text : Colors.transparent,
          borderRadius: BorderRadius.circular(context.px(14)),
          border: active && !expanded ? Border.all(color: C.text, width: context.px(3)) : null,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Avatar(name: a.name, imageUrl: img, size: 40),
          if (!expanded) ...[
            SizedBox(width: context.px(4)),
            Icon(Icons.arrow_drop_down_rounded, color: C.muted, size: context.px(26)),
          ],
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
