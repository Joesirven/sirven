#!/usr/bin/env bash
# SIR-2, SIR-34. the Cloudflare tunnel transport on a real install, with a fake Cloudflare API that keeps state (on this machine's own
# loopback), a fake cloudflared that validates the config, and a stand-in systemctl that keeps unit state in files (the container has no
# systemd). the real API is scenario 66, which needs a test token and a network. apply without a token is refused before the first change;
# apply with a token makes one tunnel, one alias record and one service, root-only credentials, and records them; a second apply needs no
# token and does nothing; revoke (whatever transport it names) and uninstall each take away exactly that and nothing else in the account,
# loudly and repeatably when the token is missing; a half-made tunnel is taken away by uninstall; the token is nowhere on the disk, in
# any output, on any command line, or in the environment of any step that is not the tunnel step.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

FIXTURES="$SRC/tests/fixtures/cloudflare"
export TOKEN="cfapi""SENTINELtoken0123456789_ZZZZ-9876543210abc"
export KEY="$TOKEN"
ACCOUNT=0123456789abcdef0123456789abcdef
ZONE=fedcba9876543210fedcba9876543210
HOST=agent.example.test
export FAKE_CF_DIR=/tmp/fake-cloudflared FAKE_SYSTEMD_DIR=/tmp/fake-systemd
export API_DIR=/tmp/fake-api
UNIT=sirven-cloudflared.service

# the stand-ins live where root looks for tools: /usr/local/bin is searched after the system folders when only root can write it
install -o root -g root -m 755 "$FIXTURES/cloudflared" /usr/local/bin/cloudflared
install -o root -g root -m 755 "$FIXTURES/systemctl" /usr/sbin/systemctl
mkdir -p /run/systemd/system /etc/systemd/system /tmp/fake-api
printf '%s\n' "$TOKEN" > /tmp/fake-api-token
python3 -I "$FIXTURES/api_server.py" "$API_DIR" --token-file /tmp/fake-api-token --account "$ACCOUNT" --zone "$ZONE" --zone-name example.test >/dev/null 2>&1 &
for _ in $(seq 1 50); do [ -s "$API_DIR/port" ] && break; sleep 0.1; done
export SIRVEN_CLOUDFLARE_API="http://127.0.0.1:$(cat "$API_DIR/port")"
# root honors that address only in a test run, which is a root-owned file in /run that this container's own setup makes (an environment
# alone is not enough: root's environment can be inherited from anywhere)
install -o root -g root -m 0600 /dev/null /run/sirven-test-run

# the scenario exports TOKEN and KEY itself, for the checks below. the installer must not be given them by accident, or every child it starts
# would carry the sentinel for a reason that is the scenario's, so each run drops both. CALLER_EXPORTED_TOKEN puts back a variable named TOKEN
# with a value that is NOT a secret: a caller that had exported that name (a shell that did export TOKEN=..., sudo -E). the helper must not
# let its own variable of that name be exported too, or the real token would reach its children as TOKEN.
as_a_caller() { env -u TOKEN -u KEY ${CALLER_EXPORTED_TOKEN:+"TOKEN=$CALLER_EXPORTED_TOKEN"} ${CALLER_SHELLOPTS:+"SHELLOPTS=$CALLER_SHELLOPTS"} "$@"; }
install_cf() { as_a_caller bash ${BASH_TRACE:+-x} install.sh --yes --level "${LEVEL:-observer}" --transport cloudflare --cloudflare-hostname "$HOST" --cloudflare-account "$ACCOUNT" "$@"; }
revoke_cf() { as_a_caller bash ${BASH_TRACE:+-x} install.sh revoke --all --yes "$@"; }
uninstall_cf() { as_a_caller bash ${BASH_TRACE:+-x} uninstall.sh --yes "$@"; }
api_value() { python3 -I -c '
import json, sys
state = json.load(open(sys.argv[1]))
live = [t for t in state["tunnels"].values() if not t.get("deleted_at")]
print({"tunnels": len(live), "records": len(state["records"])}[sys.argv[2]])' "$API_DIR/state.json" "$1"; }
api_state_empty() { [ "$(api_value tunnels)" = 0 ] && [ "$(api_value records)" = 0 ]; }
no_token_on_disk() { local hits; hits="$(grep -rl -F -- "$TOKEN" /etc /var /root /home /usr /opt /srv/pkg 2>/dev/null | grep -v '^/srv/pkg/tests/')"; [ -z "$hits" ] || { printf "the token is in: %s\n" "$hits"; return 1; }; }
cloudflare_files() { world_files | grep -i -e cloudflare -e sirven-cloudflared | grep -v -e '^/usr/local/bin/cloudflared ' -e '^/srv/pkg/' || true; }
export -f api_value api_state_empty no_token_on_disk
reset_machine() { bash uninstall.sh --yes >/dev/null 2>&1; rm -f /var/lib/sirven/agent-revoked-agent.json; rm -rf /var/lib/sirven/package; rm -rf "$FAKE_CF_DIR" "$FAKE_SYSTEMD_DIR"; }

# stand-ins for mkdir, chown and install (the commands the steps before the tunnel run) that record the NAMES of the variables in the
# environment they were started with, and "LEAK" when the VALUE of any variable holds the token (whatever its name), never the value
# itself, then run the real command. for the runs that follow only (a disposable machine).
CHILD_ENV_LOG=/tmp/child-environment-names
shim_children_on() {
  local name
  : > "$CHILD_ENV_LOG"
  for name in mkdir chown install; do
    mv "/usr/bin/$name" "/usr/bin/$name.real"
    sed -e "s|@NAME@|$name|g" -e "s|@LOG@|$CHILD_ENV_LOG|g" > "/usr/bin/$name" <<'SHIM'
#!/bin/sh
e="$(env)"
case "$e" in *"$(cat /tmp/fake-api-token)"*) leak=LEAK ;; *) leak=clean ;; esac
printf '%s @NAME@: %s\n' "$leak" "$(printf '%s\n' "$e" | /usr/bin/sed 's/=.*//' | /usr/bin/tr '\n' ' ')" >> @LOG@
exec /usr/bin/@NAME@.real "$@"
SHIM
    chmod 755 "/usr/bin/$name"
  done
}
shim_children_off() {
  local name
  for name in mkdir chown install; do mv -f "/usr/bin/$name.real" "/usr/bin/$name"; done
}

