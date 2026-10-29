import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// True on Apple TV (built with flutter-tvos). `Platform.isIOS` is also true there, so check
/// this first wherever iPhone and Apple TV need different behaviour.
final bool isAppleTv = !kIsWeb && Platform.operatingSystem == 'tvos';

/// A phone-sized touch screen (iPhone or Android phone, not a tablet or an Apple TV).
bool get isPhoneSized {
  if (kIsWeb || isAppleTv || !(Platform.isIOS || Platform.isAndroid)) return false;
  final views = PlatformDispatcher.instance.views;
  if (views.isEmpty) return false;
  final v = views.first;
  return (v.physicalSize / v.devicePixelRatio).shortestSide < 600;
}

/// Phones show the app upright and the player sideways, like the big streaming apps. Tablets
/// may turn either way outside the player.
void setPhoneOrientation({required bool player}) {
  if (kIsWeb || isAppleTv || !(Platform.isIOS || Platform.isAndroid)) return;
  SystemChrome.setPreferredOrientations(
    player
        ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : isPhoneSized
        ? const [DeviceOrientation.portraitUp]
        : const [],
  );
  SystemChrome.setEnabledSystemUIMode(player ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
}
