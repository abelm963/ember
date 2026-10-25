# Ember

A Netflix-style Jellyfin client with Seerr requests, built in Flutter so one codebase runs on
Windows now and Android TV, iPhone and Android phones later.

**Apple TV** has its own native app in [`apple-tv/`](apple-tv/README.md) (Flutter can't run on
Apple TV); see that folder for how to install it.

## Run it on Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1
```

The script installs anything missing (Git, Visual Studio C++ build tools, Flutter) and starts
the app. After the first time, `flutter run -d windows` in this folder is enough. While it runs,
press `r` in the terminal to reload code changes instantly.

Build a standalone app: `flutter build windows --release` → `build\windows\x64\runner\Release\ember.exe`.

## How it is organised

| Folder | What's in it |
| --- | --- |
| `lib/api/jellyfin.dart` | Jellyfin server: sign-in (password and Quick Connect), library, playback, progress, intro markers, file formats |
| `lib/api/seerr.dart` | Seerr: trending, search, title details, requests, approve/decline |
| `lib/state/app_state.dart` | Saved servers, profiles, settings, and which layout to use |
| `lib/ui/` | Colours, fonts, and the shared building blocks (focusable tiles, buttons, rows) |
| `lib/screens/` | Every screen: connect, sign in, profiles, home, shows, movies, My List, search, details, preview, requests, settings |
| `lib/player/` | The video player, built on mpv |

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

Settings › Seerr requests: add the Seerr address, then sign in with your Jellyfin username and
password (or sign in to Ember with a password and it happens automatically). Requests are made
as you, and admins can approve or decline from the Requests screen.

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
