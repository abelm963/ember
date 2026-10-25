# Ember: notes for Claude Code

Ember is a Netflix-style Jellyfin client with Seerr requests, written in Flutter. Windows is the
test bed (this PC, "Nexus"). Apple TV comes next (App Store eventually), then Android TV, iPhone and
Android phones. The branding is original ("Ember"); no Netflix names or marks.

The owner is not a developer: explain things in plain language, make the change yourself, and
say what to click or run to see it.

## Build, run, test

- Flutter 3.47 / Dart 3.13, at `C:\dev\flutter`. Windows Developer Mode is on (needed for symlinks).
- `flutter analyze` → only 2 known info-level lints are expected.
- `flutter test` → 9 tests, all should pass. They use a mock server through `http.runWithClient`
  (see `test/screens_test.dart`); add routes there when a screen calls a new endpoint.
- **Update Ember.bat** = kill `ember.exe` → `flutter build windows --release` → start
  `build\windows\x64\runner\Release\ember.exe`. This is how the owner runs the app.
- Pinned: `media_kit` (mpv) for playback. There is no `google_fonts`: the fonts are bundled under
  `assets/fonts` (Figtree, Bricolage Grotesque, OFL). Flutter 3.47 renamed `cacheExtent` to
  `scrollCacheExtent: const ScrollCacheExtent.pixels(n)` (import `flutter/rendering.dart`).

## The owner's setup

- **Hearth** is their home server: Jellyfin 12.1, an admin account and a few family
  profiles. (The repo is public: addresses and account names are kept out of it.)
  - Reached on the home network (LAN, port 8096) and over Tailscale (https).
- **Seerr**: on Hearth, over Tailscale (version 3.5, Jellyfin sign-in).
- **Screens**: an LG ultrawide monitor. That's why TV and desktop layouts scale with
  `min(w/1920, h/1080)` (`scaleOf` / `context.px`).

## How the code is organised

| Path | What |
| --- | --- |
| `lib/api/jellyfin.dart` | Jellyfin: sign-in (password + Quick Connect), library, playback (direct play or HLS transcode), progress, intro segments, trickplay, bitrate test, trailer-plugin calls, release calendar, plugin install/update |
| `lib/api/seerr.dart` | Seerr: cookie jar with `connect.sid` and the CSRF tokens, automatic re-sign-in, Quick Connect sign-in, discover/search/details/requests, `allMedia()` for status lookups |
| `lib/state/app_state.dart` | Accounts, settings, form factor, Seerr automatic sign-in, trailer service install/update flow |
| `lib/ui/widgets.dart` | `Focusable` (remote focus + mouse hover + touch in one), `EmberButton`, `MediaRow`/`MediaTile`, `NetImage` (`loading:` vs `fallback:`), `Loader` (`placeholder:`), skeletons (`TitlePageSkeleton`, `Bone`), `warmImages` |
| `lib/screens/` | One file per screen. `nav.dart` holds the navigation helpers (`openItem`, `openSeerr`, `play`, `playTrailer`, `prefetchTrailer`) |
| `lib/screens/coming_soon.dart` | The Coming Soon release calendar (a tab inside New & Hot) |
| `lib/player/` | The player screen (`player_screen.dart`), the muted hero trailer previews (`hero_preview.dart`), and `engine.dart`: `PlaybackEngine` with `MpvEngine` (media_kit) and `AvEngine` (video_player → AVPlayer, Apple TV only) |
| `lib/platform.dart` | `isAppleTv`. `Platform.isIOS` is also true on Apple TV, so check `isAppleTv` first |
| `server-plugin/` | Older copies of the Jellyfin plugin. **Current source and releases live in github.com/abelm963/ember-trailers** |

Layouts: TV and desktop share the side-rail design (on desktop the rail also opens on hover); phone
uses a bottom tab bar. Every interactive element goes through `Focusable`, so the remote, the mouse
and touch all work.

The design mockups (17 screens) are the reference for how everything should look:
https://claude.ai/artifact/GT3uTzN7739DSi7hcPsWLQ

## The server plugin ("Ember Trailers")

- **Repo:** github.com/abelm963/ember-trailers. It's a C# Jellyfin plugin that builds for
  Jellyfin 12 (net10.0, the default) and for 10.11 (`-p:JellyfinTarget=10.11`, net9.0).
- **Publishing:** the repo's `manifest.json` is a Jellyfin plugin repository, so each release
  needs:
  - a zip in `releases/` containing the dll and a `meta.json`;
  - its MD5 checksum in the manifest;
  - a version per target (`0.x.1.0` for Jellyfin 12, `0.x.0.1` for 10.11).
