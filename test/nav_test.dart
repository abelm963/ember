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

/// The remote and keyboard must always land on something that can be pressed: a focus node
/// without a label means focus fell out of the screen (the "focus disappears" bug class).
void expectLabelled(List<String> trail) {
  for (final step in trail) {
    final label = step.substring(step.indexOf(':') + 1);
    expect(label, isNot(contains('FocusNode')), reason: 'focus got lost: $trail');
    expect(label, isNot(contains('FocusScopeNode')), reason: 'focus got lost: $trail');
    expect(label, isNot('null'), reason: 'focus got lost: $trail');
  }
}

/// Labels only, in order.
List<String> labels(List<String> trail) => [for (final s in trail) s.substring(s.indexOf(':') + 1)];

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
        // Which row Down reaches first depends on how fast each row loads, so only what must
        // always hold is checked: focus stays on something, Down leaves the first spot, and
        // Right then Left move along a row.
        expectLabelled(trail);
        final home = labels(trail);
        expect(home.toSet().length, greaterThan(2), reason: '$trail');
        expect(home[5], isNot(home[4]), reason: 'Right did nothing: $trail');
        expect(home[6], isNot(home[5]), reason: 'Left did nothing: $trail');
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
        expectLabelled(trail);
        final details = labels(trail);
        expect(details, contains('Play from beginning'));
        expect(details, contains('Play trailer'));
        expect(details, contains('Add to My List'));
        if (mode == 'desktop') expect(details.first, 'Back');
      }, s.mockClient);
    });
  }
}
