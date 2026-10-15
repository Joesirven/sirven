#!/usr/bin/env bash
# SIR-2, SIR-34. the Cloudflare tunnel transport against the REAL Cloudflare API and the real cloudflared, in a disposable machine.
# scenario 63 does the same with fakes. this one needs a network and a SCOPED TEST token: an API token limited to Account, Cloudflare
# Tunnel, Edit and Zone, domain name records, Edit on one dedicated TEST zone (never a production zone, never a token that can deploy
# anything), the account number, and the name of that test zone. without them the steps that make anything say "skipped: needs a
# Cloudflare test token" and the rest still runs against the real API: apply without a token is refused, and a wrong token is turned
# away with nothing recorded and the token nowhere in the output.
# to run the steps that make a tunnel for real, put these lines in a dotenv file and run, as one command:
#   SIRVEN_HARNESS_SECRETS_FILE=/path/to/that.env bash tests/harness/run-linux.sh 64
#     SIRVEN_CLOUDFLARE_API_TOKEN=...   SIRVEN_CLOUDFLARE_ACCOUNT_ID=...   SIRVEN_CLOUDFLARE_TEST_ZONE=sirven-test.example
#     (and SIRVEN_CLOUDFLARE_ZONE_ID=... when the token cannot list zones)
# (or export them in the shell). they go into the container by name or by file, only those lines, never on a command line.
# the scenario makes one tunnel and one record named after the run, and deletes both in the account before it ends, whatever happens.
# harness-cloudflare: yes
# harness-memory: 512m
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

strip_quotes() { local v="$1"; v="${v#[\"\']}"; v="${v%[\"\']}"; printf '%s' "$v"; }
ENV_TOKEN="$(strip_quotes "${SIRVEN_CLOUDFLARE_API_TOKEN:-}")"
ENV_ACCOUNT="$(strip_quotes "${SIRVEN_CLOUDFLARE_ACCOUNT_ID:-}")"
ENV_ZONE_NAME="$(strip_quotes "${SIRVEN_CLOUDFLARE_TEST_ZONE:-}")"
ENV_ZONE_ID="$(strip_quotes "${SIRVEN_CLOUDFLARE_ZONE_ID:-}")"
# the harness passes the lines for these names of a dotenv file and nothing else from it: a canary variable in that file must not be here
check "no variable of the secrets file but the four Cloudflare names reached this container" bash -c '[ -z "${SIRVEN_HARNESS_CANARY:-}" ]'
unset SIRVEN_CLOUDFLARE_API_TOKEN SIRVEN_CLOUDFLARE_ACCOUNT_ID SIRVEN_CLOUDFLARE_TEST_ZONE SIRVEN_CLOUDFLARE_ZONE_ID
export BAD_TOKEN="wrongtoken0123456789wrongtoken0123456789"
RUN="${SIRVEN_HARNESS_RUN_ID:-local}"
RUN="$(printf '%s' "$RUN" | tr -c 'a-z0-9\n' '-' | tr '[:upper:]' '[:lower:]' | cut -c1-30)"
ACCOUNT="${ENV_ACCOUNT:-0123456789abcdef0123456789abcdef}"
HOST="sirven-harness-$RUN.${ENV_ZONE_NAME:-example.invalid}"
API="/srv/pkg/lib/cloudflare_api.py"

# stand-in systemctl that really runs the unit (the container has no systemd): it starts the ExecStart line of the unit file the installer
# wrote, in the background, and answers is-active from the process.
mkdir -p /run/systemd/system /etc/systemd/system /tmp/live-units
cat > /usr/sbin/systemctl <<'SCRIPT'
#!/bin/sh
state=/tmp/live-units
unit_file() { printf '/etc/systemd/system/%s' "$1"; }
case "$1" in
  enable)
    shift; unit=""
    for argument in "$@"; do case "$argument" in --now) ;; *) unit="$argument" ;; esac; done
    command="$(sed -n 's/^ExecStart=//p' "$(unit_file "$unit")")"
    # shellcheck disable=SC2086
    # (the installer's lock is on descriptor 8: a long-lived child must not keep it, as a service started by systemd never would)
    setsid $command >"$state/$unit.log" 2>&1 < /dev/null 8>&- &
    echo $! > "$state/$unit.pid"; : > "$state/$unit.enabled" ;;
  stop) [ ! -s "$state/$2.pid" ] || kill "$(cat "$state/$2.pid")" 2>/dev/null; rm -f "$state/$2.pid" ;;
  disable) rm -f "$state/$2.enabled" ;;
  is-active) shift; [ "$1" != --quiet ] || shift; [ -s "$state/$1.pid" ] && kill -0 "$(cat "$state/$1.pid")" 2>/dev/null; exit $? ;;
  is-enabled) shift; [ "$1" != --quiet ] || shift; [ -e "$state/$1.enabled" ]; exit $? ;;
