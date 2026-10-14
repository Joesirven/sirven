#!/usr/bin/env bash
# SIR-32 round 3 (review e2). the gate used to skip --dry-run, --help and --prefix, and the libraries were then read from the
# agent's folder as root. as root it runs for every command and every flag. the agent appended a line that creates a file to
# a library of the granted copy; started from that copy, none of these may run it, and --prefix / (which install.sh used to turn
# into no prefix at all, a real run with the gate skipped) is refused.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"

mkdir -p /work && cp -r "$SRC" /work/repo && cd /work/repo || exit 2
check_exit "first install from a copy only root can write applies" 0 bash install.sh --yes --level builder --transport none --path /work/repo
check "the agent edits a library of the granted copy" runuser -u agent -- bash -c 'printf "\ntouch /tmp/ran.\$(date +%%N)\n" >> /work/repo/lib/kill_switch.sh'
ran() { ls /tmp/ran.* >/dev/null 2>&1; }
try() {  # LABEL ARGUMENT...: the edit must not run, and the command must not have been refused for the wrong reason
  local label="$1"; shift
  rm -f /tmp/ran.*
  timeout 120 bash install.sh "$@" > /tmp/out 2>&1
  LAST_STATUS=$?
  if ran; then fail "$label: the agent's edit ran as root"; else pass "$label: the agent's edit did not run"; fi
}
try "revoke --all --dry-run" revoke --all --dry-run --transport none
check "revoke --all --dry-run: it ran the kept copy and printed the plan" grep -q 'sirven revoke plan' /tmp/out
try "--help" --help
check "--help: it ran the kept copy and printed the usage" grep -q '^usage:' /tmp/out
try "install --dry-run" --dry-run --level observer --transport none
try "revoke --prefix /tmp/fakeroot" revoke --all --yes --transport none --prefix /tmp/fakeroot
setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
sleep 0.3
try "revoke --prefix /" revoke --all --yes --transport none --prefix /
check "revoke --prefix / is refused as a usage error (exit 64), not run as a real revoke" bash -c '[ "'"$LAST_STATUS"'" = 64 ] && grep -q "is the real machine" /tmp/out && pgrep -u agent >/dev/null'
try "revoke --prefix //../" revoke --all --yes --transport none --prefix //../
check "revoke --prefix //../ is refused too" bash -c '[ "'"$LAST_STATUS"'" = 64 ]'
try "uninstall.sh --dry-run" --dry-run
rm -f /tmp/ran.*; bash /work/repo/uninstall.sh --dry-run >/dev/null 2>&1
check "uninstall.sh --dry-run from the copy does not run the edit" bash -c '! ls /tmp/ran.* >/dev/null 2>&1'
rm -f /tmp/ran.*; bash /work/repo/bin/sirven grant inspect >/dev/null 2>&1
check "bin/sirven grant inspect from the copy does not run the edit" bash -c '! ls /tmp/ran.* >/dev/null 2>&1'
finish
