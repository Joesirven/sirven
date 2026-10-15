# shellcheck shell=bash
# the Cloudflare tunnel transport: lib/cloudflare_tunnel.sh makes the tunnel, its alias record and its service, and takes exactly
# those away again. the tests run it against a fake Cloudflare API that keeps real state (tests/fixtures/cloudflare/api_server.py),
# a fake cloudflared and a fake systemctl. the API token is a sentinel: it must appear nowhere but in the environment of the test.

FIXTURES="$REPO_DIR/tests/fixtures/cloudflare"
HELPER="$REPO_DIR/lib/cloudflare_tunnel.sh"
SENTINEL_TOKEN="cfapi""SENTINELtoken0123456789_ZZZZ-9876543210abc"
ACCOUNT="0123456789abcdef0123456789abcdef"
ZONE="fedcba9876543210fedcba9876543210"
ZONE_NAME="example.test"
HOST_NAME="agent.example.test"

# setup: the fake API on a free port of this machine, the fake commands, and the paths a real run is given.
# the helper ignores the SIRVEN_CLOUDFLARED and SIRVEN_SYSTEMCTL seams as root (root runs only the vetted commands), so as root these
# tests could not use the fakes: they end here, and scenario 65 covers the same ground as root, in a container.
setup_tunnel() {
  local waited=0
  if [ "$(id -u)" -eq 0 ]; then
    printf 'skipped: these tests need a normal user, because root ignores the SIRVEN_CLOUDFLARED and SIRVEN_SYSTEMCTL seams\n'
    exit 0
  fi
  STATE="$TEST_TMP/state"
  MARKER="$STATE/cloudflare-tunnel.json"
  CONFIG="$TEST_TMP/etc/cloudflared.yml"
  CREDENTIALS="$TEST_TMP/etc/cloudflared-credentials.json"
  UNIT="$TEST_TMP/units/sirven-cloudflared.service"
  mkdir -p "$STATE" "$TEST_TMP/etc" "$TEST_TMP/units"
  API_DIR="$TEST_TMP/api"
  mkdir -p "$API_DIR"
  printf '%s\n' "$SENTINEL_TOKEN" > "$TEST_TMP/api-token"
  python3 -I "$FIXTURES/api_server.py" "$API_DIR" --token-file "$TEST_TMP/api-token" --account "$ACCOUNT" --zone "$ZONE" --zone-name "$ZONE_NAME" >/dev/null 2>&1 &
  API_PID=$!
  trap 'kill "$API_PID" 2>/dev/null' EXIT
  while [ ! -s "$API_DIR/port" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -s "$API_DIR/port" ] || fail "the fake API did not start"
  SIRVEN_CLOUDFLARE_API="http://127.0.0.1:$(cat "$API_DIR/port")"
  export SIRVEN_CLOUDFLARE_API
  export SIRVEN_CLOUDFLARED="$FIXTURES/cloudflared" SIRVEN_SYSTEMCTL="$FIXTURES/systemctl"
  export FAKE_CF_DIR="$TEST_TMP/fake-cloudflared" FAKE_SYSTEMD_DIR="$TEST_TMP/fake-systemd"
  # the fakes say (never print) when any variable they were started with holds the token, under any name
  export FAKE_LEAK_CHECK_FILE="$TEST_TMP/api-token"
  unset SIRVEN_CLOUDFLARE_API_TOKEN FAKE_CF_VERSION FAKE_CF_BAD_CONFIG FAKE_SYSTEMCTL_START_FAILS FAKE_SYSTEMCTL_STOP_FAILS
  mkdir -p "$FAKE_CF_DIR" "$FAKE_SYSTEMD_DIR"
}

# up and down with the token in the environment of that one command, as the installer hands it over
up() {
  SIRVEN_CLOUDFLARE_API_TOKEN="${TOKEN_FOR_RUN-$SENTINEL_TOKEN}" bash "$HELPER" up --marker "$MARKER" --config "$CONFIG" \
    --credentials "$CREDENTIALS" --unit "$UNIT" --service sirven-cloudflared.service --user agent --hostname "${1:-$HOST_NAME}" --account "$ACCOUNT"
}

down() {
  SIRVEN_CLOUDFLARE_API_TOKEN="${TOKEN_FOR_RUN-$SENTINEL_TOKEN}" bash "$HELPER" down --marker "$MARKER"
}

# what the fake API holds
api_value() {
  python3 -I -c '
import json, sys
try:
    state = json.load(open(sys.argv[1]))
except FileNotFoundError:
    state = {"tunnels": {}, "records": {}}
tunnels = [t for t in state["tunnels"].values() if not t.get("deleted_at")]
if sys.argv[2] == "tunnels": print(len(tunnels))
elif sys.argv[2] == "records": print(len(state["records"]))
elif sys.argv[2] == "tunnel_id": print(tunnels[0]["id"])
elif sys.argv[2] == "tunnel_name": print(tunnels[0]["name"])
elif sys.argv[2] == "record_content": print(list(state["records"].values())[0]["content"])
elif sys.argv[2] == "record_id": print(list(state["records"].values())[0]["id"])
' "$API_DIR/state.json" "$1"
}

