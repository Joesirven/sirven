#!/usr/bin/env bash
# app/macos/build.sh: build Sirven.app, wrap it in a disk image, and write release.json for
# the download page. plan first, like install.sh: --dry-run prints every step and runs none.
#
#   app/macos/build.sh                  local build: this Mac's architecture, ad-hoc signed,
#                                       not notarized. needs no credentials.
#   app/macos/build.sh --release        the public build: universal (Apple Silicon and Intel),
#                                       signed with Jose's Apple distribution certificate,
#                                       notarized, and stapled.
#                                       stops before building unless both credentials are set.
#   --dry-run                           print the plan and change nothing
#   --out <dir>                         where the app, disk image, and release.json go
#                                       (default: dist/macos in the repository)
#
# credentials for --release are Jose's and never live in this repository. pass them by name:
#   SIRVEN_SIGNING_IDENTITY   the full name of the Apple certificate for distributing apps
#                             outside the App Store, exactly as security find-identity lists it
#   SIRVEN_NOTARY_PROFILE     a notarytool keychain profile, created once with
#                             xcrun notarytool store-credentials <profile name>
# see docs/DOWNLOAD-AND-ONBOARDING.md for the one-time setup.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "error: run this with bash, for example: bash $0" >&2
  exit 1
fi

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$APP_DIR/../.." && pwd)"

# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"

MODE=local
DRY_RUN=0
OUT_DIR="$REPO_DIR/dist/macos"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release) MODE=release ;;
    --local) MODE=local ;;
    --dry-run) DRY_RUN=1 ;;
    --out)
      [ "$#" -ge 2 ] || die "--out needs a folder"
      OUT_DIR="$2"
      shift
      ;;
    -h | --help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown option '$1'; try --help" ;;
  esac
  shift
done

APP_NAME="Sirven"
BUNDLE_ID="${SIRVEN_BUNDLE_ID:-xyz.sirven.app}"
MINIMUM_MACOS="13.0"
VERSION="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO_DIR/package.json" | head -n 1)"
[ -n "$VERSION" ] || die "package.json has no version field"
BUILD_NUMBER="$(git -C "$REPO_DIR" rev-list --count HEAD 2>/dev/null || echo 0)"
APP_PATH="$OUT_DIR/$APP_NAME.app"
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG_PATH="$OUT_DIR/$DMG_NAME"
MANIFEST_PATH="$OUT_DIR/release.json"
COPY_FILE="$REPO_DIR/copy/onboarding-wizard.json"
ENTITLEMENTS="$APP_DIR/Sirven.entitlements"

if [ "$MODE" = release ]; then
  ARCH_FLAGS="--arch arm64 --arch x86_64"
  ARCHITECTURES='["arm64", "x86_64"]'
  SIGNING=developer-id
  NOTARIZED=true
else
  ARCH_FLAGS=""
  ARCHITECTURES="[\"$(uname -m)\"]"
  SIGNING=ad-hoc
  NOTARIZED=false
fi

# the credential seam. a release build without both credentials stops here, before anything
# is built, and says exactly what is missing. nothing ever falls back to an unsigned release.
check_release_credentials() {
  local missing=""
  [ -n "${SIRVEN_SIGNING_IDENTITY:-}" ] || missing="$missing SIRVEN_SIGNING_IDENTITY"
  [ -n "${SIRVEN_NOTARY_PROFILE:-}" ] || missing="$missing SIRVEN_NOTARY_PROFILE"
  if [ -n "$missing" ]; then
    DIE_STATUS=2 die "a release build needs Jose's Apple Developer credentials, and these are not set:$missing
  SIRVEN_SIGNING_IDENTITY  the Apple distribution certificate name, as security find-identity -v -p codesigning lists it
  SIRVEN_NOTARY_PROFILE    a keychain profile made with: xcrun notarytool store-credentials <name>
  setup: docs/DOWNLOAD-AND-ONBOARDING.md, section 'signing and notarization'.
  for a local test build, run without --release."
  fi
  if [ "$DRY_RUN" -eq 0 ] && ! security find-identity -v -p codesigning | grep -F -q "\"$SIRVEN_SIGNING_IDENTITY\""; then
    DIE_STATUS=2 die "no valid signing identity named \"$SIRVEN_SIGNING_IDENTITY\" in the keychain. list them with: security find-identity -v -p codesigning"
  fi
}

[ "$MODE" = release ] && check_release_credentials

PLAN=()
step() {
  PLAN+=("$1")
}

SIGN_IDENTITY="-"
SIGN_FLAGS="--force --sign -"
if [ "$MODE" = release ]; then
  SIGN_IDENTITY="$SIRVEN_SIGNING_IDENTITY"
  SIGN_FLAGS="--force --options runtime --timestamp --entitlements $(shell_quote "$ENTITLEMENTS") --sign $(shell_quote "$SIGN_IDENTITY")"
