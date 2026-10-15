#!/usr/bin/env bash
# tailscale_node.sh: join this machine to a tailnet as the tagged agent node, and log it out again.
# called by the installer's plan (join), by the kill switch and by the install record's undo line (leave),
# from the pinned copy of this package (see lib/tailscale.sh). one file, because the install record stores
# command text and uninstall.sh does not read lib/tailscale.sh.
#
#   tailscale_node.sh join  MARKER USER KEY_FILE
#   tailscale_node.sh leave MARKER
#   tailscale_node.sh check USER KEY_FILE      every refusal the join can make, without any change (the installer's first look)
#   tailscale_node.sh key-file-check KEY_FILE  exit 0 a usable key file, 1 none there, 2 there but not safe (says why)
#
# join: names the node USER-<short host name> (SIRVEN_TAILSCALE_HOSTNAME replaces the host name part),
# runs 'tailscale up' with the auth key and the tag, then writes MARKER, a root-only file that says
# this run joined and which node it is (node id, host name, tag; never the key). leave: logs out only the node
# MARKER names, and only when this machine's login is still that node with the tag. a login sirven did not
# make is never logged out, and no other node of the tailnet is touched: logout acts on this machine only.
#
# the auth key comes from the environment, SIRVEN_TAILSCALE_AUTHKEY or TAILSCALE_AUTHKEY, or else from
# KEY_FILE, which must be a plain file owned by root (whoever runs this, when not root) that no other account can read or
# write: mode 0600 and no extended access control list (an access entry for another account, which the mode bits can hide). it is never put on a command line: tailscale reads it from a private temporary file. whatever
# tailscale prints is shown with the key blanked out.
#
# the tailscale command is found on the search path. SIRVEN_TAILSCALE names another one for the tests (not honored as root).
# exit status: 0 done (or nothing to do), 1 failed, 2 refused before any change.

set -uo pipefail

TAILSCALE_NODE_TAG="tag:agent"
TAILSCALE_NODE_WAIT="${SIRVEN_TAILSCALE_WAIT:-60}"
PRIVATE_KEY_FILE=""

refuse() {
  printf 'error: refused: %s nothing was changed.\n' "$1" >&2
  exit 2
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

# has_extended_access_list FILE: true when FILE carries an access control list beyond the plain owner, group and other bits, which
# is a way to give another account access that the mode bits do not show. looked for on purpose, in every way the machine offers,
# and never worked out from the mode: on Linux the group bits of such a file show the mask, which can read '---' while a named
# entry sits behind it, and a later chmod g+r would let the entry through.
#   - the '+' that ls prints after the mode (Linux), whether or not getfacl is installed;
#   - any named user or group entry, a mask or a default entry in what getfacl prints (Linux);
#   - the entries ls -e lists under the file (macOS, where ls prints '@' instead of '+' when the file has extended attributes too).
has_extended_access_list() {
  local file="$1" listing entries
  listing="$(ls -ldn "$file" 2>/dev/null)" || return 0
  [ "$(printf '%s' "$listing" | cut -c11)" != "+" ] || return 0
  # each listing is read into a variable first: under pipefail, grep -q ending early would otherwise make the pipeline fail
  if command -v getfacl >/dev/null 2>&1; then
    entries="$(getfacl -p -c -- "$file" 2>/dev/null)" || true
    ! printf '%s\n' "$entries" | grep -Eq '^(default:|mask:|(user|group):[^:])' || return 0
  fi
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    # shellcheck disable=SC2012 # only ls -e prints the access entries of a file on macOS; find cannot
    entries="$(ls -ldne "$file" 2>/dev/null | tail -n +2)" || true
    ! printf '%s\n' "$entries" | grep -Eq '^ *[0-9]+: ' || return 0
  fi
  return 1
}

# key_file_problem FILE: why FILE may not be read as the auth key, or nothing when it may (or is not there at all).
# a key file must be a plain file (not a link), owned by root (by whoever runs this, when that is not root, which only the tests do),
# with no extended access list and no permission for the group or for anyone else: a file others can write picks the tailnet this
# machine joins, and a file others can read leaks the key.
key_file_problem() {
  local file="$1" listing mode owner
  [ -e "$file" ] || [ -L "$file" ] || return 0
  listing="$(ls -ldn "$file" 2>/dev/null)" || { printf 'it cannot be examined'; return 0; }
  mode="$(printf '%s' "$listing" | cut -c1-10)"
  owner="$(printf '%s' "$listing" | awk '{print $3}')"
  case "$mode" in
    -*) ;;
    *) printf 'it is not a plain file (a link or a folder is not used)'; return 0 ;;
  esac
  if [ "$owner" != "$(id -u)" ]; then
    printf 'it is owned by account number %s, not by root' "$owner"
    return 0
  fi
  if has_extended_access_list "$file"; then
    printf 'it has an extended access control list, an access entry beyond the owner, group and other bits (the mode bits do not show who it lets in); remove it (setfacl -b on Linux, chmod -N on macOS) and keep the mode 0600'
    return 0
  fi
  case "${mode#????}" in
    ------) ;;
    *) printf 'its mode is %s: the group or others have permission on it; make it 0600 (chmod 600)' "$mode" ;;
  esac
}

