#!/bin/bash
# Ember: one-time setup, then build and install on an Apple TV. Run on a Mac, from this folder:
#   bash setup-appletv.sh
# It installs what is missing (CocoaPods, flutter-tvos), adds the Apple TV project (tvos/) the
# first time, then builds Ember and puts it on your Apple TV. Run it again to reinstall.

set -e
cd "$(dirname "$0")"
FTV="$HOME/dev/flutter-tvos"

say() { printf '\n\033[33m== %s ==\033[0m\n' "$1"; }

say "Ember for Apple TV"

# 1. Xcode (from the Mac App Store), with its licence accepted and the tvOS platform installed
if [ ! -d /Applications/Xcode.app ]; then
  echo "Xcode isn't installed. Install it from the Mac App Store (it's free), open it once, then run this again."
  open "macappstore://apps.apple.com/app/id497799835" || true
  exit 1
fi
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  echo "Accepting the Xcode licence (your Mac password may be asked for)..."
  sudo xcodebuild -license accept
  sudo xcodebuild -runFirstLaunch
fi
if ! xcodebuild -showsdks 2>/dev/null | grep -q appletvos; then
  echo "Downloading the tvOS platform for Xcode (a few GB)..."
  xcodebuild -downloadPlatform tvOS
fi

# 2. CocoaPods (some Apple TV plugins need it)
if ! command -v pod >/dev/null 2>&1; then
  echo "Installing CocoaPods..."
  if command -v brew >/dev/null 2>&1; then brew install cocoapods; else sudo gem install cocoapods; fi
fi

# 3. flutter-tvos: Flutter with Apple TV support (installed to ~/dev/flutter-tvos)
if [ ! -x "$FTV/bin/flutter-tvos" ]; then
  echo "Installing flutter-tvos to $FTV ..."
  mkdir -p "$HOME/dev"
  git clone https://github.com/fluttertv/flutter-tvos.git "$FTV"
fi
export PATH="$FTV/bin:$PATH"
if ! grep -q 'flutter-tvos/bin' "$HOME/.zshrc" 2>/dev/null; then
  echo 'export PATH="$HOME/dev/flutter-tvos/bin:$PATH"' >> "$HOME/.zshrc"
fi
flutter-tvos precache

# 4. The Apple TV project (tvos/), created once
if [ ! -d tvos ]; then
  say "Adding the Apple TV project"
  had_widget_test=0; [ -f test/widget_test.dart ] && had_widget_test=1
  flutter-tvos create --org app.ember .
  # `create` also drops in Flutter's sample test, which doesn't apply to Ember.
  [ "$had_widget_test" = 0 ] && rm -f test/widget_test.dart
  echo
  echo "Xcode will open. In it:"
  echo "  1. Click 'Runner' at the top of the left-hand list, then the 'Signing & Capabilities' tab."
  echo "  2. Tick 'Automatically manage signing' and pick your Apple ID under Team"
  echo "     (Add an Account... if it isn't there; a free Apple ID is fine)."
  echo "  3. If it says the bundle identifier isn't available, change it to something of your own,"
  echo "     such as app.ember.abel."
  echo "Then close Xcode and come back here."
  open tvos/Runner.xcodeproj
  read -r -p "Press Enter when signing is set up... "
fi

flutter-tvos pub get

# 5. Find the Apple TV and install
say "Looking for your Apple TV"
echo "If it isn't listed: on the Apple TV open Settings > Remotes and Devices > Remote App and Devices,"
echo "then in Xcode open Window > Devices and Simulators and pair it (same Wi-Fi as this Mac)."
flutter-tvos devices
read -r -p "Copy your Apple TV's id from the list above (the second column) and paste it here: " DEVICE
say "Building and installing Ember (the first build takes a while)"
flutter-tvos run -d "$DEVICE" --release
