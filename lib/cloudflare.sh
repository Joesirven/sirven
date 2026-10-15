# shellcheck shell=bash
# cloudflare tunnel transport, the second path. the plan makes a tunnel for this machine through the Cloudflare API, keeps its
# credentials root-only, routes one hostname you name to this machine's SSH server (and every other name to 404), points that
# hostname at the tunnel, and runs the tunnel as a service of its own, then records what it made so the kill switch and uninstall can
# undo exactly that and nothing else in your account. the work is in lib/cloudflare_tunnel.sh and lib/cloudflare_api.py, run from the
# pinned copy of this package, so the install record's undo line works without this file.
#
# what you do by hand, once: make an API token in the Cloudflare dashboard and put cloudflare access in front of the hostname.
# the token needs Account, Cloudflare Tunnel, Edit and Zone, domain name records, Edit, limited to your one account and one zone
# (it also needs Zone, Zone, Read, unless you give the zone number in SIRVEN_CLOUDFLARE_ZONE_ID). a token that is not limited to that
# one zone is not what this is designed for; never use a token that deploys anything else.
# the token is read from the token file below (the safer way, and the one to use) or from the environment
# (SIRVEN_CLOUDFLARE_API_TOKEN), and never written anywhere by sirven. it is needed again to take the tunnel away (revoke --all and
# uninstall delete the tunnel and the alias record in your account); without it they still stop the service and remove the
# credentials, then say plainly what is left in the account and ask to be run again with the token.
#
# the token never stays in the installer's environment. the first thing the installer and the uninstaller do (cloudflare_hold_token,
# called in main) is move the variable into one that is not exported and unset the original, so no step starts a process that
# inherits it. only the processes that need it are handed it, by the environment of that one command: the first look that checks
# the token would be accepted, the step that makes the tunnel, and the step that takes it away; each unsets it at once and gives the
# interpreter that talks to the API the token through standard input only. what unset cannot do is scrub the block of the
# environment a process was started with: root can read it in /proc/<process number>/environ while the process runs. give the token
# through the root-owned token file to avoid this. the shell trace (bash -x) prints every expansion, so the
# lines that expand the token switch the trace off (and back on), and the helper switches it off from its first line; a trace of the
# installer shows the rest of its work and never the token (scenario 65 traces a refusal and an apply and looks for it).
# reads: PREFIX, PACKAGE, CONFIG_DIR, STATE_DIR, SERVICE_USER, ROOT_DIR, OPERATING_SYSTEM, COMMAND, TRANSPORT, DRY_RUN, CLOUDFLARE_*

CLOUDFLARE_SERVICE="sirven-cloudflared.service"
# the account the service runs as: made for it by the tunnel step, marked as sirven's own, removed with the tunnel
CLOUDFLARE_SERVICE_ACCOUNT="sirven-cloudflared"
# the mark (the comment field of the account) that says an account of that name is sirven's own; the same text as ACCOUNT_COMMENT in
# lib/cloudflare_tunnel.sh (a test holds them equal). an account of the name without it is never changed or removed
CLOUDFLARE_SERVICE_ACCOUNT_MARK="sirven Cloudflare Tunnel service"
CLOUDFLARE_UNIT_DIRECTORY="/etc/systemd/system"
CLOUDFLARE_PLACEHOLDER_HOSTNAME="agent.example.org"
CLOUDFLARE_MACOS_REASON="applying to a macos machine is not verified yet; the tunnel service is a systemd unit, which only linux has"
# set by the arguments and the environment (install.sh): the hostname to route, the account number, the zone number (optional)
CLOUDFLARE_HOSTNAME="${CLOUDFLARE_HOSTNAME:-}"
CLOUDFLARE_ACCOUNT="${CLOUDFLARE_ACCOUNT:-}"
CLOUDFLARE_ZONE="${CLOUDFLARE_ZONE:-}"

# the one place the environment route can hold the token, not exported (see cloudflare_hold_token). the held name is its own name, so
# nothing here is confused with the variable the person set.
HELD_SIRVEN_CLOUDFLARE_API_TOKEN=""

