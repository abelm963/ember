/// Text input helpers.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Runs [action] after [delay], cancelling any earlier pending call.
class Debouncer {
  final Duration delay;
  Timer? _t;
  Debouncer(this.delay);
  void call(VoidCallback action) {
    _t?.cancel();
    _t = Timer(delay, action);
  }

  void dispose() => _t?.cancel();
}

/// Lets the remote's / keyboard's Up and Down keys move focus out of a text field
/// (text fields otherwise keep those keys for moving the cursor).
class FieldFocusEscape extends StatelessWidget {
  final Widget child;
  const FieldFocusEscape({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(TraversalDirection.down),
      SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(TraversalDirection.up),
    },
    child: child,
  );
}
