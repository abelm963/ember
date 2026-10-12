import 'package:ember/main.dart';
import 'package:ember/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final mode in ['tv', 'desktop']) {
    testWidgets('connect screen renders ($mode)', (tester) async {
      SharedPreferences.setMockInitialValues({'interfaceMode': mode});
      tester.view.physicalSize = mode == 'tv' ? const Size(1920, 1080) : const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      final state = AppState();
      await state.init();
      await tester.pumpWidget(ChangeNotifierProvider.value(value: state, child: const EmberApp()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Connect to your Jellyfin server'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });
  }
}
