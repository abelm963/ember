/// Network images with loading and fallback states, and image pre-loading.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'theme.dart';

class NetImage extends StatelessWidget {
  final String? url;
  final BoxFit fit;

  /// Shown when there is no image or it fails to load.
  final Widget? fallback;

  /// Shown while the image is still downloading (defaults to [fallback]).
  final Widget? loading;
  final Alignment alignment;
  final Map<String, String>? headers;
  const NetImage(
    this.url, {
    super.key,
    this.fit = BoxFit.cover,
    this.fallback,
    this.loading,
    this.alignment = Alignment.center,
    this.headers,
  });

  @override
  Widget build(BuildContext context) {
    final fb = fallback ?? Container(color: C.surface2);
    if (url == null) return fb;
    return Image.network(
      url!,
      fit: fit,
      alignment: alignment,
      headers: headers,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => fb,
      frameBuilder: (context, child, frame, sync) {
        if (sync) return child;
        // Fade in once the first frame arrives instead of popping in.
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: frame != null ? KeyedSubtree(key: const ValueKey('img'), child: child) : (loading ?? fb),
        );
      },
    );
  }
}

/// Downloads images ahead of time so a page appears complete, not piece by piece.
/// Gives up after [timeout] so a slow image never blocks the page.
Future<void> warmImages(
  BuildContext context,
  Iterable<String?> urls, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final jobs = [
    for (final u in urls)
      if (u != null && context.mounted) precacheImage(NetworkImage(u), context, onError: (_, _) {}),
  ];
  try {
    await Future.wait(jobs).timeout(timeout);
  } catch (_) {}
}