# the tailscale command, or nothing. SIRVEN_TAILSCALE is a seam for the tests ('none' means not installed), and root ignores it:
# root runs only the tailscale that the search path, vetted by the root gate, finds.
node_command() {
  local seam="${SIRVEN_TAILSCALE:-}"
  [ "$(id -u)" -ne 0 ] || seam=""
  case "$seam" in
    none) return 0 ;;
    '') command -v tailscale 2>/dev/null || true ;;
    *) printf '%s' "$seam" ;;
  esac
}

# status_fields COMMAND: key=value lines from 'tailscale status --json': readable, backend, id, tags, name.
# only this machine's own entry is read, so no other device can answer for it.
status_fields() {
  local output
  output="$("$1" status --json 2>/dev/null)" || true
  printf '%s\n' "$output" | python3 -I -c '
import json, re, sys
try:
    status = json.load(sys.stdin)
except ValueError:
    status = None
if not isinstance(status, dict):
    print("readable=no")
    sys.exit(0)
me = status.get("Self")
me = me if isinstance(me, dict) else {}
backend = status.get("BackendState")
if not isinstance(backend, str) or not re.match(r"^[A-Za-z]+$", backend):
    backend = "unknown"
node_id = me.get("I" "D")
if not isinstance(node_id, str) or not re.match(r"^[A-Za-z0-9_-]{1,64}$", node_id):
    node_id = ""
name = me.get("HostName")
if not isinstance(name, str) or not re.match(r"^[A-Za-z0-9._-]{1,253}$", name):
    name = ""
tags = me.get("Tags") or []
tags = [t for t in tags if isinstance(t, str) and re.match(r"^tag:[A-Za-z0-9-]+$", t)] if isinstance(tags, list) else []
print("readable=yes")
print("backend=" + backend)
print("id=" + node_id)
print("name=" + name)
print("tags=" + " ".join(tags))
' 2>/dev/null || printf 'readable=no\n'
}

read_status() {
  local key value
  S_READABLE=no S_BACKEND="" S_ID="" S_NAME="" S_TAGS=""
  while IFS='=' read -r key value; do
    case "$key" in
      readable) S_READABLE="$value" ;;
      backend) S_BACKEND="$value" ;;
      id) S_ID="$value" ;;
      name) S_NAME="$value" ;;
      tags) S_TAGS="$value" ;;
    esac
  done <<END
$(status_fields "$1")
END
}

has_tag() {
  case " $S_TAGS " in *" $TAILSCALE_NODE_TAG "*) return 0 ;; esac
  return 1
}

# marker_field MARKER NAME: one validated field of the marker, nothing when unreadable.
marker_field() {
  python3 -I -c '
import json, re, sys
try:
    with open(sys.argv[1]) as handle:
        data = json.load(handle)
    value = data[sys.argv[2]]
except Exception:
    sys.exit(1)
if not isinstance(value, str) or not re.match(r"^[A-Za-z0-9._:-]{1,253}$", value):
    sys.exit(1)
print(value)
' "$1" "$2" 2>/dev/null
}

