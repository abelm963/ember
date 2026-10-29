# Ember: notes for Claude Code

Ember is a Netflix-style Jellyfin client with Seerr requests, written in Flutter. Windows is the
test bed (this PC, "Nexus"). Apple TV comes next (App Store eventually), then Android TV, iPhone and
Android phones. The branding is original ("Ember"); no Netflix names or marks.

The owner is not a developer: explain things in plain language, make the change yourself, and
say what to click or run to see it.

## Build, run, test

- Flutter 3.47 / Dart 3.13, at `C:\dev\flutter`. Windows Developer Mode is on (needed for symlinks).
- `dart format .` (120 columns, set in `analysis_options.yaml`), `flutter analyze` → "No issues found",
  `flutter test` → 71 tests, all pass. GitHub runs all three on every push (`checks.yml`).
  Tests use a mock server through `http.runWithClient` (see `test/screens_test.dart`); add routes
  there when a screen calls a new endpoint.
- How the code fits together, and the layering rules: `docs/ARCHITECTURE.md`. Working rules:
  `CONTRIBUTING.md`. `player/`, `api/` and `ui/` never import `screens/`.
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
| `lib/api/jellyfin.dart` | Jellyfin: sign-in (password + Quick Connect), library, playback (direct play or HLS transcode), progress, intro segments, trickplay, bitrate test, the optional plugin's release calendar |
| `lib/api/youtube.dart` | Trailers, found on the device itself (Moonfin's approach, made sturdier): YouTube is asked as its Vision Pro app (with a visitor id) and iPhone app at once for an HLS playlist, then as its Android app (360p MP4), then youtube_explode_dart. Each answer is checked before playing; a stream that won't play makes the player ask for the next way (`nextAfter`), and that way goes last for the session. Keeps the original soundtrack, not YouTube's dubs. Tested in `test/youtube_test.dart`. Nothing on the server. `player/trailers.dart` `findTrailer` picks the title's trailer (Jellyfin's RemoteTrailers, then Seerr) and caches it; `tool/trailer_probe.dart <ids>` checks it works |
| `lib/api/seerr.dart` | Seerr: cookie jar with `connect.sid` and the CSRF tokens, automatic re-sign-in, Quick Connect sign-in, discover/search/details/requests, `allMedia()` for status lookups |
| `lib/state/app_state.dart` | Accounts, settings, form factor, Seerr automatic set-up: `findSeerr` tries the address another Ember device saved on Jellyfin for this user (display preferences, client `ember`, key `seerrUrl`), then `SeerrClient.guessesFrom` the Jellyfin address (port 5055, ports next to Jellyfin's), and signs in with the Jellyfin profile (Quick Connect). No typing on the TV |
| `lib/ui/` | `widgets.dart` re-exports the building blocks, one file each: `focusable.dart` (`Focusable`: remote focus + mouse hover + touch in one), `buttons.dart` (`EmberButton`, chips, badges), `media_tiles.dart` (`MediaRow`/`MediaTile`), `images.dart` (`NetImage` with `loading:` vs `fallback:`, `warmImages`), `feedback.dart` (`Loader` with `placeholder:`, `toast`), `skeletons.dart` (`TitlePageSkeleton`, `Bone`), `dialogs.dart` (`EmberDialog`, `pickOption`), `scale.dart` (`context.px`). `browse.dart`: Billboard, poster rows, filters |
| `lib/screens/` | One file per screen. `nav.dart` holds the navigation helpers (`openItem`, `openSeerr`, `play`, `playTrailer`, `warmPlayback`); `shared/media_entries.dart` the poster-row entries and meta line several screens use |
| `lib/screens/discover.dart` | Discover (menu): Recommended, Coming Soon and Explore (Seerr's movies and shows not on the server; Type and Genre in the filter panel; TMDB genre ids in `discoverGenres`). Billboard on TV and desktop |
| `lib/api/recommend.dart`, `lib/api/taste.dart` | Recommended's ranking, run each time the tab opens. `recommend.dart` gathers 2 years of history from Jellyfin (movies: how far and how often; shows: episodes per season, seasons finished, caught up), likes and the Seerr watchlist, then links (Jellyfin Similar, TMDB recommendations/similar via Seerr, the next film in a series, shows by the same creators, a new season, same director/leads); Seerr answers are kept for a day (`rec1.*` in shared preferences). `taste.dart` has every number: taste points, fading (half every 9 months, never below 15%), link strengths, quality, the 30% variety cost and at least 12 of 20 Top picks on the server, rows, and each pick's reason (shown with its details). Tested in `test/taste_test.dart` with the worked example from the design doc |
| `lib/screens/coming_soon.dart` | The Coming Soon release calendar (a tab inside Discover) |
| `lib/player/` | The player screen (`player_screen.dart`, the player the owner designed; its buttons, menus and scrubber in `player_controls.dart`), `trailers.dart` (trailer lookup and cache), `tracks.dart` (picks the version, soundtrack, subtitles and quality before the server is asked; tested in `test/tracks_test.dart`), the muted hero trailer previews (`hero_preview.dart`), `segments.dart` (checks the server's intro/recap/credits times against the episode's length and falls back to chapter names; tested in `test/segments_test.dart`), and `engine.dart`: `PlaybackEngine` with `MpvEngine` (media_kit) and `AvEngine` (video_player → AVPlayer, Apple TV only) |
| `lib/platform.dart` | `isAppleTv`. `Platform.isIOS` is also true on Apple TV, so check `isAppleTv` first |
| `lib/util/log.dart` | `logWarning()` / `redact()`: device log with tokens, cookies and API keys removed. Use it instead of an empty `catch` when a failure matters |
| Jellyfin plugin | Not in this repo. **Source and releases live in github.com/abelm963/ember-trailers** |

Player layout (TV and desktop) follows the big streaming apps: everything along the bottom (title,
progress bar with the time left, then Episodes / Next Episode / Audio & Subtitles / Restart / Quality).
Select plays/pauses (or presses Skip Intro/Recap while it shows), left/right scrub with the trickplay
picture and jump when the presses stop. After 12 s paused a dimmed "You're watching" screen shows the
story. Next Episode fills up as it counts down, with Watch Credits beside it; "Are you still watching?"
works in Ember's player too. Audio & Subtitles is two lists over the picture with plain names
("English 5.1", "English (CC)": `audioLabel`/`subtitleLabel` in `tracks.dart`); subtitle picks are
remembered (`preferredSubtitleLanguage`, `rememberedSubtitleMode`).

Home, Movies and Shows on TV and desktop are a `Billboard` (`lib/ui/browse.dart`): the focused
title's picture fills the top of the screen (running under the menu bar) with its logo, details and
story; the rows sit underneath, one at a time; until a row has focus the featured title shows with
Play / More Info and its muted preview. `PosterRow`s inside it report focus through `BillboardScope`.
Movies and Shows have Genre and Sort in the filter panel and a Top 10 row with big numbers
(`PosterEntry.rank`).

Page headers (TV and desktop): every top-level page uses `PageHeader` (`lib/ui/browse.dart`): the title,
then one fixed line with the page's tabs on the left and a filter button (three lines) on the right, always at
`PageHeader.top`, so switching tabs never moves the heading. All of a page's filters (`FilterGroup`s: Coming
Soon's Show, Explore's Type and Genre, Movies/Shows' Genre and Sort, Requests' Status) are in the panel that
button opens from the right; with a filter on, the button names it. Phone keeps its chips.

Layouts: TV and desktop share the side-rail design (on desktop the rail also opens on hover); phone
uses a bottom tab bar. Every interactive element goes through `Focusable`, so the remote, the mouse
and touch all work.

The design mockups (17 screens) are the reference for how everything should look:
https://claude.ai/artifact/GT3uTzN7739DSi7hcPsWLQ

## The server plugin ("Ember Trailers") is optional

Ember needs nothing installed on the server: just Jellyfin (and Seerr for requests). Trailers are
found and played on the device (`lib/api/youtube.dart`). If a server happens to have the old
Ember Trailers plugin (github.com/abelm963/ember-trailers), only its release calendar is used for
Coming Soon; otherwise Coming Soon comes from Seerr. Ember never offers to install it.
**Never put API keys in the app or the repo.**

## Where things stand

Working:
- Library browsing, details pages, the player (tracks, quality, trickplay, Skip Intro, Up Next) and search.
- Seerr: automatic sign-in, Requests, Trending, Preview, requesting. A request's status (`SeerrRequest.label` in
  `seerr.dart`, tested in `test/seerr_test.dart`) puts approval first (Pending/Declined/Failed), then follows the
  copy it asked for: the 4K copy for 4K requests, only the requested seasons for series. 4K is offered only when
  Seerr has 4K set up and the account may ask for it (`AppState.canRequest4k`).
- Home: "Because you watched …" rows (up to 3) of Seerr titles that aren't on the server yet, from TMDB's
  recommendations for the titles watched most recently (`becauseYouWatched` in `seerr.dart`,
  `_recentlyWatched` in `home.dart`; Settings › Seerr can turn them off).
- The Coming Soon calendar (from Seerr, or the optional plugin when a server has it).
- Watchlist: Seerr's own watchlist (`/discover/watchlist`, `POST /watchlist`, `DELETE /watchlist/{tmdbId}`), with a
  Watchlist button on Seerr title pages. My List shows My List (Jellyfin favourites), Watchlist and Requested.
- Skeleton loading on title pages.

Trailers: played in Ember's own player on every platform, with no server plugin. If YouTube won't
hand a stream over, they open in the YouTube app (also when Settings › "Play trailers in the app" is off).

Smaller known issues:
- The side menu can stay open after clicking, and swallow the next click.

## Apple TV

- Built with flutter-tvos (github.com/fluttertv/flutter-tvos, macOS only), which tracks Flutter
  3.47. `bash setup-appletv.sh` on a Mac installs it, creates `tvos/` the first time and installs
  on the Apple TV. The owner uses a Mac with a free Apple ID, so the app expires after 7 days.
- mpv doesn't run on tvOS: `MediaKit.ensureInitialized()` is skipped and `AvEngine` plays instead.
  Plugins need `_tvos` packages (`video_player_tvos`, `shared_preferences_tvos`, `url_launcher_tvos`).
- Films and episodes on Apple TV play in **Ember's own player** (`PlayerScreen` with `AvEngine`): the
  owner wants the player designed for Ember. Its picture is a Flutter texture, so HDR/Dolby Vision show
  as SDR. Settings › "Use Apple's player (for HDR and Dolby Vision)" (`useApplePlayer`, off by default)
  switches them to Apple's player below. Trailers always use Apple's player (it joins YouTube's
  separate picture and sound files).
- Apple's own player: `lib/player/native_player.dart`
  (Dart: asks Jellyfin, picks audio/subtitles, reports progress) talks over the `ember/player` channel
  to `tvos/Runner/NativePlayer.swift` (AVPlayerViewController: true HDR10/Dolby Vision/Atmos, Match
  Content, Skip Intro, Next Episode countdown, audio/subtitle menus, "Are you still watching?").
  `nav.dart` `play()` routes there on Apple TV only when `useApplePlayer` is on, and `playTrailer()` always
  does on Apple TV; otherwise `PlayerScreen` plays.
- `JellyfinClient.playbackSource` sends an Apple TV device profile: direct play for MP4/MOV with
  H.264/HEVC and AAC/AC3/EAC3/ALAC/FLAC; everything else comes back as fMP4 HLS with the picture and
  sound copied when possible. CodecProfiles declare HDR10/HDR10+/HLG/Dolby Vision so they pass through.
  Text subtitles go inside the HLS stream (Method `Hls`); PGS/DVD are burned in.
- Audio defaults (`chooseTracks` in `tracks.dart`): preferred language (codes in any spelling, or the
  language named in a track's title when it has no code), then the best track Apple TV plays as-is
  (E-AC-3 Atmos first, never commentary). **When a file has more than one soundtrack, Ember always
  names it (AudioStreamIndex) and the server remuxes**, because direct play left the choice to
  AVPlayer, which picked the file's/Apple TV's language (the "Frozen in French" bug). With several
  versions of a film, the one with the preferred language is used (MediaSourceId). A soundtrack
  picked in the player becomes the preferred language.
- Start-up speed: everything is decided before one PlaybackInfo call (`planPlayback`); the Auto
  quality connection test (4 MB) is remembered for 20 minutes and started when a title page opens
  (`warmPlayback`); HLS starts after one segment (MinSegments 1); Apple's player starts playing only
  after the resume jump, with a keyframe-tolerant seek. TrueHD/DTS
  are converted by the server to E-AC-3 5.1/7.1, so TrueHD Atmos loses Atmos (Apple TV can't output TrueHD).
- "Are you still watching?" (Settings, Apple TV only): asked after N episodes auto-advance with no
  remote input. Presses, swipes, pause/play, scrubbing, skip buttons and track changes count; volume
  can't be seen (it goes from the remote straight to the TV).
- Trailers on Apple TV: `NativePlayer.playTrailer` with the stream from `findTrailer`; when YouTube
  gives picture and sound as two MP4 files, `NativePlayer.swift` joins them (AVMutableComposition).
- `.github/workflows/apple-tv.yml` builds `claude/**` branches too, but only `apple-tv` and `main`
  publish the release that atvloadly installs.
- Not yet tested on hardware: this was written on Linux. Check on the Apple TV first.

Later: Android TV and phones.