world_files > /tmp/empty.files
world_accounts > /tmp/empty.accounts
check "before anything, the machine has no file of cloudflare's or of the unit but the stand-in tool" bash -c '[ -z "$(cloudflare_files)" ]'

# 1. no token: refused up front, nothing changed
check_exit "apply without a token is refused" 2 install_cf
check "the refusal says there is no token, names the token file and the environment, and that nothing was changed" bash -c 'grep -q "there is no Cloudflare API token" <<< "$0" && grep -q "/etc/sirven/cloudflare-api-token" <<< "$0" && grep -q "SIRVEN_CLOUDFLARE_API_TOKEN" <<< "$0" && grep -q "nothing was changed" <<< "$0"' "$LAST_OUTPUT"
world_unchanged_if 'true' "and it changed nothing: files" files /tmp/empty.files
world_unchanged_if 'true' "and it changed nothing: accounts" accounts /tmp/empty.accounts
check "the API was never called" bash -c '[ ! -e /tmp/fake-api/calls.log ]'
check_exit "apply without a hostname is refused" 2 bash install.sh --yes --level observer --transport cloudflare --cloudflare-account "$ACCOUNT"
check "it says so, and nothing was changed" bash -c 'grep -q "no hostname is named" <<< "$0" && grep -q "nothing was changed" <<< "$0"' "$LAST_OUTPUT"

# 1b. a token file others can read, with an access entry for another account, or with a second name: each refused before the first change
TOKEN_FILE=/etc/sirven/cloudflare-api-token
mkdir -p /etc/sirven
printf '%s\n' "$TOKEN" > "$TOKEN_FILE"; chown root:root "$TOKEN_FILE"; chmod 644 "$TOKEN_FILE"
check_exit "apply with a token file that everyone can read is refused" 2 install_cf
check "the refusal names the mode, and the token is not in it" bash -c 'grep -q "its mode is" <<< "$0" && grep -q "nothing was changed" <<< "$0" && ! grep -qF -- "$KEY" <<< "$0"' "$LAST_OUTPUT"
chmod 600 "$TOKEN_FILE"; setfacl -m u:nobody:r "$TOKEN_FILE"; setfacl -m m::--- "$TOKEN_FILE"
check_exit "apply with a root-owned 0600 token file that has an entry for another account (mask hiding it) is refused" 2 install_cf
check "it names the access control list" bash -c 'grep -q "extended access control list" <<< "$0"' "$LAST_OUTPUT"
setfacl -b "$TOKEN_FILE"
mkdir -p /var/other-name && ln "$TOKEN_FILE" /var/other-name/copy
check_exit "apply with a token file that has a second name is refused" 2 install_cf
check "it names the second name" bash -c 'grep -q "more than one name" <<< "$0"' "$LAST_OUTPUT"
rm -rf /var/other-name /etc/sirven
world_unchanged_if 'true' "none of the refusals changed anything: files" files /tmp/empty.files
world_unchanged_if 'true' "none of the refusals changed anything: accounts" accounts /tmp/empty.accounts

