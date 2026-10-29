/// Focusable, the one interactive building block: remote focus, mouse hover and touch in one.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

bool isActivateKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.enter ||
    k == LogicalKeyboardKey.numpadEnter ||
    k == LogicalKeyboardKey.select ||
    k == LogicalKeyboardKey.space ||
    k == LogicalKeyboardKey.gameButtonA;

bool isBackKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.escape ||
    k == LogicalKeyboardKey.goBack ||
    k == LogicalKeyboardKey.browserBack ||
    k == LogicalKeyboardKey.gameButtonB;

typedef FocusBuilder = Widget Function(BuildContext context, bool active);

class Focusable extends StatefulWidget {
  final FocusBuilder builder;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onFocusChange;
  final bool autofocus;
  final FocusNode? focusNode;
  final String? semanticLabel;
  final bool scrollIntoView;

  const Focusable({
    super.key,
    required this.builder,
    this.onTap,
    this.onLongPress,
    this.onFocusChange,
    this.autofocus = false,
    this.focusNode,
    this.semanticLabel,
    this.scrollIntoView = true,
  });

  @override
  State<Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<Focusable> {
  bool _focused = false;
  bool _hovered = false;

  void _setFocus(bool f) {
    setState(() => _focused = f);
    widget.onFocusChange?.call(f);
    if (f && widget.scrollIntoView) {
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _focused || _hovered;
    return Semantics(
      button: widget.onTap != null,
      label: widget.semanticLabel,
      child: Focus(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        onFocusChange: _setFocus,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent && isActivateKey(event.logicalKey) && widget.onTap != null) {
            widget.onTap!();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: widget.builder(context, active),
          ),
        ),
      ),
    );
  }
}