# cloudflare_hold_token: take the token out of the exported environment, once, before anything else runs. an exported variable of the
# held name that came from outside is dropped first, so the held variable is a plain shell variable and not exported.
# the shell trace (bash -x) prints every expansion, token included, so it is switched off for the lines that expand the token and
# switched on again after; the same in the two functions below that expand it. (the plan actions below switch it off themselves.)
cloudflare_hold_token() {
  local was_tracing=no named
  case "$-" in *x*) was_tracing=yes; set +x ;; esac
  named="${SIRVEN_CLOUDFLARE_API_TOKEN:-}"
  unset SIRVEN_CLOUDFLARE_API_TOKEN HELD_SIRVEN_CLOUDFLARE_API_TOKEN
  HELD_SIRVEN_CLOUDFLARE_API_TOKEN="$named"
  [ "$was_tracing" = no ] || set -x
  return 0
}

# cloudflare_forget_held_token: drop the held token from this shell too, once nothing will read it.
cloudflare_forget_held_token() {
  HELD_SIRVEN_CLOUDFLARE_API_TOKEN=""
}

# cloudflare_tunnel_with_token ARGUMENT...: run lib/cloudflare_tunnel.sh with the held token in the environment of that one command,
# and nowhere else. it unsets the variable before it starts any process of its own.
cloudflare_tunnel_with_token() {
  local was_tracing=no status=0
  case "$-" in *x*) was_tracing=yes; set +x ;; esac
  SIRVEN_CLOUDFLARE_API_TOKEN="${HELD_SIRVEN_CLOUDFLARE_API_TOKEN:-}" bash "$ROOT_DIR/lib/cloudflare_tunnel.sh" "$@" || status=$?
  [ "$was_tracing" = no ] || set -x
  return "$status"
}

cloudflare_token_file() {
  printf '%s/cloudflare-api-token' "$CONFIG_DIR"
}

# the record of what was made: the tunnel's name and number, the alias record, the files, the service. never the token.
cloudflare_marker_file() {
  printf '%s/cloudflare-tunnel.json' "$STATE_DIR"
}

cloudflare_config_file() {
  printf '%s/cloudflared.yml' "$CONFIG_DIR"
}

cloudflare_credentials_file() {
  printf '%s/cloudflared-credentials.json' "$CONFIG_DIR"
}

cloudflare_unit_file() {
  printf '%s/%s' "$CLOUDFLARE_UNIT_DIRECTORY" "$CLOUDFLARE_SERVICE"
}

# the script that makes and takes away the tunnel, in the pinned copy of this package (the path an install record can rely on)
cloudflare_tunnel_script() {
  printf '%s/package/lib/cloudflare_tunnel.sh' "$STATE_DIR"
}

# cloudflare_applied: this machine's tunnel is made and its service runs (the record, its files and the service agree). read only,
# needs no token.
cloudflare_applied() {
  bash "$ROOT_DIR/lib/cloudflare_tunnel.sh" applied --marker "${PREFIX}$(cloudflare_marker_file)" --config "${PREFIX}$(cloudflare_config_file)" \
    --credentials "${PREFIX}$(cloudflare_credentials_file)" --unit "${PREFIX}$(cloudflare_unit_file)" --service "$CLOUDFLARE_SERVICE" --service-account "$CLOUDFLARE_SERVICE_ACCOUNT" >/dev/null 2>&1
}

# cloudflare_made_remote: the tunnel and the alias record are made and recorded and the credentials are here, but the config, the unit or
# the running service is not exactly what this installer writes (cloudflare_applied is false). what is different is only local: a re-apply
# writes it again with no token and no request to the API. read only.
cloudflare_made_remote() {
  bash "$ROOT_DIR/lib/cloudflare_tunnel.sh" made --marker "${PREFIX}$(cloudflare_marker_file)" --credentials "${PREFIX}$(cloudflare_credentials_file)" >/dev/null 2>&1
}

# cloudflare_record_there: the record of what the tunnel step made is there (a file, or anything under that name)
cloudflare_record_there() {
  [ -e "${PREFIX}$(cloudflare_marker_file)" ] || [ -L "${PREFIX}$(cloudflare_marker_file)" ]
}

