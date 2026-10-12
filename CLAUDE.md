# Ember: notes for Claude Code

Ember is a Netflix-style Jellyfin client with Seerr requests, written in Flutter. Windows is the
test bed (this PC, "Nexus"). Apple TV comes next (App Store eventually), then Android TV, iPhone and
Android phones. The branding is original ("Ember"); no Netflix names or marks.

The owner is not a developer: explain things in plain language, make the change yourself, and
say what to click or run to see it.

## Build, run, test

- Flutter 3.47 / Dart 3.13, at `C:\dev\flutter`. Windows Developer Mode is on (needed for symlinks).
- `flutter analyze` → only 2 known info-level lints are expected.
- `flutter test` → 11 tests, all should pass. They use a mock server through `http.runWithClient`
  (see `test/screens_test.dart`); add routes there when a screen calls a new endpoint.
- **Update Ember.bat** = kill `ember.exe` → `flutter build windows --release` → start
  `build\windows\x64\runner\Release\ember.exe`. This is how the owner runs the app.
- Run `flutter analyze` and `flutter test` before every push.
- Pinned: `media_kit` (mpv) for playback. `youtube_explode_dart` finds YouTube's own stream
  addresses for the in-app YouTube fallback (`lib/player/youtube_direct.dart`); YouTube changes
  break it from time to time, so update it when that fallback stops working. There is no `google_fonts`: the fonts are bundled under
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
| `lib/player/` | mpv player (`player_screen.dart`), the muted hero trailer previews (`hero_preview.dart`) and the straight-from-YouTube trailer sources (`youtube_direct.dart`) |
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
- **How a trailer streams (0.5+):** the trailer check (`Items/{id}/Info`) runs `yt-dlp -J` once and
  keeps YouTube's stream addresses until shortly before they expire. `Videos/{key}/Stream` then tries,
  in order: YouTube's combined HLS stream (remuxed by Jellyfin's ffmpeg to MPEG-TS), separate H.264
  picture + AAC sound joined to Matroska, other codecs, the plain 360p file (passed through with
  Range/seeking), the same again asking YouTube as other player kinds, and last the old yt-dlp pipe.
  Each try must produce data within 15 s (yt-dlp: 40 s). If all fail it answers 502 with
  `X-Ember-Error` and a JSON list of attempts; `Videos/{key}/Test` shows the same list in Ember.
- **Endpoints** (all under `/EmberTrailers`):
  - `Health` (the `features` list tells Ember what the running plugin can do; 0.5 adds
    `directstreams` and `streamerrors`)
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
- **Building:** `dotnet build -c Release` (and `-p:JellyfinTarget=10.11`) in
  `src/Jellyfin.Plugin.EmberTrailers`. Zip the dll with a `meta.json` (same fields as earlier zips),
  put the MD5 of the zip in the manifest, newest versions first.
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

**Trailers (in progress).** They used to fail with mpv's "Failed to open" on
`/EmberTrailers/Videos/{key}/Stream`. Plugin 0.4 was installed but never loaded (Jellyfin needs a
full restart). What changed on 2026-10-12:
- Plugin 0.5 (branch `fix/robust-trailer-stream` in ember-trailers, zips and manifest entries ready,
  **not published yet**: the owner approves before it goes to `main`) streams YouTube's addresses
  directly with several fallbacks and reports why a stream failed (see "How a trailer streams").
- Ember's player now falls back by itself: if the server can't start the trailer (error, empty
  stream, or nothing after 60 s) it plays the trailer straight from YouTube inside Ember
  (`youtube_direct.dart`, tried as several YouTube player kinds). Without the trailer service it
  goes straight to YouTube in-app. "Open on YouTube" remains only as the last resort.
- Hero previews fall back to YouTube quietly the same way.
- The side menu now closes after a pick, stays closed while the mouse rests where it was, and the
  remote/keyboard lands on the page (`shell.dart`, test in `test/menu_test.dart`).

Next steps:
1. Find out how Hearth runs Jellyfin (Docker? Unraid? TrueNAS?) and fully restart it after
   publishing 0.5.
2. Settings › Trailers & calendar should then show plugin 0.5.1.0 with no "New version available".
3. Run **Test trailer playback**: it now shows "Streamed as" and every method it tried.
4. If YouTube blocks Hearth outright, Ember already plays trailers straight from YouTube.

Later: an Apple TV build (AVPlayer for Dolby Vision/Atmos), Android TV, and phones.
