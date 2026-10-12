#!/usr/bin/env bash
# build the sirven menu bar app as an .app bundle: a release build of the Swift package, an
# Info.plist with LSUIElement so there is no Dock icon, and an ad hoc signature. Signing with a
# developer identity and notarizing belong to the download and onboarding pipeline, which takes
# this bundle as its input.
#
#   macos/menu-bar/build-app.sh            builds macos/menu-bar/build/Sirven.app
#   OUT=/some/dir macos/menu-bar/build-app.sh
#
# the app must not be sandboxed: it runs Tailscale's own command-line tool, which a sandboxed
# app cannot start.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HERE/build}"
APP="$OUT/Sirven.app"
VERSION="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HERE/../../package.json" | head -n 1)"

swift build --package-path "$HERE" -c release --product SirvenMenuBar
BIN="$(swift build --package-path "$HERE" -c release --show-bin-path)/SirvenMenuBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Sirven"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>xyz.sirven.menu-bar</string>
  <key>CFBundleName</key><string>Sirven</string>
  <key>CFBundleDisplayName</key><string>Sirven</string>
  <key>CFBundleExecutable</key><string>Sirven</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-0.0.0}</string>
  <key>CFBundleVersion</key><string>${VERSION:-0.0.0}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "built $APP"
