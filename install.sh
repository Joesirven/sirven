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

WITH_BB_REASON="--with-bb is plan only in the alpha cut; the orca install is not specified yet"

usage() {
  cat <<END
usage:
  ./install.sh [options]              set up agent access
  ./install.sh revoke --all [options] the kill switch: revoke everything

options:
  --dry-run                  print the plan and change nothing
  --prefix PATH              fake the filesystem root: every path the plan touches goes under
                             PATH, and commands that need root are recorded, not run
  --level LEVEL              observer (default), builder, or operator. see levels/
  --path PATH                grant the level on this absolute path. repeat for more paths
  --transport NAME           tailscale (default), cloudflare, or none
  --with-bb                  add the bb install note to the plan (plan only for now)
  --user NAME                service user name (default: agent)
  --owner NAME               owner account that holds the audit log (default: you)
  --help                     show this help

examples:
  ./install.sh --dry-run --level builder --path /home/you/code/app
  ./install.sh --dry-run --prefix /tmp/fake-root --level observer --path /srv/app --transport none
  ./install.sh revoke --all --dry-run

nothing is applied to a real machine in the alpha cut, except inside a linux container as root.
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
  LEVEL=observer
  GRANT_PATHS=()
  TRANSPORT=tailscale
  WITH_BB=no
  SERVICE_USER=agent
  OWNER="${SUDO_USER:-$(id -un)}"
  REVOKE_ALL=no

  if [ "$#" -gt 0 ] && [ "$1" = revoke ]; then
    COMMAND=revoke
    shift
  fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=yes ;;
      --prefix) needs_value "$1" "$#" "${2:-}"; PREFIX="$2"; shift ;;
      --prefix=*) PREFIX="${1#*=}" ;;
      --level) needs_value "$1" "$#" "${2:-}"; LEVEL="$2"; shift ;;
      --level=*) LEVEL="${1#*=}" ;;
      --path) needs_value "$1" "$#" "${2:-}"; GRANT_PATHS[${#GRANT_PATHS[@]}]="$2"; shift ;;
      --path=*) GRANT_PATHS[${#GRANT_PATHS[@]}]="${1#*=}" ;;
      --transport) needs_value "$1" "$#" "${2:-}"; TRANSPORT="$2"; shift ;;
      --transport=*) TRANSPORT="${1#*=}" ;;
      --with-bb) WITH_BB=yes ;;
      --user) needs_value "$1" "$#" "${2:-}"; SERVICE_USER="$2"; shift ;;
      --user=*) SERVICE_USER="${1#*=}" ;;
      --owner) needs_value "$1" "$#" "${2:-}"; OWNER="$2"; shift ;;
      --owner=*) OWNER="${1#*=}" ;;
      --all) REVOKE_ALL=yes ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "unknown option '$1'" ;;
    esac
    shift
  done

  case "$LEVEL" in
    observer | builder | operator) ;;
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
    PREFIX="${PREFIX%/}"
  fi
  if [ "$COMMAND" = revoke ] && [ "$REVOKE_ALL" != yes ]; then
    usage_error "revoke needs --all; revoking one invite is designed, not built"
  fi
  if [ "$COMMAND" = install ] && [ "$REVOKE_ALL" = yes ]; then
    usage_error "--all only goes with revoke"
  fi
  if [ -n "${SIRVEN_OS_OVERRIDE:-}" ] && [ "$DRY_RUN" != yes ] && [ -z "$PREFIX" ]; then
    usage_error "SIRVEN_OS_OVERRIDE only works with --dry-run or --prefix"
  fi
}

plan_header() {
  local mode="apply: the plan below is printed, then applied"
  [ "$DRY_RUN" = yes ] && mode="dry run: nothing will be changed"
  say "$PACKAGE $COMMAND plan"
  say "  operating system: $OPERATING_SYSTEM"
  if [ "$COMMAND" = install ]; then
    say "  level: $LEVEL (write allowed: $LEVEL_WRITE_ALLOWED)"
  fi
  say "  service user: $SERVICE_USER"
  say "  owner: $OWNER"
  say "  transport: $TRANSPORT"
  say "  prefix: ${PREFIX:-none, the real root}"
  say "  mode: $mode"
}

plan_with_bb() {
  plan_section "phone to agent channel"
  plan_planonly "install bb for $SERVICE_USER" \
    "# no command yet. alpha relies on bb or the runtime's own remote mode, over the transport above." \
    "$WITH_BB_REASON"
  plan_tag always
}

build_install_plan() {
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

# apply the plan, writing the install record and the audit log as it goes.
apply_for_real() {
  local status=0 record before
  PLAN_RECORD_FILE="${PREFIX}$(layout_record_file)"
  PLAN_STEP_HOOK=audit_step_hook
  AUDIT_OPERATION="$COMMAND"
  AUDIT_PENDING="$STAGE_DIR/audit-pending.jsonl"
  record="${PREFIX}$(access_control_record_file)"
  before="$STAGE_DIR/grant-before.json"
  if [ -f "$record" ]; then cp "$record" "$before"; fi
  plan_apply || status=$?
  if [ "$status" -ne 3 ]; then
    if [ "$COMMAND" = install ]; then
      audit_grant_change "$before" "$record" install
    fi
    if [ "$status" -eq 0 ]; then
      audit_write "$(audit_entry "$COMMAND" "operation=$COMMAND" "level=$LEVEL" "outcome=finished")"
    else
      audit_write "$(audit_entry "$COMMAND" "operation=$COMMAND" "level=$LEVEL" "outcome=failed" "json:exit_status=$status")"
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
      say "to undo later: ./install.sh revoke --all --dry-run, or ./uninstall.sh --dry-run"
    fi
    return 0
  fi
  apply_for_real || status=$?
  return "$status"
}

main() {
  parse_arguments "$@"
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
    refusal="$(plan_real_apply_refusal)"
    [ -z "$refusal" ] || DIE_STATUS=3 die "not applied: $refusal"
  fi
  preflight_all "$OPERATING_SYSTEM" "$TRANSPORT" "$strict"

  STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/$PACKAGE-plan.XXXXXX")"
  trap 'rm -rf "$STAGE_DIR"' EXIT

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
