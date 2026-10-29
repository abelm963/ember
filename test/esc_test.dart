import 'package:ember/main.dart';
import 'package:ember/screens/details.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'screens_test.dart' as s;

void main() {
  testWidgets('Esc leaves a details page', (tester) async {
    await http.runWithClient(() async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      final state = await s.signedInState('desktop');
      await tester.pumpWidget(ChangeNotifierProvider.value(value: state, child: const EmberApp()));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      navigatorKey.currentState!.push(MaterialPageRoute(builder: (_) => const DetailsScreen(itemId: 'm1')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(DetailsScreen), findsOneWidget);
      debugPrint('focus: ${FocusManager.instance.primaryFocus}');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(DetailsScreen), findsNothing);
      // Let image pre-loading and the trailer-setup check run out.
      await tester.pump(const Duration(seconds: 6));
    }, s.mockClient);
  });
}