api_calls() {
  cat "$API_DIR/calls.log" 2>/dev/null || true
}

record_field() {
  python3 -I "$REPO_DIR/lib/cloudflare_api.py" marker-get "$MARKER" "$1"
}

file_mode() {
  # shellcheck disable=SC2012 # ls -ln is the portable way to read a mode string on macos and linux, as the other tests do
  ls -ln "$1" | cut -c1-10
}

# nothing anywhere under the folders, or in the last output, or in anything a fake saw, holds the token.
assert_token_nowhere() {
  if grep -rl -F -- "$SENTINEL_TOKEN" "$STATE" "$TEST_TMP/etc" "$TEST_TMP/units" "$FAKE_CF_DIR" "$FAKE_SYSTEMD_DIR" "$API_DIR/state.json" >/dev/null 2>&1; then
    fail "the API token was written under the test folders"
  fi
  assert_not_contains "$(api_calls)" "$SENTINEL_TOKEN" "the log of the fake API"
  assert_not_contains "$CAPTURED_STDOUT" "$SENTINEL_TOKEN" "standard output"
  assert_not_contains "$CAPTURED_STDERR" "$SENTINEL_TOKEN" "standard error"
}

test_up_makes_the_tunnel_the_record_the_files_and_the_service() {
  setup_tunnel
  assert_status 0 up
  assert_contains "$CAPTURED_STDOUT" "made the tunnel sirven-agent-"
  assert_contains "$CAPTURED_STDOUT" "pointed $HOST_NAME at the tunnel"
  assert_eq 1 "$(api_value tunnels)" "one tunnel in the account"
  assert_eq 1 "$(api_value records)" "one alias record in the zone"
  assert_eq "$(api_value tunnel_id).cfargotunnel.com" "$(api_value record_content)" "the record points at the tunnel"
  assert_eq "$(api_value tunnel_id)" "$(record_field tunnel_id)" "the record file names the tunnel"
  assert_eq "$(api_value tunnel_name)" "$(record_field tunnel_name)"
  assert_eq "$(api_value record_id)" "$(record_field record_id)"
  assert_eq "$HOST_NAME" "$(record_field hostname)"
  assert_eq "$ACCOUNT" "$(record_field account_id)"
  assert_eq "-rw-------" "$(file_mode "$MARKER")" "mode of the record"
  assert_eq "-rw-------" "$(file_mode "$CREDENTIALS")" "mode of the credentials"
  assert_eq "-rw-------" "$(file_mode "$CONFIG")" "mode of the config"
  assert_contains "$(cat "$CREDENTIALS")" '"TunnelSecret"'
  assert_contains "$(cat "$CREDENTIALS")" "\"TunnelID\": \"$(api_value tunnel_id)\""
  assert_file_exists "$UNIT"
  assert_contains "$(cat "$UNIT")" "ExecStart=$FIXTURES/cloudflared --no-autoupdate --config $CONFIG tunnel run"
  assert_not_contains "$(cat "$UNIT")" "User=" "the service runs as root, never as the agent"
  assert_file_exists "$FAKE_SYSTEMD_DIR/sirven-cloudflared.service.active"
  assert_file_exists "$FAKE_SYSTEMD_DIR/sirven-cloudflared.service.enabled"
  assert_token_nowhere
}

# the config routes exactly one hostname to the SSH server of this machine, and every other name to 404: no wildcard, no second service
test_the_config_routes_only_the_hostname_to_ssh() {
  setup_tunnel
  assert_status 0 up
  assert_eq "tunnel: $(api_value tunnel_id)
credentials-file: $CREDENTIALS
ingress:
  - hostname: $HOST_NAME
    service: ssh://localhost:22
  - service: http_status:404" "$(cat "$CONFIG")"
  assert_contains "$(cat "$FAKE_CF_DIR/calls.log")" "tunnel --config $CONFIG ingress validate" "cloudflared was asked to validate the config before the service started"
}

test_the_account_keeps_a_tunnel_managed_from_this_machine() {
  setup_tunnel
  assert_status 0 up
  assert_contains "$(cat "$API_DIR/state.json")" '"config_src": "local"'
}

test_a_second_up_needs_no_token_and_changes_nothing() {
  setup_tunnel
  assert_status 0 up
  local calls
  calls="$(api_calls | wc -l | tr -d ' ')"
  TOKEN_FOR_RUN="" assert_status 0 up
  assert_contains "$CAPTURED_STDOUT" "already made and its service sirven-cloudflared.service runs"
  assert_eq "$calls" "$(api_calls | wc -l | tr -d ' ')" "no API call at all"
  assert_eq 1 "$(api_value tunnels)"
  assert_eq 1 "$(api_value records)"
}