esac
exit 0
SCRIPT
chmod 755 /usr/sbin/systemctl

install_cf() { SIRVEN_CLOUDFLARE_ZONE_ID="$ENV_ZONE_ID" bash install.sh --yes --level observer --transport cloudflare --cloudflare-hostname "$HOST" --cloudflare-account "$ACCOUNT" "$@"; }
revoke_cf() { bash install.sh revoke --all --yes "$@"; }
# a call to the real API with the test token, through the same script the installer uses (the token on standard input only)
api() { printf '%s\n' "$ENV_TOKEN" | python3 -I "$API" "$@"; }
json_get() { python3 -I -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
# tunnel_state NUMBER: "there" while the real account has the tunnel, "gone" when it is deleted or unknown
tunnel_state() {
  local answer
  answer="$(api tunnel-get "$ACCOUNT" "$1" 2>/dev/null)" || { echo gone; return 0; }
  if [ "$(printf '%s' "$answer" | json_get deleted)" = True ]; then echo gone; else echo there; fi
}
# record_state NUMBER: "there" while the real zone has the record, else "gone"
record_state() {
  if api record-get "$ZONE_ID" "$1" >/dev/null 2>&1; then echo there; else echo gone; fi
}
marker_field() { python3 -I "$API" marker-get /var/lib/sirven/cloudflare-tunnel.json "$1"; }
export -f api json_get tunnel_state record_state marker_field argv_has_no_key
export ENV_TOKEN API ACCOUNT HOST

# whatever happens, a tunnel and a record this scenario made do not outlive it: the record at this run's own hostname, and every tunnel
# number this scenario saw, are deleted (a delete of something already gone is done, so this is safe to repeat)
SEEN_TUNNELS=""
cleanup_account() {
  local id zone="${ZONE_ID:-}"
  [ -n "$ENV_TOKEN" ] || return 0
  [ -n "$zone" ] || zone="$(api find-zone "$HOST" 2>/dev/null | json_get id 2>/dev/null)" || true
  if [ -n "$zone" ]; then
    api record-find "$zone" "$HOST" 2>/dev/null | python3 -I -c '
import json, sys
for r in json.load(sys.stdin): print(r["id"])' 2>/dev/null | while read -r id; do api record-delete "$zone" "$id" >/dev/null 2>&1; done
  fi
  id="$(marker_field tunnel_id 2>/dev/null)" || id=""
  for id in $SEEN_TUNNELS $id; do api tunnel-delete "$ACCOUNT" "$id" >/dev/null 2>&1 || true; done
}
trap cleanup_account EXIT

world_files > /tmp/empty.files
check_exit "apply without a token is refused" 2 install_cf
check "and it names the token and changes nothing" bash -c 'grep -q "there is no Cloudflare API token" <<< "$0" && grep -q "nothing was changed" <<< "$0"' "$LAST_OUTPUT"
world_unchanged_if 'true' "files unchanged" files /tmp/empty.files

# a wrong token reaches the real API and is turned away: nothing is made, and the token is in no output
SIRVEN_CLOUDFLARE_API_TOKEN="$BAD_TOKEN" check_exit "apply with a wrong token is refused" 2 install_cf --cloudflare-account "$ACCOUNT"
bad_out="$LAST_OUTPUT"
check "it says the token cannot list tunnels, and the wrong token is in no output" bash -c 'grep -q "cannot list tunnels" <<< "$0" && ! grep -qF -- "$BAD_TOKEN" <<< "$0"' "$bad_out"
check "nothing is recorded and no unit was written" bash -c '[ ! -e /var/lib/sirven/cloudflare-tunnel.json ] && [ ! -e /etc/systemd/system/sirven-cloudflared.service ]'

if [ -z "$ENV_TOKEN" ] || [ -z "$ENV_ZONE_NAME" ] || [ -z "$ENV_ACCOUNT" ]; then
  skip "apply makes the tunnel and the record in the test zone" "needs a Cloudflare test token (SIRVEN_CLOUDFLARE_API_TOKEN, SIRVEN_CLOUDFLARE_ACCOUNT_ID and SIRVEN_CLOUDFLARE_TEST_ZONE in the environment, or in the dotenv file named by SIRVEN_HARNESS_SECRETS_FILE; see the top of this scenario)"
  skip "a second apply does nothing, revoke and uninstall take away exactly what was made" "needs a Cloudflare test token"
  finish
  exit $?
fi

export KEY="$ENV_TOKEN"
ZONE_ID="${ENV_ZONE_ID:-$(api find-zone "$HOST" | json_get id)}"
export ZONE_ID
check "the test zone is found, and the hostname has no record yet" bash -c '[ -n "$ZONE_ID" ] && [ "$(api record-find "$ZONE_ID" "$HOST" | python3 -I -c "import json,sys; print(len(json.load(sys.stdin)))")" = 0 ]'

SIRVEN_CLOUDFLARE_API_TOKEN="$ENV_TOKEN" check_exit "apply with the test token makes the tunnel" 0 install_cf
out="$LAST_OUTPUT"
TUNNEL="$(marker_field tunnel_id)"
RECORD="$(marker_field record_id)"
SEEN_TUNNELS="$TUNNEL"
check "the real account has the tunnel" bash -c '[ "$(tunnel_state "$0")" = there ]' "$TUNNEL"
check "the real zone has the alias record, pointing at the tunnel" bash -c '[ "$(api record-get "$ZONE_ID" "$0" | json_get content)" = "$1.cfargotunnel.com" ]' "$RECORD" "$TUNNEL"
check "the real cloudflared accepts the config and the service is running" bash -c '/usr/local/bin/cloudflared tunnel --config /etc/sirven/cloudflared.yml ingress validate >/dev/null 2>&1 && systemctl is-active --quiet sirven-cloudflared.service'
check "the credentials and the record are root-only" bash -c '[ "$(stat -c %a:%U /etc/sirven/cloudflared-credentials.json)" = 600:root ] && [ "$(stat -c %a:%U /var/lib/sirven/cloudflare-tunnel.json)" = 600:root ]'
check "the token is in no output, no file, and not on the command line of any process" bash -c '
  ! grep -qF -- "$KEY" <<< "$0" && ! grep -rlF -- "$KEY" /etc /var /root /home /usr/local 2>/dev/null | grep -q . && argv_has_no_key' "$out"
check "the audit log and the install record have no token" bash -c '! grep -qF -- "$KEY" /var/log/sirven/audit.jsonl /var/lib/sirven/install-record.tsv'

check_exit "a second apply without a token exits 0" 0 install_cf
check "and the tunnel is still the same one" bash -c '[ "$(marker_field tunnel_id)" = "$0" ]' "$TUNNEL"

SIRVEN_CLOUDFLARE_API_TOKEN="$ENV_TOKEN" check_exit "revoke --all takes the tunnel away" 0 revoke_cf
check "the real account no longer has the tunnel, and the zone no longer has the record" bash -c '[ "$(tunnel_state "$0")" = gone ] && [ "$(record_state "$1")" = gone ]' "$TUNNEL" "$RECORD"
check "the service is stopped and the files and the record are gone" bash -c '! systemctl is-active --quiet sirven-cloudflared.service && [ ! -e /etc/sirven/cloudflared-credentials.json ] && [ ! -e /var/lib/sirven/cloudflare-tunnel.json ] && [ ! -e /etc/systemd/system/sirven-cloudflared.service ]'
check_exit "a second revoke exits 0" 0 revoke_cf

# uninstall alone takes away the same
rm -f /var/lib/sirven/agent-revoked-agent.json
SIRVEN_CLOUDFLARE_API_TOKEN="$ENV_TOKEN" install_cf --reinstate >/dev/null 2>&1
TUNNEL2="$(marker_field tunnel_id)"
RECORD2="$(marker_field record_id)"
SEEN_TUNNELS="$TUNNEL $TUNNEL2"
check "setup: a second tunnel is made" bash -c '[ -n "$0" ] && [ "$0" != "$1" ] && [ "$(tunnel_state "$0")" = there ]' "$TUNNEL2" "$TUNNEL"
SIRVEN_CLOUDFLARE_API_TOKEN="$ENV_TOKEN" check_exit "uninstall takes it away" 0 bash uninstall.sh --yes
check "the real account no longer has the second tunnel, and the zone no longer has its record" bash -c '[ "$(tunnel_state "$0")" = gone ] && [ "$(record_state "$1")" = gone ]' "$TUNNEL2" "$RECORD2"
# the exit trap deletes anything by this run's own hostname and tunnel numbers, so a failure above leaves nothing in the test account
finish