write_marker() {
  local marker="$1" node_id="$2" name="$3" now temporary
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  temporary="$marker.new.$$"
  ( umask 077
    printf '{"node_id": "%s", "host_name": "%s", "tag": "%s", "joined_at": "%s"}\n' \
      "$node_id" "$name" "$TAILSCALE_NODE_TAG" "$now" > "$temporary" ) || return 1
  mv -f "$temporary" "$marker"
}

# show OUTPUT with KEY blanked out.
safe_print() {
  local text="$1" key="$2"
  [ -z "$key" ] || text="${text//"$key"/[key hidden]}"
  [ -z "$text" ] || printf '%s\n' "$text" >&2
}

install_hint() {
  printf 'install it from https://tailscale.com/download (on Debian or Ubuntu, add the Tailscale package repository from that page and run: apt install tailscale), then run this again.'
}

# node_hostname USER: USER-<short host name> as one plain lowercase host name.
node_hostname() {
  local host="${SIRVEN_TAILSCALE_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}" name
  name="$(printf '%s-%s' "$1" "$host" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-63 | sed 's/-$//')"
  printf '%s' "${name:-agent}"
}

# sweep_stale_key_copies MARKER: remove the private key copies a join that was killed (SIGKILL, power loss) left beside MARKER.
# the installer holds its lock while a join runs, so none of them belongs to a join that is still going.
sweep_stale_key_copies() {
  rm -f "$(dirname "$1")"/.tailscale-key.* 2>/dev/null || true
}

# logout_node COMMAND: tailscale logout, given a minute at most (a kill switch must not hang on a network that is down).
logout_node() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 60 "$1" logout >/dev/null 2>&1 || true
  else
    "$1" logout >/dev/null 2>&1 || true
  fi
}

# node_prepare USER KEY_FILE: every check the join makes before it changes anything: the host name, tailscale itself, the key and
# where it came from, the state of this machine's login. sets NODE_HOSTNAME, NODE_COMMAND, NODE_KEY and NODE_ORIGIN, refuses
# (exit 2, nothing changed) when anything is wrong, and returns 3 when this machine is already the agent node (nothing to join).
node_prepare() {
  local user="$1" key_file="$2" problem
  NODE_KEY="" NODE_ORIGIN=""
  NODE_HOSTNAME="$(node_hostname "$user")"
  case "$NODE_HOSTNAME" in -* | *[!a-z0-9-]*) refuse "the host name '$NODE_HOSTNAME' is not a plain lowercase name (letters, digits, hyphens)." ;; esac
  NODE_COMMAND="$(node_command)"
  [ -n "$NODE_COMMAND" ] || refuse "tailscale is not installed on this machine. $(install_hint)"
  if [ -n "${SIRVEN_TAILSCALE_AUTHKEY:-}" ]; then
    NODE_KEY="$SIRVEN_TAILSCALE_AUTHKEY"; NODE_ORIGIN="SIRVEN_TAILSCALE_AUTHKEY"
  elif [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    NODE_KEY="$TAILSCALE_AUTHKEY"; NODE_ORIGIN="TAILSCALE_AUTHKEY"
  elif [ -n "$key_file" ]; then
    problem="$(key_file_problem "$key_file")"
    [ -z "$problem" ] || refuse "the auth key file $key_file is not used: $problem."
    if [ -f "$key_file" ]; then
      NODE_KEY="$(head -n 1 "$key_file")"; NODE_ORIGIN="$key_file"
    fi
  fi
  [ -n "$NODE_KEY" ] || refuse "there is no Tailscale auth key. save it as ${key_file:-the key file}, owned by root, mode 0600 (the safer way), or put it in the environment as SIRVEN_TAILSCALE_AUTHKEY (sudo --preserve-env=SIRVEN_TAILSCALE_AUTHKEY ..., which works only if the sudo policy allows it). make it in the Tailscale admin console, settings, keys: tagged $TAILSCALE_NODE_TAG, pre-approved."
  unset SIRVEN_TAILSCALE_AUTHKEY TAILSCALE_AUTHKEY
  case "$NODE_KEY" in *[!A-Za-z0-9_-]*) refuse "the auth key in $NODE_ORIGIN has characters a Tailscale key never has (a carriage return from Windows line ends, for one); it is not used." ;; esac

  read_status "$NODE_COMMAND"
  [ "$S_READABLE" = yes ] || refuse "tailscale is installed but tailscaled does not answer. start it (systemctl enable --now tailscaled) and run this again."
  "$NODE_COMMAND" up --help 2>&1 | grep -q 'file:' || refuse "this tailscale cannot read an auth key from a file, which is the only way sirven passes one (a key on the command line shows in the process list). update tailscale from https://tailscale.com/download and run this again."
  case "$S_BACKEND" in
    NeedsLogin | NoState) ;;
    Running | Starting | Stopped | NeedsMachineAuth)
      has_tag && return 3
      refuse "this machine is already logged in to Tailscale without $TAILSCALE_NODE_TAG, and sirven never changes a login it did not make."
      ;;
    *) refuse "tailscale reports the state '$S_BACKEND'; sirven joins only from a machine that is logged out." ;;
  esac
}

