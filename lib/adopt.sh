# shellcheck shell=bash
# adopt what is already on the machine: a Tailscale install and login, a bb install, and sirven
# state from an earlier run (the grant in force, the policy copy, the audit log, the install
# record). install only; the kill switch and uninstall never look here.
#
# the rule: what is found is kept exactly as it is. the plan shows one "adopted:" line for each
# thing it keeps, and leaves out the steps that would install it again. nothing here ever logs
# Tailscale in or out, changes its keys, tags, or settings, reinstalls bb, or rewrites a grant
# record, a policy copy, or the audit log. when what is there cannot be kept alongside what was
# asked, a real run stops before any change and says what conflicts and what the person can do
# (adopt_refuse_conflicts). a dry run changes nothing anyway, so it goes on and prints the whole
# plan with each conflict as a blocked step (plan_adopt), then exits 2, the status of the real
# refusal, so a script that tests for 2 sees the same answer with or without --dry-run.
#
# detection is read only: 'tailscale version', 'tailscale status --json' (only the backend state
# and this machine's own tags are kept), 'bb --version', and files under the package directories.
#
# test seams, the same names the menu bar app uses:
#   SIRVEN_TAILSCALE   the tailscale command to probe, or none for "not installed"
#   SIRVEN_BB          the bb command to probe, or none for "not installed"
# a command path only works with --dry-run or --prefix. under --prefix, with no seam set, nothing
# outside the fake root is probed: a fake root has no Tailscale and no bb of its own.
# reads: PREFIX, PACKAGE, OPERATING_SYSTEM, CONFIG_DIR, STATE_DIR, AUDIT_DIR, SERVICE_USER, OWNER,
#        LEVEL, GRANT_PATHS, PATHS_GIVEN, TRANSPORT, WITH_BB, ROOT_DIR, STAGE_DIR, DRY_RUN

ADOPT_TAILSCALE_APP="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

# nothing found until adopt_detect runs, so a plan built without it is the fresh install plan.
ADOPT_TAILSCALE=none
ADOPT_TAILSCALE_VERSION=""
ADOPT_TAILSCALE_BACKEND=""
ADOPT_TAILSCALE_TAGS=""
ADOPT_BB=none
ADOPT_BB_VERSION=""
ADOPT_GRANT=none
ADOPT_GRANT_LEVEL=""
ADOPT_GRANT_PATHS=()
ADOPT_REVOKED=no
ADOPT_RECORD=no
ADOPT_AUDIT_ENTRIES=""

# adopt_check_seams: a seam pointing at a command is for tests, so only a dry run or a fake root.
adopt_check_seams() {
  local name value
  for name in SIRVEN_TAILSCALE SIRVEN_BB; do
    eval "value=\"\${$name:-}\""
    case "$value" in
      '' | none) ;;
      *)
        if [ "$DRY_RUN" != yes ] && [ -z "$PREFIX" ]; then
          usage_error "$name only works with --dry-run or --prefix"
        fi
        ;;
    esac
  done
}

# _adopt_command SEAM NAME [FALLBACK]: the command to probe, or nothing when it is not there or
# must not be probed.
_adopt_command() {
  local seam="$1" name="$2" fallback="${3:-}"
  case "$seam" in
    none) return 0 ;;
    '') ;;
    *) printf '%s' "$seam"; return 0 ;;
  esac
  [ -z "$PREFIX" ] || return 0
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
  elif [ -n "$fallback" ] && [ -x "$fallback" ]; then
    printf '%s' "$fallback"
  fi
}

_adopt_tailscale_command() {
  local fallback=""
  [ "${OPERATING_SYSTEM:-}" = macos ] && fallback="$ADOPT_TAILSCALE_APP"
  _adopt_command "${SIRVEN_TAILSCALE:-}" tailscale "$fallback"
}

