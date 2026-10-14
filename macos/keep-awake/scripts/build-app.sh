#!/usr/bin/env bash
# build the app bundle that carries sirven-keep-awake and its privileged helper, laid out the way
# SMAppService expects. it builds and signs; it never registers the helper.
#
#   SIRVEN_TEAM_IDENTIFIER=<team> SIRVEN_SIGNING_IDENTITY="<certificate name>" \
#     macos/keep-awake/scripts/build-app.sh [output folder]     (default: macos/keep-awake/.build/app)
#
# SIRVEN_TEAM_IDENTIFIER is the ten-character identifier of the Apple developer team that signs the
# app. find it with: security find-identity -v -p codesigning (the value in parentheses). it is
# written into the helper's executable and into nothing else; the helper refuses every connection
# without it, and this script refuses to build without it.
#
# SIRVEN_SIGNING_IDENTITY names the signing certificate in the keychain. ad hoc signing ("-") has no
# team, so the helper could never be registered with it, and the script refuses it too.
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$PACKAGE_DIR/.build/app}"
TEAM="${SIRVEN_TEAM_IDENTIFIER:-}"
IDENTITY="${SIRVEN_SIGNING_IDENTITY:-}"
APP="$OUTPUT/Sirven.app"

[ -n "$TEAM" ] || { echo "SIRVEN_TEAM_IDENTIFIER is not set: the helper would refuse every connection. see the top of this script." >&2; exit 1; }
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo "SIRVEN_TEAM_IDENTIFIER must be ten capital letters and digits" >&2; exit 1; }
[ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ] || { echo "SIRVEN_SIGNING_IDENTITY must name a certificate in the keychain; ad hoc signing has no team" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift build --package-path "$PACKAGE_DIR" -c release
BUILT="$(swift build --package-path "$PACKAGE_DIR" -c release --show-bin-path)"

# the helper is linked again alone, with the team identifier in an Info.plist section of its own
# executable. the section is part of the signed binary, so the value cannot be changed afterwards.
cat >"$WORK/helper-info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>xyz.sirven.keep-awake-helper</string>
	<key>SirvenTeamIdentifier</key><string>$TEAM</string>
</dict>
</plist>
PLIST
swift build --package-path "$PACKAGE_DIR" -c release --product sirven-keep-awake-helper \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$WORK/helper-info.plist"

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

# the two checks that the helper will accept the app: the helper, run from inside the finished bundle,
# reports the team it embedded (--print-team exits before it touches anything), and the signature is by
# the same team. a mismatch means the helper would refuse the app, so stop here.
HELPER="$APP/Contents/MacOS/sirven-keep-awake-helper"
[ "$("$HELPER" --print-team)" = "$TEAM" ] || { echo "the helper does not report team $TEAM from inside the app; refusing to continue" >&2; exit 1; }
SIGNED_TEAM="$(codesign -dv --verbose=2 "$HELPER" 2>&1 | sed -n 's/^TeamIdentifier=//p' || true)"
[ "$SIGNED_TEAM" = "$TEAM" ] || { echo "the helper is signed by team '${SIGNED_TEAM:-none}', not $TEAM; refusing to continue" >&2; exit 1; }
echo "built $APP (team $TEAM, signed with: $IDENTITY)"