# node_check USER KEY_FILE: the refusals of the join, and nothing else. for the installer's first look, before its first change.
node_check() {
  [ -n "${1:-}" ] || refuse "check needs the account name."
  node_prepare "$1" "${2:-}" || true
}

# node_key_file_check FILE: exit 0 a key file that may be used, 1 there is none, 2 there is one that may not be used (says why).
node_key_file_check() {
  local problem
  [ -n "${1:-}" ] || refuse "key-file-check needs a path."
  problem="$(key_file_problem "$1")"
  if [ -n "$problem" ]; then
    printf 'error: the auth key file %s is not used: %s.\n' "$1" "$problem" >&2
    exit 2
  fi
  [ -f "$1" ] && [ -s "$1" ] || exit 1
}

node_join() {
  local marker="${1:-}" user="${2:-}" key_file="${3:-}" hostname command key output status=0 waited=0 prepared=0
  [ -n "$marker" ] && [ -n "$user" ] || refuse "join needs a marker path and the account name."
  [ -d "$(dirname "$marker")" ] || refuse "the folder for the record, $(dirname "$marker"), is not there."
  node_prepare "$user" "$key_file" || prepared=$?
  if [ "$prepared" -eq 3 ]; then
    printf 'this machine is already logged in to Tailscale as %s. kept as it is: no join, nothing recorded.\n' "$TAILSCALE_NODE_TAG"
    return 0
  fi
  hostname="$NODE_HOSTNAME" command="$NODE_COMMAND" key="$NODE_KEY"
  NODE_KEY=""

  sweep_stale_key_copies "$marker"
  PRIVATE_KEY_FILE="$(dirname "$marker")/.tailscale-key.$$"
  trap 'rm -f "$PRIVATE_KEY_FILE"' EXIT
  ( umask 077; printf '%s\n' "$key" > "$PRIVATE_KEY_FILE" ) || fail "could not write a private copy of the auth key next to $marker."
  output="$("$command" up --auth-key="file:$PRIVATE_KEY_FILE" --advertise-tags="$TAILSCALE_NODE_TAG" --hostname="$hostname" \
    --ssh=false --accept-dns=false --accept-routes=false --reset --timeout="${TAILSCALE_NODE_WAIT}s" 2>&1)" || status=$?
  rm -f "$PRIVATE_KEY_FILE"
  safe_print "$output" "$key"

  # read the machine as it is now, whatever 'up' said: a login that exists must be recorded, so it can be undone.
  while :; do
    read_status "$command"
    [ "$S_BACKEND" = Running ] && [ -n "$S_ID" ] && break
    waited=$((waited + 1))
    [ "$waited" -lt 5 ] || break
    sleep 1
  done
  if [ "$S_READABLE" = yes ] && [ -n "$S_ID" ] && has_tag; then
    write_marker "$marker" "$S_ID" "${S_NAME:-$hostname}" || fail "joined the tailnet as $S_NAME, but could not write $marker. log out by hand: tailscale logout"
    if [ "$S_BACKEND" != Running ]; then
      fail "tailscale up ended in the state '$S_BACKEND', not Running (exit $status). the login is recorded in $marker; fix the cause and run again."
    fi
    printf 'joined the tailnet as %s (node %s), tagged %s. recorded in %s.\n' "${S_NAME:-$hostname}" "$S_ID" "$TAILSCALE_NODE_TAG" "$marker"
    return 0
  fi
  if [ "$S_READABLE" = yes ] && [ "$S_BACKEND" != NeedsLogin ] && [ "$S_BACKEND" != NoState ]; then
    # a login that cannot be recorded (no tag:agent, or no node number to record) is one sirven just made and could not undo later:
    # take it back out now.
    logout_node "$command"
    if [ -n "$S_ID" ]; then
      fail "the machine joined without $TAILSCALE_NODE_TAG (the key is not tagged, or $TAILSCALE_NODE_TAG is not owned in your tailnet policy), so sirven logged it out again. make the key with $TAILSCALE_NODE_TAG and run again."
    fi
    fail "the machine joined, but tailscale did not report a node number to record, so sirven logged it out again. nothing is recorded."
  fi
  fail "tailscale up failed (exit $status) and the machine is not logged in. nothing is recorded; the key was not kept. fix the cause above and run again."
}

