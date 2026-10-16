#!/usr/bin/env bash
# uninstall.sh: reverse what install.sh created on this machine, plan first.
#
# the plan comes from the install record in the state directory, not from guessing: install.sh
# appends one undo for every step it really applied, and this script reverses those steps in
# reverse order. a step install.sh found already done was not created by it, so it is not in
# the record and nothing here touches it. directories are removed only when empty.
#
# --dry-run prints the removal plan and changes nothing; without it the identical plan is
# printed and then applied. the audit log is kept unless --remove-audit-log is given.
# runs on macos bash 3.2 and on linux bash. python3 is used only to remove the agent's key files and ssh folder
# without following a link the agent planted (lib/kill_switch.py).

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
import grp, os, pwd, re, stat, struct, sys
folder, owner = sys.argv[1], sys.argv[2]
ACCESS_LIST, USER, GROUP, MASK = "system.posix_acl_access", 0x02, 0x08, 0x10
LOGIN_DEFS, SHADOW = "/etc/login.defs", "/etc/shadow"
NO_SHELL = ("/sbin/nologin", "/usr/sbin/nologin", "/bin/false", "/usr/bin/false")
users = {0}
try:
    users.add(pwd.getpwnam(owner).pw_uid)
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
def system_limit():  # the first ordinary user number: UID_MIN of the login definitions, 1000 when they do not say
    try:
        with open(LOGIN_DEFS) as handle:
            found = re.search(r"^[ \t]*UID_MIN[ \t]+([0-9]+)[ \t]*(#.*)?$", handle.read(), re.M)
        return int(found.group(1)) if found else 1000
    except (OSError, ValueError):
        return 1000
def locked_names():  # accounts whose password cannot be typed: the password field starts with ! or *. read by hand (spwd is gone from Python 3.13)
    found = set()
    try:
        with open(SHADOW) as handle:
            for line in handle:
                fields = line.split(":")
                if len(fields) > 1 and fields[1][:1] in ("!", "*"):
                    found.add(fields[0])
    except (OSError, ValueError):
        pass
    return found
def harmless(name, gid, limit, locked):
    # root and the owner are trusted. in group root (number 0) so is a system account (a user number below the first ordinary one)
    # that cannot log in or be used to write: its shell is nologin or false, or its password is locked. every other member is an outsider.
    try:
        entry = pwd.getpwnam(name)
    except KeyError:
        return False
    if entry.pw_uid in users:
        return True
    return gid == 0 and entry.pw_uid < limit and (entry.pw_shell in NO_SHELL or name in locked)
def outsiders(gid):  # the members of group gid who could still change what the group can write, by name
    try:
        members = set(grp.getgrgid(gid).gr_mem)
    except KeyError:
        if gid != 0:
            return ["(the members of group number %d are unknown)" % gid]
        members = set()
    members.update(entry.pw_name for entry in pwd.getpwall() if entry.pw_gid == gid)
    limit, locked = system_limit(), locked_names()
    return sorted(name for name in members if not harmless(name, gid, limit, locked))
def group_trusted(gid):
    return not outsiders(gid)
def entries(path):
    if not hasattr(os, "getxattr"):
        return []
    try:
        blob = os.getxattr(path, ACCESS_LIST, follow_symlinks=False)
    except OSError:
        return []
    return [struct.unpack_from("<HHI", blob, offset) for offset in range(4, len(blob) - 7, 8)]
def writers(path, info, sticky_parent):
    # sticky_parent: this folder is on the way to the package, sticky and open to everyone (like /tmp), and the folder below it is
    # judged with no such allowance. the sticky bit stops anyone but the owner of an entry from renaming or replacing it, so the
    # open bit and the group bit (both only let others add entries) cannot change what is already there. never true for the package
    # folder or anything inside it.
    if info.st_uid not in users:
        return "owned by %s, who can change its mode" % uid_name(info.st_uid)
    mode = stat.S_IMODE(info.st_mode)
    if mode & 0o002 and not sticky_parent:
        return "writable by everyone (mode %o)" % mode
    if mode & 0o020 and not sticky_parent:
        others = outsiders(info.st_gid)
        if others:
            return "writable by the group %s (mode %o), which has other members: %s" % (gid_name(info.st_gid), mode, ", ".join(others))
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
    allowed = False  # the folder above was let through as a sticky parent: this one gets no such allowance
    for index in range(len(parts) + 1):
        if index:
            path = os.path.join(path, parts[index - 1])
        info = os.lstat(path)
        if stat.S_ISDIR(info.st_mode):
            sticky = (index < len(parts) and not allowed and info.st_mode & stat.S_ISVTX and info.st_mode & 0o002
                      and info.st_uid in users)
            reason = writers(path, info, bool(sticky))
            allowed = bool(sticky) and not reason
            if reason:
                problems.append((path, reason))
        else:
            allowed = False
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
if [ "${BASH_SOURCE[0]}" = "$0" ]; then sirven_gate uninstall.sh uninstall "$@"; fi

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
# shellcheck source=lib/lock.sh
. "$ROOT_DIR/lib/lock.sh"
# shellcheck source=lib/tailscale.sh
. "$ROOT_DIR/lib/tailscale.sh"