# cloudflare_local_pieces: the unit, the config or the credentials, by sirven's own fixed names, are on this machine (whatever the record
# is, or whether there is one)
cloudflare_local_pieces() {
  local path
  for path in "$(cloudflare_unit_file)" "$(cloudflare_config_file)" "$(cloudflare_credentials_file)"; do
    if [ -e "${PREFIX}$path" ] || [ -L "${PREFIX}$path" ]; then return 0; fi
  done
  # the account the service ran as, when it carries sirven's mark (on a fake root there is no account to look at)
  if [ -z "$PREFIX" ] && command -v getent >/dev/null 2>&1 &&
    getent passwd "$CLOUDFLARE_SERVICE_ACCOUNT" 2>/dev/null | grep -q ":$CLOUDFLARE_SERVICE_ACCOUNT_MARK:"; then
    return 0
  fi
  return 1
}

# cloudflare_made_by_us: an earlier run of this package made a tunnel here: its record is there (complete or not), or pieces of it are
# on this machine under sirven's own fixed names. a record lost or damaged does not leave the service running.
cloudflare_made_by_us() {
  cloudflare_record_there || cloudflare_local_pieces
}

# cloudflare_taken_away_check: the text of a plan check that holds once the record and every piece on this machine are gone
cloudflare_taken_away_check() {
  printf '[ ! -e %s ] && [ ! -e %s ] && [ ! -e %s ] && [ ! -e %s ]' "$(rooted "$(cloudflare_marker_file)")" "$(rooted "$(cloudflare_unit_file)")" \
    "$(rooted "$(cloudflare_config_file)")" "$(rooted "$(cloudflare_credentials_file)")"
  # and the account the service ran as is gone (only one that carries sirven's mark counts; none is looked for on a fake root)
  if [ -z "$PREFIX" ]; then
    printf " && ! { getent passwd %s 2>/dev/null | grep -q ':%s:'; }" "$CLOUDFLARE_SERVICE_ACCOUNT" "$CLOUDFLARE_SERVICE_ACCOUNT_MARK"
  fi
}

# true when a token is there to work with: held from the environment, or in the token file. the token file counts only when it passes
# the same check the tunnel step makes (a plain file, owned by root, no extended access control list, no permission for anyone else), so the
# refusal comes before a change.
cloudflare_token_available() {
  local was_tracing=no held=no
  case "$-" in *x*) was_tracing=yes; set +x ;; esac
  [ -z "${HELD_SIRVEN_CLOUDFLARE_API_TOKEN:-}" ] || held=yes
  [ "$was_tracing" = no ] || set -x
  [ "$held" = yes ] || bash "$ROOT_DIR/lib/cloudflare_tunnel.sh" token-file-check "${PREFIX}$(cloudflare_token_file)" >/dev/null 2>&1
}

# the arguments of the helper that name where everything goes, as one shell-quoted line
cloudflare_paths_arguments() {
  printf -- '--marker %s --config %s --credentials %s --unit %s --service %s --service-account %s' \
    "$(rooted "$(cloudflare_marker_file)")" "$(rooted "$(cloudflare_config_file)")" "$(rooted "$(cloudflare_credentials_file)")" \
    "$(rooted "$(cloudflare_unit_file)")" "$(shell_quote "$CLOUDFLARE_SERVICE")" "$(shell_quote "$CLOUDFLARE_SERVICE_ACCOUNT")"
}

cloudflare_target_arguments() {
  local hostname="${CLOUDFLARE_HOSTNAME:-$CLOUDFLARE_PLACEHOLDER_HOSTNAME}" account="${CLOUDFLARE_ACCOUNT:-<your account number>}"
  printf -- '--user %s --hostname %s --account %s' "$(shell_quote "$SERVICE_USER")" "$(shell_quote "$hostname")" "$(shell_quote "$account")"
  [ -z "$CLOUDFLARE_ZONE" ] || printf -- ' --zone %s' "$(shell_quote "$CLOUDFLARE_ZONE")"
  printf -- ' --token-file %s' "$(rooted "$(cloudflare_token_file)")"
}

# cloudflare_down: take the tunnel away, with the held token in the environment of that one command. what the kill switch runs.
cloudflare_down() {
  cloudflare_tunnel_with_token down --marker "${PREFIX}$(cloudflare_marker_file)" --config "${PREFIX}$(cloudflare_config_file)" \
    --credentials "${PREFIX}$(cloudflare_credentials_file)" --unit "${PREFIX}$(cloudflare_unit_file)" --service "$CLOUDFLARE_SERVICE" \
    --service-account "$CLOUDFLARE_SERVICE_ACCOUNT" --token-file "${PREFIX}$(cloudflare_token_file)"
}