# 1c. a wrong token is turned away by the API before the first change, and is not in the output
WRONG="wrongtoken0123456789wrongtoken0123456789"
SIRVEN_CLOUDFLARE_API_TOKEN="$WRONG" check_exit "apply with a wrong token is refused" 2 install_cf
check "it says the token cannot list tunnels, and does not print it" bash -c 'grep -q "cannot list tunnels" <<< "$0" && grep -q "nothing was changed" <<< "$0" && ! grep -qF -- wrongtoken0123456789 <<< "$0"' "$LAST_OUTPUT"
world_unchanged_if 'true' "and it changed nothing" files /tmp/empty.files
check "the plan was printed first, and the API was asked only after it (the refusal comes below the plan)" bash -c '[ "$(grep -n "transport: cloudflare tunnel" <<< "$0" | head -n 1 | cut -d: -f1)" -lt "$(grep -n "cannot list tunnels" <<< "$0" | head -n 1 | cut -d: -f1)" ]' "$LAST_OUTPUT"
check "and the refusal left no entry in the audit log" bash -c '! grep -q cloudflare /var/log/sirven/audit.jsonl 2>/dev/null'

# 1e. nothing goes to the API until the plan is confirmed: a good token and no yes (and no terminal here) is "not applied" (exit 3), and the
# fake API was sent nothing at all
calls_before_no_yes="$(wc -l < /tmp/fake-api/calls.log 2>/dev/null || echo 0)"
no_yes_install() { as_a_caller bash install.sh --level observer --transport cloudflare --cloudflare-hostname "$HOST" --cloudflare-account "$ACCOUNT" < /dev/null; }
SIRVEN_YES=0 SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" check_exit "a valid token without a yes is not applied" 3 no_yes_install
check "it printed the plan, said it was not applied, and sent the API nothing" bash -c 'grep -q "transport: cloudflare tunnel" <<< "$0" && grep -q "not applied" <<< "$0" && [ "$(wc -l < /tmp/fake-api/calls.log)" = "$1" ]' "$LAST_OUTPUT" "$calls_before_no_yes"
world_unchanged_if 'true' "and it changed nothing" files /tmp/empty.files

