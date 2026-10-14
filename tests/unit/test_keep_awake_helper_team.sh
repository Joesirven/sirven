# shellcheck shell=bash
# the helper reads its team identifier from its own embedded section, not from the app bundle around it.
# this builds the real helper with a placeholder team (no signing identity needed), puts it in a scratch
# Sirven.app whose Info.plist lacks the key, and checks that it still reports the team. macos only.
#
# two app Info.plist layouts are checked: the shipped one, and one whose CFBundleExecutable names the
# helper. the second is the layout where Bundle.main answers nil for the key, so it is the one that
# catches a lookup through Bundle.main.

PLACEHOLDER_TEAM="ZZTEST0001"

helper_team_ready() {
  if [ "$(uname -s)" != Darwin ]; then
    echo "skipped: the helper's team identifier is macos only"
    return 1
  fi
  return 0
}

# builds the helper once per test, with the placeholder team embedded in its own section.
build_helper_with_placeholder() {
  local package="$REPO_DIR/macos/keep-awake" build="$TEST_TMP/build"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict><key>SirvenTeamIdentifier</key><string>'"$PLACEHOLDER_TEAM"'</string></dict></plist>' \
    > "$TEST_TMP/helper-info.plist"
  swift build --package-path "$package" --scratch-path "$build" -c release --product sirven-keep-awake-helper \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$TEST_TMP/helper-info.plist" \
    > "$TEST_TMP/build.log" 2>&1 || fail "the helper did not build: $(tail -n 20 "$TEST_TMP/build.log")"
}

# checks one app layout: $1 names the scratch app, $2 is the Info.plist to put in it.
check_helper_team_in_app() {
  local app="$1" info="$2" helper="$TEST_TMP/build/release/sirven-keep-awake-helper"
  mkdir -p "$app/Contents/MacOS"
  cp "$info" "$app/Contents/Info.plist"
  assert_eq 0 "$(grep -c SirvenTeamIdentifier "$app/Contents/Info.plist" || true)" "the app's Info.plist must not carry the team"
  cp "$helper" "$app/Contents/MacOS/"
  assert_eq "$PLACEHOLDER_TEAM" "$("$app/Contents/MacOS/sirven-keep-awake-helper" --print-team)" \
    "the helper must report the team from its own section ($info)"
}

test_the_helper_reads_its_team_from_its_own_section_inside_an_app_without_the_key() {
  helper_team_ready || return 0
  build_helper_with_placeholder
  check_helper_team_in_app "$TEST_TMP/shipped/Sirven.app" "$REPO_DIR/macos/keep-awake/Support/Info.plist"
}

test_the_helper_reads_its_team_when_bundle_main_would_answer_nil() {
  helper_team_ready || return 0
  build_helper_with_placeholder
  local info="$TEST_TMP/named-for-helper.plist"
  /usr/bin/python3 -I -c '
import plistlib, sys
with open(sys.argv[1], "rb") as source: plist = plistlib.load(source)
plist["CFBundleExecutable"] = "sirven-keep-awake-helper"
with open(sys.argv[2], "wb") as target: plistlib.dump(plist, target)' "$REPO_DIR/macos/keep-awake/Support/Info.plist" "$info"
  check_helper_team_in_app "$TEST_TMP/named/Sirven.app" "$info"
}