node_leave() {
  local marker="${1:-}" command recorded
  [ -n "$marker" ] || refuse "leave needs a marker path."
  sweep_stale_key_copies "$marker"
  if [ ! -e "$marker" ]; then
    printf 'no Tailscale join of ours is recorded: nothing to log out.\n'
    return 0
  fi
  if [ -L "$marker" ] || [ ! -f "$marker" ]; then
    fail "$marker is not a plain file, so it is not trusted. remove it by hand once you have checked it, and log out by hand if sirven joined: tailscale logout"
  fi
  recorded="$(marker_field "$marker" node_id)" || fail "$marker cannot be read. nothing was logged out. if sirven joined this machine, check it with: tailscale status, then: tailscale logout"
  command="$(node_command)"
  if [ -z "$command" ]; then
    rm -f "$marker"
    printf 'tailscale is not installed on this machine, so there is no login to log out. the machine entry in the admin console goes when it expires; you can delete it there.\n'
    return 0
  fi
  read_status "$command"
  [ "$S_READABLE" = yes ] || fail "tailscaled does not answer, so the login of node $recorded could not be checked or logged out. start it (systemctl start tailscaled) and run this again; the record stays."
  case "$S_BACKEND" in
    NeedsLogin | NoState)
      rm -f "$marker"
      printf 'this machine is already logged out of Tailscale: record removed.\n'
      return 0
      ;;
  esac
  if [ "$S_ID" != "$recorded" ] || ! has_tag; then
    rm -f "$marker"
    printf 'this machine is logged in to Tailscale as something sirven did not join (node %s, tags: %s; sirven joined node %s). left alone, never logged out. record removed.\n' \
      "${S_ID:-unknown}" "${S_TAGS:-none}" "$recorded"
    return 0
  fi
  logout_node "$command"
  read_status "$command"
  case "$S_BACKEND" in
    NeedsLogin | NoState) ;;
    *) fail "tailscale logout did not end the login (state $S_BACKEND, node $recorded). the record stays; run this again, or log out by hand: tailscale logout" ;;
  esac
  rm -f "$marker"
  printf 'logged this machine (node %s) out of the tailnet: record removed. an ephemeral key drops the node from the tailnet at once; otherwise delete the machine in the admin console.\n' "$recorded"
}

case "${1:-}" in
  join) shift; node_join "$@" ;;
  leave) shift; node_leave "$@" ;;
  check) shift; node_check "$@" ;;
  key-file-check) shift; node_key_file_check "$@" ;;
  *) printf 'usage: tailscale_node.sh join MARKER USER KEY_FILE | leave MARKER | check USER KEY_FILE | key-file-check KEY_FILE\n' >&2; exit 64 ;;
esac