test_up_without_a_token_is_refused_before_any_change() {
  setup_tunnel
  TOKEN_FOR_RUN="" assert_status 2 up
  assert_contains "$CAPTURED_STDERR" "there is no Cloudflare API token"
  assert_contains "$CAPTURED_STDERR" "nothing was changed"
  assert_contains "$CAPTURED_STDERR" "SIRVEN_CLOUDFLARE_API_TOKEN"
  assert_no_file "$MARKER"
  assert_no_file "$CONFIG"
  assert_no_file "$UNIT"
  assert_eq "" "$(api_calls)" "no API call"
}

test_up_refuses_a_wrong_token_without_printing_it() {
  setup_tunnel
  TOKEN_FOR_RUN="wrongtoken0123456789wrongtoken0123456789" assert_status 2 up
  assert_contains "$CAPTURED_STDERR" "cannot list tunnels"
  assert_contains "$CAPTURED_STDERR" "nothing was changed"
  assert_not_contains "$CAPTURED_STDERR" "wrongtoken0123456789"
  assert_no_file "$MARKER"
  assert_eq 0 "$(api_value tunnels)"
}

test_the_refusals_come_before_the_first_change() {
  setup_tunnel
  SIRVEN_CLOUDFLARED=none assert_status 2 up
  assert_contains "$CAPTURED_STDERR" "cloudflared is not installed"
  assert_contains "$CAPTURED_STDERR" "apt install cloudflared"
  SIRVEN_SYSTEMCTL=none assert_status 2 up
  assert_contains "$CAPTURED_STDERR" "systemd does not run on this machine"
  assert_status 2 up "Agent.Example.Test"
  assert_contains "$CAPTURED_STDERR" "is not a plain lowercase host name"
  assert_status 2 up "nodots"
  assert_status 2 bash "$HELPER" up --marker "$MARKER" --config "$CONFIG" --credentials "$CREDENTIALS" --unit "$UNIT" --service sirven-cloudflared.service --user agent --hostname "$HOST_NAME" --account "not-an-account"
  assert_contains "$CAPTURED_STDERR" "is not 32 hexadecimal characters"
  assert_no_file "$MARKER"
  assert_eq 0 "$(api_value tunnels)"
  assert_eq 0 "$(api_value records)"
}

test_up_refuses_a_hostname_that_already_has_a_record_of_someone_else() {
  setup_tunnel
  python3 -I - "$API_DIR" "$SIRVEN_CLOUDFLARE_API" "$SENTINEL_TOKEN" "$ZONE" <<'PY'
import json, sys, urllib.request
directory, base, token, zone = sys.argv[1:5]
request = urllib.request.Request(base + "/zones/%s/dns_records" % zone, data=json.dumps({"type": "A", "name": "agent.example.test", "content": "192.0.2.1"}).encode(), method="POST")
request.add_header("Authorization", "Bearer " + token)
urllib.request.urlopen(request)
PY
  assert_status 2 up
  assert_contains "$CAPTURED_STDERR" "already has a record in the zone that sirven did not make"
  assert_contains "$CAPTURED_STDERR" "nothing was changed"
  assert_eq 0 "$(api_value tunnels)" "no tunnel was made"
  assert_eq 1 "$(api_value records)" "and the record of someone else is untouched"
  assert_no_file "$MARKER"
}

test_the_token_can_come_from_a_safe_file_and_an_unsafe_one_is_refused() {
  setup_tunnel
  local file="$TEST_TMP/token-file"
  printf '%s\n' "$SENTINEL_TOKEN" > "$file"
  chmod 640 "$file"
  TOKEN_FOR_RUN="" assert_status 2 bash "$HELPER" up --token-file "$file" --marker "$MARKER" --config "$CONFIG" --credentials "$CREDENTIALS" --unit "$UNIT" --service sirven-cloudflared.service --user agent --hostname "$HOST_NAME" --account "$ACCOUNT"
  assert_contains "$CAPTURED_STDERR" "its mode is -rw-r-----"
  assert_not_contains "$CAPTURED_STDERR" "$SENTINEL_TOKEN"
  assert_no_file "$MARKER"
  chmod 600 "$file"
  ln "$file" "$TEST_TMP/second-name"
  TOKEN_FOR_RUN="" assert_status 2 bash "$HELPER" up --token-file "$file" --marker "$MARKER" --config "$CONFIG" --credentials "$CREDENTIALS" --unit "$UNIT" --service sirven-cloudflared.service --user agent --hostname "$HOST_NAME" --account "$ACCOUNT"
  assert_contains "$CAPTURED_STDERR" "more than one name"
  rm -f "$TEST_TMP/second-name"
  TOKEN_FOR_RUN="" assert_status 0 bash "$HELPER" up --token-file "$file" --marker "$MARKER" --config "$CONFIG" --credentials "$CREDENTIALS" --unit "$UNIT" --service sirven-cloudflared.service --user agent --hostname "$HOST_NAME" --account "$ACCOUNT"
  assert_eq 1 "$(api_value tunnels)"
  assert_token_nowhere
}