# _adopt_tailscale_status COMMAND: key=value lines from 'tailscale status --json'. only the
# backend state and this machine's own tags are read, so no other device can answer for it.
# status exits non-zero when stopped or logged out but still prints the JSON, so the JSON decides.
_adopt_tailscale_status() {
  local output
  output="$("$1" status --json 2>/dev/null)" || true
  printf '%s\n' "$output" | python3 -c '
import json, re, sys
try:
    status = json.load(sys.stdin)
except ValueError:
    print("readable=no")
    sys.exit(0)
if not isinstance(status, dict):
    print("readable=no")
    sys.exit(0)
me = status.get("Self") or {}
tags = me.get("Tags") or [] if isinstance(me, dict) else []
backend = status.get("BackendState")
if not isinstance(backend, str) or not re.match(r"^[A-Za-z]+$", backend):
    backend = "unknown"
print("readable=yes")
print("backend=%s" % backend)
print("tags=%s" % " ".join(tag for tag in tags if isinstance(tag, str) and re.match(r"^tag:[A-Za-z0-9-]+$", tag)))
' 2>/dev/null || printf 'readable=no\n'
}

# adopt_detect_tailscale: ADOPT_TAILSCALE is none (not installed, or not probed), unanswered,
# logged_out, agent_node (logged in with tag:agent on this machine), or other_node (logged in
# without it). ADOPT_TAILSCALE_VERSION, ADOPT_TAILSCALE_BACKEND, ADOPT_TAILSCALE_TAGS go with it.
adopt_detect_tailscale() {
  local command key value readable=no
  ADOPT_TAILSCALE=none
  ADOPT_TAILSCALE_VERSION=""
  ADOPT_TAILSCALE_BACKEND=""
  ADOPT_TAILSCALE_TAGS=""
  command="$(_adopt_tailscale_command)"
  [ -n "$command" ] || return 0
  ADOPT_TAILSCALE_VERSION="$(first_version "$("$command" version 2>/dev/null | head -n 1)")"
  while IFS='=' read -r key value; do
    case "$key" in
      readable) readable="$value" ;;
      backend) ADOPT_TAILSCALE_BACKEND="$value" ;;
      tags) ADOPT_TAILSCALE_TAGS="$value" ;;
    esac
  done <<END
$(_adopt_tailscale_status "$command")
END
  if [ "$readable" != yes ]; then
    ADOPT_TAILSCALE=unanswered
    return 0
  fi
  case "$ADOPT_TAILSCALE_BACKEND" in
    Running | Starting | Stopped | NeedsMachineAuth) ;;
    *) ADOPT_TAILSCALE=logged_out; return 0 ;;
  esac
  case " $ADOPT_TAILSCALE_TAGS " in
    *" tag:agent "*) ADOPT_TAILSCALE=agent_node ;;
    *) ADOPT_TAILSCALE=other_node ;;
  esac
}

# adopt_tailscale_is_agent_node: the probe for the join step. true when this machine is already
# logged in to Tailscale with tag:agent.
adopt_tailscale_is_agent_node() {
  adopt_detect_tailscale
  [ "$ADOPT_TAILSCALE" = agent_node ]
}

# adopt_detect_bb: ADOPT_BB is none or installed, with ADOPT_BB_VERSION.
adopt_detect_bb() {
  local command
  ADOPT_BB=none
  ADOPT_BB_VERSION=""
  command="$(_adopt_command "${SIRVEN_BB:-}" bb)"
  [ -n "$command" ] || return 0
  ADOPT_BB=installed
  ADOPT_BB_VERSION="$(first_version "$("$command" --version 2>/dev/null | head -n 1)")"
}

adopt_grant_record() {
  printf '%s/grants/%s.json' "$CONFIG_DIR" "$SERVICE_USER"
}

