import 'package:ember/main.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'screens_test.dart' as s;

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('the side menu closes after a mouse click and lets the next click through', (tester) async {
    await http.runWithClient(() async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      final state = await s.signedInState('desktop');
      await tester.pumpWidget(ChangeNotifierProvider.value(value: state, child: const EmberApp()));
      await settle(tester);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(800, 450));
      await mouse.moveTo(const Offset(40, 300));
      await settle(tester);
      expect(find.text('Movies'), findsOneWidget, reason: 'hovering opens the menu');

      // Click "Movies" on its label, well inside the open menu.
      final movies = tester.getCenter(find.text('Movies'));
      await mouse.moveTo(movies);
      await mouse.down(movies);
      await mouse.up();
      await settle(tester);
      expect(find.text('New & Hot'), findsNothing, reason: 'the menu closes after a pick');

      // Moving a little further over where the open menu was must not reopen it and cover the page.
      await mouse.moveTo(movies + const Offset(30, 0));
      await settle(tester);
      expect(find.text('New & Hot'), findsNothing);

      // Leaving and coming back opens it again.
      await mouse.moveTo(const Offset(900, 450));
      await settle(tester);
      await mouse.moveTo(const Offset(40, 300));
      await settle(tester);
      expect(find.text('New & Hot'), findsOneWidget);
      await mouse.removePointer();
      await tester.pump(const Duration(seconds: 6));
    }, s.mockClient);
  });

  testWidgets('picking a section with the keyboard moves focus to the page', (tester) async {
    await http.runWithClient(() async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      final state = await s.signedInState('tv');
      await tester.pumpWidget(ChangeNotifierProvider.value(value: state, child: const EmberApp()));
      await settle(tester);
      // Into the menu, down to a section, and pick it.
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await settle(tester);
      }
      expect(find.text('Movies'), findsOneWidget, reason: 'focus in the menu opens it');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.text('New & Hot'), findsNothing, reason: 'the menu closes after a pick');
      await tester.pump(const Duration(seconds: 6));
    }, s.mockClient);
  });
}