test_token_file_check_says_usable_missing_or_unsafe() {
  setup_tunnel
  local file="$TEST_TMP/token-file"
  assert_status 1 bash "$HELPER" token-file-check "$file"
  printf '%s\n' "$SENTINEL_TOKEN" > "$file"
  chmod 600 "$file"
  assert_status 0 bash "$HELPER" token-file-check "$file"
  chmod 644 "$file"
  assert_status 2 bash "$HELPER" token-file-check "$file"
  assert_contains "$CAPTURED_STDERR" "its mode is"
  assert_not_contains "$CAPTURED_STDERR" "$SENTINEL_TOKEN"
  chmod 600 "$file"
  rm "$file"
  ln -s /etc/hosts "$file"
  assert_status 2 bash "$HELPER" token-file-check "$file"
  assert_contains "$CAPTURED_STDERR" "not a plain file"
}

# the checks a saved token file must pass live in lib/secret_file.sh. a copy of the script without that file, or with one that defines
# nothing, must fail closed: a group readable token file is not accepted because the rule that refuses it is missing
test_a_token_file_is_refused_when_the_file_of_checks_is_missing_or_defines_nothing() {
  setup_tunnel
  local lonely="$TEST_TMP/lonely" kind
  mkdir -p "$lonely/missing" "$lonely/empty"
  cp "$HELPER" "$lonely/missing/cloudflare_tunnel.sh"
  cp "$HELPER" "$lonely/empty/cloudflare_tunnel.sh"
  : > "$lonely/empty/secret_file.sh"
  printf '%s\n' "$SENTINEL_TOKEN" > "$TEST_TMP/open-token"
  chmod 644 "$TEST_TMP/open-token"
  for kind in missing empty; do
    assert_status 2 bash "$lonely/$kind/cloudflare_tunnel.sh" token-file-check "$TEST_TMP/open-token"
    assert_contains "$CAPTURED_STDERR" "cannot be checked"
    assert_not_contains "$CAPTURED_STDERR" "$SENTINEL_TOKEN"
    TOKEN_FOR_RUN="" assert_status 2 bash "$lonely/$kind/cloudflare_tunnel.sh" up --token-file "$TEST_TMP/open-token" --marker "$MARKER" --config "$CONFIG" --credentials "$CREDENTIALS" --unit "$UNIT" --service sirven-cloudflared.service --user agent --hostname "$HOST_NAME" --account "$ACCOUNT"
    assert_contains "$CAPTURED_STDERR" "nothing was changed"
  done
  assert_no_file "$MARKER"
  assert_eq 0 "$(api_value tunnels)" "no tunnel was made"
  # the real script, with its file of checks beside it, refuses the same file for its mode (the control)
  assert_status 2 bash "$HELPER" token-file-check "$TEST_TMP/open-token"
  assert_contains "$CAPTURED_STDERR" "its mode is"
}

test_down_takes_away_exactly_what_up_made() {
  setup_tunnel
  assert_status 0 up
  assert_status 0 down
  assert_contains "$CAPTURED_STDOUT" "deleted the alias record $HOST_NAME"
  assert_contains "$CAPTURED_STDOUT" "deleted the tunnel sirven-agent-"
  assert_eq 0 "$(api_value tunnels)"
  assert_eq 0 "$(api_value records)"
  assert_no_file "$MARKER"
  assert_no_file "$CONFIG"
  assert_no_file "$CREDENTIALS"
  assert_no_file "$UNIT"
  assert_no_file "$FAKE_SYSTEMD_DIR/sirven-cloudflared.service.active"
  assert_no_file "$FAKE_SYSTEMD_DIR/sirven-cloudflared.service.enabled"
  assert_token_nowhere
}

test_down_ends_the_connections_before_it_deletes_the_tunnel() {
  setup_tunnel
  assert_status 0 up
  assert_status 0 down
  local calls
  calls="$(api_calls | grep '^DELETE /accounts')"
  assert_contains "$calls" "/connections"
  assert_eq "DELETE /accounts/$ACCOUNT/cfd_tunnel/$(record_field_after_down)/connections authorized" "$(printf '%s\n' "$calls" | sed -n 1p)" "the connections go first"
}