# adopt_detect_sirven: state an earlier run left under the package directories.
# ADOPT_GRANT is none, active, or unreadable; ADOPT_GRANT_LEVEL and ADOPT_GRANT_PATHS describe an
# active one. ADOPT_REVOKED, ADOPT_RECORD are yes or no; ADOPT_AUDIT_ENTRIES is a count, or empty
# when there is no audit log.
adopt_detect_sirven() {
  local record key value shown log
  ADOPT_GRANT=none
  ADOPT_GRANT_LEVEL=""
  ADOPT_GRANT_PATHS=()
  ADOPT_REVOKED=no
  ADOPT_RECORD=no
  ADOPT_AUDIT_ENTRIES=""
  record="${PREFIX}$(adopt_grant_record)"
  if [ -f "$record" ]; then
    if shown="$(python3 "$ROOT_DIR/lib/grant_compiler.py" show --record "$record" 2>/dev/null)"; then
      ADOPT_GRANT=active
      while IFS='=' read -r key value; do
        case "$key" in
          level) ADOPT_GRANT_LEVEL="$value" ;;
          path) ADOPT_GRANT_PATHS[${#ADOPT_GRANT_PATHS[@]}]="$value" ;;
        esac
      done <<END
$shown
END
      case "$ADOPT_GRANT_LEVEL" in
        observer | builder | operator) ;;
        *) ADOPT_GRANT=unreadable ;;
      esac
    else
      ADOPT_GRANT=unreadable
    fi
  fi
  [ ! -f "$record.revoked" ] || ADOPT_REVOKED=yes
  [ ! -f "${PREFIX}$(layout_record_file)" ] || ADOPT_RECORD=yes
  log="${PREFIX}$(audit_log_file)"
  if [ -f "$log" ]; then
    ADOPT_AUDIT_ENTRIES="$(grep -c . "$log" || true)"
  fi
}

# adopt_detect: everything above, once, before the setup questions.
adopt_detect() {
  adopt_detect_tailscale
  adopt_detect_bb
  adopt_detect_sirven
}

_adopt_describe_paths() {
  local index=0 text=""
  if [ "${#ADOPT_GRANT_PATHS[@]}" -eq 0 ]; then
    printf 'no path'
    return 0
  fi
  while [ "$index" -lt "${#ADOPT_GRANT_PATHS[@]}" ]; do
    text="${text:+$text, }${ADOPT_GRANT_PATHS[index]}"
    index=$((index + 1))
  done
  printf '%s' "$text"
}

# adopt_fill_answers: with a grant in force, whatever a flag or the environment left open comes
# from that grant, so a re-run keeps it instead of falling back to observer and no path. nothing
# is asked for an answer the machine already gives.
adopt_fill_answers() {
  local index=0
  # shellcheck disable=SC2153 # COMMAND is set by install.sh before this file's functions run
  [ "$COMMAND" = install ] && [ "$ADOPT_GRANT" = active ] || return 0
  [ -z "$LEVEL" ] || [ "$PATHS_GIVEN" = no ] || return 0
  [ -n "$LEVEL" ] || LEVEL="$ADOPT_GRANT_LEVEL"
  if [ "$PATHS_GIVEN" = no ]; then
    GRANT_PATHS=()
    while [ "$index" -lt "${#ADOPT_GRANT_PATHS[@]}" ]; do
      GRANT_PATHS[index]="${ADOPT_GRANT_PATHS[index]}"
      index=$((index + 1))
    done
    PATHS_GIVEN=yes
  fi
  say "adopting the grant in force for $SERVICE_USER: level $ADOPT_GRANT_LEVEL on $(_adopt_describe_paths)." >&2
  say "  to change it, give --level and --path; sirven grant rollback reverses a change." >&2
}

# _adopt_compare_grant: ADOPT_GRANT_SAME is yes when the grant asked for is the grant in force,
# byte for byte as the installer would write it. a grant the compiler refuses is left to the plan,
# which stops with the compiler's own reason.
_adopt_compare_grant() {
  local staged="$STAGE_DIR/adopt-requested-grant.json" index=0
  ADOPT_GRANT_SAME=no
  [ "$ADOPT_GRANT" = active ] && [ "${#GRANT_PATHS[@]}" -gt 0 ] || return 0
  set -- record --level "$ROOT_DIR/levels/$LEVEL.json" --user "$SERVICE_USER" --os "$OPERATING_SYSTEM" --package "$PACKAGE"
  while [ "$index" -lt "${#GRANT_PATHS[@]}" ]; do
    set -- "$@" --path "${GRANT_PATHS[index]}"
    index=$((index + 1))
  done
  python3 "$ROOT_DIR/lib/grant_compiler.py" "$@" > "$staged" 2>/dev/null || return 0
  if cmp -s "$staged" "${PREFIX}$(adopt_grant_record)"; then
    ADOPT_GRANT_SAME=yes
  fi
}

