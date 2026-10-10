# shellcheck shell=bash
# plan-then-apply engine.
#
# callers add steps, then either print the plan (--dry-run) or print the identical plan and
# apply it. every step that changes something has a check: a read-only command that exits 0
# when the step is already done, so re-runs skip finished work.
#
# step kinds
#   run       applied by this script, on paths under the prefix
#   system    needs root on a real machine (user accounts, ownership, access control lists).
#             under --prefix the command is recorded in a simulation log instead of run.
#   owner     something the owner does by hand, once (a browser login, pasting a policy)
#   planonly  shown in the plan, but the alpha cut does not apply it yet
#   section   a heading
#   note      a line of context under the current section
#
# plain indexed arrays only, so it runs on bash 3.2.

PLAN_PREFIX="${PLAN_PREFIX:-}"
PLAN_SIMULATION_LOG="${PLAN_SIMULATION_LOG:-}"
PLAN_OPERATING_SYSTEM="${PLAN_OPERATING_SYSTEM:-linux}"

plan_reset() {
  PLAN_KIND=()
  PLAN_TITLE=()
  PLAN_CHECK=()
  PLAN_ACTION=()
  PLAN_SHOWN=()
  PLAN_REASON=()
  PLAN_STATUS=()
  PLAN_NUMBER=()
  PLAN_COUNT=0
}

plan_reset

_plan_add() {
  local index="$PLAN_COUNT"
  PLAN_KIND[index]="$1"
  PLAN_TITLE[index]="$2"
  PLAN_CHECK[index]="$3"
  PLAN_ACTION[index]="$4"
  PLAN_SHOWN[index]="$5"
  PLAN_REASON[index]="$6"
  PLAN_STATUS[index]=""
  PLAN_NUMBER[index]=""
  PLAN_COUNT=$((PLAN_COUNT + 1))
}

plan_section() {
  _plan_add section "$1" "" "" "" ""
}

plan_note() {
  _plan_add note "$1" "" "" "" ""
}

# plan_step run|system TITLE CHECK ACTION [SHOWN]
# SHOWN replaces ACTION in the printed plan when the action is a helper call.
plan_step() {
  local kind="$1" title="$2" check="$3" action="$4" shown="${5:-}"
  case "$kind" in
    run | system) ;;
    *) die "plan_step: unknown kind '$kind'" ;;
  esac
  [ -n "$action" ] || die "plan_step: step '$title' has no action"
  [ -n "$shown" ] || shown="$action"
  _plan_add "$kind" "$title" "$check" "$action" "$shown" ""
}

# plan_owner TITLE TEXT
plan_owner() {
  _plan_add owner "$1" "" "" "$2" ""
}

# plan_planonly TITLE SHOWN REASON [CHECK]
plan_planonly() {
  _plan_add planonly "$1" "${4:-}" "" "$2" "$3"
}

# run a check without pipefail, so 'producer | grep -q' is judged by grep alone.
_plan_check_passes() {
  local check="$1"
  [ -n "$check" ] || return 1
  (
    set +e +o pipefail
    eval "$check"
  ) >/dev/null 2>&1
}

_plan_simulated() {
  [ -n "$PLAN_SIMULATION_LOG" ] && [ -f "$PLAN_SIMULATION_LOG" ] && grep -qxF -- "$1" "$PLAN_SIMULATION_LOG"
}

# work out every step's status once. checks are read only, so this is safe in a dry run.
plan_evaluate() {
  local index=0 number=0 kind
  while [ "$index" -lt "$PLAN_COUNT" ]; do
    kind="${PLAN_KIND[index]}"
    case "$kind" in
      section | note) PLAN_STATUS[index]="info" ;;
      owner) number=$((number + 1)); PLAN_STATUS[index]="owner" ;;
      planonly)
        number=$((number + 1))
        PLAN_STATUS[index]="planonly"
        if [ -z "$PLAN_PREFIX" ] && _plan_check_passes "${PLAN_CHECK[index]}"; then
          PLAN_STATUS[index]="done"
        fi
        ;;
      run)
        number=$((number + 1))
        if _plan_check_passes "${PLAN_CHECK[index]}"; then PLAN_STATUS[index]="done"; else PLAN_STATUS[index]="todo"; fi
        ;;
      system)
        number=$((number + 1))
        PLAN_STATUS[index]="todo"
        if [ -n "$PLAN_PREFIX" ]; then
          if _plan_simulated "${PLAN_ACTION[index]}"; then PLAN_STATUS[index]="done"; fi
        elif _plan_check_passes "${PLAN_CHECK[index]}"; then
          PLAN_STATUS[index]="done"
        fi
        ;;
    esac
    case "$kind" in
      section | note) ;;
      *) PLAN_NUMBER[index]="$number" ;;
    esac
    index=$((index + 1))
  done
}

_plan_status_label() {
  local index="$1"
  case "${PLAN_STATUS[index]}" in
    done) printf 'already done' ;;
    owner) printf 'owner, by hand' ;;
    planonly) printf 'plan only' ;;
    todo)
      if [ "${PLAN_KIND[index]}" = system ] && [ -n "$PLAN_PREFIX" ]; then
        printf 'to do, recorded not run under --prefix'
      elif [ "${PLAN_KIND[index]}" = system ]; then
        printf 'to do, needs root'
      else
        printf 'to do'
      fi
      ;;
  esac
}

# lines of a shown command get a '$ ' marker, except comment lines starting with '#' and the
# body of a here document, which is indented to line up instead.
_plan_print_block() {
  local text="$1" marker="$2" line inside=no
  while IFS= read -r line; do
    if [ "$inside" = yes ]; then
      printf '       %s%s\n' "${marker:+  }" "$line"
      [ "$line" = END ] && inside=no
      continue
    fi
    case "$line" in
      '#'*) printf '       %s\n' "$line" ;;
      *"<<'END'") printf '       %s%s\n' "$marker" "$line"; inside=yes ;;
      *) printf '       %s%s\n' "$marker" "$line" ;;
    esac
  done <<END