# 1d. a hostname that already has a record of someone else is never touched, and nothing is made
python3 -I - "$SIRVEN_CLOUDFLARE_API" "$TOKEN" "$ZONE" <<'PY'
import json, sys, urllib.request
base, token, zone = sys.argv[1:4]
request = urllib.request.Request(base + "/zones/%s/dns_records" % zone, data=json.dumps({"type": "A", "name": "agent.example.test", "content": "192.0.2.1"}).encode(), method="POST")
request.add_header("Authorization", "Bearer " + token)
urllib.request.urlopen(request)
PY
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" check_exit "apply onto a hostname that has a record of someone else is refused" 2 install_cf
check "it says whose record it is, and nothing was changed" bash -c 'grep -q "did not make" <<< "$0" && grep -q "nothing was changed" <<< "$0"' "$LAST_OUTPUT"
check "no tunnel was made, and the record of someone else is untouched" bash -c '[ "$(python3 -I -c "
import json
s = json.load(open(\"/tmp/fake-api/state.json\"))
print(len(s[\"tunnels\"]), len(s[\"records\"]))")" = "0 1" ]'
python3 -I -c '
import json
p = "/tmp/fake-api/state.json"
s = json.load(open(p)); s["records"] = {}; json.dump(s, open(p, "w"))'

# 2. with a token: one tunnel, one alias record, one service, recorded. the steps before and after the tunnel step start children, and
# none of them is given the token
mkdir -p /etc/sirven
printf '%s\n' "$TOKEN" > "$TOKEN_FILE"; chown root:root "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
calls_at_start="$(wc -l < /tmp/fake-api/calls.log)"
mv /usr/bin/rm /usr/bin/rm.real
cat > /usr/bin/rm <<'SHIM'
#!/bin/sh
case "$*" in
  *cloudflare-api-token*)
    e="$(env)"
    printf '%s\n' "$e" | /usr/bin/sed "s/=.*//" > /tmp/rm-environment-names
    case "$e" in *"$(cat /tmp/fake-api-token)"*) : > /tmp/rm-leak ;; esac ;;
esac
exec /usr/bin/rm.real "$@"
SHIM
chmod 755 /usr/bin/rm
shim_children_on
# the caller here has a variable named TOKEN exported (not a secret), and the fakes look at the VALUE of every variable they get
FAKE_LEAK_CHECK_FILE=/tmp/fake-api-token CALLER_EXPORTED_TOKEN="a-caller-variable-that-is-not-a-secret" FAKE_CF_PS_LOG=/tmp/ps-during-apply SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" check_exit "apply with a token makes the tunnel" 0 install_cf
out="$LAST_OUTPUT"
mv -f /usr/bin/rm.real /usr/bin/rm
shim_children_off
check "steps before the tunnel did start children (so the next check proves something)" bash -c '[ "$(grep -c " mkdir:" "$0")" -gt 0 ] && [ "$(grep -c " chown:" "$0")" -gt 0 ]' "$CHILD_ENV_LOG"
check "and none of them was started with the token variable in its environment" bash -c '! grep -q "CLOUDFLARE_API_TOKEN" "$0"' "$CHILD_ENV_LOG"
check "and none had the token as the value of any variable, under any name (they looked at the values)" bash -c 'grep -q "^clean mkdir:" "$0" && ! grep -q "^LEAK " "$0"' "$CHILD_ENV_LOG"
check "the step after the tunnel started its child without the token variable in the environment" bash -c '[ -s /tmp/rm-environment-names ] && ! grep -q "CLOUDFLARE_API_TOKEN" /tmp/rm-environment-names && [ ! -e /tmp/rm-leak ]'
check "the tunnel step's own children (cloudflared, systemctl) had the token in no variable of any name, though the caller exported one named TOKEN" bash -c '[ -s /tmp/fake-cloudflared/calls.log ] && [ -s /tmp/fake-systemd/calls.log ] && [ ! -e /tmp/fake-cloudflared/leaks.log ] && [ ! -e /tmp/fake-systemd/leaks.log ]'
check "the saved token file was removed by that step" bash -c '[ ! -e "$0" ]' "$TOKEN_FILE"
check "one tunnel and one alias record in the account" bash -c '[ "$(api_value tunnels)" = 1 ] && [ "$(api_value records)" = 1 ]'
check "the alias record points at the tunnel" bash -c 'python3 -I -c "
import json
s = json.load(open(\"/tmp/fake-api/state.json\"))
t = [t for t in s[\"tunnels\"].values() if not t.get(\"deleted_at\")][0]
r = list(s[\"records\"].values())[0]
assert r[\"content\"] == t[\"id\"] + \".cfargotunnel.com\" and r[\"name\"] == \"agent.example.test\" and t[\"config_src\"] == \"local\""'
check "the credentials, the record and the config are root-only" bash -c '[ "$(stat -c %a:%U /etc/sirven/cloudflared-credentials.json)" = 600:root ] && [ "$(stat -c %a:%U /var/lib/sirven/cloudflare-tunnel.json)" = 600:root ] && [ "$(stat -c %a:%U /etc/sirven/cloudflared.yml)" = 600:root ]'
check "the config routes the one hostname to ssh and everything else to 404" bash -c 'tail -n 4 /etc/sirven/cloudflared.yml | tr "\n" "|" | grep -qF "ingress:|  - hostname: agent.example.test|    service: ssh://localhost:22|  - service: http_status:404|"'
check "the service runs as root with a name of its own, and cloudflared was asked to validate the config" bash -c 'grep -q "^ExecStart=/usr/local/bin/cloudflared --no-autoupdate --config /etc/sirven/cloudflared.yml tunnel run" /etc/systemd/system/sirven-cloudflared.service && ! grep -q "^User=" /etc/systemd/system/sirven-cloudflared.service && [ -e /tmp/fake-systemd/sirven-cloudflared.service.active ] && grep -q "ingress validate" /tmp/fake-cloudflared/calls.log'
check "nothing of the owner's own cloudflared was written or run" bash -c '[ ! -e /etc/cloudflared ] && ! grep -q -e "service install" -e "tunnel login" -e "route dns" /tmp/fake-cloudflared/calls.log /tmp/fake-systemd/calls.log'
check "the install record can undo it" grep -q 'cloudflare_tunnel.sh down --marker /var/lib/sirven/cloudflare-tunnel.json' /var/lib/sirven/install-record.tsv
check "the token is nowhere on the disk" no_token_on_disk
check "the token is in no output" bash -c '! grep -qF -- "$TOKEN" <<< "$0"' "$out"
check "the audit log and the install record have no token" bash -c '! grep -qF -- "$TOKEN" /var/log/sirven/audit.jsonl /var/lib/sirven/install-record.tsv'
check "the token was on no command line while cloudflared ran" bash -c '[ -s /tmp/ps-during-apply ] && ! grep -qF -- "$TOKEN" /tmp/ps-during-apply'
check "no step but the tunnel step was started with the token variable (the fake cloudflared and systemctl saw none)" bash -c '! grep -q CLOUDFLARE_API_TOKEN /tmp/fake-cloudflared/environment-names.log /tmp/fake-systemd/environment-names.log'
check "every call this apply made to the API carried the token in the Authorization header" bash -c 'tail -n +$(($0 + 1)) /tmp/fake-api/calls.log | grep -c authorized | grep -qv "^0$" && ! tail -n +$(($0 + 1)) /tmp/fake-api/calls.log | grep -q unauthorized' "$calls_at_start"

# 3. again: nothing more happens, no error, and no token is needed
world_files > /tmp/one.files
calls_before="$(wc -l < /tmp/fake-api/calls.log)"
check_exit "a second apply without any token exits 0" 0 install_cf
check "it made no tunnel and called no API" bash -c '[ "$(wc -l < /tmp/fake-api/calls.log)" = "$0" ] && [ "$(api_value tunnels)" = 1 ]' "$calls_before"
world_unchanged_if 'true' "and it changed no file" files /tmp/one.files
shim_children_on
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" check_exit "a second apply with a token in the environment (no tunnel is made) exits 0" 0 install_cf
shim_children_off
check "the steps that ran started children, and none had the token variable or its value" bash -c '[ -s "$0" ] && ! grep -q CLOUDFLARE_API_TOKEN "$0" && ! grep -q "^LEAK " "$0"' "$CHILD_ENV_LOG"

# 4. revoke that names no transport at all (so the default one) takes the tunnel away, because the record says there is one
shim_children_on
FAKE_LEAK_CHECK_FILE=/tmp/fake-api-token CALLER_EXPORTED_TOKEN="a-caller-variable-that-is-not-a-secret" SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" check_exit "revoke --all applies" 0 revoke_cf
shim_children_off
check "the plan showed the teardown and the audit log recorded the step" bash -c 'grep -q "take this machine.s Cloudflare tunnel away" <<< "$0" && grep -q "take this machine.s Cloudflare tunnel away" /var/log/sirven/audit.jsonl' "$LAST_OUTPUT"
check "the account has no tunnel and no record of ours any more" api_state_empty
check "the service is stopped and disabled, and the files are gone" bash -c '[ ! -e /tmp/fake-systemd/sirven-cloudflared.service.active ] && [ ! -e /tmp/fake-systemd/sirven-cloudflared.service.enabled ] && [ ! -e /etc/systemd/system/sirven-cloudflared.service ] && [ ! -e /etc/sirven/cloudflared.yml ] && [ ! -e /etc/sirven/cloudflared-credentials.json ] && [ ! -e /var/lib/sirven/cloudflare-tunnel.json ]'
check "no child of the revoke had the token variable or its value, and the token is nowhere" bash -c '! grep -q CLOUDFLARE_API_TOKEN "$0" && ! grep -q "^LEAK " "$0" && [ ! -e /tmp/fake-cloudflared/leaks.log ] && [ ! -e /tmp/fake-systemd/leaks.log ]' "$CHILD_ENV_LOG"
check "the token is in no output of the revoke" bash -c '! grep -qF -- "$TOKEN" <<< "$0"' "$LAST_OUTPUT"
deletes_before="$(grep -c '^DELETE ' /tmp/fake-api/calls.log)"
check_exit "a second revoke exits 0" 0 revoke_cf
check "and deleted nothing more" bash -c '[ "$(grep -c "^DELETE " /tmp/fake-api/calls.log)" = "$0" ]' "$deletes_before"

# 5. revoke WITHOUT the token: the machine is cut off, the account is not touched, it says exactly what is left, and the same command with the
# token finishes it
reset_machine
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" install_cf --reinstate >/dev/null 2>&1
check "setup: the tunnel is made again" bash -c '[ "$(api_value tunnels)" = 1 ]'
tunnel_number="$(python3 -I -c 'import json; print([t for t in json.load(open("/tmp/fake-api/state.json"))["tunnels"].values() if not t.get("deleted_at")][0]["id"])')"
check_exit "revoke --all without a token exits 4" 4 revoke_cf
check "it says access is already cut and only the inert tunnel object and the alias record remain" bash -c 'grep -q "access is already cut" <<< "$0" && grep -q "only the inert tunnel object and the alias record" <<< "$0"' "$LAST_OUTPUT"
check "it names the tunnel and the record that are still in the account, and how to finish" bash -c 'grep -q "there is no Cloudflare API token" <<< "$0" && grep -qF -- "$1" <<< "$0" && grep -q "run the same command again with the token" <<< "$0"' "$LAST_OUTPUT" "$tunnel_number"
check "the service and the credentials are gone, the agent is locked out, and the record stays" bash -c '[ ! -e /etc/sirven/cloudflared-credentials.json ] && [ ! -e /etc/systemd/system/sirven-cloudflared.service ] && [ ! -e /tmp/fake-systemd/sirven-cloudflared.service.active ] && [ -s /var/lib/sirven/cloudflare-tunnel.json ] && passwd --status agent | grep -q "^agent L"'
check "the account still has the tunnel and the record (not touched)" bash -c '[ "$(api_value tunnels)" = 1 ] && [ "$(api_value records)" = 1 ]'
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" check_exit "the same revoke with the token exits 0" 0 revoke_cf
check "and finished the job" bash -c '[ ! -e /var/lib/sirven/cloudflare-tunnel.json ] && api_state_empty'

# 5b. the token in the token file works for the teardown too
reset_machine
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" install_cf --reinstate >/dev/null 2>&1
printf '%s\n' "$TOKEN" > "$TOKEN_FILE"; chown root:root "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
check_exit "revoke --all with the token in the token file exits 0" 0 revoke_cf
check "and the tunnel is gone from the account" api_state_empty
check "the revoke removed the token file it was given" bash -c '[ ! -e "$0" ]' "$TOKEN_FILE"

# 6. what the owner changed in the account is left alone: a record that now points elsewhere, a tunnel that was renamed
reset_machine
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" install_cf --reinstate >/dev/null 2>&1
python3 -I -c '
import json
p = "/tmp/fake-api/state.json"
s = json.load(open(p))
for r in s["records"].values(): r["content"] = "someone-elses-tunnel.cfargotunnel.com"
json.dump(s, open(p, "w"))'
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" check_exit "revoke with a record the owner repointed exits 0" 0 revoke_cf
check "it left the repointed record alone and deleted our tunnel" bash -c 'grep -q "no longer points at this tunnel" <<< "$0" && [ "$(api_value records)" = 1 ] && [ "$(api_value tunnels)" = 0 ]' "$LAST_OUTPUT"
python3 -I -c '
import json
p = "/tmp/fake-api/state.json"
s = json.load(open(p)); s["records"] = {}; json.dump(s, open(p, "w"))'
reset_machine
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" install_cf --reinstate >/dev/null 2>&1
python3 -I -c '
import json
p = "/tmp/fake-api/state.json"
s = json.load(open(p))
for t in s["tunnels"].values():
    if not t.get("deleted_at"): t["name"] = "owners-own-tunnel"
json.dump(s, open(p, "w"))'
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" check_exit "revoke with a tunnel the owner renamed exits 0" 0 revoke_cf
check "it left the renamed tunnel alone" bash -c 'grep -q "is now named owners-own-tunnel" <<< "$0" && [ "$(api_value tunnels)" = 1 ]' "$LAST_OUTPUT"
python3 -I -c '
import json
p = "/tmp/fake-api/state.json"
s = json.load(open(p))
for t in s["tunnels"].values(): t["deleted_at"] = "2026-01-01T00:00:00Z"
json.dump(s, open(p, "w"))'

# 7. uninstall alone takes away exactly what apply made, and the machine has nothing of cloudflare's left but the stand-in tool
reset_machine
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" install_cf >/dev/null 2>&1
check "setup: the tunnel is made" bash -c '[ "$(api_value tunnels)" = 1 ]'
FAKE_LEAK_CHECK_FILE=/tmp/fake-api-token CALLER_EXPORTED_TOKEN="a-caller-variable-that-is-not-a-secret" SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" check_exit "uninstall takes the tunnel away" 0 uninstall_cf
out="$LAST_OUTPUT"
check "the children of the uninstall (cloudflared, systemctl) had the token in no variable of any name, though the caller exported one named TOKEN" bash -c '[ -s /tmp/fake-systemd/calls.log ] && [ ! -e /tmp/fake-cloudflared/leaks.log ] && [ ! -e /tmp/fake-systemd/leaks.log ]'
check "the account has nothing of ours" api_state_empty
check "this machine has no file of cloudflare's or of the unit left, but the stand-in tool" bash -c '[ -z "$(cloudflare_files)" ]'
check "the token is in no output of the uninstall" bash -c '! grep -qF -- "$TOKEN" <<< "$0"' "$out"
check "and nowhere on the disk" no_token_on_disk

# 8. a tunnel made and then not finished (the alias record refused): the install step fails, the install record has no line for it,
# and uninstall still takes the half-made tunnel away, because the record file of the tunnel step names it
reset_machine
: > /tmp/fake-api/refuse-records
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" check_exit "apply when the alias record is refused fails (exit 4)" 4 install_cf
check "it says which step failed and why" bash -c 'grep -q "could not point agent.example.test at the tunnel" <<< "$0"' "$LAST_OUTPUT"
check "the tunnel exists in the account and the record file names it" bash -c '[ "$(api_value tunnels)" = 1 ] && grep -q tunnel_id /var/lib/sirven/cloudflare-tunnel.json'
check "the install record has no line for the failed step" bash -c '! grep -q cloudflare_tunnel.sh /var/lib/sirven/install-record.tsv'
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" check_exit "uninstall takes the half-made tunnel away" 0 uninstall_cf
check "it says it is the one a run left behind" bash -c 'grep -q "a run left behind" <<< "$0"' "$LAST_OUTPUT"
check "the account has nothing of ours, and the record file is gone" bash -c 'api_state_empty && [ ! -e /var/lib/sirven/cloudflare-tunnel.json ]'
rm -f /tmp/fake-api/refuse-records
# the same, finished by a second apply instead: the tunnel is reused
reset_machine
: > /tmp/fake-api/refuse-records
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" install_cf >/dev/null 2>&1
first_tunnel="$(python3 -I -c 'import json; print([t for t in json.load(open("/tmp/fake-api/state.json"))["tunnels"].values() if not t.get("deleted_at")][0]["id"])')"
rm -f /tmp/fake-api/refuse-records
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" check_exit "a second apply finishes the half-made tunnel" 0 install_cf
check "with the same tunnel, one record, and the service running" bash -c '[ "$(api_value tunnels)" = 1 ] && [ "$(api_value records)" = 1 ] && grep -q "$0" /var/lib/sirven/cloudflare-tunnel.json && [ -e /tmp/fake-systemd/sirven-cloudflared.service.active ]' "$first_tunnel"
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" uninstall_cf >/dev/null 2>&1

# 9. the routing is the same for every level
for level in observer builder operator; do
  reset_machine
  LEVEL="$level" SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" install_cf >/dev/null 2>&1
  sed '1d' /etc/sirven/cloudflared.yml | sed "s|^credentials-file:.*||" > "/tmp/config-$level"
  SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" uninstall_cf >/dev/null 2>&1
done
check "the config is the same text for observer, builder and operator (but for the tunnel number)" bash -c 'cmp -s /tmp/config-observer /tmp/config-builder && cmp -s /tmp/config-observer /tmp/config-operator && grep -q "service: ssh://localhost:22" /tmp/config-observer && [ "$(grep -c "service:" /tmp/config-observer)" = 2 ]'

# 10. an address that is not this machine is never used for the API, as root either, even when the environment names one; and an
# address that is this machine is used only in a test run (the marker file), never on an environment alone
api_base_with() {
  env SIRVEN_CLOUDFLARE_API="$1" python3 -I -c '
import importlib.util
spec = importlib.util.spec_from_file_location("api", "/srv/pkg/lib/cloudflare_api.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.api_base())' 2>/dev/null
}
export -f api_base_with
REAL_API="https://api.cloudflare.com/client/v4"
check "a non-loopback API address in the environment is ignored" bash -c '[ "$(api_base_with http://example.invalid:9)" = "$0" ]' "$REAL_API"
check "with the marker file, as root, the address of this machine is used" bash -c '[ "$(api_base_with http://127.0.0.1:9)" = http://127.0.0.1:9 ]'
rm -f /run/sirven-test-run
check "without the marker file, as root, the address of this machine is ignored (the environment alone is not a test run)" bash -c '[ "$(api_base_with http://127.0.0.1:9)" = "$0" ]' "$REAL_API"
install -o nobody -g nogroup -m 0600 /dev/null /run/sirven-test-run
check "a marker file owned by someone else is not a test run" bash -c '[ "$(api_base_with http://127.0.0.1:9)" = "$0" ]' "$REAL_API"
rm -f /run/sirven-test-run; install -o root -g root -m 0666 /dev/null /run/sirven-test-run
check "a marker file anyone can write is not a test run" bash -c '[ "$(api_base_with http://127.0.0.1:9)" = "$0" ]' "$REAL_API"
rm -f /run/sirven-test-run; ln -s /etc/hostname /run/sirven-test-run
check "a link in place of the marker file is not a test run" bash -c '[ "$(api_base_with http://127.0.0.1:9)" = "$0" ]' "$REAL_API"
rm -f /run/sirven-test-run
reset_machine
calls_before="$(wc -l < /tmp/fake-api/calls.log)"
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" check_exit "a real apply as root without the marker file goes to the real address, which this container cannot reach, and is refused" 2 install_cf
check "it says it could not reach the Cloudflare API, and the fake API was sent nothing" bash -c 'grep -q "could not reach the Cloudflare API" <<< "$0" && grep -q "nothing was changed" <<< "$0" && [ "$(wc -l < /tmp/fake-api/calls.log)" = "$1" ]' "$LAST_OUTPUT" "$calls_before"
install -o root -g root -m 0600 /dev/null /run/sirven-test-run

save_trace() { printf '%s\n' "$LAST_OUTPUT" > /tmp/trace-output; printf '/tmp/trace-output'; }
# 11. a shell trace (bash -x) prints every expansion, and a refusal captures standard error into its message: the token must be in none of
# it, on a refusal, on a full apply, on the revoke and on the uninstall, all traced (the trace is on: the output is long and has the steps)
reset_machine
BASH_TRACE=1 SIRVEN_CLOUDFLARE_API_TOKEN="$WRONG" check_exit "a traced apply with a wrong token is refused" 2 install_cf
check "the traced refusal says why, and the trace is there" bash -c 'grep -q "cannot list tunnels" < "$0" && grep -q "cloudflare_hold_token" < "$0" && ! grep -qF -- wrongtoken0123456789 < "$0"' "$(save_trace)"
BASH_TRACE=1 SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" check_exit "a traced apply with the token makes the tunnel" 0 install_cf
check "the trace of the apply is long (it traced the steps), and the token is not in it" bash -c '[ "$(wc -l < "$0")" -gt 200 ] && grep -q "make the tunnel, point the hostname" < "$0" && ! grep -qF -- "$TOKEN" < "$0"' "$(save_trace)"
check "and the tunnel was made" bash -c '[ "$(api_value tunnels)" = 1 ]'
BASH_TRACE=1 SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" check_exit "a traced revoke takes the tunnel away" 0 revoke_cf
check "the token is not in the trace of the revoke, and the account is empty" bash -c '! grep -qF -- "$TOKEN" < "$0" && api_state_empty' "$(save_trace)"
reset_machine
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" install_cf --reinstate >/dev/null 2>&1
BASH_TRACE=1 SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" check_exit "a traced uninstall takes the tunnel away" 0 uninstall_cf
check "the token is not in the trace of the uninstall, and the account is empty" bash -c '! grep -qF -- "$TOKEN" < "$0" && api_state_empty' "$(save_trace)"
# (xtrace in an exported SHELLOPTS is covered by the unit tests: it also traces the installer's own SSH probe, which a real apply here
# cannot get past, and that is not what is under test)

# 12. the record is lost or edited: the machine is still cut off, by sirven's own fixed names, and nothing else is touched
api_clear() { python3 -I -c '
import json
p = "/tmp/fake-api/state.json"
s = json.load(open(p)); s["records"] = {}
for t in s["tunnels"].values(): t["deleted_at"] = "2026-01-01T00:00:00Z"
json.dump(s, open(p, "w"))'; }
local_pieces_gone() { [ ! -e /etc/systemd/system/sirven-cloudflared.service ] && [ ! -e /etc/sirven/cloudflared.yml ] && [ ! -e /etc/sirven/cloudflared-credentials.json ] && [ ! -e /tmp/fake-systemd/sirven-cloudflared.service.active ] && [ ! -e /tmp/fake-systemd/sirven-cloudflared.service.enabled ]; }
export -f api_clear local_pieces_gone
reset_machine
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" install_cf --reinstate >/dev/null 2>&1
check "setup: the tunnel is made and its service runs" bash -c '[ "$(api_value tunnels)" = 1 ] && [ -e /tmp/fake-systemd/sirven-cloudflared.service.active ]'
rm -f /var/lib/sirven/cloudflare-tunnel.json
check_exit "revoke --all with the record lost, and no token, exits 0" 0 revoke_cf
check "the service is stopped and the unit, config and credentials are gone, though there is no record" local_pieces_gone
check "it says there is no record, and the account was not touched" bash -c 'grep -q "there is no record of a tunnel made here" <<< "$0" && [ "$(api_value tunnels)" = 1 ] && [ "$(api_value records)" = 1 ]' "$LAST_OUTPUT"
api_clear
reset_machine
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" install_cf --reinstate >/dev/null 2>&1
rm -f /var/lib/sirven/cloudflare-tunnel.json
check_exit "uninstall with the record lost exits 0" 0 uninstall_cf
check "and this machine has no piece of the tunnel left" bash -c 'local_pieces_gone && [ -z "$(cloudflare_files)" ]'
api_clear
# a record edited by hand to name a file and a service that are not sirven's
reset_machine
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" install_cf --reinstate >/dev/null 2>&1
printf 'precious\n' > /root/victim-unit; printf 'precious\n' > /root/victim-config; printf 'precious\n' > /root/victim-credentials
: > /tmp/fake-systemd/cloudflared.service.active; : > /tmp/fake-systemd/cloudflared.service.enabled
python3 -I /srv/pkg/lib/cloudflare_api.py marker-set /var/lib/sirven/cloudflare-tunnel.json unit=/root/victim-unit config=/root/victim-config credentials=/root/victim-credentials service=cloudflared.service >/dev/null
SIRVEN_CLOUDFLARE_API_TOKEN="$TOKEN" check_exit "revoke --all with an edited record exits 0" 0 revoke_cf
check "sirven's own pieces are gone" local_pieces_gone
check "the files the record named are untouched, and so is the other service" bash -c '[ "$(cat /root/victim-unit)" = precious ] && [ "$(cat /root/victim-config)" = precious ] && [ "$(cat /root/victim-credentials)" = precious ] && [ -e /tmp/fake-systemd/cloudflared.service.active ] && [ -e /tmp/fake-systemd/cloudflared.service.enabled ] && ! grep -q "stop cloudflared.service\|disable cloudflared.service" /tmp/fake-systemd/calls.log'
check "it said what it left alone" bash -c 'grep -q "is left alone" <<< "$0"' "$LAST_OUTPUT"
check "the tunnel and the alias record of the account, which the record names by number, are taken away" api_state_empty
rm -f /root/victim-unit /root/victim-config /root/victim-credentials /tmp/fake-systemd/cloudflared.service.active /tmp/fake-systemd/cloudflared.service.enabled

# nothing of the stand-ins or the scenario's own state is left in a place the next scenario would see: the container is thrown away
finish
