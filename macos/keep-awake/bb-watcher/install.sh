#!/usr/bin/env bash
# install the bb watcher as a user LaunchAgent (no administrator rights needed). it copies the
# watcher out of the repository, so the agent keeps working when this checkout moves or goes away.
#
#   macos/keep-awake/bb-watcher/install.sh            install (or reinstall) and start it
#   macos/keep-awake/bb-watcher/install.sh remove     stop it, remove its files, and unregister the helper
#
# needs, for install: Sirven.app in ~/Applications (scripts/build-app.sh, then copy it there), bb and
# node on PATH, and either a bb thread running on this Mac or SIRVEN_BB_HOST set to this Mac's bb host id.
# the argument and every prerequisite are checked before the agent is stopped or anything is written.
set -euo pipefail

LABEL="xyz.sirven.keep-awake-bb-watcher"
HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HOME/Library/Application Support/sirven/bb-watcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
AWAKE="$HOME/Applications/Sirven.app/Contents/MacOS/sirven-keep-awake"
HELPER_MARKER="/Library/Application Support/sirven/keep-awake-helper/sleep-disabled-by-sirven"

ACTION="${1:-install}"
case "$ACTION" in
  install|remove) ;;
  *) echo "usage: install.sh [install|remove]" >&2; exit 64 ;;
esac

stop_agent() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  # bootout returns before the job is gone; bootstrapping again too soon fails with an input/output error.
  for _ in $(seq 1 50); do launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break; sleep 0.2; done
}

if [ "$ACTION" = remove ]; then
  stop_agent
  rm -f "$PLIST"
  rm -rf "$TARGET"
  echo "removed $LABEL and the copied watcher and its log from $TARGET."
  if [ -x "$AWAKE" ] && "$AWAKE" helper unregister; then
    :
  else
    echo "the helper's registration was not removed (Sirven.app is missing or the command failed)."
    echo "with Sirven.app in ~/Applications, run: $AWAKE helper unregister"
  fi
  if [ -e "$HELPER_MARKER" ]; then
    echo "sleep-disabled was left on by sirven. to put it back, run these two commands yourself"
    echo "(they need your administrator password, so install.sh did not run them):"
    echo "  sudo pmset -a disablesleep 0"
    echo "  sudo rm -f \"$HELPER_MARKER\""
  fi
  exit 0
fi

# everything that can fail is checked here, before the agent is stopped.
BB_PATH="$(command -v bb)" || { echo "bb is not on PATH" >&2; exit 1; }
NODE_BIN="$(command -v node)" || { echo "node is not on PATH" >&2; exit 1; }
[ -x "$AWAKE" ] || { echo "Sirven.app is not in ~/Applications; build it with scripts/build-app.sh first" >&2; exit 1; }
HOST="${SIRVEN_BB_HOST:-}"
if [ -z "$HOST" ]; then
  HOST="$("$BB_PATH" status --json 2>/dev/null | /usr/bin/python3 -c '
import json, sys
try: print(json.load(sys.stdin)["thread"]["environment"]["hostId"])
except (ValueError, KeyError, TypeError): pass' || true)"
fi
[[ "$HOST" =~ ^host_[a-z0-9]+$ ]] ||
  { echo "could not tell this Mac's bb host id: run this from a bb thread on this Mac, or set SIRVEN_BB_HOST" >&2; exit 1; }
NODE_PATH_DIR="$(dirname "$NODE_BIN")"

stop_agent
mkdir -p "$TARGET" "$(dirname "$PLIST")"
install -m 0755 "$HERE/sirven-bb-awake-watcher.sh" "$TARGET/sirven-bb-awake-watcher.sh"

# the agent reads its settings from this file, which only the user can read. it carries no secret.
(
  umask 077
  cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- sirven keep-awake, bb watcher: holds the Mac awake only while bb has agent work on it.
     installed by sirven macos/keep-awake/bb-watcher/install.sh; remove with: install.sh remove -->
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$TARGET/sirven-bb-awake-watcher.sh</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key><string>$NODE_PATH_DIR:$(dirname "$BB_PATH"):/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>SIRVEN_BB_HOST</key><string>$HOST</string>
		<key>SIRVEN_BB_COMMAND</key><string>$BB_PATH</string>
	</dict>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ThrottleInterval</key><integer>30</integer>
	<key>ProcessType</key><string>Background</string>
	<key>StandardOutPath</key><string>$TARGET/watcher.log</string>
	<key>StandardErrorPath</key><string>$TARGET/watcher.log</string>
</dict>
</plist>
PLIST
)
chmod 600 "$PLIST"

launchctl bootstrap "$DOMAIN" "$PLIST"
echo "installed and started $LABEL for bb host $HOST; its log is $TARGET/watcher.log"