- **Endpoints** (all under `/EmberTrailers`):
  - `Health` (the `features` list tells Ember what the running plugin can do)
  - `Items/{id}/Info` (returns a reason when a trailer can't play)
  - `Videos/{key}/Info`
  - `Videos/{key}/Stream`
  - `Videos/{key}/Test` (admins only)
  - `Calendar`
  - `CalendarKeys` (admins only)
  - `Items/{id}/Override`
- **Keys:** it uses Jellyfin's own TMDB key, read through reflection from the TMDb plugin
  settings, or Jellyfin's built-in key. A Trakt Client ID is optional and saved on the server
  only. **Never put API keys in the app or the repo.**
- **yt-dlp:** the plugin downloads yt-dlp and keeps it updated, and also downloads Deno (yt-dlp
  needs a JavaScript runtime for YouTube).
- **Updating:** Ember can install or update the plugin from Settings › Trailers & calendar. It
  adds the repository, installs the package and restarts. **Gotcha:** Jellyfin's built-in restart
  does not reload plugin code that's already loaded. After an update the Jellyfin container or
  service needs a full restart, and Ember now says so.

## Where things stand

Working:
- Library browsing, details pages, the player (tracks, quality, trickplay, Skip Intro, Up Next) and search.
- Seerr: automatic sign-in, Requests, Trending, Preview, requesting.
- The Coming Soon calendar, served through the plugin.
- Skeleton loading on title pages.

**Open problem: trailers don't play in Ember.** Where it gets to:
- Hearth accepts the trailer, and the player opens with "Trailer · streamed by your server".
- mpv then reports "Failed to open" on `/EmberTrailers/Videos/{key}/Stream`.
- Plugin 0.4 (which prefers YouTube's combined HLS streams and adds the Test endpoint) is
  installed but was never loaded, because Jellyfin needs a full container restart.

Next steps:
1. Find out how Hearth runs Jellyfin (Docker? Unraid? TrueNAS?) and fully restart it.
2. Settings › Trailers & calendar should then show plugin 0.4.1.0 with no "New version available".
3. Run **Test trailer playback** and read the error.
4. If YouTube blocks Hearth outright, consider playing trailers directly from YouTube in the
   app instead of through the server.

Smaller known issues:
- The side menu can stay open after clicking, and swallow the next click.

## Apple TV

- Built with flutter-tvos (github.com/fluttertv/flutter-tvos, macOS only), which tracks Flutter
  3.47. `bash setup-appletv.sh` on a Mac installs it, creates `tvos/` the first time and installs
  on the Apple TV. The owner uses a Mac with a free Apple ID, so the app expires after 7 days.
- mpv doesn't run on tvOS: `MediaKit.ensureInitialized()` is skipped and `AvEngine` plays instead.
  Plugins need `_tvos` packages (`video_player_tvos`, `shared_preferences_tvos`, `url_launcher_tvos`).
- Full-screen playback on Apple TV uses Apple's own player, not Flutter: `lib/player/native_player.dart`
  (Dart: asks Jellyfin, picks audio/subtitles, reports progress) talks over the `ember/player` channel
  to `tvos/Runner/NativePlayer.swift` (AVPlayerViewController: true HDR10/Dolby Vision/Atmos, Match
  Content, Skip Intro, Next Episode countdown, audio/subtitle menus, "Are you still watching?").
  `nav.dart` `play()`/`playTrailer()` route there when `isAppleTv`; `PlayerScreen` is for the other platforms.
- `JellyfinClient.playbackSource` sends an Apple TV device profile: direct play for MP4/MOV with
  H.264/HEVC and AAC/AC3/EAC3/ALAC/FLAC; everything else comes back as fMP4 HLS with the picture and
  sound copied when possible. CodecProfiles declare HDR10/HDR10+/HLG/Dolby Vision so they pass through.
  Text subtitles go inside the HLS stream (Method `Hls`); PGS/DVD are burned in.
- Audio defaults (`NativePlayer.chooseTracks`, tested in `test/native_player_test.dart`): preferred
  language, then the best track Apple TV plays as-is (E-AC-3 Atmos first, never commentary). TrueHD/DTS
  are converted by the server to E-AC-3 5.1/7.1, so TrueHD Atmos loses Atmos (Apple TV can't output TrueHD).
- "Are you still watching?" (Settings, Apple TV only): asked after N episodes auto-advance with no
  remote input. Presses, swipes, pause/play, scrubbing, skip buttons and track changes count; volume
  can't be seen (it goes from the remote straight to the TV).
- Trailers on Apple TV need Ember Trailers 0.5+ (`features` contains `hls`): `trailerHlsUrl` →
  `/EmberTrailers/Videos/{key}/master.m3u8`, YouTube's HLS passed through the server.
- `.github/workflows/apple-tv.yml` builds `claude/**` branches too, but only `apple-tv` and `main`
  publish the release that atvloadly installs.
- Not yet tested on hardware: this was written on Linux. Check on the Apple TV first.

Later: Android TV and phones.
