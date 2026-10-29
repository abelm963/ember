/// Loading, error and toast feedback, and the Loader that shows them around a Future.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'buttons.dart';
import 'scale.dart';
import 'theme.dart';

class Loading extends StatelessWidget {
  const Loading({super.key});
  @override
  Widget build(BuildContext context) => const Center(child: CircularProgressIndicator(color: C.accent));
}

class ErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback? onRetry;
  const ErrorView(this.error, {super.key, this.onRetry});
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.cloud_off, color: C.faint, size: context.px(64)),
        SizedBox(height: context.px(16)),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: context.px(900)),
          child: Text(
            '$error',
            textAlign: TextAlign.center,
            style: body(context.px(24), color: C.muted),
          ),
        ),
        if (onRetry != null) ...[
          SizedBox(height: context.px(24)),
          EmberButton(label: 'Try again', icon: Icons.refresh, onTap: onRetry, autofocus: true, kind: BtnKind.ghost),
        ],
      ],
    ),
  );
}

/// Loads a future once (and again when [deps] change) and shows loading / error states.
class Loader<T> extends StatefulWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext, T) builder;
  final Object? deps;

  /// Shown while loading (a spinner if not given).
  final Widget? placeholder;
  const Loader({super.key, required this.load, required this.builder, this.deps, this.placeholder});
  @override
  State<Loader<T>> createState() => _LoaderState<T>();
}

class _LoaderState<T> extends State<Loader<T>> {
  late Future<T> _f;
  @override
  void initState() {
    super.initState();
    _f = widget.load();
  }

  @override
  void didUpdateWidget(covariant Loader<T> old) {
    super.didUpdateWidget(old);
    if (old.deps != widget.deps) _f = widget.load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
    future: _f,
    builder: (context, snap) {
      if (snap.hasError) return ErrorView(snap.error!, onRetry: () => setState(() => _f = widget.load()));
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: !snap.hasData
            ? KeyedSubtree(key: const ValueKey('loading'), child: widget.placeholder ?? const Loading())
            : KeyedSubtree(key: const ValueKey('ready'), child: widget.builder(context, snap.data as T)),
      );
    },
  );
}

void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message, style: body(context.px(22))),
      backgroundColor: C.surface3,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ),
  );
}