# (the record is gone after down: the tunnel number is read back from the calls)
record_field_after_down() {
  api_calls | sed -n 's|^DELETE /accounts/[0-9a-f]*/cfd_tunnel/\([0-9a-f-]*\)/connections.*|\1|p' | head -n 1
}

test_a_second_down_does_nothing_and_does_not_fail() {
  setup_tunnel
  assert_status 0 up
  assert_status 0 down
  local calls
  calls="$(api_calls | wc -l | tr -d ' ')"
  TOKEN_FOR_RUN="" assert_status 0 down
  assert_contains "$CAPTURED_STDOUT" "no Cloudflare tunnel of ours is recorded"
  assert_eq "$calls" "$(api_calls | wc -l | tr -d ' ')"
}

test_down_without_the_token_still_cuts_the_machine_off_and_finishes_when_given_the_token() {
  setup_tunnel
  assert_status 0 up
  local tunnel record
  tunnel="$(api_value tunnel_id)"
  record="$(api_value record_id)"
  TOKEN_FOR_RUN="" assert_status 1 down
  assert_contains "$CAPTURED_STDERR" "access is already cut"
  assert_contains "$CAPTURED_STDERR" "only the inert tunnel object and the alias record"
  assert_contains "$CAPTURED_STDERR" "there is no Cloudflare API token"
  assert_contains "$CAPTURED_STDERR" "$tunnel"
  assert_contains "$CAPTURED_STDERR" "$record"
  assert_no_file "$UNIT"
  assert_no_file "$CONFIG"
  assert_no_file "$CREDENTIALS"
  assert_no_file "$FAKE_SYSTEMD_DIR/sirven-cloudflared.service.active"
  assert_file_exists "$MARKER"
  assert_eq 1 "$(api_value tunnels)" "the account still has the tunnel"
  assert_eq 1 "$(api_value records)" "and the record"
  assert_status 0 down
  assert_eq 0 "$(api_value tunnels)"
  assert_eq 0 "$(api_value records)"
  assert_no_file "$MARKER"
}

test_down_leaves_a_record_the_owner_changed_alone() {
  setup_tunnel
  assert_status 0 up
  python3 -I - "$API_DIR" <<'PY'
import json, sys
path = sys.argv[1] + "/state.json"
state = json.load(open(path))
for record in state["records"].values():
    record["content"] = "someone-elses-tunnel.cfargotunnel.com"
json.dump(state, open(path, "w"))
PY
  assert_status 0 down
  assert_contains "$CAPTURED_STDOUT" "no longer points at this tunnel"
  assert_eq 1 "$(api_value records)" "the record is still there"
  assert_eq 0 "$(api_value tunnels)" "our tunnel is gone"
}

test_down_leaves_a_tunnel_the_owner_renamed_alone() {
  setup_tunnel
  assert_status 0 up
  python3 -I - "$API_DIR" <<'PY'
import json, sys
path = sys.argv[1] + "/state.json"
state = json.load(open(path))
for tunnel in state["tunnels"].values():
    tunnel["name"] = "owners-own-tunnel"
json.dump(state, open(path, "w"))
PY
  assert_status 0 down
  assert_contains "$CAPTURED_STDOUT" "is now named owners-own-tunnel"
  assert_eq 1 "$(api_value tunnels)" "the tunnel is still there"
}

# a stopped run: the tunnel exists but the alias record could not be made. the record file names the tunnel, down removes it, and a
# second up finishes the job with the same tunnel
test_a_run_that_stops_halfway_leaves_a_record_that_down_can_undo() {
  setup_tunnel
  : > "$API_DIR/refuse-records"
  assert_status 1 up
  assert_contains "$CAPTURED_STDERR" "could not point $HOST_NAME at the tunnel"
  assert_eq 1 "$(api_value tunnels)"
  assert_eq "$(api_value tunnel_id)" "$(record_field tunnel_id)" "the half-made tunnel is recorded"
  assert_status 0 down
  assert_eq 0 "$(api_value tunnels)" "down removed the half-made tunnel"
  assert_no_file "$MARKER"
}

test_a_second_up_finishes_a_run_that_stopped_halfway_with_the_same_tunnel() {
  setup_tunnel
  : > "$API_DIR/refuse-records"
  assert_status 1 up
  local tunnel
  tunnel="$(api_value tunnel_id)"
  rm "$API_DIR/refuse-records"
  assert_status 0 up
  assert_eq 1 "$(api_value tunnels)"
  assert_eq "$tunnel" "$(api_value tunnel_id)" "the tunnel was reused, not made again"
  assert_eq 1 "$(api_value records)"
  assert_file_exists "$FAKE_SYSTEMD_DIR/sirven-cloudflared.service.active"
}