usage() {
  cat <<END
usage:
  ./uninstall.sh [options]    remove what install.sh created, in reverse order

options:
  --dry-run              print the removal plan and change nothing
  --yes, -y              on a real machine, apply without asking you to type yes (or SIRVEN_YES=1)
  --prefix PATH          the fake root an install was applied to with --prefix
  --remove-audit-log     also remove the audit log and its directory. kept by default
  --help                 show this help

only steps recorded in the install record are reversed. the service user's home folder is
kept, with whatever the agent left in it. to cut access now without removing anything, use
the kill switch: $(layout_root_command revoke) (--dry-run reads the plan first)

examples:
  ./uninstall.sh --dry-run
  ./uninstall.sh --dry-run --prefix /tmp/fake-root
END
}

usage_error() {
  printf 'error: %s\n' "$1" >&2
  printf 'run ./uninstall.sh --help for usage.\n' >&2
  exit 64
}

parse_arguments() {
  DRY_RUN=no
  ASSUME_YES=no
  PREFIX=""
  REMOVE_AUDIT_LOG=no
  SERVICE_USER=agent
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=yes ;;
      --yes | -y) ASSUME_YES=yes ;;
      --prefix)
        [ "$#" -ge 2 ] || usage_error "--prefix needs a value"
        case "$2" in --*) usage_error "--prefix needs a value" ;; esac
        PREFIX="$2"
        shift
        ;;
      --prefix=*) PREFIX="${1#*=}" ;;
      --remove-audit-log) REMOVE_AUDIT_LOG=yes ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "unknown option '$1'" ;;
    esac
    shift
  done
  if [ -n "$PREFIX" ]; then
    case "$PREFIX" in
      /*) ;;
      *) usage_error "--prefix must be an absolute path" ;;
    esac
    if ! checked_prefix="$(prefix_normalize "$PREFIX")"; then usage_error "$checked_prefix"; fi
    PREFIX="$checked_prefix"
  fi
  if [ -n "${SIRVEN_OS_OVERRIDE:-}" ] && [ "$DRY_RUN" != yes ] && [ -z "$PREFIX" ]; then
    usage_error "SIRVEN_OS_OVERRIDE only works with --dry-run or --prefix"
  fi
}

# the record is run as root on a real machine, so it must belong to root and be writable by
# root alone. a fake root is the owner's own folder, so the check is skipped there.
check_record_ownership() {
  local listing mode owner
  [ -z "$PREFIX" ] || return 0
  # ls shows the owner and mode the same way on linux and macos, unlike stat
  # shellcheck disable=SC2012
  listing="$(ls -ln "$RECORD_FILE")"
  mode="$(printf '%s' "$listing" | cut -c1-10)"
  owner="$(printf '%s' "$listing" | awk '{print $3}')"
  if [ "$owner" != 0 ]; then
    DIE_STATUS=2 die "the install record $RECORD_FILE does not belong to root; nothing was changed"
  fi
  case "$mode" in
    ?????w???? | ????????w?) DIE_STATUS=2 die "the install record $RECORD_FILE can be changed by other accounts; nothing was changed" ;;
  esac
}

_unfield() {
  if [ "$1" = - ]; then printf ''; else printf '%s' "$1"; fi
}

# read the install record into RECORD_* arrays, refusing a damaged line.
read_record() {
  local tab kind tag section undo_title undo_check undo_action undo_shown line_number=0
  tab="$(printf '\t')"
  RECORD_COUNT=0
  RECORD_KIND=()
  RECORD_TAG=()
  RECORD_SECTION=()
  RECORD_UNDO_TITLE=()
  RECORD_UNDO_CHECK=()
  RECORD_UNDO_ACTION=()
  RECORD_UNDO_SHOWN=()
  RECORD_HAS_STATE=no
  while IFS="$tab" read -r kind tag section _ undo_title undo_check undo_action undo_shown; do
    line_number=$((line_number + 1))
    [ -n "$kind" ] || continue
    case "$kind" in
      run | system | owner) ;;
      *) DIE_STATUS=2 die "install record line $line_number has an unknown kind '$kind'; nothing was changed" ;;
    esac
    if [ -z "$undo_shown" ] || [ "$undo_title" = - ]; then
      DIE_STATUS=2 die "install record line $line_number is damaged; nothing was changed"
    fi
    if [ "$kind" != owner ] && [ "$undo_action" = - ]; then
      DIE_STATUS=2 die "install record line $line_number has no undo command; nothing was changed"
    fi
    RECORD_KIND[RECORD_COUNT]="$kind"
    RECORD_TAG[RECORD_COUNT]="$(_unfield "$tag")"
    RECORD_SECTION[RECORD_COUNT]="$(_unfield "$section")"
    RECORD_UNDO_TITLE[RECORD_COUNT]="$undo_title"
    RECORD_UNDO_CHECK[RECORD_COUNT]="$(_unfield "$undo_check")"
    RECORD_UNDO_ACTION[RECORD_COUNT]="$(_unfield "$undo_action")"
    RECORD_UNDO_SHOWN[RECORD_COUNT]="$(_unfield "$undo_shown")"
    if [ "$(_unfield "$tag")" = state ]; then RECORD_HAS_STATE=yes; fi
    RECORD_COUNT=$((RECORD_COUNT + 1))
  done < "$RECORD_FILE"
}

# plan_uninstall_tailscale_leftovers: log out a node the join left behind, whether or not the install record has an undo line for it.
# a join that logs in but does not reach Running writes its record file and then fails, and a failed step is never added to the
# install record, so the record can be silent about a node that is logged in. the record file of the join is the evidence, and
# the script logs out only the node it names, and only while this machine's login is still that node.
# it comes first in the plan, so it is undone first, like the last thing applied.
plan_uninstall_tailscale_leftovers() {
  local marker state_dir index script
  marker="$(rooted "$(tailscale_marker_file)")"
  state_dir="$(rooted "$STATE_DIR")"
  # nothing to do unless the join's record or a stale copy of its key is there
  if [ ! -e "$marker" ] && [ ! -L "$marker" ] && ! compgen -G "$state_dir/.tailscale-key.*" >/dev/null; then
    return 0
  fi
  # the install record already undoes it: that line logs out, and one logout is enough
  index=0
  while [ "$index" -lt "$RECORD_COUNT" ]; do
    case "${RECORD_UNDO_ACTION[index]}" in *tailscale_node.sh\ leave*) return 0 ;; esac
    index=$((index + 1))
  done
  script="$(printf '%q' "$ROOT_DIR/lib/tailscale_node.sh")"
  plan_section "undo: tailscale join left behind"
  plan_step system "log this machine out of the tailnet: the node a join left behind, and only it" \
    "[ ! -e $marker ] && ! compgen -G \"$state_dir/.tailscale-key.*\" >/dev/null" \
    "bash $script leave $marker" \
    "tailscale logout   # via lib/tailscale_node.sh leave, only when this machine's login is still the node recorded in $(tailscale_marker_file); also removes any copy of the auth key a killed join left"
}

build_uninstall_plan() {
  local index=$((RECORD_COUNT - 1)) section last="" record
  record="$(rooted "$(layout_record_file)")"
  plan_uninstall_tailscale_leftovers
  while [ "$index" -ge 0 ]; do
    section="${RECORD_SECTION[index]}"
    if [ "$section" != "$last" ]; then
      plan_section "undo: ${section:-steps}"
      last="$section"
    fi
    if [ "${RECORD_TAG[index]}" = audit ] && [ "$REMOVE_AUDIT_LOG" != yes ]; then
      plan_note "kept, not reversed: ${RECORD_UNDO_TITLE[index]}. add --remove-audit-log to remove it too."
    elif [ "${RECORD_KIND[index]}" = owner ]; then
      plan_owner "${RECORD_UNDO_TITLE[index]}" "${RECORD_UNDO_SHOWN[index]}"
    else
      plan_step "${RECORD_KIND[index]}" "${RECORD_UNDO_TITLE[index]}" "${RECORD_UNDO_CHECK[index]}" \
        "${RECORD_UNDO_ACTION[index]}" "${RECORD_UNDO_SHOWN[index]}"
    fi
    index=$((index - 1))
  done
  if [ "$RECORD_HAS_STATE" != yes ]; then
    plan_section "undo: install record"
    plan_note "the state directory $STATE_DIR was there before the install, so it stays."
    plan_step run "remove the install record" "[ ! -e $record ]" "rm -f $record"
  fi
}

plan_header() {
  local mode="apply: the plan below is printed, then applied" audit="kept"
  [ "$DRY_RUN" = yes ] && mode="dry run: nothing will be changed"
  [ "$REMOVE_AUDIT_LOG" = yes ] && audit="removed"
  say "$PACKAGE uninstall plan"
  say "  operating system: $OPERATING_SYSTEM"
  if [ -f "$RECORD_FILE" ]; then
    say "  install record: $(layout_record_file), $RECORD_COUNT steps this package created"
  else
    say "  install record: $(layout_record_file), not found"
  fi
  say "  audit log: $audit"
  say "  prefix: ${PREFIX:-none, the real root}"
  say "  mode: $mode"
}

apply_for_real() {
  local status=0
  if [ "$REMOVE_AUDIT_LOG" != yes ]; then
    PLAN_STEP_HOOK=audit_step_hook
    AUDIT_OPERATION=uninstall
    AUDIT_PENDING="$STAGE_DIR/audit-pending.jsonl"
  fi
  plan_apply || status=$?
  if [ "$status" -eq 4 ]; then
    printf 'if the step that ends the agent processes already ran, the account %s is locked and expired until uninstall finishes.\n' "$SERVICE_USER" >&2
    printf 'fix the cause printed above and run uninstall.sh again: it continues where it stopped and removes the account at the end.\n' >&2
  fi
  if [ "$REMOVE_AUDIT_LOG" != yes ] && [ "$status" -ne 3 ]; then
    if [ "$status" -eq 0 ]; then
      audit_write "$(audit_entry uninstall "operation=uninstall" "outcome=finished")"
    else
      audit_write "$(audit_entry uninstall "operation=uninstall" "outcome=failed" "json:exit_status=$status")"
    fi
    audit_flush
  fi
  if [ "$status" -eq 0 ]; then
    say "kept on purpose: the service user's home folder, and anything this package did not create."
  fi
  return "$status"
}

finish() {
  plan_print
  plan_summary
  if [ "$DRY_RUN" = yes ]; then
    say "dry run: nothing was changed. run the same command without --dry-run to apply this plan."
    return 0
  fi
  lock_take 60 refuse
  apply_for_real
}

main() {
  # first, before anything starts a process: removal never needs the Tailscale auth key, so it leaves the exported environment
  # and is dropped (see lib/tailscale.sh). the dirname above still starts with the caller's variables, as install.sh's does.
  tailscale_hold_key
  tailscale_forget_held_key
  parse_arguments "$@"
  OPERATING_SYSTEM="$(detect_os)"
  PACKAGE="$(package_name "$ROOT_DIR/project.json")"
  layout_set_directories
  RECORD_FILE="${PREFIX}$(layout_record_file)"

  local strict=yes refusal
  if [ "$DRY_RUN" = yes ] || [ -n "$PREFIX" ]; then
    strict=no
  fi
  PLAN_PREFIX="$PREFIX"
  PLAN_OPERATING_SYSTEM="$OPERATING_SYSTEM"
  if [ "$DRY_RUN" != yes ]; then
    refusal="$(plan_real_apply_refusal)"
    [ -z "$refusal" ] || DIE_STATUS=3 die "not applied: $refusal"
  fi
  preflight_bash
  preflight_commands yes rm rmdir grep cut awk python3
  case "$OPERATING_SYSTEM" in
    linux) preflight_commands "$strict" userdel pkill setfacl getfacl ;;
    macos) preflight_commands "$strict" dscl pkill python3 ;;
  esac
  if [ "$PREFLIGHT_PROBLEMS" -gt 0 ]; then
    die "preflight found $PREFLIGHT_PROBLEMS problem(s); nothing was changed"
  fi

  if [ ! -f "$RECORD_FILE" ]; then
    RECORD_COUNT=0
    plan_header
    say ""
    say "no install record at $RECORD_FILE."
    say "this package has applied nothing here that it recorded, so there is nothing it may remove."
    return 0
  fi
  check_record_ownership

  STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/$PACKAGE-uninstall.XXXXXX")"
  trap 'rm -rf "$STAGE_DIR"' EXIT
  PLAN_SIMULATION_LOG=""
  if [ -n "$PREFIX" ]; then
    PLAN_SIMULATION_LOG="$PREFIX$(layout_simulation_log)"
  fi

  read_record
  plan_reset
  build_uninstall_plan
  plan_evaluate
  plan_header
  finish
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
