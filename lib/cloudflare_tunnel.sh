#!/usr/bin/env bash
# cloudflare_tunnel.sh: make this machine's Cloudflare Tunnel for the agent, and take it away again. called by the installer's plan
# (up), by the kill switch and uninstall and the install record's undo line (down), from the pinned copy of this package (see
# lib/cloudflare.sh). one file for the steps, because the install record stores command text and uninstall.sh does not read
# lib/cloudflare.sh.
#
#   cloudflare_tunnel.sh up    --marker F --config F --credentials F --unit F --service NAME --user NAME --hostname H --account A [--zone Z] [--token-file F]
#   cloudflare_tunnel.sh down  --marker F [--token-file F]
#   cloudflare_tunnel.sh check --marker F --hostname H --account A [--zone Z] [--token-file F]   every refusal 'up' can make, no change
#   cloudflare_tunnel.sh applied MARKER                       exit 0 when the tunnel is made and its service runs (needs no token)
#   cloudflare_tunnel.sh token-file-check FILE                exit 0 a usable token file, 1 none there, 2 there but not safe (says why)
#
# up makes a tunnel named sirven-USER-HOST-RANDOM, managed from this machine (its ingress is the config file below, so the owner's
# dashboard cannot widen it), keeps its credentials root-only, writes a config that routes exactly one hostname to this machine's SSH
# server (ssh://localhost:22) and answers every other name with 404, points that hostname at the tunnel with an alias record, writes
# a service unit of its own (not 'cloudflared service install': that would take the name and the config of an owner's own cloudflared,
# and puts a token on the command line), and starts it. the service runs as root, never as the agent account, and only dials out.
# every artifact is written to the record (MARKER, root-only, never the token) as soon as it exists, the unique tunnel name before
# the tunnel is made, so a run that stops halfway leaves a record that names what exists, and 'down' undoes exactly that.
#
# down acts only on what the record names, and checks before it deletes: the alias record only while it still points at this tunnel,
# the tunnel only while it still has the recorded name. the local part (stop and remove the service, remove the credentials and
# the config) never needs the token, so the agent is cut off from this machine even when the token is gone. the part in the
# Cloudflare account does: without the token 'down' says plainly what is left there (tunnel and record numbers), keeps the record,
# and exits 1, so the same command with the token finishes it.
#
# the API token comes from the environment (SIRVEN_CLOUDFLARE_API_TOKEN), which this script takes into a variable of its own and unsets
# before it starts any other process, or from the token file (mode 0600, owned by root, one name, no extended access list: the safer
# way, the same checks as the Tailscale key file). it is handed to lib/cloudflare_api.py through standard input, never on a
# command line, never in a file, and whatever is printed has it blanked out.
#
# cloudflared and systemctl are found on the search path. SIRVEN_CLOUDFLARED and SIRVEN_SYSTEMCTL name others for the tests (not
# honored as root). exit status: 0 done (or nothing to do), 1 failed, 2 refused before any change.

set -uo pipefail

unset CF_ENV_TOKEN
CF_ENV_TOKEN="${SIRVEN_CLOUDFLARE_API_TOKEN:-}"
unset SIRVEN_CLOUDFLARE_API_TOKEN

