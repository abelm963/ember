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

On Apple TV, films and episodes play in Ember's own player, drawn on top of Apple's video engine
(AVPlayer). Settings › "Use Apple's player (for HDR and Dolby Vision)" switches them to Apple's
own player instead, which shows true HDR10 and Dolby Vision. Trailers always use Apple's player.
Files Apple TV can't open directly (MKV, DTS, TrueHD) are repackaged by your server into a
stream it can, copying the picture untouched where possible. Audio and subtitle choices go
through the server, and picture-based subtitles (PGS) are burned in.

### Apple TV builds on GitHub (no Mac needed)

Every push to `apple-tv` or `main` builds `Ember.ipa` on one of GitHub's Macs
(`.github/workflows/apple-tv.yml`) and publishes it as a release. atvloadly on a home server
(`tools/hearth/install-atvloadly.sh`) picks each release up, signs it with a free Apple ID and
installs it on the Apple TV. Pushes to `claude/**` branches are built to check them but are not
published.

## How it is organised

| Folder | What's in it |
| --- | --- |
| `lib/main.dart` | Start-up, the Back key everywhere, and the first screen (connect → profiles → app) |
| `lib/api/` | Jellyfin (`jellyfin.dart`), Seerr (`seerr.dart`), trailers found on YouTube (`youtube.dart`), and the Recommended ranking (`recommend.dart`, `taste.dart`) |
| `lib/state/app_state.dart` | Saved servers, profiles, settings, and which layout to use |
| `lib/player/` | The player screen and its controls, the playback engines (mpv, or AVPlayer on Apple TV), track choice, intro markers, trailers, Apple's player on Apple TV |
| `lib/screens/` | Every screen, plus `nav.dart` (opening titles and starting playback) and `shared/` (pieces several screens use) |
| `lib/ui/` | Colours, fonts and the shared building blocks: `Focusable`, buttons, images, rows, dialogs, skeletons |
| `lib/util/` | Logging with sign-in secrets removed |
| `test/` | Unit and widget tests against a fake server |
| `tvos/` | The Apple TV Xcode project, including Apple's player (`NativePlayer.swift`) |

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the parts fit together, and
[CONTRIBUTING.md](CONTRIBUTING.md) how to change and check the code.

## One app, three ways to navigate

The layout is picked automatically, and can be forced in Settings › Interface:

- **TV** (Apple TV, Android TV): remote only. A side menu, a focus highlight that is always
  visible, Select to open, Back to go back. On Windows use the arrow keys, Enter and Esc to test it.
- **Desktop** (Windows, Mac): mouse first. The same side menu as TV (it also opens when the mouse
  moves onto it), hover effects, scroll arrows on rows, Back buttons. The keyboard also works.
- **Phone** (iPhone, Android): touch. A bottom tab bar and swipeable rows.

Every interactive element is a `Focusable` (`lib/ui/focusable.dart`), which handles remote focus,
mouse hover and touch in one place, so new screens get all three for free.

## Picture and sound

| Format | Windows | Apple TV |
| --- | --- | --- |
| 4K, HEVC, AV1, MKV, any subtitle | Plays directly | Plays directly |
| HDR10, HDR10+, HLG | Tone-mapped to SDR (accurate colours, not true HDR) | Apple TV: true HDR with Settings › "Use Apple's player", SDR in Ember's player |
| Dolby Vision (profiles 5, 7, 8) | Decoded with correct colours, shown as SDR | Apple TV: true Dolby Vision with Apple's player, SDR in Ember's player |
| Dolby Atmos, TrueHD, DTS-HD MA, DTS:X | Passthrough to a receiver (Settings › Playback), or decoded to multichannel | Apple TV: Dolby Digital Plus (including Atmos) plays as-is; TrueHD and DTS are converted by the server to Dolby Digital Plus 5.1/7.1, so TrueHD Atmos loses Atmos |

Flutter draws in SDR, so true HDR needs a native video surface: on Apple TV that is Apple's
player (the setting above). Android TV is not built yet.

## Seerr

Settings › Seerr requests: add the Seerr address. Ember then signs in to Seerr as you by itself,
using your Jellyfin sign-in (Quick Connect), so there is no second password. Signing in to Ember
with a password also signs in to Seerr with it. Requests are made as you, and admins can approve
or decline from the Requests screen.

## Trailers

Nothing needs installing on the server. Ember finds each title's official trailer (from
Jellyfin's trailer links, or Seerr's) on YouTube itself and plays it in its own player, keeping
the original soundtrack. If YouTube won't hand a stream over, or Settings › "Play trailers in
the app" is off, the trailer opens in the YouTube app instead.

The older Ember Trailers Jellyfin plugin now lives in
[abelm963/ember-trailers](https://github.com/abelm963/ember-trailers). It is optional: if a server
has it, Ember only uses its release calendar for Coming Soon.

## Development

```bash
flutter pub get
dart format --output=none --set-exit-if-changed .   # formatting (120 columns)
flutter analyze                                     # expected: No issues found
flutter test                                        # unit and widget tests against a fake server
```

The same three checks run on GitHub for every push and pull request
(`.github/workflows/checks.yml`). See [CONTRIBUTING.md](CONTRIBUTING.md).

Ember is built with Flutter 3.47.8 (Dart 3.13). Apple TV uses flutter-tvos `v3.47.8-tvos.1.11.4`,
which pins the same Flutter.
