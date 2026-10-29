import 'package:ember/main.dart';
import 'package:ember/screens/details.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'screens_test.dart' as s;

String focused() {
  final f = FocusManager.instance.primaryFocus;
  final ctx = f?.context;
  if (ctx == null) return '$f';
  final sem = ctx.findAncestorWidgetOfExactType<Semantics>();
  return sem?.properties.label ?? '$f';
}

void main() {
  for (final mode in ['tv', 'desktop']) {
    testWidgets('arrow keys move around ($mode)', (tester) async {
      await http.runWithClient(() async {
        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1;
        final state = await s.signedInState(mode);
        await tester.pumpWidget(ChangeNotifierProvider.value(value: state, child: const EmberApp()));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        final trail = <String>[];
        Future<void> press(LogicalKeyboardKey k) async {
          await tester.sendKeyEvent(k);
          for (var i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          trail.add('${k.keyLabel}:${focused()}');
        }

        for (var i = 0; i < 5; i++) {
          await press(LogicalKeyboardKey.arrowDown);
        }
        await press(LogicalKeyboardKey.arrowRight);
        await press(LogicalKeyboardKey.arrowLeft);
        await press(LogicalKeyboardKey.arrowLeft);
        await press(LogicalKeyboardKey.arrowLeft);
        await press(LogicalKeyboardKey.arrowUp);
        debugPrint('HOME $mode: ${trail.join(' | ')}');
        navigatorKey.currentState!.push(MaterialPageRoute(builder: (_) => const DetailsScreen(itemId: 'm1')));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        trail.clear();
        for (var i = 0; i < 5; i++) {
          await press(LogicalKeyboardKey.arrowDown);
        }
        await press(LogicalKeyboardKey.arrowRight);
        debugPrint('DETAILS $mode: ${trail.join(' | ')}');
      }, s.mockClient);
    });
  }
}