# cloudflare_refuse_before_apply: a real apply that cannot make the tunnel stops before its first change, with what to do. a dry run and
# a fake root never make it, so they are not stopped. a machine that already has its tunnel needs no token. this part sends nothing to the
# network: it runs before the plan is printed, and the owner has not said yes yet. what needs the Cloudflare API waits for
# cloudflare_check_account_before_apply, below.
cloudflare_refuse_before_apply() {
  local token_file_status
  [ "$COMMAND" = install ] && [ "$TRANSPORT" = cloudflare ] && [ "$DRY_RUN" != yes ] && [ -z "$PREFIX" ] || return 0
  [ "$OPERATING_SYSTEM" = linux ] || return 0
  if cloudflare_applied; then return 0; fi
  if [ -z "$CLOUDFLARE_HOSTNAME" ]; then
    printf 'error: refused: no hostname is named for the tunnel. nothing was changed.\n' >&2
    printf 'you can: run again with --cloudflare-hostname agent.your-zone.example (a name inside a zone of your own Cloudflare account that nothing uses yet), or run again with --transport none.\n' >&2
    exit 2
  fi
  if [ -z "$CLOUDFLARE_ACCOUNT" ]; then
    printf 'error: refused: no Cloudflare account number is named. nothing was changed.\n' >&2
    printf 'you can: run again with --cloudflare-account NUMBER (the 32 character account number on the right of the Cloudflare dashboard overview of any zone), or run again with --transport none.\n' >&2
    exit 2
  fi
  if ! cloudflare_made_remote && ! cloudflare_token_available; then
    token_file_status=0
    bash "$ROOT_DIR/lib/cloudflare_tunnel.sh" token-file-check "$(cloudflare_token_file)" >/dev/null || token_file_status=$?
    if [ "$token_file_status" -eq 2 ]; then
      printf 'error: refused: the saved API token file cannot be trusted (above). nothing was changed.\n' >&2
      printf 'you can: fix it (chown root:root %s, take off any extended access control list with setfacl -b %s, then chmod 600 %s; if it has more than one name, copy the token into a new file with umask 077 and remove the old names), or remove it and hand the token over in the environment.\n' \
        "$(cloudflare_token_file)" "$(cloudflare_token_file)" "$(cloudflare_token_file)" >&2
      exit 2
    fi
    printf 'error: refused: there is no Cloudflare API token to make the tunnel with. nothing was changed.\n' >&2
    printf 'you can: make a token in the Cloudflare dashboard (My Profile, API Tokens): permissions Account, Cloudflare Tunnel, Edit and Zone, domain name records, Edit, limited to the one account and the one zone, then run again with it saved as %s, owned by root, mode 0600 (the safer way), or in the environment: sudo --preserve-env=SIRVEN_CLOUDFLARE_API_TOKEN ... (which works only if the sudo policy allows it). or run again with --transport none.\n' "$(cloudflare_token_file)" >&2
    exit 2
  fi
  # every other refusal the tunnel step would make that needs no network, now, so that "nothing was changed" is true: cloudflared missing,
  # no systemd, a hostname or number that is not in the form Cloudflare uses. the script prints why.
  # shellcheck disable=SC2046 # the helper's options are words by design
  cloudflare_tunnel_with_token check --marker "$(cloudflare_marker_file)" --hostname "$CLOUDFLARE_HOSTNAME" --account "$CLOUDFLARE_ACCOUNT" \
    --user "$SERVICE_USER" --service-account "$CLOUDFLARE_SERVICE_ACCOUNT" \
    ${CLOUDFLARE_ZONE:+--zone "$CLOUDFLARE_ZONE"} --token-file "$(cloudflare_token_file)" || exit 2
}

