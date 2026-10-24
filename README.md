# Ember

A Netflix-style Jellyfin client with Seerr requests, built in Flutter so one codebase runs on
Windows now and Apple TV, Android TV, iPhone and Android phones later.

## Run it on Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1
```

The script installs anything missing (Git, Visual Studio C++ build tools, Flutter) and starts
the app. After the first time, `flutter run -d windows` in this folder is enough. While it runs,
press `r` in the terminal to reload code changes instantly.

Build a standalone app: `flutter build windows --release` → `build\windows\x64\runner\Release\ember.exe`.

## Run it on Apple TV (from a Mac)

Apple TV apps can only be built on a Mac with Xcode (free from the Mac App Store). Ember uses
[flutter-tvos](https://github.com/fluttertv/flutter-tvos), a community version of Flutter that
builds for Apple TV.

1. Put the Apple TV and the Mac on the same Wi-Fi.
2. On the Apple TV: Settings › Remotes and Devices › Remote App and Devices (leave it open).
3. On the Mac, in this folder: `bash setup-appletv.sh`

The script installs what's missing, adds the Apple TV project (`tvos/`) the first time, asks you
to pick your Apple ID in Xcode for signing, then builds Ember and installs it on the Apple TV.

With a free Apple ID, Apple lets a self-installed app run for 7 days. After that it won't open
until you run `bash setup-appletv.sh` again. A paid Apple Developer account ($99/year) removes the
limit and allows TestFlight.

On Apple TV, Ember plays through Apple's own player. Files it can't open directly (MKV, DTS,
TrueHD) are repackaged by your server into a stream it can, copying the picture untouched where
possible. Audio and subtitle choices go through the server, and picture-based subtitles (PGS)
are burned in.

## How it is organised

| Folder | What's in it |
| --- | --- |
| `lib/api/jellyfin.dart` | Jellyfin server: sign-in (password and Quick Connect), library, playback, progress, intro markers, file formats |
| `lib/api/seerr.dart` | Seerr: trending, search, title details, requests, approve/decline |
| `lib/state/app_state.dart` | Saved servers, profiles, settings, and which layout to use |
| `lib/ui/` | Colours, fonts, and the shared building blocks (focusable tiles, buttons, rows) |
| `lib/screens/` | Every screen: connect, sign in, profiles, home, shows, movies, My List, search, details, preview, requests, settings |
| `lib/player/` | The video player: mpv everywhere, Apple's player on Apple TV (`engine.dart`) |

## One app, three ways to navigate

The layout is picked automatically, and can be forced in Settings › Interface:

- **TV** (Apple TV, Android TV): remote only. A side menu, a focus highlight that is always
  visible, Select to open, Back to go back. On Windows use the arrow keys, Enter and Esc to test it.
- **Desktop** (Windows, Mac): mouse first. A top menu bar, hover effects, scroll arrows on rows,
  Back buttons. The keyboard also works.
- **Phone** (iPhone, Android): touch. A bottom tab bar and swipeable rows.

Every interactive element is a `Focusable` (`lib/ui/widgets.dart`), which handles remote focus,
mouse hover and touch in one place, so new screens get all three for free.

## Picture and sound

| Format | Windows (this build) | Apple TV / Android TV (later) |
| --- | --- | --- |
| 4K, HEVC, AV1, MKV, any subtitle | Plays directly | Plays directly |
| HDR10, HDR10+, HLG | Tone-mapped to SDR (accurate colours, not true HDR) | True HDR through the native player |
| Dolby Vision (profiles 5, 7, 8) | Decoded with correct colours, shown as SDR | True Dolby Vision through the native player |
| Dolby Atmos, TrueHD, DTS-HD MA, DTS:X | Passthrough to a receiver (Settings › Playback), or decoded to multichannel | Passthrough to a receiver where the TV box supports it |

Flutter draws in SDR on Windows, so true HDR there needs a native video surface. That is
planned with the Apple TV and Android TV players.

## Seerr

No setup is needed when Seerr runs on the same machine as Jellyfin on its usual port (5055):
Ember finds it and signs in with your Jellyfin profile (Seerr asks for a Quick Connect code and
Ember approves it for you, so Quick Connect must be on in Jellyfin). Otherwise add the address in
Settings › Seerr requests. Requests are made as you, and admins can approve or decline from the
Requests screen, which also shows download progress from Radarr / Sonarr.

Home shows "Because you watched …" rows: TMDB recommendations (through Seerr) for the last few
movies and shows you watched, limited to titles that aren't on the server yet, so each one can be
requested from its page.

## Trailers inside Ember (server plugin)

`server-plugin/EmberTrailers-plugin.zip` is a Jellyfin plugin (built for Jellyfin 12.1) that
streams official trailers through your server, so Ember plays them in its own player and
autoplays muted previews on Home. Nothing is stored.

1. Unzip it into Jellyfin's `plugins` folder, so you get `plugins/EmberTrailers_0.1.0.0/`:
   - Docker: the folder mapped to `/config/plugins`
   - Linux: `/var/lib/jellyfin/plugins`
   - Windows: `C:\ProgramData\Jellyfin\Server\plugins`
2. Restart Jellyfin. On start it downloads yt-dlp, and updates it every night at 03:00
   (Dashboard › Scheduled Tasks › Ember Trailers).
3. In Ember: Settings › Trailers should say "online".

Source is in `server-plugin/src` (`dotnet build -c Release`).