# _adopt_audit_owner: who the audit log directory belongs to, or nothing when it is not there or
# still belongs to root. under --prefix, ownership is never really changed, so the owner is the
# one in the simulated chown an earlier run recorded.
_adopt_audit_owner() {
  local directory log
  directory="$(rooted "$AUDIT_DIR")"
  if [ -n "$PREFIX" ]; then
    log="${PREFIX}$(layout_simulation_log)"
    [ -f "$log" ] || return 0
    grep -F "chown -R " "$log" | grep -F " $directory" | tail -n 1 | awk '{print $3}'
    return 0
  fi
  [ -d "$AUDIT_DIR" ] || return 0
  # shellcheck disable=SC2012 # ls -ld is the portable way to read one owner on macos and linux
  ls -ld "$AUDIT_DIR" | awk '$3 != "root" {print $3}'
}

_ADOPT_CONFLICT_WHAT=()
_ADOPT_CONFLICT_ADVICE=()

_adopt_conflict() {
  _ADOPT_CONFLICT_WHAT+=("$1")
  _ADOPT_CONFLICT_ADVICE+=("$2")
}

# adopt_has_conflicts: true when adopt_refuse_conflicts found something that cannot be kept.
adopt_has_conflicts() {
  [ "${#_ADOPT_CONFLICT_WHAT[@]}" -gt 0 ]
}