test_a_service_that_will_not_start_fails_loudly_and_down_still_undoes_everything() {
  setup_tunnel
  FAKE_SYSTEMCTL_START_FAILS=yes assert_status 1 up
  assert_contains "$CAPTURED_STDERR" "could not start sirven-cloudflared.service"
  assert_eq 1 "$(api_value tunnels)"
  assert_eq 1 "$(api_value records)"
  assert_status 0 down
  assert_eq 0 "$(api_value tunnels)"
  assert_eq 0 "$(api_value records)"
  assert_no_file "$UNIT"
}

test_a_config_cloudflared_rejects_stops_before_the_service_starts() {
  setup_tunnel
  FAKE_CF_BAD_CONFIG=yes assert_status 1 up
  assert_contains "$CAPTURED_STDERR" "cloudflared does not accept the config"
  assert_no_file "$UNIT"
  assert_no_file "$FAKE_SYSTEMD_DIR/sirven-cloudflared.service.active"
  assert_eq 0 "$(api_value records)" "no hostname was pointed at a tunnel that cannot run"
}

test_down_that_cannot_delete_the_tunnel_fails_loudly_keeps_the_record_and_can_be_repeated() {
  setup_tunnel
  assert_status 0 up
  : > "$API_DIR/fail-tunnel-delete"
  assert_status 1 down
  assert_contains "$CAPTURED_STDERR" "not everything was taken away"
  assert_file_exists "$MARKER"
  assert_eq 1 "$(api_value tunnels)"
  assert_eq 0 "$(api_value records)" "the record was deleted before the tunnel failed"
  rm "$API_DIR/fail-tunnel-delete"
  assert_status 0 down
  assert_eq 0 "$(api_value tunnels)"
  assert_no_file "$MARKER"
}

test_a_service_that_will_not_stop_fails_the_down_but_the_files_are_gone() {
  setup_tunnel
  assert_status 0 up
  FAKE_SYSTEMCTL_STOP_FAILS=yes assert_status 1 down
  assert_contains "$CAPTURED_STDERR" "is still running after stop"
  assert_no_file "$CREDENTIALS"
  assert_file_exists "$MARKER"
  assert_status 0 down
}

test_up_for_another_hostname_is_refused_while_a_tunnel_is_recorded() {
  setup_tunnel
  assert_status 0 up
  assert_status 2 up "other.example.test"
  assert_contains "$CAPTURED_STDERR" "already has a tunnel recorded for $HOST_NAME"
  assert_eq 1 "$(api_value tunnels)"
}

test_applied_is_true_only_while_everything_is_there() {
  setup_tunnel
  assert_status 1 bash "$HELPER" applied "$MARKER"
  assert_status 0 up
  assert_status 0 bash "$HELPER" applied "$MARKER"
  rm "$FAKE_SYSTEMD_DIR/sirven-cloudflared.service.active"
  assert_status 1 bash "$HELPER" applied "$MARKER"
}

# make_shims: stand-ins for the commands the helper starts, first on the search path. each logs "clean NAME: variable names" or
# "LEAK NAME: variable names" to shim-log, LEAK when the VALUE of any variable it was started with holds the token (under whatever
# name), then runs the real command. the log never holds a value.
make_shims() {
  local bin="$TEST_TMP/shims" name real
  mkdir -p "$bin"
  : > "$TEST_TMP/shim-log"
  for name in python3 date hostname mv chmod cat tr sed cut head id dirname; do
    real="$(command -v "$name")" || continue
    cat > "$bin/$name" <<SHIM
#!/bin/sh
e="\$(env)"
case "\$e" in *"$SENTINEL_TOKEN"*) leak=LEAK ;; *) leak=clean ;; esac
printf '%s %s: %s\\n' "\$leak" "$name" "\$(printf '%s\\n' "\$e" | /usr/bin/sed 's/=.*//' | /usr/bin/tr '\\n' ' ')" >> "$TEST_TMP/shim-log"
exec "$real" "\$@"
SHIM
    chmod 755 "$bin/$name"
  done
  SHIM_BIN="$bin"
}

assert_no_child_had_the_token() {
  local log
  log="$(cat "$TEST_TMP/shim-log")"
  assert_contains "$log" "python3:" "children were started (else this test proves nothing)"
  assert_contains "$log" "mv:"
  assert_eq 0 "$(printf '%s\n' "$log" | grep -c '^LEAK ' || true)" "children that had the token as the value of a variable (under any name)"
  assert_not_contains "$log" "CLOUDFLARE_API_TOKEN" "the environment of every child"
  assert_not_contains "$(cat "$FAKE_CF_DIR/environment-names.log")" "CLOUDFLARE_API_TOKEN" "cloudflared"
  assert_not_contains "$(cat "$FAKE_SYSTEMD_DIR/environment-names.log")" "CLOUDFLARE_API_TOKEN" "systemctl"
  assert_contains "$(cat "$FAKE_CF_DIR/environment-names.log")" "PATH" "the fake saw an environment (else this proves nothing)"
  assert_no_file "$FAKE_CF_DIR/leaks.log"
  assert_no_file "$FAKE_SYSTEMD_DIR/leaks.log"
}

