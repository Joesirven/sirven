#!/usr/bin/env bash
# build a development app bundle that carries sirven-keep-awake and its privileged helper, laid
# out the way SMAppService expects. it builds and signs; it never registers the helper.
#
#   macos/keep-awake/scripts/build-app.sh [output folder]     (default: macos/keep-awake/.build/app)
#
# SIRVEN_SIGNING_IDENTITY names a Developer ID Application certificate in the keychain. without it
# the bundle is signed ad hoc, which is enough to inspect the layout but not to register the helper:
# the system only runs a registered daemon from a properly signed app.
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$PACKAGE_DIR/.build/app}"
IDENTITY="${SIRVEN_SIGNING_IDENTITY:--}"
APP="$OUTPUT/Sirven.app"

swift build --package-path "$PACKAGE_DIR" -c release
BUILT="$(swift build --package-path "$PACKAGE_DIR" -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons"
cp "$PACKAGE_DIR/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$PACKAGE_DIR/Support/xyz.sirven.keep-awake-helper.plist" "$APP/Contents/Library/LaunchDaemons/"
cp "$BUILT/sirven-keep-awake" "$BUILT/sirven-keep-awake-helper" "$APP/Contents/MacOS/"

# the helper first, with its own identifier, then the bundle around it.
codesign --force --options runtime --identifier xyz.sirven.keep-awake-helper --sign "$IDENTITY" \
  "$APP/Contents/MacOS/sirven-keep-awake-helper"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "built $APP (signed with: $IDENTITY)"
