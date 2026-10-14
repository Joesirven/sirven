#!/usr/bin/env bash
# install.sh: set up secure agent access on this machine, plan first.
#
# every change goes through one plan. --dry-run prints it and changes nothing; without
# --dry-run the identical plan is printed and then applied. re-runs skip finished steps.
# runs on macos bash 3.2 and on linux bash.

# stop early, and readably, when started by sh or zsh instead of bash.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "error: run this with bash, for example: bash $0" >&2
  exit 1
fi

set -euo pipefail

# ---- root gate: begin. the same text is at the top of install.sh, uninstall.sh and bin/sirven; tests/unit/test_gate.sh keeps it so.
# when this runs as root, every line of code and every tool it uses must come from a place that only root (and the owner who
# ran sudo) controls. nothing here asks the folder it is judging where the trusted copy is, or lets that folder judge itself:
#   - the search path is reset (/usr/local/sbin and /usr/local/bin are added back only if root alone controls them) and every tool
#     the gate uses is named by its absolute path;
#   - the kept copy is the fixed path below, never read from project.json or any other file of the folder under test;
#   - the checker is the text of this block, not a file of the folder under test;
#   - the folder is resolved to its physical path once, and every library is read through that path;
#   - it runs for every command and every flag as root, --dry-run, --help and --prefix included: a dry run reads the same code.
# what it does: a copy of this package other than the kept one is never run as root when the kept one exists (install is the
# exception, to upgrade, and only from a folder that nobody but root and the owner can write). with no kept copy, the folder it
# runs from must be one that nobody but root and the owner can write, the whole way down and up. the kept copy itself must be
# that too. the safe way to run any root command is the one install prints: the launcher /usr/local/sbin/sirven when its folder is safe, else the kept copy.
if [ -z "${BASH_SOURCE[0]:-}" ]; then
  printf 'error: run this as a file, for example: bash install.sh ... . started from standard input or with -c it cannot tell which folder it belongs to, and so cannot check the code it would read. nothing was changed.\n' >&2
  exit 2
fi
if [ "$EUID" -eq 0 ]; then
  PATH=/usr/sbin:/usr/bin:/sbin:/bin
  export PATH
  # (bash has already read BASH_ENV and ENV before this line, for this script; sudo removes them. this protects what is started from here.)
  unset BASH_ENV ENV CDPATH LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT PYTHONPATH PYTHONHOME PYTHONSTARTUP
fi
SIRVEN_KEPT=/var/lib/sirven/package

# sirven_vet FOLDER OWNER: exit 0 when nobody but root and OWNER can change anything in FOLDER or replace anything on the way to
# it; otherwise exit 3 and print each place somebody else can write. read only. this text is the checker.
sirven_vet() {
  /usr/bin/python3 -I - "$1" "$2" <<'PY'
import grp, os, pwd, stat, struct, sys
folder, owner = sys.argv[1], sys.argv[2]
ACCESS_LIST, USER, GROUP, MASK = "system.posix_acl_access", 0x02, 0x08, 0x10
users = {0}
try:
    users.add(pwd.getpwnam(owner).pw_uid)
except KeyError:
    pass
names = set()
for number in users:
    try:
        names.add(pwd.getpwuid(number).pw_name)
    except KeyError:
        pass
def uid_name(number):
    try:
        return pwd.getpwuid(number).pw_name
    except KeyError:
        return "user number %d" % number
def gid_name(number):
    try:
        return grp.getgrgid(number).gr_name
    except KeyError:
        return "group number %d" % number
def group_trusted(gid):
    try:
        members = set(grp.getgrgid(gid).gr_mem)
    except KeyError:
        return gid == 0
    members.update(entry.pw_name for entry in pwd.getpwall() if entry.pw_gid == gid)
    return members <= names
def entries(path):
    if not hasattr(os, "getxattr"):
        return []
    try:
        blob = os.getxattr(path, ACCESS_LIST, follow_symlinks=False)
    except OSError:
        return []
    return [struct.unpack_from("<HHI", blob, offset) for offset in range(4, len(blob) - 7, 8)]
def writers(path, info, on_the_way):
    if info.st_uid not in users:
        return "owned by %s, who can change its mode" % uid_name(info.st_uid)
    mode = stat.S_IMODE(info.st_mode)
    if mode & 0o002 and not (on_the_way and mode & stat.S_ISVTX):
        return "writable by everyone (mode %o)" % mode
    if mode & 0o020 and not group_trusted(info.st_gid):
        return "writable by the group %s (mode %o), which has other members" % (gid_name(info.st_gid), mode)
    listed = entries(path)
    mask = next((perm for tag, perm, _ in listed if tag == MASK), 7)
    for tag, perm, number in listed:
        if perm & mask & 0o2:
            if tag == USER and number not in users:
                return "an access list entry gives %s write" % uid_name(number)
            if tag == GROUP and not group_trusted(number):
                return "an access list entry gives the group %s write" % gid_name(number)
    return None
problems = []
try:
    real = os.path.realpath(folder)
    parts = [part for part in real.split("/") if part]
    path = "/"
    for index in range(len(parts) + 1):
        if index:
            path = os.path.join(path, parts[index - 1])
        info = os.lstat(path)
        if stat.S_ISDIR(info.st_mode):
            reason = writers(path, info, index < len(parts))
            if reason:
                problems.append((path, reason))
    pending = [real]
    while pending:
        item = pending.pop()
        info = os.lstat(item)
        if stat.S_ISLNK(info.st_mode):
            target = os.path.realpath(item)
            if not (target + "/").startswith(real + "/"):
                problems.append((item, "a link to %s, outside the package" % target))
            continue
        reason = writers(item, info, False)
        if reason:
            problems.append((item, reason))
        if stat.S_ISDIR(info.st_mode):
            with os.scandir(item) as listing:
                pending.extend(entry.path for entry in listing)
except OSError as error:
    problems.append((error.filename or folder, "cannot be examined (%s)" % error.strerror))
except Exception as error:
    problems.append((folder, "cannot be examined (%s: %s)" % (type(error).__name__, error)))
seen, shown = set(), 0
for path, reason in problems:
    if path in seen:
        continue
    seen.add(path)
    if shown < 12:
        print("  %s: %s" % (path, reason))
    shown += 1
if shown > 12:
    print("  and %d more" % (shown - 12))
sys.exit(3 if problems else 0)
PY
}

