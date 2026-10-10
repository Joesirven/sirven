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
# runs on macos bash 3.2 and on linux bash. needs no python.

# stop early, and readably, when started by sh or zsh instead of bash.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "error: run this with bash, for example: bash $0" >&2
  exit 1
fi

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

usage() {
  cat <<END
usage:
  ./uninstall.sh [options]    remove what install.sh created, in reverse order

options:
  --dry-run              print the removal plan and change nothing
  --prefix PATH          the fake root an install was applied to with --prefix
  --remove-audit-log     also remove the audit log and its directory. kept by default
  --help                 show this help

only steps recorded in the install record are reversed. the service user's home folder is
kept, with whatever the agent left in it. to cut access now without removing anything, use
the kill switch: ./install.sh revoke --all --dry-run

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
  COMMAND=uninstall
  DRY_RUN=no
  PREFIX=""
  REMOVE_AUDIT_LOG=no
  SERVICE_USER=agent
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=yes ;;
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
    PREFIX="${PREFIX%/}"
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

build_uninstall_plan() {
  local index=$((RECORD_COUNT - 1)) section last="" record
  record="$(rooted "$(layout_record_file)")"
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
  apply_for_real
}

main() {
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
  preflight_commands yes rm rmdir grep cut awk
  case "$OPERATING_SYSTEM" in
    linux) preflight_commands "$strict" userdel pkill setfacl getfacl ;;
    macos) preflight_commands "$strict" dscl pkill ;;
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