# adopt_refuse_conflicts: find what on the machine cannot be kept alongside what was asked. a real
# run (also under --prefix) prints every conflict and what to do about it, then stops before any
# change. a dry run keeps them for plan_adopt to show and for install.sh to report and exit on.
adopt_refuse_conflicts() {
  local copy shipped owner wanted record_file index=0
  _ADOPT_CONFLICT_WHAT=()
  _ADOPT_CONFLICT_ADVICE=()
  [ "$COMMAND" = install ] || return 0

  if [ "$TRANSPORT" = tailscale ] && [ "$ADOPT_TAILSCALE" = other_node ]; then
    _adopt_conflict "this machine is already logged in to Tailscale (tags: ${ADOPT_TAILSCALE_TAGS:-none}), and it is not the agent node. joining as tag:agent would log it in again with a new key and re-tag it, and sirven never changes a Tailscale login, key, or tag." \
      "keep it as it is and run again with --transport none: the agent stays reachable over your tailnet, under your tailnet's own policy. or tag this machine tag:agent yourself in the Tailscale admin console and run again: sirven adopts a tagged machine as it is."
  fi

  if [ "$REINSTATE" != yes ] && kill_switch_account_cut_off "$SERVICE_USER"; then
    _adopt_conflict "the account $SERVICE_USER was cut off by the kill switch (its revoke marker $STATE_DIR/agent-revoked-$SERVICE_USER.json is there, or the account is expired and no install is in the middle of changing it). install will not turn it back on by itself, also when the kill switch stopped before it finished." \
      "to bring it back on purpose, run the same command with --reinstate: it unlocks the account, removes the expiry and the marker, gives back the /bin/bash shell, writes audit entries, then goes on with the install. to leave it cut off, do not install."
  fi

  case "$ADOPT_GRANT" in
    unreadable)
      _adopt_conflict "the grant record $(adopt_grant_record) is there but cannot be read as a grant, and sirven will not overwrite it." \
        "look at it with sirven grant inspect. if it is not worth keeping, move it aside yourself and run again."
      ;;
    active)
      if [ "${#GRANT_PATHS[@]}" -eq 0 ]; then
        _adopt_conflict "a grant is in force for $SERVICE_USER: level $ADOPT_GRANT_LEVEL on $(_adopt_describe_paths). this request grants no path, and installing would leave that grant in force while saying none." \
          "keep it: run again without --path. take it back: $(layout_root_command revoke) --dry-run shows the kill switch."
      fi
      ;;
  esac

  copy="${PREFIX}$CONFIG_DIR/levels/$LEVEL.json"
  shipped="$ROOT_DIR/levels/$LEVEL.json"
  record_file="${PREFIX}$STATE_DIR/install-record.tsv"
  if [ -f "$copy" ] && ! cmp -s "$shipped" "$copy" && [ -r "$record_file" ] && \
    grep -q 'access_control_snapshot.sh restore\|setfacl -R -P -x u:' "$record_file" && ! grep -q -- '--audit' "$record_file"; then
    _adopt_conflict "an install made by an older version of this package is in place (its policy copy $CONFIG_DIR/levels/$LEVEL.json and its undo steps are older than this package's), and an older undo leaves the default list, the mask and the folder owner's entry behind." \
      "move to this version in three steps, as root: 1) sirven grant repair (from this package) removes what the old grant added. 2) the old install's own uninstall.sh (sudo bash $STATE_DIR/package/uninstall.sh) removes the account and the rest. 3) run this install again. add --dry-run to the first to see what it would remove."
  elif [ -f "$copy" ] && ! cmp -s "$shipped" "$copy"; then
    _adopt_conflict "the installed $LEVEL policy $CONFIG_DIR/levels/$LEVEL.json differs from this package's levels/$LEVEL.json: edited by hand, or written by another version. sirven will not overwrite it." \
      "compare the two with diff. to keep yours, leave it and do not reinstall this level. to take this package's copy, move yours aside yourself and run again."
  fi

  owner="$(_adopt_audit_owner)"
  # shellcheck disable=SC2153 # OWNER is set by the entry script (install.sh, bin/sirven) before this runs
  wanted="$(shell_quote "$OWNER")"
  if [ -n "$owner" ] && [ "$owner" != "$wanted" ] && [ "$owner" != "$OWNER" ]; then
    _adopt_conflict "the audit log directory $AUDIT_DIR belongs to $owner, and this run would give it to $OWNER." \
      "run again with --owner $owner to keep it as it is."
  fi

  adopt_has_conflicts || return 0
  [ "$DRY_RUN" != yes ] || return 0
  printf 'error: refused: what is already on this machine conflicts with this request. nothing was changed.\n' >&2
  printf 'sirven adopts what it finds and never overwrites it. each conflict, and what you can do:\n' >&2
  while [ "$index" -lt "${#_ADOPT_CONFLICT_WHAT[@]}" ]; do
    printf '  - %s\n    you can: %s\n' "${_ADOPT_CONFLICT_WHAT[index]}" "${_ADOPT_CONFLICT_ADVICE[index]}" >&2
    index=$((index + 1))
  done
  exit 2
}

# adopt_found_anything: true when the plan has something to adopt.
adopt_found_anything() {
  [ "$ADOPT_TAILSCALE" != none ] || [ "$ADOPT_BB" != none ] || [ "$ADOPT_GRANT" != none ] ||
    [ "$ADOPT_REVOKED" = yes ] || [ "$ADOPT_RECORD" = yes ] || [ -n "$ADOPT_AUDIT_ENTRIES" ]
}

_adopt_tailscale_line() {
  local version="Tailscale${ADOPT_TAILSCALE_VERSION:+ $ADOPT_TAILSCALE_VERSION}" unused=""
  [ "$TRANSPORT" = tailscale ] || unused=" not used by this plan."
  case "$ADOPT_TAILSCALE" in
    agent_node)
      if [ "$TRANSPORT" = tailscale ] && tailscale_joined_by_us; then
        printf '%s, logged in; this machine is already the agent node (tag:agent), joined by an earlier run of this installer. kept as it is: not re-keyed or re-tagged. the kill switch and uninstall log it out, because this installer joined it.' "$version"
      elif [ "$ADOPT_TAILSCALE_BACKEND" = Stopped ]; then
        printf '%s, logged in and stopped; this machine is already the agent node (tag:agent).%s kept as it is: never logged out, re-keyed, re-tagged, or started.' "$version" "$unused"
      else
        printf '%s, logged in; this machine is already the agent node (tag:agent).%s kept as it is: never logged out, re-keyed, or re-tagged.' "$version" "$unused"
      fi
      ;;
    other_node)
      printf '%s, logged in as a device of your tailnet (tags: %s).%s kept as it is: never logged out, re-keyed, or re-tagged.' "$version" "${ADOPT_TAILSCALE_TAGS:-none}" "$unused"
      ;;
    logged_out)
      if [ -n "$unused" ]; then
        printf '%s, installed and not logged in.%s kept as it is.' "$version" "$unused"
      else
        printf '%s, installed and not logged in. the install is kept, never reinstalled. there is no login to adopt, so the join below is the fresh setup.' "$version"
      fi
      ;;
    unanswered)
      printf '%s is installed, but tailscale status did not answer.%s kept as it is, never reinstalled.' "$version" "$unused"
      ;;
  esac
}

