//
//  Generated file. Do not edit.
//

import Flutter
import Foundation

import shared_preferences_tvos
import url_launcher_tvos
import video_player_tvos
import wakelock_plus_tvos

func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {
  // The registry returns nil registrars when the Flutter engine is not
  // running (on a physical Apple TV the debug engine requires an attached
  // debugger). Nil crashes plugin registration, so bail out loudly.
  guard registry.registrar(forPlugin: "__flutter_tvos_engine_probe__") != nil else {
    NSLog("[GeneratedPluginRegistrant] Flutter engine is not running; skipping plugin registration. Debug builds on a physical Apple TV must be launched via 'flutter-tvos run' (the debug engine requires an attached debugger).")
    return
  }
  SharedPreferencesPlugin.register(with: registry.registrar(forPlugin: "SharedPreferencesPlugin"))
  URLLauncherPlugin.register(with: registry.registrar(forPlugin: "URLLauncherPlugin"))
  VideoPlayerPlugin.register(with: registry.registrar(forPlugin: "VideoPlayerPlugin"))
  WakelockPlusPlugin.register(with: registry.registrar(forPlugin: "WakelockPlusPlugin"))
}
