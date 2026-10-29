/// Buttons, chips and badges.
library;

import 'package:flutter/material.dart';

import 'focusable.dart';
import 'scale.dart';
import 'theme.dart';

enum BtnKind { primary, secondary, accent, ghost }

class EmberButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final BtnKind kind;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool compact;

  const EmberButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.kind = BtnKind.secondary,
    this.autofocus = false,
    this.focusNode,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final h = context.px(compact ? 60 : 72);
    return Focusable(
      autofocus: autofocus,
      focusNode: focusNode,
      onTap: onTap,
      semanticLabel: label,
      builder: (context, active) {
        Color bg, fg;
        switch (kind) {
          case BtnKind.primary:
            bg = C.text;
            fg = const Color(0xFF111111);
            break;
          case BtnKind.accent:
            bg = active ? C.text : C.accent;
            fg = active ? const Color(0xFF111111) : C.accentInk;
            break;
          case BtnKind.secondary:
            bg = active ? C.text : const Color(0x66787880);
            fg = active ? const Color(0xFF111111) : Colors.white;
            break;
          case BtnKind.ghost:
            bg = active ? C.text : C.surface3;
            fg = active ? const Color(0xFF111111) : C.text;
            break;
        }
        return AnimatedScale(
          scale: active ? 1.05 : 1,
          duration: const Duration(milliseconds: 150),
          child: Container(
            height: h,
            padding: EdgeInsets.symmetric(horizontal: context.px(icon != null && label.isEmpty ? 0 : 34)),
            width: label.isEmpty ? h : null,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(context.px(12)),
              border: active && kind == BtnKind.primary ? Border.all(color: C.accent, width: context.px(3)) : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) Icon(icon, color: fg, size: context.px(30)),
                if (icon != null && label.isNotEmpty) SizedBox(width: context.px(12)),
                if (label.isNotEmpty)
                  Text(
                    label,
                    style: body(context.px(compact ? 22 : 25), color: fg, weight: FontWeight.w700),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class Chip2 extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const Chip2({super.key, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onTap: onTap,
      semanticLabel: label,
      builder: (context, active) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: context.px(54),
        padding: EdgeInsets.symmetric(horizontal: context.px(26)),
        decoration: BoxDecoration(
          color: active ? C.text : (selected ? C.accentDark : C.surface),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: body(
                context.px(22),
                weight: FontWeight.w600,
                color: active ? const Color(0xFF111111) : (selected ? C.accent : C.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  const Pill(this.text, {super.key, this.bg = C.accent, this.fg = C.accentInk});
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: context.px(12), vertical: context.px(5)),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
    child: Text(
      text,
      style: body(context.px(15), color: fg, weight: FontWeight.w700),
    ),
  );
}

class Badge2 extends StatelessWidget {
  final String text;
  const Badge2(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: context.px(8), vertical: context.px(1)),
    decoration: BoxDecoration(
      border: Border.all(color: C.faint, width: context.px(2)),
      borderRadius: BorderRadius.circular(context.px(4)),
    ),
    child: Text(
      text,
      style: body(context.px(18), color: C.muted, weight: FontWeight.w700),
    ),
  );
}

/// The small round back arrow in the top-left corner of detail pages (mouse and touch only;
/// a remote uses its Back button).
class BackArrow extends StatelessWidget {
  final VoidCallback onTap;
  const BackArrow({super.key, required this.onTap});
  @override
  Widget build(BuildContext context) => Focusable(
    onTap: onTap,
    semanticLabel: 'Back',
    scrollIntoView: false,
    builder: (context, active) => Container(
      width: context.px(64),
      height: context.px(64),
      decoration: BoxDecoration(
        color: active ? C.text : const Color(0xB32A2A2F),
        borderRadius: BorderRadius.circular(context.px(14)),
      ),
      child: Icon(Icons.arrow_back, color: active ? const Color(0xFF111111) : C.text, size: context.px(32)),
    ),
  );
}