fi

step "swift build -c release ${ARCH_FLAGS:+$ARCH_FLAGS }--package-path $(shell_quote "$APP_DIR")"
step "assemble $(shell_quote "$APP_PATH"): executable, Info.plist ($BUNDLE_ID $VERSION build $BUILD_NUMBER, macOS $MINIMUM_MACOS or newer, no dock icon), wizard copy, icon"
step "codesign $SIGN_FLAGS $(shell_quote "$APP_PATH")"
step "codesign --verify --strict $(shell_quote "$APP_PATH")"
step "hdiutil create $(shell_quote "$DMG_PATH") from $APP_NAME.app and an Applications shortcut"
if [ "$MODE" = release ]; then
  step "codesign --force --timestamp --sign $(shell_quote "$SIGN_IDENTITY") $(shell_quote "$DMG_PATH")"
  step "xcrun notarytool submit $(shell_quote "$DMG_PATH") --keychain-profile $(shell_quote "$SIRVEN_NOTARY_PROFILE") --wait"
  step "xcrun stapler staple $(shell_quote "$DMG_PATH")"
  step "spctl --assess --type open --context context:primary-signature $(shell_quote "$DMG_PATH")"
fi
step "write $(shell_quote "$MANIFEST_PATH"): version, size, sha256, signing $SIGNING, notarized $NOTARIZED"

say "sirven macOS app, $MODE build, version $VERSION"
for line in "${PLAN[@]}"; do
  say "  - $line"
done
if [ "$DRY_RUN" -eq 1 ]; then
  say "dry run: nothing was built"
  exit 0
fi

[ "$(uname -s)" = Darwin ] || die "the macOS app builds only on macOS"
command -v swift >/dev/null 2>&1 || die "swift not found; install Xcode or the Xcode command line tools"
[ -f "$COPY_FILE" ] || die "missing $COPY_FILE"

# 1. compile. word splitting of ARCH_FLAGS is intended.
# shellcheck disable=SC2086
swift build -c release $ARCH_FLAGS --package-path "$APP_DIR"
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c release $ARCH_FLAGS --package-path "$APP_DIR" --show-bin-path)"
[ -x "$BIN_DIR/$APP_NAME" ] || die "the build finished but $BIN_DIR/$APP_NAME is missing"

# 2. assemble the bundle from scratch, so nothing from an earlier build lingers.
mkdir -p "$OUT_DIR"
rm -rf "$APP_PATH" "$DMG_PATH" "$MANIFEST_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_PATH/Contents/MacOS/$APP_NAME"
cp "$COPY_FILE" "$APP_PATH/Contents/Resources/"
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"

work="$(mktemp -d "${TMPDIR:-/tmp}/sirven-app.XXXXXX")"
trap 'rm -rf "$work"' EXIT
"$BIN_DIR/$APP_NAME" --render-icon "$work" >/dev/null
iconutil -c icns "$work/AppIcon.iconset" -o "$APP_PATH/Contents/Resources/AppIcon.icns"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>$MINIMUM_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>MIT license</string>
</dict>
</plist>
PLIST
plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null

# 3. sign. release: hardened runtime and a secure timestamp, which notarization requires.
eval "codesign $SIGN_FLAGS \"\$APP_PATH\""
codesign --verify --strict --verbose=1 "$APP_PATH"

# 4. the disk image: the app next to an Applications shortcut, nothing else.
mkdir -p "$work/image"
cp -R "$APP_PATH" "$work/image/"
ln -s /Applications "$work/image/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$work/image" -ov -format UDZO "$DMG_PATH"

# 5. release only: sign the image, notarize, staple, and let Gatekeeper judge the result.
if [ "$MODE" = release ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$SIRVEN_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
fi

# 6. the manifest the download page reads. it states the signing truthfully, so the page
# can say "not notarized" when that is the case.
bytes="$(wc -c < "$DMG_PATH" | tr -d ' ')"
app_bytes="$(( $(du -sk "$APP_PATH" | cut -f1) * 1024 ))"
sha="$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"
cat > "$MANIFEST_PATH" <<JSON
{
  "name": "$APP_NAME",
  "version": "$VERSION",
  "build": "$BUILD_NUMBER",
  "file": "$DMG_NAME",
  "bytes": $bytes,
  "appBytes": $app_bytes,
  "sha256": "$sha",
  "minimumMacOS": "$MINIMUM_MACOS",
  "architectures": $ARCHITECTURES,
  "signing": "$SIGNING",
  "notarized": $NOTARIZED,
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

say "built $APP_PATH"
say "built $DMG_PATH ($bytes bytes, sha256 $sha)"
say "wrote $MANIFEST_PATH"
