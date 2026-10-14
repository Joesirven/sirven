# shellcheck shell=bash
# shared set-up for the attack scripts: the fake tailscale from the test fixtures, put on the search path as a thin wrapper so a
# script can make 'up' slow, make it end in a bad state, or have it report what it can see of its own process.
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
export KEY="tskey""-auth-ATTACKkey0123456789-QQQQ"
export FAKE_TS_DIR=/tmp/fake-ts FAKE_TS_KEY="$KEY" SIRVEN_TAILSCALE_HOSTNAME=attack-node
FIXTURE=/src/tests/fixtures/tailscale-node/tailscale
cat > /usr/local/bin/tailscale <<'WRAP'
#!/usr/bin/env bash
# wrapper: knobs are files under /tmp/ts-knob so they survive the install's own environment handling
fixture=/src/tests/fixtures/tailscale-node/tailscale
if [ "$1" = up ] && [ "${2:-}" != --help ]; then
  { printf 'argv: %s\n' "$*"; printf 'environ-has-key: %s\n' "$(tr '\0' '\n' < /proc/$$/environ | grep -c -E "^(SIRVEN_)?TAILSCALE_AUTHKEY=")"; } >> /tmp/ts-up-view
  [ ! -e /tmp/ts-knob/slow ] || sleep 30
  ls -la "$(dirname "$(printf '%s\n' "$@" | sed -n 's/^--auth-key=file://p')")" >> /tmp/ts-up-view 2>&1
fi
bash "$fixture" "$@"; status=$?
if [ "$1" = up ] && [ "${2:-}" != --help ] && [ -e /tmp/ts-knob/end-needs-machine-auth ]; then printf 'NeedsMachineAuth\n' > "$FAKE_TS_DIR/state"; fi
exit "$status"
WRAP
chmod 755 /usr/local/bin/tailscale
mkdir -p /tmp/ts-knob
install_ts() { bash install.sh --yes --level observer --transport tailscale "$@"; }
state() { cat "$FAKE_TS_DIR/state" 2>/dev/null; }
