# shellcheck shell=bash
# tailscale transport, the first path. the plan writes a policy snippet you paste yourself, then joins this
# machine to your tailnet as the tagged agent node, and records the join so the kill switch and uninstall can
# undo exactly that and nothing else. the work is in lib/tailscale_node.sh, run from the pinned copy of this
# package, so the install record's undo line works without this file.
#
# interactive once: you log in to the tailscale admin console in a browser and make one tagged
# auth key. after that the machine joins with that key, and the agent client connects over
# SSH with its own key. the key is read from the key file below (the safer way, and the one to use) or from the environment
# (SIRVEN_TAILSCALE_AUTHKEY or TAILSCALE_AUTHKEY), never written anywhere by sirven, and removed from disk
# after the join when it came from the file.
#
# the key never stays in the installer's environment. the first thing the installer does (tailscale_hold_key, called first in
# main) is move both variables into two variables that are not exported and unset the originals, so no step before the join,
# nor any later one, starts a process that inherits the key. only the two processes that need it are handed it, by the
# environment of that one command (the join step, and the first look that checks the join would be accepted); the join then
# unsets it at once and gives tailscale a private file. what unset cannot do is scrub the block of the environment a process
# was started with: root can read it in /proc/<process number>/environ for as long as the process runs, for the installer and
# for those two short-lived processes (the first look and the join). some processes start before main() runs, so before
# tailscale_hold_key, and they start with the variables the caller exported: the dirname of install.sh (and of uninstall.sh),
# which finds its own folder on every run; as root, the root gate's uname check (on any system) and, on linux, its python3 check;
# and, with the one-line bootstrap, its download, checksum and unpack tools. the key file avoids all of this: the key is never in
# any environment.
# the key file is the only route that never puts the key in an environment, which is why the plan names it first.
# opt-in debugging: the shell trace (bash -x, or set -x) prints the key in plain text on the lines that hold it. do not trace the
# installer while a key is in the environment.
# reads: PREFIX, PACKAGE, CONFIG_DIR, STATE_DIR, SERVICE_USER, ADOPT_TAILSCALE, OPERATING_SYSTEM

# the two places the environment route can hold the key, not exported (see tailscale_hold_key). the held names are their own
# names, so nothing here is confused with the variables the person set.
HELD_SIRVEN_TAILSCALE_AUTHKEY=""
HELD_TAILSCALE_AUTHKEY=""

# tailscale_hold_key: take the key out of the exported environment, once, before anything else runs. an exported variable of the
# held name that came from outside is dropped first, so the held variable is a plain shell variable and not exported.
tailscale_hold_key() {
  local sirven_named="${SIRVEN_TAILSCALE_AUTHKEY:-}" plain_named="${TAILSCALE_AUTHKEY:-}"
  unset SIRVEN_TAILSCALE_AUTHKEY TAILSCALE_AUTHKEY HELD_SIRVEN_TAILSCALE_AUTHKEY HELD_TAILSCALE_AUTHKEY
  HELD_SIRVEN_TAILSCALE_AUTHKEY="$sirven_named"
  HELD_TAILSCALE_AUTHKEY="$plain_named"
}

# tailscale_forget_held_key: drop the held key from this shell too, once nothing will read it.
tailscale_forget_held_key() {
  HELD_SIRVEN_TAILSCALE_AUTHKEY=""
  HELD_TAILSCALE_AUTHKEY=""
}

# tailscale_node_with_key ARGUMENT...: run lib/tailscale_node.sh with the held key in the environment of that one command, and
# nowhere else. it unsets the two variables before it starts any process of its own.
tailscale_node_with_key() {
  SIRVEN_TAILSCALE_AUTHKEY="${HELD_SIRVEN_TAILSCALE_AUTHKEY:-}" TAILSCALE_AUTHKEY="${HELD_TAILSCALE_AUTHKEY:-}" \
    bash "$ROOT_DIR/lib/tailscale_node.sh" "$@"
}

TAILSCALE_MACOS_REASON="applying to a macos machine is not verified yet; the join runs only on linux, inside a throwaway container"

tailscale_auth_key_file() {
  printf '%s/tailscale-auth-key' "$CONFIG_DIR"
}

# the record of the join: this node's id, host name and tag, never the key. kill switch and uninstall log out only that node.
tailscale_marker_file() {
  printf '%s/tailscale-node.json' "$STATE_DIR"
}

# the script that joins and logs out, in the pinned copy of this package (the path an install record can rely on)
tailscale_node_script() {
  printf '%s/package/lib/tailscale_node.sh' "$STATE_DIR"
}