# sirven_gate ENTRY KIND ARGUMENT...: ENTRY is this script's path below the package folder (install.sh, uninstall.sh, bin/sirven);
# KIND is install for an install, anything else for the rest. ROOT_DIR is this script's physical folder. as root on linux it
# either returns, having vetted the folder it will read its libraries from, or runs the kept copy instead, or refuses.
sirven_gate() {
  local entry="$1" kind="$2" owner="${SUDO_USER:-root}" kept="" output who dir real
  shift 2
  [ "$EUID" -eq 0 ] || return 0
  [ "$(/usr/bin/uname -s)" = Linux ] || return 0
  if [ ! -x /usr/bin/python3 ]; then
    printf 'error: refusing to run as root: there is no /usr/bin/python3 to check the code with, and the check does not use any other. nothing was changed.\n' >&2
    exit 2
  fi
  # tools under /usr/local (tailscale, cloudflared, bb) are found only if root alone controls the folder and every folder above
  # it, checked now with the same checker; they come after the system folders, and a folder that fails is left out and said so
  # (the physical path is vetted and the physical path is what goes on PATH: a link at /usr/local/bin that somebody can swap after
  # the check would otherwise be checked as one folder and searched as another)
  for dir in /usr/local/sbin /usr/local/bin; do
    [ -d "$dir" ] || continue
    real="$(cd -P "$dir" 2>/dev/null && pwd -P)" || real=""
    if [ -n "$real" ] && output="$(sirven_vet "$real" root 2>&1)"; then
      PATH="$PATH:$real"
    else
      printf 'warning: %s is not on root'"'"'s search path: somebody besides root can change it or something in it:\n%s\n' "$dir" "$output" >&2
    fi
  done
  export PATH
  who="any account other than root"
  [ "$owner" = root ] || who="any account other than root and $owner"
  if [ -f "$SIRVEN_KEPT/$entry" ]; then kept="$(cd -P "$SIRVEN_KEPT" && pwd -P)"; fi
  if [ -n "$kept" ] && [ "$ROOT_DIR" != "$kept" ]; then
    if [ "$kind" = install ] && sirven_vet "$ROOT_DIR" "$owner" >/dev/null 2>&1; then return 0; fi
    if output="$(sirven_vet "$kept" "$owner" 2>&1)"; then
      printf 'running the kept copy %s instead of %s: root runs the root-owned copy, not a folder an agent may have changed.\n' "$kept" "$ROOT_DIR" >&2
      exec "$BASH" "$kept/$entry" "$@"
    fi
    # the kept copy is not trusted (somebody loosened the state directory). the folder this was started from may still be:
    # an emergency command must not be refused for that, but it runs only if this folder passes the same check
    if sirven_vet "$ROOT_DIR" "$owner" >/dev/null 2>&1; then
      printf 'warning: the kept copy %s can be changed by %s, so it was not used; running %s, which only root and %s can write.\n%s\n' "$kept" "$who" "$ROOT_DIR" "$owner" "$output" >&2
      return 0
    fi
    printf 'error: refusing to run as root: the kept copy %s can be changed by %s, and so can %s:\n%s\nnothing was changed.\n' "$kept" "$who" "$ROOT_DIR" "$output" >&2
    exit 2
  fi
  if ! output="$(sirven_vet "$ROOT_DIR" "$owner" 2>&1)"; then
    printf 'error: refusing to run as root from %s: %s can change the code there, and it would run as root:\n%s\n' "$ROOT_DIR" "$who" "$output" >&2
    printf 'there is no kept copy to run instead. run it from a folder only %s can write, or, once installed, with the root command that install prints (it is the launcher when its folder is safe, and the kept copy otherwise).\nnothing was changed.\n' "${owner}" >&2
    exit 2
  fi
}
# ---- root gate: end