$text
END
}

plan_print() {
  local index=0 kind
  while [ "$index" -lt "$PLAN_COUNT" ]; do
    kind="${PLAN_KIND[index]}"
    case "$kind" in
      section) printf '\n%s\n' "${PLAN_TITLE[index]}" ;;
      note) printf '     note: %s\n' "${PLAN_TITLE[index]}" ;;
      *)
        printf '  %3s. %s (%s)\n' "${PLAN_NUMBER[index]}" "${PLAN_TITLE[index]}" "$(_plan_status_label "$index")"
        if [ "$kind" = owner ]; then
          _plan_print_block "${PLAN_SHOWN[index]}" ''
        else
          _plan_print_block "${PLAN_SHOWN[index]}" '$ '
        fi
        if [ "$kind" = planonly ] && [ "${PLAN_STATUS[index]}" != "done" ]; then
          printf '       not yet: %s\n' "${PLAN_REASON[index]}"
        fi
        ;;
    esac
    index=$((index + 1))
  done
}

_plan_count_status() {
  local wanted="$1" index=0 total=0
  while [ "$index" -lt "$PLAN_COUNT" ]; do
    if [ "${PLAN_STATUS[index]}" = "$wanted" ]; then total=$((total + 1)); fi
    index=$((index + 1))
  done
  printf '%s' "$total"
}

plan_summary() {
  local steps=0 index=0
  while [ "$index" -lt "$PLAN_COUNT" ]; do
    if [ -n "${PLAN_NUMBER[index]}" ]; then steps=$((steps + 1)); fi
    index=$((index + 1))
  done
  printf '\nsummary: %s steps. %s to do, %s already done, %s by the owner, %s plan only.\n' \
    "$steps" "$(_plan_count_status todo)" "$(_plan_count_status "done")" \
    "$(_plan_count_status owner)" "$(_plan_count_status planonly)"
}

# why a real (no --prefix) apply is refused, or nothing when it is allowed.
# the alpha cut only changes a real system inside a linux container, as root.
plan_real_apply_refusal() {
  if [ -n "$PLAN_PREFIX" ]; then
    return 0
  fi
  if [ "$PLAN_OPERATING_SYSTEM" != linux ]; then
    printf 'applying to a real macos machine is not verified yet; use --dry-run, or --prefix for a fake root'
  elif ! in_container; then
    printf 'the alpha cut only applies to a real system inside a throwaway container; use --dry-run, or --prefix for a fake root'
  elif [ "$(id -u)" != 0 ]; then
    printf 'applying needs root; run it with sudo inside the container'
  fi
}

# list steps that stop the apply. prints nothing when the plan can be applied.
plan_blockers() {
  local index=0
  while [ "$index" -lt "$PLAN_COUNT" ]; do
    if [ "${PLAN_STATUS[index]}" = planonly ]; then
      printf '  step %s, %s: %s\n' "${PLAN_NUMBER[index]}" "${PLAN_TITLE[index]}" "${PLAN_REASON[index]}"
    fi
    index=$((index + 1))
  done
}

# apply the evaluated plan. refuses up front, before any change, if any step cannot run.
plan_apply() {
  local refusal blockers index=0 kind applied=0 skipped=0
  refusal="$(plan_real_apply_refusal)"
  if [ -n "$refusal" ]; then
    printf '\nnot applied: %s\n' "$refusal" >&2
    return 3
  fi
  blockers="$(plan_blockers)"
  if [ -n "$blockers" ]; then
    printf '\nnot yet: this plan has steps the alpha cut does not apply. nothing was changed.\n%s\n' "$blockers" >&2
    printf 'run with --dry-run to read the full plan, or leave out the flags that add plan-only steps.\n' >&2
    return 3
  fi
  printf '\napplying\n'
  while [ "$index" -lt "$PLAN_COUNT" ]; do
    kind="${PLAN_KIND[index]}"
    case "$kind" in
      run | system)
        if [ "${PLAN_STATUS[index]}" = "done" ]; then
          printf '  %3s. skipped, already done\n' "${PLAN_NUMBER[index]}"
          skipped=$((skipped + 1))
        elif [ "$kind" = system ] && [ -n "$PLAN_PREFIX" ]; then
          mkdir -p "$(dirname "$PLAN_SIMULATION_LOG")"
          printf '%s\n' "${PLAN_ACTION[index]}" >> "$PLAN_SIMULATION_LOG"
          printf '  %3s. recorded in %s\n' "${PLAN_NUMBER[index]}" "$PLAN_SIMULATION_LOG"
          applied=$((applied + 1))
        else
          if ! ( eval "${PLAN_ACTION[index]}" ); then
            printf 'error: step %s failed: %s\n' "${PLAN_NUMBER[index]}" "${PLAN_TITLE[index]}" >&2
            printf 'steps before it stay applied; fix the cause and run again, finished steps are skipped.\n' >&2
            return 4
          fi
          printf '  %3s. done\n' "${PLAN_NUMBER[index]}"
          applied=$((applied + 1))
        fi
        ;;
      owner)
        printf '  %3s. yours to do by hand: %s\n' "${PLAN_NUMBER[index]}" "${PLAN_TITLE[index]}"
        ;;
      planonly)
        printf '  %3s. skipped, already done\n' "${PLAN_NUMBER[index]}"
        skipped=$((skipped + 1))
        ;;
    esac
    index=$((index + 1))
  done
  printf '\napplied %s steps, skipped %s already done.\n' "$applied" "$skipped"
}