# true when a key is there to join with: held from the environment, or in the key file. the key file counts only when it passes the
# same check the join makes (a plain file, owned by root, no extended access control list, no permission for anyone else), so the refusal comes before a change.
tailscale_key_available() {
  [ -n "${HELD_SIRVEN_TAILSCALE_AUTHKEY:-}" ] || [ -n "${HELD_TAILSCALE_AUTHKEY:-}" ] ||
    bash "$ROOT_DIR/lib/tailscale_node.sh" key-file-check "${PREFIX}$(tailscale_auth_key_file)" >/dev/null 2>&1 ||
    return 1
}

# true when an earlier run of this package joined this machine to the tailnet (the record is there).
tailscale_joined_by_us() {
  [ -f "${PREFIX}$(tailscale_marker_file)" ]
}

# tailscale_refuse_before_apply: a real apply that cannot join stops before its first change, with what to do. a dry run and a
# fake root never join, so they are not stopped. a machine that is already the agent node needs no key.
tailscale_refuse_before_apply() {
  local key_file_status
  [ "$COMMAND" = install ] && [ "$TRANSPORT" = tailscale ] && [ "$DRY_RUN" != yes ] && [ -z "$PREFIX" ] || return 0
  [ "$OPERATING_SYSTEM" = linux ] && [ "$ADOPT_TAILSCALE" != agent_node ] || return 0
  if [ "$ADOPT_TAILSCALE" = unanswered ]; then
    printf 'error: refused: tailscale is installed, but tailscaled does not answer, so this machine cannot join the tailnet. nothing was changed.\n' >&2
    printf 'you can: start it (systemctl enable --now tailscaled) and run again, or run again with --transport none.\n' >&2
    exit 2
  fi
  if ! tailscale_key_available; then
    key_file_status=0
    bash "$ROOT_DIR/lib/tailscale_node.sh" key-file-check "$(tailscale_auth_key_file)" >/dev/null || key_file_status=$?
    if [ "$key_file_status" -eq 2 ]; then
      printf 'error: refused: the saved auth key file cannot be trusted (above). nothing was changed.\n' >&2
      printf 'you can: fix it (chown root:root %s, take off any extended access control list with setfacl -b %s, then chmod 600 %s; if it has more than one name, copy the key into a new file with umask 077 and remove the old names), or remove it and hand the key over in the environment.\n' \
        "$(tailscale_auth_key_file)" "$(tailscale_auth_key_file)" "$(tailscale_auth_key_file)" >&2
      exit 2
    fi
    printf 'error: refused: there is no Tailscale auth key to join the tailnet with. nothing was changed.\n' >&2
    printf 'you can: make a key in the Tailscale admin console (settings, keys: tagged tag:agent, pre-approved, ephemeral if you can), then run again with it saved as %s, owned by root, mode 0600 (the safer way), or in the environment: sudo --preserve-env=SIRVEN_TAILSCALE_AUTHKEY ... (which works only if the sudo policy allows it). or run again with --transport none.\n' "$(tailscale_auth_key_file)" >&2
    exit 2
  fi
  # every other refusal the join itself would make, now, so that "nothing was changed" is true: a tailscale too old to read a key from
  # a file, a key with characters no key has, a login that is not ours, tailscale itself missing. the script prints why.
  tailscale_node_with_key check "$SERVICE_USER" "$(tailscale_auth_key_file)" || exit 2
}

# policy snippet in the tailscale policy file syntax, which allows comments.
tailscale_policy_snippet() {
  cat <<'END'
// paste into your tailnet policy file, merging with what is there.
// replace you@example.com with your own tailscale login.
// only your devices reach the agent, and only on the SSH port.
{
  "tagOwners": {
    "tag:agent": ["autogroup:admin"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["you@example.com"],
      "dst": ["tag:agent:22"]
    }
  ]
}
END
}

