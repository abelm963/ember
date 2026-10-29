/// Skeleton placeholders shown while a page loads.
library;

import 'package:flutter/material.dart';

import 'scale.dart';
import 'theme.dart';

/// Gently pulsing grey blocks shown while a page loads.
class SkeletonPulse extends StatefulWidget {
  final Widget child;
  const SkeletonPulse({super.key, required this.child});
  @override
  State<SkeletonPulse> createState() => _SkeletonPulseState();
}

class _SkeletonPulseState extends State<SkeletonPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
    lowerBound: 0.45,
    upperBound: 1,
  )..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(opacity: _c, child: widget.child);
}

class Bone extends StatelessWidget {
  final double width;
  final double height;
  final double radius;
  const Bone(this.width, this.height, {super.key, this.radius = 10});
  @override
  Widget build(BuildContext context) => Container(
    width: context.px(width),
    height: context.px(height),
    decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(context.px(radius))),
  );
}

/// The shape of a movie / series / preview page, shown while it loads.
class TitlePageSkeleton extends StatelessWidget {
  const TitlePageSkeleton({super.key});
  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < 700;
    final pad = context.px(phone ? 40 : 120);
    final gap = SizedBox(height: context.px(22));
    return SkeletonPulse(
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(pad, context.px(phone ? 100 : 110), pad, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Bone(560, 140, radius: 14),
            gap,
            Row(
              children: [
                for (final w in const [70.0, 70.0, 64.0, 110.0, 220.0]) ...[
                  Bone(w, 30, radius: 8),
                  SizedBox(width: context.px(14)),
                ],
              ],
            ),
            SizedBox(height: context.px(30)),
            const Bone(900, 24),
            SizedBox(height: context.px(14)),
            const Bone(860, 24),
            SizedBox(height: context.px(14)),
            const Bone(620, 24),
            SizedBox(height: context.px(34)),
            Wrap(
              spacing: context.px(16),
              runSpacing: context.px(14),
              children: const [
                Bone(230, 72, radius: 14),
                Bone(190, 72, radius: 14),
                Bone(72, 72, radius: 14),
                Bone(72, 72, radius: 14),
              ],
            ),
            SizedBox(height: context.px(70)),
            Row(
              children: [
                const Bone(200, 34),
                SizedBox(width: context.px(30)),
                const Bone(170, 34),
              ],
            ),
            SizedBox(height: context.px(30)),
            ClipRect(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                child: Row(
                  children: [
                    for (var i = 0; i < 6; i++) ...[const Bone(340, 192, radius: 12), SizedBox(width: context.px(18))],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
