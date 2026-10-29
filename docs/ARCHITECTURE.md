# How Ember is built

Ember is one Flutter app for TV (Apple TV now, Android TV later), desktop (Windows, Mac) and
phones. It talks to a Jellyfin server for the library and playback, and optionally to Seerr for
discovery and requests. Nothing has to be installed on the server.

This page describes the code as it is. When you change how the parts fit together, update it.

## The layers

```
lib/
  main.dart          start-up, Back key handling, RootGate (connect → profiles → app)
  platform.dart      isAppleTv (check it before Platform.isIOS)
  state/             AppState: saved servers, profiles, settings, layout; builds the API clients
  api/               talks to servers; no Flutter widgets
    jellyfin.dart      JellyfinClient + JfItem and friends
    seerr.dart         SeerrClient (cookie session, CSRF, automatic re-sign-in)
    youtube.dart       finds a playable trailer stream on the device
    recommend.dart     gathers facts for Recommended (Jellyfin history, Seerr links)
    taste.dart         Recommended's ranking: pure functions, all the numbers in one place
  player/            playback; imports api/, state/ and ui/, never screens/
    engine.dart        PlaybackEngine: MpvEngine (media_kit) or AvEngine (AVPlayer, Apple TV)
    player_screen.dart PlayerScreen: the playback session and its overlays
    player_controls.dart buttons, menus, episode rows, scrubber (stateless pieces of the player)
    tracks.dart        picks version, soundtrack, subtitles and quality before asking the server
    segments.dart      tidies intro / recap / credits times
    trailers.dart      trailer lookup and cache, opening the YouTube app
    native_player.dart Apple's own player on Apple TV, over the ember/player channel
    hero_preview.dart  muted trailer previews behind Home's billboard
  screens/           one file per screen
    nav.dart           openItem, openSeerr, play, playSeries, playTrailer, warmPlayback
    shared/            pieces several screens use (poster-row entries, the meta line)
  ui/                presentation only; imports state/ for the layout, nothing else of Ember
    widgets.dart       re-exports the files below, so one import gets all of them
    focusable.dart     Focusable and the activate/back keys
    scale.dart         scaleOf / context.px, gutter
    buttons.dart, images.dart, media_tiles.dart, skeletons.dart, feedback.dart,
    dialogs.dart, format.dart, input.dart, browse.dart (billboard, poster rows, filters),
    theme.dart, tv_keyboard.dart
  util/
    log.dart           logWarning() and redact(): device log with secrets removed
tvos/Runner/         Apple TV native code: NativePlayer.swift (Apple's player), keyboard channel
```

Dependencies point one way: `screens → player → api / state → (nothing of Ember)`, and every
layer may use `ui/` and `util/`. `ui/` and `api/` never import screens or the player. Keep it
that way: it is what lets the player and the API clients be tested on their own.

## State

`AppState` (a `ChangeNotifier`, provided at the top with `provider`) is the only app-wide state.
It holds the accounts and settings, saves them to `SharedPreferences` on every change
(`update((s) => ...)`), and rebuilds the `JellyfinClient` and `SeerrClient` when the server or
profile changes. Screens read it with `context.read<AppState>()` / `watch`. `revision` is bumped
when library data may have changed (after playback, a sign-in, Seerr connecting), and screens
reload on it.

Screens keep their own loading state, mostly through `Loader<T>` (`ui/feedback.dart`), which
shows a skeleton or spinner, then the content or an error with Retry.

## Navigation and input

Every control is a `Focusable` (`ui/focusable.dart`): one widget that handles remote/D-pad focus,
mouse hover and click, and touch. The layout is picked by `AppState.formFactor` (TV, desktop,
phone; can be forced in Settings › Interface):

- TV and desktop share the side-menu layout (`screens/shell.dart`); on desktop the menu also opens
  on hover.
- Phone uses a bottom tab bar.

Sizes are written for a 1920×1080 TV and scaled with `context.px(n)` (`ui/scale.dart`), so the
same design fits a TV, an ultrawide monitor and a phone.

Back: `main.dart` maps Esc, the remote's Back/Menu and browser Back to "pop one screen" whenever
nothing on screen handles it first. The player handles Back itself (closes its menus first).

## Playback

1. `screens/nav.dart` `play()` opens `PlayerScreen`, or on Apple TV with Settings › "Use Apple's
   player" on, `NativePlayer.play()`.
2. The maximum bitrate comes from Settings › Quality; Auto plays the original unless a
   connection test (remembered for 20 minutes, started early by `warmPlayback`) says it won't
   fit. On Apple TV, `tracks.dart` `planPlayback` also chooses the version, soundtrack and
   subtitles first, so the server is asked once for exactly that. Elsewhere mpv switches tracks
   itself and `tracks.dart` picks the defaults once the file is open.
3. `JellyfinClient.playbackSource` sends PlaybackInfo with a device profile: everything plays
   directly on mpv; Apple TV gets a profile that direct-plays MP4/MOV and has the server
   repackage the rest into HLS, passing HDR and Dolby Vision through. With a chosen soundtrack
   on Apple TV the server always builds the stream (the "Frozen in French" fix).
4. `PlayerScreen` drives a `PlaybackEngine`, reports start / progress (every 10 s) / stop to
   Jellyfin, and shows intro and recap skipping, Up Next, trickplay and the Episodes panel.

## Trailers

`player/trailers.dart` collects a title's YouTube keys (Jellyfin's RemoteTrailers, then Seerr),
asks `youtube.dart` for a stream it can play, and caches the answer for 50 minutes. If a stream
fails, the player asks for the next way (`YouTubeTrailers.nextAfter`). If none works, the
trailer opens in the YouTube app.

## Errors and logging

API clients throw `ApiException` with a message fit to show people. Best-effort work (discovery,
prefetching, optional Seerr details) may carry on after a failure; when that failure would
matter for diagnosing a problem, it goes to `logWarning()`, which strips tokens, cookies and API
keys first. Never log a URL or header without `redact()`.

Jellyfin's token travels in stream, image and subtitle URLs as `api_key` (that is how Jellyfin
works). Accounts, tokens and the Seerr session cookie are stored in `SharedPreferences`.

## Tests

`flutter test` runs everything against a fake Jellyfin and Seerr (`http.runWithClient` with a
`MockClient`):

| File | Covers |
| --- | --- |
| `jellyfin_client_test.dart` | address clean-up, auth header, expired sessions, PlaybackInfo for desktop and Apple TV, progress reports |
| `app_state_test.dart` | settings and profiles surviving a restart, switching, leaving and signing out, quality |
| `tracks_test.dart`, `segments_test.dart` | soundtrack/subtitle/version choice, intro and credits times |
| `seerr_test.dart`, `youtube_test.dart`, `taste_test.dart` | Seerr sign-in and errors, trailer lookup, Recommended ranking |
| `screens_test.dart`, `smoke_test.dart`, `esc_test.dart`, `nav_test.dart` | every screen renders on TV, desktop and phone; Esc goes back; arrow keys keep focus on a control |

Not covered by automated tests, so check by hand after touching them: playback itself (mpv and
AVPlayer), Apple's player (`NativePlayer.swift`), real remote input on an Apple TV, and the
Windows build.

## Known limits and next steps

- `PlayerScreen`'s state is still one large class (session, reporting, tracks, overlays). The next
  step is a playback controller separate from the widgets, with tests around it first.
- Many screens use `app.jf!`; a screen still loading when a profile is left can throw.
- Android TV detection asks an `ember/device` channel that has no Android side yet, so Android TV
  is treated as a phone until that is added.
- Credentials are in `SharedPreferences`, not the system keychain.