# cloudflare_check_account_before_apply: the refusals that need the Cloudflare API (a token the API turns away, a zone that cannot be
# found, a hostname that already has a record that is not ours). the first request goes out only here: after the plan is printed and the
# owner has confirmed it (plan_apply runs this through PLAN_BEFORE_FIRST_CHANGE, see install.sh), and before the first change, so "nothing
# was changed" is still true when it refuses. a refusal is status 2.
cloudflare_check_account_before_apply() {
  [ "$COMMAND" = install ] && [ "$TRANSPORT" = cloudflare ] && [ "$DRY_RUN" != yes ] && [ -z "$PREFIX" ] || return 0
  [ "$OPERATING_SYSTEM" = linux ] || return 0
  if cloudflare_applied; then return 0; fi
  # shellcheck disable=SC2046 # the helper's options are words by design
  cloudflare_tunnel_with_token check-account --marker "$(cloudflare_marker_file)" --hostname "$CLOUDFLARE_HOSTNAME" --account "$CLOUDFLARE_ACCOUNT" \
    --user "$SERVICE_USER" --service-account "$CLOUDFLARE_SERVICE_ACCOUNT" \
    ${CLOUDFLARE_ZONE:+--zone "$CLOUDFLARE_ZONE"} --token-file "$(cloudflare_token_file)" || return 2
}