case "${BASH_SOURCE[0]}" in */*) SELF_DIR="${BASH_SOURCE[0]%/*}" ;; *) SELF_DIR="." ;; esac
# shellcheck source=lib/secret_file.sh
. "$SELF_DIR/secret_file.sh" 2>/dev/null || true
API_SCRIPT="$SELF_DIR/cloudflare_api.py"

TOKEN=""
TOKEN_ORIGIN=""
FAILED=0

refuse() {
  printf 'error: refused: %s nothing was changed.\n' "$1" >&2
  exit 2
}

# require_secret_checks FILE: a copy of this script run without lib/secret_file.sh (or with a file that does not define the checks) must
# not read a saved file as if it had passed them: the answer is a refusal. guarded where the checks are used, not at load, so that
# taking the tunnel away (down) does not depend on them.
require_secret_checks() {
  { declare -F key_file_problem >/dev/null 2>&1 && declare -F has_extended_access_list >/dev/null 2>&1; } ||
    refuse "the saved file $1 cannot be checked, because the file of checks that goes with this script (lib/secret_file.sh) is missing or damaged, so it is not used."
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

# the seams, honored only when not root
seam() {
  local value="$1"
  [ "$(id -u)" -ne 0 ] || value=""
  printf '%s' "$value"
}

cloudflared_command() {
  local seam_value
  seam_value="$(seam "${SIRVEN_CLOUDFLARED:-}")"
  case "$seam_value" in
    none) return 0 ;;
    '') command -v cloudflared 2>/dev/null || true ;;
    *) printf '%s' "$seam_value" ;;
  esac
}

systemctl_command() {
  local seam_value
  seam_value="$(seam "${SIRVEN_SYSTEMCTL:-}")"
  case "$seam_value" in
    none) return 0 ;;
    '') command -v systemctl 2>/dev/null || true ;;
    *) printf '%s' "$seam_value" ;;
  esac
}

# systemd_running: systemd runs here and answers (a test seam stands in for both)
systemd_running() {
  [ -n "$(seam "${SIRVEN_SYSTEMCTL:-}")" ] && [ "$(seam "${SIRVEN_SYSTEMCTL:-}")" != none ] && return 0
  [ -d /run/systemd/system ] && [ -n "$(systemctl_command)" ]
}

# json_get FIELD: one field of the JSON on standard input
json_get() {
  python3 -I -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"
}

# json_count: how many items the JSON list on standard input has
json_count() {
  python3 -I -c 'import json, sys; print(len(json.load(sys.stdin)))'
}

# api ACTION ARGUMENT...: one API call, the token on standard input only (printf is a builtin: no process holds it)
api() {
  printf '%s\n' "$TOKEN" | python3 -I "$API_SCRIPT" "$@"
}

record_get() { python3 -I "$API_SCRIPT" marker-get "$MARKER" "$1" 2>/dev/null </dev/null; }
record_set() { python3 -I "$API_SCRIPT" marker-set "$MARKER" "$@" >/dev/null </dev/null; }

valid_hostname() {
  case "$1" in
    *[!a-z0-9.-]* | .* | *. | *..* | -* | *.-* | *-.* | '') return 1 ;;
    *.*) return 0 ;;
  esac
  return 1
}

# parse_options ARGUMENT...: the --name value pairs into OPT_* variables
parse_options() {
  OPT_MARKER="" OPT_CONFIG="" OPT_CREDENTIALS="" OPT_UNIT="" OPT_SERVICE="" OPT_USER="" OPT_HOSTNAME="" OPT_ACCOUNT="" OPT_ZONE="" OPT_TOKEN_FILE=""
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || refuse "$1 needs a value."
    case "$1" in
      --marker) OPT_MARKER="$2" ;;
      --config) OPT_CONFIG="$2" ;;
      --credentials) OPT_CREDENTIALS="$2" ;;
      --unit) OPT_UNIT="$2" ;;
      --service) OPT_SERVICE="$2" ;;
      --user) OPT_USER="$2" ;;
      --hostname) OPT_HOSTNAME="$2" ;;
      --account) OPT_ACCOUNT="$2" ;;
      --zone) OPT_ZONE="$2" ;;
      --token-file) OPT_TOKEN_FILE="$2" ;;
      *) refuse "unknown option '$1'." ;;
    esac
    shift 2
  done
  MARKER="$OPT_MARKER"
  [ -n "$MARKER" ] || refuse "a record path (--marker) is needed."
}

# find_token FILE: sets TOKEN and TOKEN_ORIGIN from the environment, else the token file. refuses on an unsafe file; leaves TOKEN
# empty when there is none.
find_token() {
  local file="${1:-}" problem
  TOKEN="" TOKEN_ORIGIN=""
  if [ -n "$CF_ENV_TOKEN" ]; then
    TOKEN="$CF_ENV_TOKEN"; TOKEN_ORIGIN="SIRVEN_CLOUDFLARE_API_TOKEN"
  elif [ -n "$file" ]; then
    require_secret_checks "$file"
    problem="$(key_file_problem "$file")"
    [ -z "$problem" ] || refuse "the API token file $file is not used: $problem."
    if [ -f "$file" ]; then
      TOKEN="$(head -n 1 "$file")"; TOKEN_ORIGIN="$file"
    fi
  fi
  CF_ENV_TOKEN=""
  case "$TOKEN" in
    *[!A-Za-z0-9_-]*) refuse "the API token in $TOKEN_ORIGIN has characters a Cloudflare token never has (a carriage return from Windows line ends, for one); it is not used." ;;
  esac
}

token_hint() {
  printf 'make a token in the Cloudflare dashboard (My Profile, API Tokens): permissions Account, Cloudflare Tunnel, Edit and Zone, domain name records, Edit (and Zone, Zone, Read unless you give the zone number in SIRVEN_CLOUDFLARE_ZONE_ID), limited to the one account and the one zone. save it as the token file, owned by root, mode 0600 (the safer way), or put it in the environment as SIRVEN_CLOUDFLARE_API_TOKEN (sudo --preserve-env=SIRVEN_CLOUDFLARE_API_TOKEN ..., which works only if the sudo policy allows it).'
}

short_host() {
  local host
  host="$(hostname -s 2>/dev/null || uname -n)"
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-30 | sed 's/-$//')"
  printf '%s' "${host:-machine}"
}

random_hex() {
  python3 -I -c 'import os; print(os.urandom(4).hex())'
}

install_hint() {
  printf 'install it from https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/ (on Debian or Ubuntu, add the Cloudflare package repository from that page and run: apt install cloudflared), then run this again.'
}

# write_file PATH MODE: standard input into PATH, mode set before the name appears, replaced in one step
write_file() {
  local path="$1" mode="$2" temporary
  temporary="$path.new.$$"
  ( umask 077; cat > "$temporary" ) || return 1
  if chmod "$mode" "$temporary" && mv -f "$temporary" "$path"; then return 0; fi
  rm -f "$temporary"
  return 1
}

config_text() {
  cat <<END
tunnel: $1
credentials-file: $2
ingress:
  - hostname: $3
    service: ssh://localhost:22
  - service: http_status:404
END
}

unit_text() {
  cat <<END
[Unit]
Description=sirven Cloudflare Tunnel to this machine's SSH server, for the agent account
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$1 --no-autoupdate --config $2 tunnel run
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
END
}

# service_active SERVICE: the unit is running
service_active() {
  local command
  command="$(systemctl_command)"
  [ -n "$command" ] && "$command" is-active --quiet "$1" 2>/dev/null
}

# complete: the record, its files and the running service all agree that the tunnel is made. read only, no token.
complete() {
  local field
  [ -f "$MARKER" ] || return 1
  for field in tunnel_id record_id account_id hostname config credentials unit service; do
    [ -n "$(record_get "$field")" ] || return 1
  done
  [ -s "$(record_get credentials)" ] && [ -s "$(record_get config)" ] && [ -s "$(record_get unit)" ] || return 1
  service_active "$(record_get service)"
}

# first_look_problem: every reason 'up' would refuse, found before any change. sets nothing; prints the reason and returns 1.
first_look() {
  local command hostname="$1" account="$2" zone="$3" found zone_found existing count
  valid_hostname "$hostname" || refuse "the hostname '$hostname' is not a plain lowercase host name with a zone in it (like agent.example.org)."
  [[ "$account" =~ ^[0-9a-f]{32}$ ]] || refuse "the account number '$account' is not 32 hexadecimal characters (dashboard, any zone, overview, the account number on the right)."
  [ -z "$zone" ] || [[ "$zone" =~ ^[0-9a-f]{32}$ ]] || refuse "the zone number '$zone' is not 32 hexadecimal characters."
  [ -n "$TOKEN" ] || refuse "there is no Cloudflare API token. $(token_hint)"
  command="$(cloudflared_command)"
  [ -n "$command" ] || refuse "cloudflared is not installed on this machine. $(install_hint)"
  systemd_running || refuse "systemd does not run on this machine, and the tunnel service is a systemd unit. sirven starts the tunnel only under systemd. run again with --transport none, or start the tunnel yourself."
  command -v python3 >/dev/null 2>&1 || refuse "python3 is not installed."
  found="$(api verify "$account" 2>&1 >/dev/null)" || refuse "the token cannot list tunnels of account $account: ${found#error: }. $(token_hint)"
  if [ -z "$zone" ]; then
    zone_found="$(api find-zone "$hostname" 2>&1)" || refuse "could not find the zone of $hostname: ${zone_found#error: }."
    zone="$(printf '%s' "$zone_found" | json_get id)"
  fi
  existing="$(api record-find "$zone" "$hostname" 2>&1)" || refuse "could not read the records of the zone: ${existing#error: }."
  count="$(printf '%s' "$existing" | json_count)"
  if [ "$count" != 0 ]; then
    # a record of ours is fine: the one the record names, or one that points at our tunnel (a run stopped before it wrote the number down)
    if printf '%s' "$existing" | python3 -I -c '
import json, sys
mine, target = sys.argv[1], sys.argv[2]
sys.exit(0 if any(r["id"] == mine or (target and r["content"] == target) for r in json.load(sys.stdin)) else 1)' \
      "$(record_get record_id)" "$([ -z "$(record_get tunnel_id)" ] || printf '%s.cfargotunnel.com' "$(record_get tunnel_id)")"; then
      return 0
    fi
    refuse "$hostname already has a record in the zone that sirven did not make, and sirven never changes a record it did not make. pick another hostname, or remove that record yourself."
  fi
}

# the record's hostname and account must be the ones asked for, or the machine already has a tunnel for something else
same_target() {
  local recorded
  [ -f "$MARKER" ] || return 0
  recorded="$(record_get hostname)"
  if [ -n "$recorded" ] && [ "$recorded" != "$1" ]; then
    refuse "this machine already has a tunnel recorded for $recorded, not $1. remove that one first (uninstall.sh, or the kill switch), then run this again."
  fi
  recorded="$(record_get account_id)"
  if [ -n "$recorded" ] && [ "$recorded" != "$2" ]; then
    refuse "this machine already has a tunnel recorded in another Cloudflare account. remove that one first (uninstall.sh, or the kill switch), then run this again."
  fi
}

# remote_cleanup: delete, in the Cloudflare account, what the record names and only that. returns 0 when none of it is left.
# needs the token. an alias record goes only while it still points at the recorded tunnel; a tunnel only while it still has the
# recorded name.
remote_cleanup() {
  local tunnel_id name record_id zone hostname account answer content failed=0 found current
  tunnel_id="$(record_get tunnel_id)"; name="$(record_get tunnel_name)"; record_id="$(record_get record_id)"
  zone="$(record_get zone_id)"; hostname="$(record_get hostname)"; account="$(record_get account_id)"
  [ -n "$account" ] || return 0
  if [ -z "$tunnel_id" ] && [ -n "$name" ]; then
    # a run that stopped between making the tunnel and writing its number down: the unique name finds it
    found="$(api tunnel-find "$account" "$name")" || return 1
    tunnel_id="$(printf '%s' "$found" | python3 -I -c 'import json, sys; rows = json.load(sys.stdin); print(rows[0]["id"] if rows else "")')"
  fi
  if [ -n "$zone" ] && [ -n "$tunnel_id" ]; then
    if [ -z "$record_id" ] && [ -n "$hostname" ]; then
      # likewise for the record: found by its content, which names this tunnel
      found="$(api record-find "$zone" "$hostname")" || return 1
      record_id="$(printf '%s' "$found" | python3 -I -c '
import json, sys
for r in json.load(sys.stdin):
    if r["content"] == sys.argv[1] + ".cfargotunnel.com":
        print(r["id"])
        break' "$tunnel_id")"
    fi
  fi
  if [ -n "$zone" ] && [ -n "$record_id" ]; then
    answer="$(api record-get "$zone" "$record_id" 2>&1)"
    case $? in
      0)
        content="$(printf '%s' "$answer" | json_get content)"
        if [ -n "$tunnel_id" ] && [ "$content" = "$tunnel_id.cfargotunnel.com" ]; then
          if api record-delete "$zone" "$record_id" >/dev/null; then
            printf 'deleted the alias record %s (%s) from the zone.\n' "$hostname" "$record_id"
          else
            failed=1
          fi
        else
          printf 'the record %s no longer points at this tunnel (it points at %s), so it is not ours any more: left alone.\n' "${hostname:-$record_id}" "$content"
        fi
        ;;
      3) printf 'the alias record %s is already gone from the zone.\n' "${hostname:-$record_id}" ;;
      *) printf '%s\n' "$answer" >&2; failed=1 ;;
    esac
  fi
  if [ -n "$tunnel_id" ]; then
    answer="$(api tunnel-get "$account" "$tunnel_id" 2>&1)"
    case $? in
      0)
        found="$(printf '%s' "$answer" | python3 -I -c 'import json, sys; row = json.load(sys.stdin); print("%s|%s" % (row["name"], "gone" if row["deleted"] else "there"))')"
        current="${found%%|*}"
        if [ "${found#*|}" = gone ]; then
          printf 'the tunnel %s is already deleted.\n' "$tunnel_id"
        elif [ -n "$name" ] && [ "$current" != "$name" ]; then
          printf 'the tunnel %s is now named %s, not %s: it is not ours any more, left alone.\n' "$tunnel_id" "$current" "$name"
        elif api tunnel-delete "$account" "$tunnel_id" >/dev/null; then
          printf 'deleted the tunnel %s (%s) from the account.\n' "$name" "$tunnel_id"
        else
          failed=1
        fi
        ;;
      3) printf 'the tunnel %s is already gone from the account.\n' "$tunnel_id" ;;
      *) printf '%s\n' "$answer" >&2; failed=1 ;;
    esac
  fi
  return "$failed"
}

cmd_applied() {
  MARKER="${1:-}"
  [ -n "$MARKER" ] || refuse "applied needs a record path."
  complete
}

cmd_token_file_check() {
  local problem
  [ -n "${1:-}" ] || refuse "token-file-check needs a path."
  require_secret_checks "$1"
  problem="$(key_file_problem "$1")"
  if [ -n "$problem" ]; then
    printf 'error: the API token file %s is not used: %s.\n' "$1" "$problem" >&2
    exit 2
  fi
  [ -f "$1" ] && [ -s "$1" ] || exit 1
}

cmd_check() {
  parse_options "$@"
  find_token "$OPT_TOKEN_FILE"
  same_target "$OPT_HOSTNAME" "$OPT_ACCOUNT"
  if complete; then return 0; fi
  first_look "$OPT_HOSTNAME" "$OPT_ACCOUNT" "$OPT_ZONE"
}

cmd_up() {
  local name tunnel_id zone zone_found record_id cloudflared target created found made_record existing
  parse_options "$@"
  for name in "$OPT_CONFIG" "$OPT_CREDENTIALS" "$OPT_UNIT" "$OPT_SERVICE" "$OPT_USER" "$OPT_HOSTNAME" "$OPT_ACCOUNT"; do
    [ -n "$name" ] || refuse "up needs --config, --credentials, --unit, --service, --user, --hostname and --account."
  done
  [ -d "$(dirname "$MARKER")" ] || refuse "the folder for the record, $(dirname "$MARKER"), is not there."
  find_token "$OPT_TOKEN_FILE"
  same_target "$OPT_HOSTNAME" "$OPT_ACCOUNT"
  if complete; then
    printf 'the tunnel %s is already made and its service %s runs: kept as it is.\n' "$(record_get tunnel_name)" "$OPT_SERVICE"
    return 0
  fi
  first_look "$OPT_HOSTNAME" "$OPT_ACCOUNT" "$OPT_ZONE"
  cloudflared="$(cloudflared_command)"
  [ -n "$OPT_ZONE" ] && zone="$OPT_ZONE" || zone="$(record_get zone_id)"
  if [ -z "$zone" ]; then
    zone_found="$(api find-zone "$OPT_HOSTNAME")" || fail "could not find the zone of $OPT_HOSTNAME."
    zone="$(printf '%s' "$zone_found" | json_get id)"
  fi

  # 1. the record first, with the unique name, so a run that stops after the tunnel exists but before its number is written down can be undone
  name="$(record_get tunnel_name)"
  [ -n "$name" ] || name="sirven-$OPT_USER-$(short_host)-$(random_hex)"
  record_set "tunnel_name=$name" "account_id=$OPT_ACCOUNT" "hostname=$OPT_HOSTNAME" "zone_id=$zone" "config=$OPT_CONFIG" \
    "credentials=$OPT_CREDENTIALS" "unit=$OPT_UNIT" "service=$OPT_SERVICE" "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" || fail "could not write the record $MARKER."

  # 2. the tunnel. a tunnel without credentials on disk cannot be run (its secret is gone): a leftover of a stopped run is deleted and made again
  tunnel_id="$(record_get tunnel_id)"
  if [ -z "$tunnel_id" ] || [ ! -s "$OPT_CREDENTIALS" ]; then
    if [ -n "$tunnel_id" ] || [ -n "$(record_get record_id)" ]; then
      remote_cleanup || fail "a tunnel left by an earlier run could not be cleaned up in the account (above). the record stays; fix the cause and run this again."
      record_set tunnel_id= record_id= >/dev/null 2>&1 || true
    fi
    found="$(api tunnel-find "$OPT_ACCOUNT" "$name")" || fail "could not look for the tunnel $name in the account."
    if [ "$(printf '%s' "$found" | json_count)" != 0 ]; then
      remote_cleanup || fail "a tunnel left by an earlier run could not be cleaned up in the account (above). the record stays; fix the cause and run this again."
    fi
    created="$(api tunnel-create "$OPT_ACCOUNT" "$name" "$OPT_CREDENTIALS")" || fail "could not make the tunnel $name. the record $MARKER names what exists; undo it with the same command that removes the install."
    tunnel_id="$(printf '%s' "$created" | json_get id)"
    record_set "tunnel_id=$tunnel_id" || fail "made the tunnel $tunnel_id but could not write the record $MARKER. delete it by hand: Cloudflare dashboard, Zero Trust, Networks, Tunnels, $name."
    printf 'made the tunnel %s (%s).\n' "$name" "$tunnel_id"
  fi

  # 3. the config: one hostname to this machine's SSH server, every other name 404
  config_text "$tunnel_id" "$OPT_CREDENTIALS" "$OPT_HOSTNAME" | write_file "$OPT_CONFIG" 0600 || fail "could not write $OPT_CONFIG."
  if ! found="$("$cloudflared" tunnel --config "$OPT_CONFIG" ingress validate 2>&1)"; then
    fail "cloudflared does not accept the config it was just given ($OPT_CONFIG): $found"
  fi

  # 4. the alias record, only after checking the hostname is free or ours
  target="$tunnel_id.cfargotunnel.com"
  record_id="$(record_get record_id)"
  if [ -z "$record_id" ]; then
    existing="$(api record-find "$zone" "$OPT_HOSTNAME")" || fail "could not read the records of the zone."
    found="$(printf '%s' "$existing" | python3 -I -c '
import json, sys
rows = json.load(sys.stdin)
mine = [r["id"] for r in rows if r["content"] == sys.argv[1]]
print(mine[0] if mine else ("other" if rows else ""))' "$target")"
    case "$found" in
      other) fail "$OPT_HOSTNAME now has a record that is not ours. nothing was pointed at the tunnel; the tunnel stays recorded, and uninstall removes it." ;;
      '') made_record="$(api record-create "$zone" "$OPT_HOSTNAME" "$tunnel_id")" || fail "could not point $OPT_HOSTNAME at the tunnel. the tunnel is recorded; uninstall removes it."
          record_id="$(printf '%s' "$made_record" | json_get id)" ;;
      *) record_id="$found" ;;
    esac
    record_set "record_id=$record_id" || fail "pointed $OPT_HOSTNAME at the tunnel but could not write the record $MARKER. delete the alias record $record_id by hand."
    printf 'pointed %s at the tunnel (record %s).\n' "$OPT_HOSTNAME" "$record_id"
  fi

  # 5. the service
  unit_text "$cloudflared" "$OPT_CONFIG" | write_file "$OPT_UNIT" 0644 || fail "could not write $OPT_UNIT."
  systemctl_command_run daemon-reload || fail "systemctl daemon-reload failed."
  systemctl_command_run enable --now "$OPT_SERVICE" || fail "could not start $OPT_SERVICE. the record names the tunnel; fix the cause above and run again, or undo it with uninstall."
  service_active "$OPT_SERVICE" || fail "$OPT_SERVICE was started but is not running. see: journalctl -u $OPT_SERVICE"
  printf 'the tunnel %s runs as %s and routes %s to ssh://localhost:22 (nothing else). recorded in %s.\n' "$name" "$OPT_SERVICE" "$OPT_HOSTNAME" "$MARKER"
}

systemctl_command_run() {
  local command
  command="$(systemctl_command)"
  [ -n "$command" ] || return 1
  "$command" "$@"
}

cmd_down() {
  local service unit config credentials path
  parse_options "$@"
  find_token "$OPT_TOKEN_FILE"
  rm -f "$MARKER".new.* 2>/dev/null || true
  if [ ! -e "$MARKER" ] && [ ! -L "$MARKER" ]; then
    printf 'no Cloudflare tunnel of ours is recorded: nothing to take away.\n'
    return 0
  fi
  if [ -L "$MARKER" ] || [ ! -f "$MARKER" ]; then
    fail "$MARKER is not a plain file, so it is not trusted. remove it by hand once you have checked it, and look for a tunnel named sirven-... in the Cloudflare dashboard."
  fi
  python3 -I "$API_SCRIPT" marker-get "$MARKER" account_id >/dev/null 2>&1 </dev/null
  [ "$?" -ne 1 ] || fail "$MARKER cannot be read. nothing was removed. look for a tunnel named sirven-... in the Cloudflare dashboard."
  service="$(record_get service)"; unit="$(record_get unit)"; config="$(record_get config)"; credentials="$(record_get credentials)"
  # the record is root-only, so these were written by this script; they are still checked before anything is removed or stopped by name
  for path in "$unit" "$config" "$credentials"; do
    case "$path" in
      '' | /*) ;;
      *) fail "$MARKER names '$path', which is not an absolute path, so nothing was removed. check the record, and look for a tunnel named sirven-... in the Cloudflare dashboard." ;;
    esac
  done
  case "$service" in
    *[!A-Za-z0-9_.@-]*) fail "$MARKER names the service '$service', which is not a plain unit name, so nothing was removed." ;;
  esac

  # the local part: never needs the token
  if [ -n "$service" ]; then
    if [ -n "$(systemctl_command)" ]; then
      systemctl_command_run stop "$service" >/dev/null 2>&1 || true
      systemctl_command_run disable "$service" >/dev/null 2>&1 || true
    fi
  fi
  for path in "$unit" "$config" "$credentials"; do
    [ -n "$path" ] || continue
    rm -f "$path" "$path".new.* 2>/dev/null
    [ ! -e "$path" ] || { printf 'error: could not remove %s\n' "$path" >&2; FAILED=1; }
  done
  if [ -n "$service" ] && [ -n "$(systemctl_command)" ]; then
    systemctl_command_run daemon-reload >/dev/null 2>&1 || true
    if service_active "$service"; then
      printf 'error: %s is still running after stop\n' "$service" >&2
      FAILED=1
    fi
  fi
  [ "$FAILED" -eq 0 ] && printf 'stopped and removed the tunnel service, its config and its credentials.\n'

  # the part in the Cloudflare account: needs the token
  if [ -z "$(record_get tunnel_id)$(record_get tunnel_name)$(record_get record_id)" ]; then
    :
  elif [ -z "$TOKEN" ]; then
    printf 'access is already cut: the service is stopped and removed and the tunnel credentials and config are deleted, so no connector can attach to the tunnel any more. what is left is only the inert tunnel object and the alias record in your Cloudflare account: tunnel %s (%s), alias record %s (%s).\n' \
      "$(record_get tunnel_name)" "$(record_get tunnel_id)" "$(record_get hostname)" "$(record_get record_id)" >&2
    printf 'error: there is no Cloudflare API token, so those two could not be deleted. to finish, run the same command again with the token (saved as the token file, or in SIRVEN_CLOUDFLARE_API_TOKEN) and it deletes them, or delete them in the dashboard and then remove %s. the record stays until then.\n' "$MARKER" >&2
    exit 1
  elif ! remote_cleanup; then
    FAILED=1
  fi
  [ "$FAILED" -eq 0 ] || fail "not everything was taken away (above). the record $MARKER stays; run the same command again."
  rm -f "$MARKER"
  printf 'the Cloudflare tunnel is taken away: record removed.\n'
}

case "${1:-}" in
  up) shift; cmd_up "$@" ;;
  down) shift; cmd_down "$@" ;;
  check) shift; cmd_check "$@" ;;
  applied) shift; cmd_applied "$@" ;;
  token-file-check) shift; cmd_token_file_check "$@" ;;
  *) printf 'usage: cloudflare_tunnel.sh up OPTIONS | down OPTIONS | check OPTIONS | applied MARKER | token-file-check FILE\n' >&2; exit 64 ;;
esac
