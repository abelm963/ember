# Working on Ember

## Set-up

- Flutter **3.47.8** (Dart 3.13). Windows: `setup-windows.ps1` installs everything. Apple TV builds
  need a Mac (`setup-appletv.sh`) or GitHub's build (`.github/workflows/apple-tv.yml`).
- `flutter pub get`, then `flutter run -d windows` (press `r` to reload).

## Before you push

```bash
dart format .          # 120 columns, set in analysis_options.yaml
flutter analyze        # must say "No issues found"
flutter test
```

GitHub runs the same checks on every push and pull request (`checks.yml`), and builds Apple TV
for `apple-tv`, `main` and `claude/**` branches (`apple-tv.yml`).

## Rules of the codebase

- **Keep behaviour.** Refactors move code; they don't change what people see or how playback
  works. Changes to behaviour go in their own commits, described as such.
- **Every control is a `Focusable`**, so the remote, mouse and touch all work. After changing a
  screen, try it with the arrow keys, Enter and Esc (TV mode: Settings › Interface › TV).
- **Sizes in TV units:** write `context.px(24)`, not `24`.
- **Layering:** `ui/` and `api/` never import `screens/` or `player/`; `player/` never imports
  `screens/`. Pieces used by several screens go in `screens/shared/` or `ui/`.
- **Errors:** show people a plain sentence; for failures Ember carries on without, call
  `logWarning()` (it removes tokens and cookies). Never print URLs or headers raw.
- **No secrets in the repo**, and no server addresses or account names (the repo is public).
- **Tests:** a screen that calls a new endpoint needs a route in the fake server in
  `test/screens_test.dart`. Pure logic (tracks, segments, ranking) gets unit tests.
- **Playback and the Apple TV player are high-risk:** test on the device after changing
  `player/`, `tracks.dart`, `JellyfinClient.playbackSource` or `tvos/Runner/NativePlayer.swift`.

## Branches

`apple-tv` is where work lands (it publishes the Apple TV build). Make a branch, open a pull
request into `apple-tv`, and merge once the checks are green.