plan_cloudflare() {
  local script hostname account token_file
  script="$(rooted "$(cloudflare_tunnel_script)")"
  token_file="$(rooted "$(cloudflare_token_file)")"
  hostname="${CLOUDFLARE_HOSTNAME:-$CLOUDFLARE_PLACEHOLDER_HOSTNAME}"
  account="${CLOUDFLARE_ACCOUNT:-<your account number>}"
  plan_section "transport: cloudflare tunnel"
  if [ -z "$CLOUDFLARE_HOSTNAME" ]; then
    plan_note "no hostname is named, so $CLOUDFLARE_PLACEHOLDER_HOSTNAME stands in. a real apply needs --cloudflare-hostname (a name in a zone of your own that nothing uses yet) and --cloudflare-account."
  fi
  plan_note "warning: until you put cloudflare access in front of $hostname (an owner step below), anyone on the internet can reach that hostname, and only the SSH keys of $SERVICE_USER stand in the way. do that before you give the hostname to anyone."
  plan_note "the tunnel routes exactly one hostname, $hostname, to this machine's SSH server (ssh://localhost:22), whatever the level; every other name gets 404. no other port, no private network route."
  if cloudflare_applied; then
    plan_note "this machine already has its tunnel, made by an earlier run of this installer and recorded in $(cloudflare_marker_file): no API token and no new tunnel. the kill switch and uninstall delete that tunnel and its alias record, and only them."
    cloudflare_forget_held_token
    if [ -e "${PREFIX}$(cloudflare_token_file)" ]; then
      plan_note "an API token is still saved at $(cloudflare_token_file) and is not needed now: delete it, and hand it over again when you take the tunnel away."
    fi
  elif cloudflare_made_remote; then
    plan_note "this machine already has its tunnel in your Cloudflare account, recorded in $(cloudflare_marker_file), but its config, its unit or its running service is not exactly what this installer writes (a hostname added to the config by hand, a changed unit, a stopped service). this apply writes them again and restarts the service. no API token is needed, no request goes to Cloudflare, and nothing in your account changes."
    cloudflare_forget_held_token
  else
    plan_owner "give the installer one Cloudflare API token, once" \
      "Cloudflare dashboard, My Profile, API Tokens: create a token with the permissions Account, Cloudflare Tunnel, Edit and Zone, domain name records, Edit (and Zone, Zone, Read, unless you give the zone number in SIRVEN_CLOUDFLARE_ZONE_ID), limited to your one account and the one zone of $hostname. never a token that can do anything else.
hand it over one of two ways, and it is the only interactive step:
  in a file, the safer way and the one to use first: save it as $(cloudflare_token_file), owned by root, mode 0600, with one name only (no hard link) and no extra access control list; it is removed after the tunnel is made, so give it again to take the tunnel away. this is the only way that never puts the token in an environment.
  in the environment: set SIRVEN_CLOUDFLARE_API_TOKEN in your shell and run sudo --preserve-env=SIRVEN_CLOUDFLARE_API_TOKEN. sudo allows that only when its policy does. the installer takes the token out of its environment at once and hands it only to the steps that need it, but it cannot scrub the block of the environment it was started with: root can still read it in /proc/<installer process number>/environ until the installer ends." \
      "cloudflare_token_available"
  fi
  plan_owner "put cloudflare access in front of the hostname, with a service token" \
    "cloudflare dashboard, access, applications: add $hostname as a self-hosted application.
policy action: service auth, allowing only a new service token for your agent client.
do not add email code login or any other login method.
(until you do, the hostname is reachable by anyone, and only the SSH keys of $SERVICE_USER stand in the way. do this before you give the hostname to anyone.)"
  if [ "$OPERATING_SYSTEM" = macos ]; then
    plan_planonly "make the tunnel, point the hostname at it, and run it as a service" \
      "bash $(cloudflare_tunnel_script) up $(cloudflare_paths_arguments) $(cloudflare_target_arguments)" \
      "$CLOUDFLARE_MACOS_REASON" \
      "cloudflare_applied"
    plan_undo "take this machine's Cloudflare tunnel away, if this installer made it" "$(cloudflare_taken_away_check)" \
      "bash $script down $(cloudflare_paths_arguments) --token-file $token_file"
  else
    plan_step system "make the tunnel, point the hostname at it, and run it as a service" \
      "cloudflare_applied" \
      "{ set +x; } 2>/dev/null; SIRVEN_CLOUDFLARE_API_TOKEN=\"\${HELD_SIRVEN_CLOUDFLARE_API_TOKEN:-}\" bash $script up $(cloudflare_paths_arguments) $(cloudflare_target_arguments)" \
      "# runs lib/cloudflare_tunnel.sh up; the token comes from $(cloudflare_token_file) or from the environment of this one command, and is never put on a command line.
# it makes a tunnel named sirven-$SERVICE_USER-<this machine's name>-<random> in account $account, managed from this machine (the dashboard cannot widen it),
# makes the account $CLOUDFLARE_SERVICE_ACCOUNT for the service (a system account: no shell, no home) unless it is already there and is sirven's own, keeps the tunnel's credentials in $(cloudflare_credentials_file)
# and its config in $(cloudflare_config_file) (both owned by that account alone, mode 0600), points $hostname at it with an alias record,
# writes $(cloudflare_unit_file) and starts it. it records each of these in $(cloudflare_marker_file) as soon as it exists, and refuses with nothing changed if there is no token, no cloudflared, no systemd, or a record at $hostname that is not ours.
# the service it starts runs: cloudflared --no-autoupdate --config $(cloudflare_config_file) tunnel run   (as $CLOUDFLARE_SERVICE, run by the account $CLOUDFLARE_SERVICE_ACCOUNT that this step makes: no shell, no home, the only account that can read the credentials and the config; under systemd's sandboxing; it only dials out)
bash $script up $(cloudflare_paths_arguments) $(cloudflare_target_arguments)"
    # the tunnel step is the only one that reads the token, and it is handed it in its own command's environment (see
    # cloudflare_hold_token): no step before or after starts a child process that inherits it. once it has run (done, failed or
    # skipped) the held copy is dropped from the shell too, and the exported name is unset again as defense in depth.
    plan_forget_secrets HELD_SIRVEN_CLOUDFLARE_API_TOKEN SIRVEN_CLOUDFLARE_API_TOKEN
    plan_undo "take this machine's Cloudflare tunnel away, if this installer made it" "$(cloudflare_taken_away_check)" \
      "{ set +x; } 2>/dev/null; SIRVEN_CLOUDFLARE_API_TOKEN=\"\${HELD_SIRVEN_CLOUDFLARE_API_TOKEN:-}\" bash $script down $(cloudflare_paths_arguments) --token-file $token_file" \
      "cloudflared tunnel delete, and the alias record, via lib/cloudflare_tunnel.sh down: the service, the credentials, the config and the account it ran as go from this machine; the tunnel and the alias record go from your account, each only while it is still the one this installer made. needs the token again (the token file, or SIRVEN_CLOUDFLARE_API_TOKEN)"
    plan_step run "remove the used API token file, if one was saved" \
      "[ ! -e $token_file ]" \
      "rm -f $token_file"
  fi
  plan_note "the agent client connects with: ssh -o ProxyCommand='cloudflared access ssh --hostname %h --service-token-id <token> --service-token-secret <secret>' $SERVICE_USER@$hostname"
}