# the token reaches no process the helper starts: not cloudflared, not systemctl, not the interpreter, not date or hostname
test_no_process_the_helper_starts_has_the_token_in_its_environment() {
  setup_tunnel
  make_shims
  PATH="$SHIM_BIN:$PATH" assert_status 0 up
  PATH="$SHIM_BIN:$PATH" assert_status 0 down
  assert_no_child_had_the_token
}

# a caller that had a variable named TOKEN exported (a shell that did "export TOKEN=...", sudo -E) must not make the helper's own
# variable of that name exported too: the real token, whichever way it was handed over, would then reach every child as TOKEN.
test_an_exported_variable_named_token_does_not_carry_the_token_to_a_child() {
  setup_tunnel
  make_shims
  local file="$TEST_TMP/token-file"
  export TOKEN="a-caller-variable-that-is-not-a-secret" TOKEN_ORIGIN="neither-is-this"
  PATH="$SHIM_BIN:$PATH" assert_status 0 up
  PATH="$SHIM_BIN:$PATH" assert_status 0 down
  assert_no_child_had_the_token
  # the same when the token comes from the token file, and for the other command that reads it
  printf '%s\n' "$SENTINEL_TOKEN" > "$file"
  chmod 600 "$file"
  : > "$TEST_TMP/shim-log"
  TOKEN_FOR_RUN="" PATH="$SHIM_BIN:$PATH" assert_status 0 bash "$HELPER" up --token-file "$file" --marker "$MARKER" --config "$CONFIG" --credentials "$CREDENTIALS" --unit "$UNIT" --service sirven-cloudflared.service --user agent --hostname "$HOST_NAME" --account "$ACCOUNT"
  TOKEN_FOR_RUN="" PATH="$SHIM_BIN:$PATH" assert_status 0 bash "$HELPER" down --marker "$MARKER" --token-file "$file"
  assert_no_child_had_the_token
  unset TOKEN TOKEN_ORIGIN
}

# a shell trace (bash -x, or xtrace in an exported SHELLOPTS) prints every expansion, and a refusal captures standard error into its
# message: the token must not get into what is printed by either route, on a refusal, on the apply and on the teardown
test_a_shell_trace_of_the_helper_does_not_carry_the_token() {
  setup_tunnel
  local wrong="wrongtoken""0123456789abcdefghij" arguments
  arguments=(--marker "$MARKER" --config "$CONFIG" --credentials "$CREDENTIALS" --unit "$UNIT" --service sirven-cloudflared.service --user agent --hostname "$HOST_NAME" --account "$ACCOUNT")
  SIRVEN_CLOUDFLARE_API_TOKEN="$wrong" assert_status 2 bash -x "$HELPER" up "${arguments[@]}"
  assert_contains "$CAPTURED_STDERR" "cannot list tunnels"
  assert_not_contains "$CAPTURED_STDERR" "$wrong" "a refusal made under bash -x"
  SHELLOPTS=xtrace SIRVEN_CLOUDFLARE_API_TOKEN="$wrong" assert_status 2 bash "$HELPER" up "${arguments[@]}"
  assert_contains "$CAPTURED_STDERR" "cannot list tunnels"
  assert_not_contains "$CAPTURED_STDERR" "$wrong" "a refusal made with xtrace in SHELLOPTS"
  SIRVEN_CLOUDFLARE_API_TOKEN="$SENTINEL_TOKEN" assert_status 0 bash -x "$HELPER" up "${arguments[@]}"
  assert_token_nowhere
  SHELLOPTS=xtrace SIRVEN_CLOUDFLARE_API_TOKEN="$SENTINEL_TOKEN" assert_status 0 bash "$HELPER" down --marker "$MARKER"
  assert_token_nowhere
  assert_eq 0 "$(api_value tunnels)" "the teardown did its work"
}

test_the_token_variable_is_used_only_as_a_check_or_as_standard_input_to_the_interpreter() {
  local uses
  # every line of the helper that expands the variable must be a test that it is set, the case that checks its characters, or the
  # builtin printf into the interpreter's standard input: never an argument of any command, never a redirection into a file
  uses="$(python3 -I - "$HELPER" <<'PY'
import re, sys
allowed = (r"""^\s*printf '%s\\n' "\$TOKEN" \| python3 -I "\$API_SCRIPT" "\$@"$""", r"""\[ -[nz] "\$TOKEN" \]""", r"""^\s*case "\$TOKEN" in$""")
for number, line in enumerate(open(sys.argv[1]), 1):
    if '"$TOKEN"' in line and not any(re.search(pattern, line) for pattern in allowed):
        print("%d: %s" % (number, line.rstrip()))
PY
)"
  assert_eq "" "$uses" "a use of the token that is neither a check nor the interpreter's standard input"
}

