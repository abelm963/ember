/// Sizes: every size in Ember is written for a 1920×1080 TV screen and scaled to the window.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

double scaleOf(BuildContext context) {
  final state = context.read<AppState>();
  final size = MediaQuery.sizeOf(context);
  switch (state.formFactor) {
    // Fit the 1920×1080 design inside the window: on ultra-wide screens the height decides,
    // so nothing is pushed off the bottom; extra width just shows more of each row.
    case FormFactor.tv:
      return min(size.width / 1920, size.height / 1080).clamp(0.3, 3.0);
    case FormFactor.desktop:
      return min(size.width / 1920, size.height / 1080).clamp(0.4, 2.0);
    case FormFactor.phone:
      return (size.shortestSide / 900).clamp(0.4, 1.0);
  }
}

extension Px on BuildContext {
  /// Converts a design size (1920-wide TV units) into this screen's pixels.
  double px(double v) => v * scaleOf(this);
  AppState get app => read<AppState>();
}

/// Left/right page margin in design units, per form factor.
double gutter(BuildContext context) {
  final app = context.read<AppState>();
  // TV and desktop line up with the menu bar and the billboard pages.
  return switch (app.formFactor) {
    FormFactor.tv => 60,
    FormFactor.desktop => 60,
    FormFactor.phone => 40,
  };
}
