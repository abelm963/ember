/// Ember's dialog frame and the list picker built on it.
library;

import 'package:flutter/material.dart';

import 'focusable.dart';
import 'scale.dart';
import 'theme.dart';

/// A list picker that works with a remote, a mouse or a finger.
Future<void> pickOption<T>(
  BuildContext context,
  String title,
  Map<T, String> options,
  T current,
  ValueChanged<T> onPick,
) async {
  await showDialog(
    context: context,
    builder: (ctx) => EmberDialog(
      title: title,
      children: [
        for (final e in options.entries)
          Padding(
            padding: EdgeInsets.only(bottom: ctx.px(8)),
            child: Focusable(
              autofocus: e.key == current,
              onTap: () {
                onPick(e.key);
                Navigator.pop(ctx);
              },
              semanticLabel: e.value,
              builder: (context, active) => Container(
                height: context.px(66),
                padding: EdgeInsets.symmetric(horizontal: context.px(20)),
                decoration: BoxDecoration(
                  color: active ? C.text : C.surface2,
                  borderRadius: BorderRadius.circular(context.px(12)),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: context.px(40),
                      child: e.key == current
                          ? Icon(Icons.check, color: active ? const Color(0xFF111111) : C.accent, size: context.px(28))
                          : null,
                    ),
                    Expanded(
                      child: Text(
                        e.value,
                        style: body(
                          context.px(24),
                          weight: FontWeight.w600,
                          color: active ? const Color(0xFF111111) : C.soft,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Ember's dialog: a title over a column of content, sized for the TV and scaled down elsewhere.
class EmberDialog extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const EmberDialog({super.key, required this.title, required this.children});
  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: C.surface,
    insetPadding: EdgeInsets.all(context.px(60)),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(context.px(24))),
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: context.px(820), maxHeight: context.px(960)),
      child: SingleChildScrollView(
        padding: EdgeInsets.all(context.px(48)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: display(context.px(46))),
            SizedBox(height: context.px(26)),
            ...children,
          ],
        ),
      ),
    ),
  );
}