plan_tailscale() {
  local key_file marker script staged
  key_file="$(rooted "$(tailscale_auth_key_file)")"
  marker="$(rooted "$(tailscale_marker_file)")"
  script="$(rooted "$(tailscale_node_script)")"
  plan_section "transport: tailscale"
  staged="$(tailscale_policy_snippet | stage_file tailscale-policy-snippet.hujson)"
  layout_write_file "write the tailnet policy snippet" "$CONFIG_DIR/tailscale-policy-snippet.hujson" 0644 "$staged" \
    "tag:agent, reachable only from your login, only on port 22"
  plan_owner "paste the policy snippet into your tailnet policy" \
    "tailscale admin console, access controls: merge $CONFIG_DIR/tailscale-policy-snippet.hujson and put your login in place of you@example.com."
  # a machine already logged in with tag:agent is adopted as it is: no key, no join, no
  # tailscale up, which could re-key it or reset its settings. see lib/adopt.sh.
  if [ "${ADOPT_TAILSCALE:-none}" = agent_node ]; then
    if tailscale_joined_by_us; then
      plan_note "this machine is already the agent node, joined by an earlier run of this installer and recorded in $(tailscale_marker_file): no auth key and no new join. the kill switch and uninstall log out that node, and only it."
    else
      plan_note "this machine is already the agent node, adopted above: no auth key and no join. sirven never runs tailscale up on it."
    fi
    # nothing will read the key on this run: drop the held copies
    tailscale_forget_held_key
    if [ -e "${PREFIX}$(tailscale_auth_key_file)" ]; then
      plan_note "an auth key is still saved at $(tailscale_auth_key_file) and is not needed: delete it."
    fi
    plan_note "the agent client connects with: ssh $SERVICE_USER@<this machine's tailnet name>. tailscale ssh stays off; the machine's own SSH server and keys are used."
    return 0
  fi
  plan_owner "give the installer one tagged auth key, once" \
    "tailscale admin console, settings, keys: generate an auth key with tag:agent, pre-approved. ephemeral is the better choice: the node then leaves the tailnet by itself when it logs out.
hand it over one of two ways, and it is the only interactive step:
  in a file, the safer way and the one to use first: save it as $(tailscale_auth_key_file), owned by root, mode 0600, with one name only (no hard link) and no extra access control list; it is removed after the join. this is the only way that never puts the key in an environment.
  in the environment: set SIRVEN_TAILSCALE_AUTHKEY (or TAILSCALE_AUTHKEY) in your shell and run sudo --preserve-env=SIRVEN_TAILSCALE_AUTHKEY. sudo allows that only when its policy does: a sudoers rule for all commands implies the SETENV tag, a narrower rule needs that tag, or an env_keep line for the variable. when the policy does not allow it, sudo may refuse the command with an error; without the option, sudo drops the variable and the join finds no key. the installer takes the key out of its environment at once and hands it only to the join, but it cannot scrub the block of the environment it was started with: root can still read it in /proc/<installer process number>/environ until the installer ends." \
    "tailscale_key_available"
  if [ "$OPERATING_SYSTEM" = macos ]; then
    plan_planonly "join the tailnet as a tagged device with that key" \
      "tailscale up --auth-key=file:<a private copy of the key> --advertise-tags=tag:agent --hostname=$SERVICE_USER-<this machine's name> --ssh=false --accept-dns=false --accept-routes=false --reset" \
      "$TAILSCALE_MACOS_REASON" \
      "adopt_tailscale_is_agent_node"
  else
    plan_step system "join the tailnet as a tagged device with that key" \
      "adopt_tailscale_is_agent_node" \
      "SIRVEN_TAILSCALE_AUTHKEY=\"\${HELD_SIRVEN_TAILSCALE_AUTHKEY:-}\" TAILSCALE_AUTHKEY=\"\${HELD_TAILSCALE_AUTHKEY:-}\" bash $script join $marker $SERVICE_USER $key_file" \
      "# runs lib/tailscale_node.sh join; the key comes from $key_file or from the environment of this one command, and is never put on a command line.
# it records the node in $(tailscale_marker_file), and refuses with nothing changed if there is no key, no tailscale, or a login that is not ours.
tailscale up --auth-key=file:<a private copy of the key> --advertise-tags=tag:agent --hostname=$SERVICE_USER-<this machine's name> --ssh=false --accept-dns=false --accept-routes=false --reset --timeout=60s"
    # the join is the only step that reads the key, and it is handed it in its own command's environment (see tailscale_hold_key):
    # the installer's environment never holds it, so no step before or after the join starts a child process that inherits it.
    # once the join has run (done, failed or skipped) the held copies are dropped from the shell too, and the two exported names
    # are unset again. that second part cannot matter now (they are not there), and stays as defense in depth: the held names are
    # the ones that count.
    plan_forget_secrets HELD_SIRVEN_TAILSCALE_AUTHKEY HELD_TAILSCALE_AUTHKEY SIRVEN_TAILSCALE_AUTHKEY TAILSCALE_AUTHKEY
    plan_undo "log this machine out of the tailnet, if this installer joined it" "[ ! -e $marker ]" \
      "bash $script leave $marker" \
      "tailscale logout   # via lib/tailscale_node.sh leave, only when this machine's login is still the node recorded in $(tailscale_marker_file)"
    plan_step run "remove the used auth key from disk, if one was saved" \
      "[ ! -e $key_file ]" \
      "rm -f $key_file"
  fi
  plan_note "the agent client connects with: ssh $SERVICE_USER@<this machine's tailnet name>. tailscale ssh stays off; the machine's own SSH server and keys are used."
}
