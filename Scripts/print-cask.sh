#!/bin/sh
# Prints the Homebrew cask stanza for the kartikssj/homebrew-alter tap,
# with version and sha256 filled in from the release artifact.
set -eu
cd "$(dirname "$0")/.."

APP="build/Build/Products/Release/Alter.app"
if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run 'make release' first" >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="dist/Alter-$VERSION.zip"
if [ ! -f "$ZIP" ]; then
    echo "error: $ZIP not found — run 'make release' first" >&2
    exit 1
fi
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

cat <<EOF
cask "alter" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/kartikssj/alter/releases/download/v#{version}/Alter-#{version}.zip"
  name "Alter"
  desc "Keyboard-driven window switcher for macOS"
  homepage "https://github.com/kartikssj/alter"

  depends_on macos: ">= :sonoma"

  app "Alter.app"

  caveats <<~EOS
    Alter is not notarized yet. On first launch, right-click the app and choose
    Open, or install with:
      brew install --cask kartikssj/alter/alter --no-quarantine

    Alter requires Accessibility access (to intercept the hotkeys and focus
    windows) and optionally Screen Recording (to show other apps' window
    titles). Grant them when prompted on first launch.
  EOS
end
EOF
