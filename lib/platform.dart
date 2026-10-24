import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// True on Apple TV (built with flutter-tvos). `Platform.isIOS` is also true there, so check
/// this first wherever iPhone and Apple TV need different behaviour.
final bool isAppleTv = !kIsWeb && Platform.operatingSystem == 'tvos';