# the physical folder of this script, resolved once; every library is read through it (a link swapped in later changes nothing)
ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = revoke ]; then sirven_gate install.sh revoke "$@"; else sirven_gate install.sh install "$@"; fi
fi

# shellcheck source=lib/common.sh
. "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/plan.sh
. "$ROOT_DIR/lib/plan.sh"
# shellcheck source=lib/preflight.sh
. "$ROOT_DIR/lib/preflight.sh"
# shellcheck source=lib/layout.sh
. "$ROOT_DIR/lib/layout.sh"
# shellcheck source=lib/audit.sh
. "$ROOT_DIR/lib/audit.sh"
# shellcheck source=lib/service_user.sh
. "$ROOT_DIR/lib/service_user.sh"
# shellcheck source=lib/access_control.sh
. "$ROOT_DIR/lib/access_control.sh"
# shellcheck source=lib/tailscale.sh
. "$ROOT_DIR/lib/tailscale.sh"
# shellcheck source=lib/cloudflare.sh
. "$ROOT_DIR/lib/cloudflare.sh"
# shellcheck source=lib/kill_switch.sh
. "$ROOT_DIR/lib/kill_switch.sh"
# shellcheck source=lib/lock.sh
. "$ROOT_DIR/lib/lock.sh"
# shellcheck source=lib/questions.sh
. "$ROOT_DIR/lib/questions.sh"
# shellcheck source=lib/adopt.sh
. "$ROOT_DIR/lib/adopt.sh"

WITH_BB_REASON="--with-bb is plan only in the alpha cut; the orca install is not specified yet"

usage() {
  cat <<END
usage:
  ./install.sh [options]              set up agent access
  $(layout_root_command revoke) [options]
                                      the kill switch: cut the agent off now, keep the records

setup asks at most two questions, the level and the path, each with its default shown. a flag
or environment variable answers a question ahead of time. with --yes, or with no terminal to
ask on, nothing is asked: the level is observer and no path is granted.

what is already on the machine is adopted, never reinstalled or overwritten: a Tailscale login,
a bb install, and the grant, policy, and audit log of an earlier run. with a grant in force, a
level or path left open is taken from it. when what is there conflicts with the request, the
run stops before any change and says what to do.

options:
  --dry-run                  print the plan and change nothing
  --yes, --defaults          ask nothing; use the defaults for anything not given
  --prefix PATH              fake the filesystem root: every path the plan touches goes under
                             PATH, and commands that need root are recorded, not run
  --level LEVEL              observer (default), builder, or operator. see levels/
  --path PATH                grant the level on this absolute path. repeat for more paths.
                             asked default: the current folder when it can be granted
  --transport NAME           tailscale (default), cloudflare, or none
  --with-bb                  add the bb install note to the plan (plan only for now)
  --reinstate                turn an account the kill switch cut off back on (unlock, no expiry, the
                             /bin/bash shell) and go on with the install. without it, install refuses
  --user NAME                service user name (default: agent)
  --owner NAME               owner account that holds the audit log (default: you)
  --help                     show this help

environment:
  SIRVEN_LEVEL               the level, as --level
  SIRVEN_PATH                paths to grant, separated by colons, or none
  SIRVEN_YES=1               as --yes
  SIRVEN_INTERACTIVE=no      never ask; yes asks on standard input even when it is a pipe

examples:
  ./install.sh --dry-run
  ./install.sh --dry-run --level builder --path /home/you/code/app
  SIRVEN_LEVEL=builder SIRVEN_PATH=/srv/app ./install.sh --yes --dry-run
  ./install.sh --dry-run --prefix /tmp/fake-root --level observer --path /srv/app --transport none
  $(layout_root_command revoke) --dry-run

nothing is applied to a real machine in the alpha cut, except inside a linux container as root, and
revoke --all, which only takes access away and also runs on a real linux machine as root. a real revoke asks
you to type "revoke" first; --yes skips the question.
END
}

