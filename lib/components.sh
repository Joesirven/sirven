# shellcheck shell=bash
# optional components: sirven add and sirven remove.
#
# a component is something sirven can set up for the owner that core never needs: install.sh,
# uninstall.sh, grants, and the kill switch work the same with no component added, and nothing
# outside this file and components/ knows any component by name. the registry is the components
# folder, one file per component, components/NAME.sh. like shadcn, add copies the component's
# files into a folder the owner owns and may edit; sirven keeps no hidden copy and never
# overwrites a file that is already there.
#
# add and remove are plans, with the installer's engine (lib/plan.sh): --dry-run prints the plan
# and changes nothing, and without --dry-run the identical plan is printed and then applied,
# under the same rule as install.sh. every applied step goes into the installer's audit log.
# components are never in the install record, so uninstall.sh leaves them alone.
#
# a component file defines, for its NAME:
#   component_NAME_summary            one line for sirven add --list
#   component_NAME_preflight STRICT   check the commands it needs, with lib/preflight.sh
#   component_NAME_plan_add           the add plan, for COMPONENT_DIR and COMPONENT_ENV_FILE
#   component_NAME_plan_remove        the remove plan, honoring COMPONENT_REMOVE_DATA
# reads: ROOT_DIR, PACKAGE, PREFIX, OWNER, SERVICE_USER, STAGE_DIR

components_registry() {
  printf '%s/components' "$ROOT_DIR"
}