# the API address of the tests is honored only when it is this machine itself
test_the_test_api_address_is_ignored_unless_it_is_this_machine() {
  local value base
  for value in "http://example.invalid:9" "https://127.0.0.1:9" "http://127.0.0.1.example.invalid:9" "http://user@127.0.0.1:9" "ftp://127.0.0.1:9"; do
    base="$(SIRVEN_CLOUDFLARE_API="$value" python3 -I -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cloudflare_api", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.api_base())' "$REPO_DIR/lib/cloudflare_api.py" 2>/dev/null)"
    assert_eq "https://api.cloudflare.com/client/v4" "$base" "$value must be ignored"
  done
  base="$(SIRVEN_CLOUDFLARE_API="http://127.0.0.1:9" python3 -I -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cloudflare_api", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.api_base())' "$REPO_DIR/lib/cloudflare_api.py")"
  assert_eq "http://127.0.0.1:9" "$base" "an address on this machine is honored"
}

# the Authorization header goes to the one address and to no other: every redirect is refused, so a redirect to a listener of
# someone else never reaches it
test_every_redirect_is_refused_and_the_token_is_not_forwarded() {
  setup_tunnel
  local code catcher_pid waited=0
  cat > "$TEST_TMP/catcher.py" <<'CATCHER'
import os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
directory = sys.argv[1]


class Catcher(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        with open(os.path.join(directory, "catcher.log"), "a") as log:
            log.write("%s %s\n" % (self.path, "with-authorization" if self.headers.get("Authorization") else "without-authorization"))
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")


server = HTTPServer(("127.0.0.1", 0), Catcher)
with open(os.path.join(directory, "catcher-port.new"), "w") as handle:
    handle.write(str(server.server_address[1]))
os.rename(os.path.join(directory, "catcher-port.new"), os.path.join(directory, "catcher-port"))
server.serve_forever()
CATCHER
  python3 -I "$TEST_TMP/catcher.py" "$API_DIR" >/dev/null 2>&1 &
  catcher_pid=$!
  trap 'kill "$API_PID" "$catcher_pid" 2>/dev/null' EXIT
  while [ ! -s "$API_DIR/catcher-port" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -s "$API_DIR/catcher-port" ] || fail "the listener of someone else did not start"
  for code in 301 302 303 307 308; do
    printf '%s http://127.0.0.1:%s/stolen\n' "$code" "$(cat "$API_DIR/catcher-port")" > "$API_DIR/redirect-to"
    # shellcheck disable=SC2016 # the quotes keep the shell of the test from expanding what the inner bash expands
    assert_status 1 bash -c 'printf "%s\n" "$1" | python3 -I "$2" verify "$3"' _ "$SENTINEL_TOKEN" "$REPO_DIR/lib/cloudflare_api.py" "$ACCOUNT"
    assert_contains "$CAPTURED_STDERR" "follows no redirect" "HTTP $code"
    assert_not_contains "$CAPTURED_STDERR" "$SENTINEL_TOKEN"
    assert_not_contains "$CAPTURED_STDERR" "stolen" "where the redirect pointed is not echoed"
  done
  assert_no_file "$API_DIR/catcher.log"
}

test_the_api_helper_takes_the_token_from_standard_input_only() {
  setup_tunnel
  # shellcheck disable=SC2016 # the quotes keep the shell of the test from expanding what the inner bash expands
  assert_status 2 bash -c 'python3 -I "$0" verify "$1" < /dev/null' "$REPO_DIR/lib/cloudflare_api.py" "$ACCOUNT"
  assert_contains "$CAPTURED_STDERR" "no API token on standard input"
  # shellcheck disable=SC2016
  SIRVEN_CLOUDFLARE_API_TOKEN="$SENTINEL_TOKEN" assert_status 2 bash -c 'python3 -I "$0" verify "$1" < /dev/null' "$REPO_DIR/lib/cloudflare_api.py" "$ACCOUNT"
  # shellcheck disable=SC2016
  assert_status 0 bash -c 'printf "%s\n" "$2" | python3 -I "$0" verify "$1"' "$REPO_DIR/lib/cloudflare_api.py" "$ACCOUNT" "$SENTINEL_TOKEN"
}

test_an_api_error_is_printed_with_the_token_blanked() {
  setup_tunnel
  # a fake that echoes the token cannot be made here; the blanking is checked on the function itself
  local out
  out="$(python3 -I -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cloudflare_api", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
client = module.Client(sys.argv[2])
print(client.blank("error with " + sys.argv[2] + " inside"))' "$REPO_DIR/lib/cloudflare_api.py" "$SENTINEL_TOKEN")"
  assert_eq "error with [token hidden] inside" "$out"
}
