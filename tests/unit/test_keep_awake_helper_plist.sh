# shellcheck shell=bash
# the helper's launchd plist must start it at boot (RunAtLoad) and keep it running (KeepAlive). build-app.sh
# copies this file into the app bundle unchanged, so the checked file is the one that ships. without
# RunAtLoad, a setting left on by a crash waits for the next connection; without KeepAlive, a killed helper
# stays down with the setting on. plistlib reads the file on every platform, so this runs everywhere.

HELPER_PLIST="$REPO_DIR/macos/keep-awake/Support/xyz.sirven.keep-awake-helper.plist"

test_the_helper_plist_starts_at_boot_and_is_kept_alive() {
  assert_file_exists "$HELPER_PLIST"
  /usr/bin/env python3 -I -c '
import plistlib, sys
with open(sys.argv[1], "rb") as source:
    plist = plistlib.load(source)
problems = [key for key in ("RunAtLoad", "KeepAlive") if plist.get(key) is not True]
if problems:
    sys.exit("not true in the helper plist: " + ", ".join(problems))
' "$HELPER_PLIST" || fail "the helper plist must set RunAtLoad and KeepAlive to true"
}