# component_names: every component in the registry, one per line, in name order.
component_names() {
  local file
  for file in "$(components_registry)"/*.sh; do
    [ -f "$file" ] || continue
    basename "$file" .sh
  done
}

component_exists() {
  case "$1" in
    '' | *[!a-z0-9-]* | -*) return 1 ;;
  esac
  [ -f "$(components_registry)/$1.sh" ]
}

# the folder a component is copied into, unless --dir names another.
component_default_dir() {
  printf '%s/%s/components/%s' "${XDG_CONFIG_HOME:-$HOME/.config}" "$PACKAGE" "$1"
}

components_usage() {
  cat <<END
usage:
  sirven add --list                  the optional components, and which ones are added
  sirven add NAME [options]          copy a component into a folder you own, and set it up
  sirven remove NAME [options]       stop it and remove what add copied, keeping your changes

components are optional: sirven itself never needs one. add copies the component's files into
your folder, where they are yours to edit; running add again never overwrites them.

options:
  --dry-run          print the plan and change nothing
  --yes, -y          on a real machine, apply without asking you to type yes (or SIRVEN_YES=1)
  --dir PATH         the folder for the component (default: $(component_default_dir NAME))
  --env-file PATH    the dotenv that holds the component's credentials (default: .env in the
                     folder). a dotenv you control, for example one bb secret wrote. never a
                     file inside this repository
  --remove-data      remove only: also delete the component's stored data and its dotenv
  --prefix PATH      a fake root, as with install.sh; commands outside it are recorded, not run
  --help             show this help

examples:
  sirven add --list
  sirven add NAME --dry-run
  sirven remove NAME --dry-run
END
}

components_usage_error() {
  printf 'error: %s\n' "$1" >&2
  printf 'run sirven add --help for usage.\n' >&2
  exit 64
}

# components_parse ACTION ARGUMENT...: ACTION is add or remove.
components_parse() {
  COMPONENT_ACTION="$1"
  shift
  COMPONENT_NAME=""
  COMPONENT_LIST=no
  COMPONENT_DIR=""
  COMPONENT_ENV_FILE=""
  COMPONENT_REMOVE_DATA=no
  DRY_RUN=no
  ASSUME_YES=no
  PREFIX=""
  # shellcheck disable=SC2034 # read by lib/audit.sh (audit_entry records the user) and lib/access_control.sh
  SERVICE_USER=agent
  OWNER="${SUDO_USER:-$(id -un)}"
  # shellcheck disable=SC2034 # ASSUME_YES is read by lib/plan.sh (plan_confirm_real_apply)
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --list) COMPONENT_LIST=yes ;;
      --dry-run) DRY_RUN=yes ;;
      --yes | -y) ASSUME_YES=yes ;;
      --remove-data) COMPONENT_REMOVE_DATA=yes ;;
      --dir | --env-file | --prefix)
        [ "$#" -ge 2 ] || components_usage_error "$1 needs a value"
        case "$2" in --*) components_usage_error "$1 needs a value" ;; esac
        case "$1" in
          --dir) COMPONENT_DIR="$2" ;;
          --env-file) COMPONENT_ENV_FILE="$2" ;;
          --prefix) PREFIX="$2" ;;
        esac
        shift
        ;;
      --dir=*) COMPONENT_DIR="${1#*=}" ;;
      --env-file=*) COMPONENT_ENV_FILE="${1#*=}" ;;
      --prefix=*) PREFIX="${1#*=}" ;;
      -h | --help) components_usage; exit 0 ;;
      -*) components_usage_error "unknown option '$1'" ;;
      *)
        [ -z "$COMPONENT_NAME" ] || components_usage_error "one component at a time, got '$COMPONENT_NAME' and '$1'"
        COMPONENT_NAME="$1"
        ;;
    esac
    shift
  done
  if [ "$COMPONENT_LIST" = yes ]; then
    [ "$COMPONENT_ACTION" = add ] || components_usage_error "--list goes with add: sirven add --list"
    [ -z "$COMPONENT_NAME" ] || components_usage_error "--list takes no component name"
    return 0
  fi
  [ -n "$COMPONENT_NAME" ] || components_usage_error "$COMPONENT_ACTION needs a component name; sirven add --list shows them"
  component_exists "$COMPONENT_NAME" || components_usage_error "no component named '$COMPONENT_NAME'; sirven add --list shows them"
  if [ "$COMPONENT_REMOVE_DATA" = yes ] && [ "$COMPONENT_ACTION" != remove ]; then
    components_usage_error "--remove-data goes with remove"
  fi
  if [ -n "$PREFIX" ]; then
    case "$PREFIX" in
      /*) ;;
      *) components_usage_error "--prefix must be an absolute path" ;;
    esac
    if ! checked_prefix="$(prefix_normalize "$PREFIX")"; then components_usage_error "$checked_prefix"; fi
    PREFIX="$checked_prefix"
  fi
  if [ -n "${SIRVEN_OS_OVERRIDE:-}" ] && [ "$DRY_RUN" != yes ] && [ -z "$PREFIX" ]; then
    components_usage_error "SIRVEN_OS_OVERRIDE only works with --dry-run or --prefix"
  fi
}

# _component_path_allowed OPTION PATH: absolute, and never inside this repository, so a
# component's files and credentials cannot end up committed with sirven.
_component_path_allowed() {
  case "$2" in
    /*) ;;
    *) components_usage_error "$1 must be an absolute path" ;;
  esac
  case "$2/" in
    "$ROOT_DIR"/*) components_usage_error "$1 must be outside this repository ($ROOT_DIR): what add copies is yours, and credentials never go in the repository" ;;
  esac
  case "$PREFIX$2/" in
    "$ROOT_DIR"/*) components_usage_error "$1 under --prefix lands inside this repository ($ROOT_DIR)" ;;
  esac
}

components_resolve_paths() {
  [ -n "$COMPONENT_DIR" ] || COMPONENT_DIR="$(component_default_dir "$COMPONENT_NAME")"
  COMPONENT_DIR="${COMPONENT_DIR%/}"
  _component_path_allowed --dir "$COMPONENT_DIR"
  [ -n "$COMPONENT_ENV_FILE" ] || COMPONENT_ENV_FILE="$COMPONENT_DIR/.env"
  _component_path_allowed --env-file "$COMPONENT_ENV_FILE"
}

components_list() {
  local name dir found=0 state
  say "optional components. sirven itself never needs one."
  for name in $(component_names); do
    found=$((found + 1))
    # shellcheck disable=SC1090
    . "$(components_registry)/$name.sh"
    dir="$(component_default_dir "$name")"
    state="not added"
    if [ -d "${PREFIX}$dir" ]; then state="added, in $dir"; fi
    say "  $name: $("component_${name}_summary") ($state)"
  done
  if [ "$found" -eq 0 ]; then
    say "  none: this copy of sirven has no components folder, and needs none."
    return 0
  fi
  say ""
  say "add one: sirven add NAME --dry-run"
}

components_header() {
  local mode="apply: the plan below is printed, then applied" env_note="a dotenv you control"
  [ "$DRY_RUN" = yes ] && mode="dry run: nothing will be changed"
  if [ "$COMPONENT_ENV_FILE" = "$COMPONENT_DIR/.env" ]; then env_note="a dotenv in your folder"; fi
  say "$PACKAGE $COMPONENT_ACTION $COMPONENT_NAME plan"
  say "  component: $COMPONENT_NAME, $("component_${COMPONENT_NAME}_summary"). optional: sirven itself never needs it"
  say "  operating system: $OPERATING_SYSTEM"
  say "  folder: $COMPONENT_DIR, yours to edit"
  say "  credentials: $COMPONENT_ENV_FILE, $env_note, never this repository"
  say "  owner: $OWNER"
  say "  audit log: $(audit_log_file)"
  say "  prefix: ${PREFIX:-none, the real root}"
  say "  mode: $mode"
}

components_apply() {
  local status=0 operation="$COMPONENT_ACTION $COMPONENT_NAME"
  # shellcheck disable=SC2034 # read by lib/plan.sh, which runs each step; it takes none of these from the environment
  PLAN_STEP_HOOK=audit_step_hook
  # shellcheck disable=SC2034 # read by lib/plan.sh
  PLAN_RECORD_FILE=""
  # shellcheck disable=SC2034 # read by lib/plan.sh
  PLAN_RECHECK=no
  # shellcheck disable=SC2034 # read by lib/audit.sh when it writes the entry
  AUDIT_OPERATION="$operation"
  # shellcheck disable=SC2034 # read by lib/audit.sh when it writes the entry
  AUDIT_PENDING="$STAGE_DIR/audit-pending.jsonl"
  plan_apply || status=$?
  if [ "$status" -ne 3 ]; then
    if [ "$status" -eq 0 ]; then
      audit_write "$(audit_entry component "operation=$operation" "component=$COMPONENT_NAME" "directory=$COMPONENT_DIR" "outcome=finished")"
    else
      audit_write "$(audit_entry component "operation=$operation" "component=$COMPONENT_NAME" "directory=$COMPONENT_DIR" "outcome=failed" "json:exit_status=$status")"
    fi
  fi
  audit_flush
  return "$status"
}

# components_main ACTION ARGUMENT...: sirven add and sirven remove.
components_main() {
  local strict=yes refusal log
  components_parse "$@"
  OPERATING_SYSTEM="$(detect_os)"
  PACKAGE="$(package_name "$ROOT_DIR/project.json")"
  layout_set_directories
  if [ "$COMPONENT_LIST" = yes ]; then
    components_list
    return 0
  fi
  components_resolve_paths
  # shellcheck disable=SC1090
  . "$(components_registry)/$COMPONENT_NAME.sh"

  # shellcheck disable=SC2034 # read by lib/plan.sh
  PLAN_PREFIX="$PREFIX"
  # shellcheck disable=SC2034 # read by lib/plan.sh
  PLAN_OPERATING_SYSTEM="$OPERATING_SYSTEM"
  if [ "$DRY_RUN" = yes ] || [ -n "$PREFIX" ]; then
    strict=no
  fi
  if [ "$DRY_RUN" != yes ]; then
    refusal="$(plan_real_apply_refusal)"
    [ -z "$refusal" ] || DIE_STATUS=3 die "not applied: $refusal"
    # the change goes in the installer's audit log, so applying needs one.
    log="${PREFIX}$(audit_log_file)"
    [ -f "$log" ] || DIE_STATUS=3 die "not applied: no audit log at $log, so this change could not be recorded. install sirven first (./install.sh --dry-run shows the plan), or use --dry-run"
  fi
  PREFLIGHT_PROBLEMS=0
  preflight_bash
  "component_${COMPONENT_NAME}_preflight" "$strict"
  if [ "$PREFLIGHT_PROBLEMS" -gt 0 ]; then
    die "preflight found $PREFLIGHT_PROBLEMS problem(s); nothing was changed"
  fi

  STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/$PACKAGE-component.XXXXXX")"
  trap 'rm -rf "$STAGE_DIR"' EXIT
  PLAN_SIMULATION_LOG=""
  if [ -n "$PREFIX" ]; then
    # shellcheck disable=SC2034 # read by lib/plan.sh
    PLAN_SIMULATION_LOG="$PREFIX$(layout_simulation_log)"
  fi
  plan_reset
  "component_${COMPONENT_NAME}_plan_$COMPONENT_ACTION"
  plan_evaluate
  components_header
  plan_print
  plan_summary
  if [ "$DRY_RUN" = yes ]; then
    say "dry run: nothing was changed. run the same command without --dry-run to apply this plan."
    return 0
  fi
  components_apply
}
