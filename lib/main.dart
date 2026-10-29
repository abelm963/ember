import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import 'platform.dart';
import 'player/hero_preview.dart';
import 'screens/connect.dart';
import 'screens/profiles.dart';
import 'screens/shell.dart';
import 'state/app_state.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

final navigatorKey = GlobalKey<NavigatorState>();

class BackIntent extends Intent {
  const BackIntent();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Apple TV plays through Apple's own player instead of mpv (see player/engine.dart).
  if (!isAppleTv) MediaKit.ensureInitialized();
  final state = AppState();
  await state.init();
  // Back (Esc / remote Back) must work even when nothing on screen has keyboard focus,
  // e.g. after using the mouse. Focused widgets get the key first; this only catches the rest.
  HardwareKeyboard.instance.addHandler((event) {
    if (event is! KeyDownEvent || !isBackKey(event.logicalKey)) return false;
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || focus == FocusManager.instance.rootScope) {
      navigatorKey.currentState?.maybePop();
      return true;
    }
    return false;
  });
  runApp(ChangeNotifierProvider.value(value: state, child: const EmberApp()));
}

class EmberApp extends StatelessWidget {
  const EmberApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ember',
      debugShowCheckedModeBanner: false,
      theme: emberTheme(),
      navigatorKey: navigatorKey,
      navigatorObservers: [routeObserver],
      // Remote / keyboard "Back" keys pop the current screen everywhere.
      shortcuts: {
        ...WidgetsApp.defaultShortcuts,
        const SingleActivator(LogicalKeyboardKey.goBack): const BackIntent(),
        const SingleActivator(LogicalKeyboardKey.browserBack): const BackIntent(),
        const SingleActivator(LogicalKeyboardKey.gameButtonB): const BackIntent(),
        const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
      },
      actions: {
        ...WidgetsApp.defaultActions,
        BackIntent: CallbackAction<BackIntent>(
          onInvoke: (_) {
            navigatorKey.currentState?.maybePop();
            return null;
          },
        ),
        // Esc is mapped to DismissIntent by Flutter's default shortcuts; outside dialogs
        // (which handle it themselves) it means "go back".
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            navigatorKey.currentState?.maybePop();
            return null;
          },
        ),
      },
      // Every Back key (Esc, the remote's Back/Menu button) that no screen handled itself
      // goes back one screen. The player handles Back first (hides its menus, then leaves).
      builder: (context, child) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent && isBackKey(event.logicalKey)) {
            navigatorKey.currentState?.maybePop();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: child!,
      ),
      home: const RootGate(),
    );
  }
}

/// Decides the first screen: connect to a server → choose a profile → the app.
class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (!app.ready) return const Scaffold(body: Loading());
    if (app.serverUrl == null) return const ConnectScreen();
    if (app.account == null) return const ProfilesScreen();
    return const AppShell();
  }
}
