#!/usr/bin/env bash
# install the bb watcher as a user LaunchAgent (no administrator rights needed). it copies the
# watcher out of the repository, so the agent keeps working when this checkout moves or goes away.
#
#   macos/keep-awake/bb-watcher/install.sh            install (or reinstall) and start it
#   macos/keep-awake/bb-watcher/install.sh remove     stop it and remove it
#
# needs: Sirven.app in ~/Applications (scripts/build-app.sh, then copy it there), bb and node on
# PATH, and BB_SERVER_URL set (bb sets it in every bb thread).
set -euo pipefail

LABEL="xyz.sirven.keep-awake-bb-watcher"
HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HOME/Library/Application Support/sirven/bb-watcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout returns before the job is gone; bootstrapping again too soon fails with an input/output error.
for _ in $(seq 1 50); do launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break; sleep 0.2; done
if [ "${1:-}" = remove ]; then
  rm -f "$PLIST"
  echo "removed $LABEL. the Mac sleeps as usual; the copied watcher stays in $TARGET."
  exit 0
fi

: "${BB_SERVER_URL:?BB_SERVER_URL must be set (run this from a bb thread, or export it)}"
BB_PATH="$(command -v bb)" || { echo "bb is not on PATH" >&2; exit 1; }
NODE_PATH_DIR="$(dirname "$(command -v node)")" || { echo "node is not on PATH" >&2; exit 1; }
[ -x "$HOME/Applications/Sirven.app/Contents/MacOS/sirven-keep-awake" ] ||
  { echo "Sirven.app is not in ~/Applications; build it with scripts/build-app.sh first" >&2; exit 1; }

mkdir -p "$TARGET" "$(dirname "$PLIST")"
install -m 0755 "$HERE/sirven-bb-awake-watcher.sh" "$TARGET/sirven-bb-awake-watcher.sh"

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
		<key>BB_SERVER_URL</key><string>$BB_SERVER_URL</string>
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

launchctl bootstrap "$DOMAIN" "$PLIST"
echo "installed and started $LABEL; its log is $TARGET/watcher.log"