# plan_adopt: the "already on this machine" section, only when something was found.
plan_adopt() {
  local policy index=0
  if adopt_has_conflicts; then
    plan_section "conflicts with what is already on this machine: a real run would refuse"
    plan_note "sirven adopts what it finds and never overwrites it. a real run stops before any change until each of these is resolved; this dry run shows the rest of the plan as it would be."
    while [ "$index" -lt "${#_ADOPT_CONFLICT_WHAT[@]}" ]; do
      plan_conflict "${_ADOPT_CONFLICT_WHAT[index]}" "${_ADOPT_CONFLICT_ADVICE[index]}"
      index=$((index + 1))
    done
  fi
  adopt_found_anything || return 0
  plan_section "already on this machine, adopted as it is"
  if [ "$ADOPT_TAILSCALE" != none ]; then
    plan_adopted "$(_adopt_tailscale_line)"
  fi
  if [ "$ADOPT_BB" = installed ]; then
    plan_adopted "bb${ADOPT_BB_VERSION:+ $ADOPT_BB_VERSION}, installed for the account running this. kept as it is: never reinstalled or updated."
  fi
  if [ "$ADOPT_GRANT" = active ]; then
    _adopt_compare_grant
    if [ "$ADOPT_GRANT_SAME" = yes ]; then
      plan_adopted "the grant for $SERVICE_USER from an earlier run: level $ADOPT_GRANT_LEVEL on $(_adopt_describe_paths). kept as it is; its steps below show as already done."
    else
      plan_note "the grant in force for $SERVICE_USER, level $ADOPT_GRANT_LEVEL on $(_adopt_describe_paths), changes to the one below, as asked. sirven grant rollback reverses the change."
    fi
  fi
  policy="${PREFIX}$CONFIG_DIR/levels/$LEVEL.json"
  if [ -f "$policy" ] && cmp -s "$ROOT_DIR/levels/$LEVEL.json" "$policy"; then
    plan_adopted "the $LEVEL policy $CONFIG_DIR/levels/$LEVEL.json, the same as levels/$LEVEL.json. kept as it is."
  fi
  if [ "$ADOPT_REVOKED" = yes ]; then
    plan_adopted "a grant for $SERVICE_USER revoked by the kill switch, $(adopt_grant_record).revoked. kept as history, never rewritten."
  fi
  if [ -n "$ADOPT_AUDIT_ENTRIES" ]; then
    plan_adopted "the audit log $(audit_log_file), $ADOPT_AUDIT_ENTRIES entries. kept: new entries are appended, and nothing in it is rewritten."
  fi
  if [ "$ADOPT_RECORD" = yes ]; then
    plan_adopted "the install record $(layout_record_file). kept: steps applied now are added after what it lists, so uninstall still reverses only what this package created."
  fi
}

# adopt_audit_entries: on a real apply, one adopt entry per adopted line, so the audit log says
# what the install found and kept.
adopt_audit_entries() {
  local index=0
  while [ "$index" -lt "$PLAN_COUNT" ]; do
    if [ "${PLAN_KIND[index]}" = adopted ]; then
      audit_write "$(audit_entry adopt "operation=$AUDIT_OPERATION" "found=${PLAN_TITLE[index]}")"
    fi
    index=$((index + 1))
  done
}
