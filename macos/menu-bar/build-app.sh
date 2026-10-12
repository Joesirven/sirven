#!/usr/bin/env bash
# build the sirven menu bar app as an .app bundle: a release build of the Swift package, an
# Info.plist with LSUIElement so there is no Dock icon, and an ad hoc signature. Signing with a
# developer identity and notarizing belong to the download and onboarding pipeline, which takes
# this bundle as its input.
#
#   macos/menu-bar/build-app.sh            builds macos/menu-bar/build/<name>.app, the name from project.json
#   OUT=/some/dir macos/menu-bar/build-app.sh
#
# BUNDLE_IDENTIFIER sets the bundle identifier; the default is a placeholder until the signed
# bundle settles one shared identifier.
#
# the app must not be sandboxed: it runs Tailscale's own command-line tool, which a sandboxed
# app cannot start.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HERE/build}"
# the product name is a working name that lives only in project.json, so it is read from there.
NAME="$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HERE/../../project.json" | head -n 1)"
NAME="${NAME:-Sirven}"
APP="$OUT/$NAME.app"
VERSION="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HERE/../../package.json" | head -n 1)"

swift build --package-path "$HERE" -c release --product SirvenMenuBar
BIN="$(swift build --package-path "$HERE" -c release --show-bin-path)/SirvenMenuBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_IDENTIFIER:-org.example.sirven.menu-bar}</string>
  <key>CFBundleName</key><string>${NAME}</string>
  <key>CFBundleDisplayName</key><string>${NAME}</string>
  <key>CFBundleExecutable</key><string>${NAME}</string>
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