usage_error() {
  printf 'error: %s\n' "$1" >&2
  printf 'run ./install.sh --help for usage.\n' >&2
  exit 64
}

# needs_value FLAG COUNT NEXT: a flag that takes a value must have one, and not another flag.
needs_value() {
  [ "$2" -ge 2 ] || usage_error "$1 needs a value"
  case "${3:-}" in
    --*) usage_error "$1 needs a value" ;;
  esac
}

parse_arguments() {
  COMMAND=install
  DRY_RUN=no
  PREFIX=""
  LEVEL=""
  GRANT_PATHS=()
  PATHS_GIVEN=no
  ASSUME_YES=no
  TRANSPORT=tailscale
  WITH_BB=no
  SERVICE_USER=agent
  OWNER="${SUDO_USER:-$(id -un)}"
  REVOKE_ALL=no
  REINSTATE=no

  if [ "$#" -gt 0 ] && [ "$1" = revoke ]; then
    COMMAND=revoke
    shift
  fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=yes ;;
      --yes | --defaults | -y) ASSUME_YES=yes ;;
      --prefix) needs_value "$1" "$#" "${2:-}"; PREFIX="$2"; shift ;;
      --prefix=*) PREFIX="${1#*=}" ;;
      --level) needs_value "$1" "$#" "${2:-}"; LEVEL="$2"; shift ;;
      --level=*) LEVEL="${1#*=}" ;;
      --path) needs_value "$1" "$#" "${2:-}"; GRANT_PATHS[${#GRANT_PATHS[@]}]="$2"; PATHS_GIVEN=yes; shift ;;
      --path=*) GRANT_PATHS[${#GRANT_PATHS[@]}]="${1#*=}"; PATHS_GIVEN=yes ;;
      --transport) needs_value "$1" "$#" "${2:-}"; TRANSPORT="$2"; shift ;;
      --transport=*) TRANSPORT="${1#*=}" ;;
      --with-bb) WITH_BB=yes ;;
      --user) needs_value "$1" "$#" "${2:-}"; SERVICE_USER="$2"; shift ;;
      --user=*) SERVICE_USER="${1#*=}" ;;
      --owner) needs_value "$1" "$#" "${2:-}"; OWNER="$2"; shift ;;
      --owner=*) OWNER="${1#*=}" ;;
      --all) REVOKE_ALL=yes ;;
      --reinstate) REINSTATE=yes ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "unknown option '$1'" ;;
    esac
    shift
  done

  case "$LEVEL" in
    '' | observer | builder | operator) ;;
    *) usage_error "--level must be observer, builder, or operator, got '$LEVEL'" ;;
  esac
  case "$TRANSPORT" in
    tailscale | cloudflare | none) ;;
    *) usage_error "--transport must be tailscale, cloudflare, or none, got '$TRANSPORT'" ;;
  esac
  case "$SERVICE_USER" in
    [a-z_]*) ;;
    *) usage_error "--user must be a plain lowercase account name" ;;
  esac
  case "$SERVICE_USER" in
    *[!a-z0-9_-]*) usage_error "--user must be a plain lowercase account name" ;;
  esac
  case "$OWNER" in
    '' | *[!A-Za-z0-9._-]*) usage_error "--owner must be a plain account name" ;;
  esac
  if [ -n "$PREFIX" ]; then
    case "$PREFIX" in
      /*) ;;
      *) usage_error "--prefix must be an absolute path" ;;
    esac
    if ! checked_prefix="$(prefix_normalize "$PREFIX")"; then usage_error "$checked_prefix"; fi
    PREFIX="$checked_prefix"
  fi
  if [ "$COMMAND" = revoke ] && [ "$REVOKE_ALL" != yes ]; then
    usage_error "revoke needs --all; revoking one invite is designed, not built"
  fi
  if [ "$COMMAND" = revoke ] && [ "$REINSTATE" = yes ]; then
    usage_error "--reinstate only goes with install; the kill switch never turns an account back on"
  fi
  if [ "$COMMAND" = install ] && [ "$REVOKE_ALL" = yes ]; then
    usage_error "--all only goes with revoke"
  fi
  if [ -n "${SIRVEN_OS_OVERRIDE:-}" ] && [ "$DRY_RUN" != yes ] && [ -z "$PREFIX" ]; then
    usage_error "SIRVEN_OS_OVERRIDE only works with --dry-run or --prefix"
  fi
  adopt_check_seams
}

plan_header() {
  local mode="apply: the plan below is printed, then applied"
  [ "$DRY_RUN" = yes ] && mode="dry run: nothing will be changed"
  say "$PACKAGE $COMMAND plan"
  say "  operating system: $OPERATING_SYSTEM"
  if [ "$COMMAND" = install ]; then
    say "  level: $LEVEL (write allowed: $LEVEL_WRITE_ALLOWED)"
    say "  paths: $(setup_describe_paths)"
  fi
  say "  service user: $SERVICE_USER"
  say "  owner: $OWNER"
  say "  transport: $TRANSPORT"
  say "  prefix: ${PREFIX:-none, the real root}"
  say "  mode: $mode"
}

plan_with_bb() {
  plan_section "phone to agent channel"
  if [ "$ADOPT_BB" = installed ]; then
    plan_note "bb is already installed, adopted above: nothing to install."
    return 0
  fi
  plan_planonly "install bb for $SERVICE_USER" \
    "# no command yet. alpha relies on bb or the runtime's own remote mode, over the transport above." \
    "$WITH_BB_REASON"
  plan_tag always
}

build_install_plan() {
  plan_adopt
  plan_reinstate
  plan_layout
  plan_audit
  plan_service_user
  plan_access_control
  case "$TRANSPORT" in
    tailscale) plan_tailscale ;;
    cloudflare) plan_cloudflare ;;
    none)
      plan_section "transport: none"
      plan_note "no transport. the agent is reachable only from this machine or your own network."
      ;;
  esac
  if [ "$WITH_BB" = yes ]; then
    plan_with_bb
  fi
}

# kill_switch_audit_paths: the paths the kill switch removed, as a JSON array for the audit log.
kill_switch_audit_paths() {
  local index=0 paths=""
  while [ "$index" -lt "${#KILL_SWITCH_REVOKE_PATHS[@]}" ]; do
    paths="${paths:+$paths, }$(audit_json_string "${KILL_SWITCH_REVOKE_PATHS[index]}")"
    index=$((index + 1))
  done
  printf '[%s]' "$paths"
}

# apply the plan, writing the install record and the audit log as it goes. the kill switch writes
# revoke_started before its first step and revoke_finished after its last, also when a step failed.
apply_for_real() {
  local status=0 record before
  PLAN_RECORD_FILE="${PREFIX}$(layout_record_file)"
  PLAN_STEP_HOOK=audit_step_hook
  if [ "$COMMAND" = revoke ]; then PLAN_RECHECK=yes; fi
  AUDIT_OPERATION="$COMMAND"
  AUDIT_PENDING="$STAGE_DIR/audit-pending.jsonl"
  record="${PREFIX}$(access_control_record_file)"
  before="$STAGE_DIR/grant-before.json"
  if [ -f "$record" ]; then cp "$record" "$before"; fi
  if [ "$COMMAND" = revoke ] && [ -z "$(plan_blockers)" ]; then
    audit_write "$(audit_entry revoke_started "operation=revoke")"
  fi
  if [ "$COMMAND" = install ] && [ "$REINSTATE" = yes ] && kill_switch_account_cut_off "$SERVICE_USER"; then
    audit_write "$(audit_entry reinstate "operation=install" "message=$SERVICE_USER was cut off by the kill switch (expired, shell $KILL_SWITCH_NOLOGIN); --reinstate turns it back on")"
  fi
  plan_apply || status=$?
  if [ "$status" -eq 4 ]; then
    if [ "$COMMAND" = revoke ]; then kill_switch_report_failure; else access_control_report_locked_account; fi
  fi
  if [ "$status" -ne 3 ]; then
    if [ "$COMMAND" = revoke ]; then
      if [ "$status" -eq 0 ]; then
        audit_write "$(audit_entry revoke_finished "operation=revoke" "outcome=finished" "json:paths=$(kill_switch_audit_paths)")"
      else
        audit_write "$(audit_entry revoke_finished "operation=revoke" "outcome=failed" "json:exit_status=$status" "json:paths=$(kill_switch_audit_paths)")"
      fi
    else
      adopt_audit_entries
      audit_grant_change "$before" "$record" install
      if [ "$status" -eq 0 ]; then
        audit_write "$(audit_entry "$COMMAND" "operation=$COMMAND" "level=$LEVEL" "outcome=finished")"
      else
        audit_write "$(audit_entry "$COMMAND" "operation=$COMMAND" "level=$LEVEL" "outcome=failed" "json:exit_status=$status")"
      fi
    fi
  fi
  audit_flush
  return "$status"
}

# build_plan: the plan for the parsed command, not yet evaluated.
build_plan() {
  load_level
  plan_reset
  if [ "$COMMAND" = revoke ]; then
    plan_kill_switch
  else
    build_install_plan
  fi
}

finish() {
  local status=0
  plan_print
  plan_summary
  if [ "$DRY_RUN" = yes ]; then
    say "dry run: nothing was changed. run the same command without --dry-run to apply this plan."
    if [ -n "$(plan_blockers)" ]; then
      say "applying would stop before any change: the plan has plan-only steps the alpha cut does not apply yet."
    fi
    if [ "$COMMAND" = install ]; then
      say "to cut the agent off later: $(layout_root_command revoke) --dry-run to read the plan; to remove everything: $(layout_root_command uninstall) --dry-run"
    fi
    return 0
  fi
  if [ "$COMMAND" = revoke ]; then
    kill_switch_confirm
    lock_take 10 go_on
  else
    lock_take 60 refuse
    # a revoke may have finished while this run waited for the lock, and the plan above was made before it
    if [ "$COMMAND" = install ] && [ "$REINSTATE" != yes ] && kill_switch_account_cut_off "$SERVICE_USER"; then
      DIE_STATUS=2 die "the kill switch cut $SERVICE_USER off while this run waited for the lock, and the plan above was made before that. nothing was changed. to bring the account back on purpose, run it again with --reinstate."
    fi
  fi
  apply_for_real || status=$?
  return "$status"
}

main() {
  parse_arguments "$@"
  setup_from_environment
  OPERATING_SYSTEM="$(detect_os)"
  PACKAGE="$(package_name "$ROOT_DIR/project.json")"
  layout_set_directories

  local strict=yes refusal
  if [ "$DRY_RUN" = yes ] || [ -n "$PREFIX" ]; then
    strict=no
  fi
  if [ "$DRY_RUN" != yes ]; then
    PLAN_PREFIX="$PREFIX"
    PLAN_OPERATING_SYSTEM="$OPERATING_SYSTEM"
    # the kill switch only takes access away, so it runs on a real linux machine too, not only in a container
    if [ "$COMMAND" = revoke ]; then PLAN_ALLOW_REAL_LINUX=yes; fi
    refusal="$(plan_real_apply_refusal)"
    [ -z "$refusal" ] || DIE_STATUS=3 die "not applied: $refusal"
  fi
  if [ "$COMMAND" = revoke ]; then
    kill_switch_refuse_unsafe_user
    # the kill switch needs no transport tool and no SSH probe: it must work on a machine where
    # tailscale is gone or never was, and it must not stop on something it does not use.
    preflight_revoke "$OPERATING_SYSTEM" "$strict"
  else
    preflight_all "$OPERATING_SYSTEM" "$TRANSPORT" "$strict"
  fi

  # what is already here comes first: a grant in force answers the questions it can.
  if [ "$COMMAND" = install ]; then
    adopt_detect
    adopt_fill_answers
  fi

  # the questions come before the plan is built, so the plan shows the answers.
  setup_questions

  STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/$PACKAGE-plan.XXXXXX")"
  trap 'rm -rf "$STAGE_DIR"' EXIT

  adopt_refuse_conflicts

  PLAN_PREFIX="$PREFIX"
  PLAN_OPERATING_SYSTEM="$OPERATING_SYSTEM"
  PLAN_SIMULATION_LOG=""
  if [ -n "$PREFIX" ]; then
    PLAN_SIMULATION_LOG="$PREFIX$(layout_simulation_log)"
  fi

  build_plan
  plan_evaluate
  plan_header
  finish
}

# run main only when executed, so tests can source this file and build plans themselves.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
