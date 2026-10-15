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
#   adopted   something already on the machine that the plan keeps as it is and never changes:
#             a Tailscale login, a bb install, sirven state from an earlier run. see lib/adopt.sh.
#             not a step: it has no action, no number, and never goes in the install record.
#
# a step can also carry
#   a tag     plan_tag TAG, a word other modules match on: state, audit, and grant mark the
#             steps uninstall.sh and the audit writer treat specially; always marks a step that
#             has no read-only probe for its end state, so it runs every time
#   an undo   plan_undo TITLE CHECK ACTION [SHOWN], or plan_undo_owner TITLE TEXT: how to
#             reverse the step. when apply really runs a step that has an undo, the undo is
#             appended to PLAN_RECORD_FILE, the install record. uninstall.sh reverses only what
#             that record lists, so it never removes something this package did not create.
#
# plan_assume_undone: steps added after it are shown as to do and always applied, without their
# check. for plans where an earlier step undoes their end state, like a grant rollback that
# removes access and then grants the earlier access again: a check run before applying would
# wrongly find them done.
#
# PLAN_STEP_HOOK, when set, names a function apply calls after every numbered step with
# NUMBER KIND TAG TITLE OUTCOME. install.sh points it at the audit log writer.
#
# plan_forget_secrets NAME...: the most recent step is the last to need these environment variables (an auth key handed over
# in the environment). the installer unsets them as soon as that step has run, whether it was applied, failed or skipped, so no
# later step starts a child process that inherits them.
#
# plan_conflict TITLE ADVICE: a step blocked by something already on the machine that cannot be kept
# alongside what was asked (see lib/adopt.sh). it is never applied: a real run refuses before the plan
# is made, and plan_apply refuses a plan that holds one. ADVICE is what the person can do about it.
plan_conflict() {
  _plan_add conflict "$1" "" "" "$2" ""
}

# plan_continue: the most recent step may fail without stopping the run. the run goes on, records the failure,
# and ends with exit 4 listing every failed step. for a plan whose steps each remove access, so one step that
# cannot finish (a name the agent planted, a unit that will not stop) never leaves a later one undone.
# PLAN_RECHECK=yes: the check of a step is read again immediately before the step runs, not only once before
# the first step, so a step judged done earlier (or not done) is judged on the machine as it is now.
#
# plain indexed arrays only, walked by index and never expanded whole, so it runs on bash 3.2
# with set -u, where expanding an empty array is an error.

PLAN_PREFIX="${PLAN_PREFIX:-}"
PLAN_SIMULATION_LOG="${PLAN_SIMULATION_LOG:-}"
PLAN_OPERATING_SYSTEM="${PLAN_OPERATING_SYSTEM:-linux}"
PLAN_RECORD_FILE="${PLAN_RECORD_FILE:-}"
PLAN_STEP_HOOK="${PLAN_STEP_HOOK:-}"
PLAN_RECHECK="${PLAN_RECHECK:-no}"
PLAN_CONFIRMED=no

plan_reset() {
  PLAN_KIND=()
  PLAN_TITLE=()
  PLAN_CHECK=()
  PLAN_ACTION=()
  PLAN_SHOWN=()
  PLAN_REASON=()
  PLAN_STATUS=()
  PLAN_NUMBER=()
  PLAN_TAG=()
  PLAN_SECTION=()
  PLAN_UNDO_TITLE=()
  PLAN_UNDO_CHECK=()
  PLAN_UNDO_ACTION=()
  PLAN_UNDO_SHOWN=()
  PLAN_ASSUMED_UNDONE=()
  PLAN_CONTINUE=()
  PLAN_FORGET=()
  PLAN_FAILURES=0
  PLAN_FAILED_LIST=""
  PLAN_COUNT=0
  PLAN_CURRENT_SECTION=""
  PLAN_ASSUME_UNDONE=no
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
  PLAN_TAG[index]=""
  if [ "$1" = section ]; then PLAN_CURRENT_SECTION="$2"; fi
  PLAN_SECTION[index]="$PLAN_CURRENT_SECTION"
  PLAN_UNDO_TITLE[index]=""
  PLAN_UNDO_CHECK[index]=""
  PLAN_UNDO_ACTION[index]=""
  PLAN_UNDO_SHOWN[index]=""
  PLAN_ASSUMED_UNDONE[index]="$PLAN_ASSUME_UNDONE"
  PLAN_CONTINUE[index]=no
  PLAN_FORGET[index]=""
  PLAN_COUNT=$((PLAN_COUNT + 1))
}

plan_assume_undone() {
  PLAN_ASSUME_UNDONE=yes
}

plan_section() {
  _plan_add section "$1" "" "" "" ""
}

plan_note() {
  _plan_add note "$1" "" "" "" ""
}

plan_adopted() {
  _plan_add adopted "$1" "" "" "" ""
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

# plan_owner TITLE TEXT [CHECK]
# with CHECK, a step the owner already did shows as already done.
plan_owner() {
  _plan_add owner "$1" "${3:-}" "" "$2" ""
}

# plan_planonly TITLE SHOWN REASON [CHECK]
plan_planonly() {
  _plan_add planonly "$1" "${4:-}" "" "$2" "$3"
}

# plan_continue: the most recent step may fail without stopping the run (see the header).
plan_continue() {
  [ "$PLAN_COUNT" -gt 0 ] || die "plan_continue: no step to mark"
  PLAN_CONTINUE[PLAN_COUNT - 1]=yes
}

# plan_forget_secrets NAME...: see the header. NAMEs are environment variable names, and nothing else.
plan_forget_secrets() {
  local name
  [ "$PLAN_COUNT" -gt 0 ] || die "plan_forget_secrets: no step to mark"
  for name in "$@"; do
    case "$name" in
      '' | [0-9]* | *[!A-Za-z0-9_]*) die "plan_forget_secrets: '$name' is not a variable name" ;;
    esac
  done
  PLAN_FORGET[PLAN_COUNT - 1]="$*"
}

# plan_continue_since FIRST TAG: every run or system step added since step index FIRST may fail without stopping the
# run (see plan_continue) and gets TAG. for a module that adds a list of steps through a helper.
plan_continue_since() {
  local index="$1"
  while [ "$index" -lt "$PLAN_COUNT" ]; do
    case "${PLAN_KIND[index]}" in
      run | system) PLAN_CONTINUE[index]=yes; PLAN_TAG[index]="$2" ;;
    esac
    index=$((index + 1))
  done
}

# plan_tag TAG: tag the most recent step.
plan_tag() {
  [ "$PLAN_COUNT" -gt 0 ] || die "plan_tag: no step to tag"
  PLAN_TAG[PLAN_COUNT - 1]="$1"
}

# the install record keeps one undo per line, fields separated by tabs, so an undo must not
# hold a tab or a newline.
_plan_one_line() {
  local tab newline
  tab="$(printf '\t')"
  newline="
"
  case "$1" in
    *"$tab"* | *"$newline"*) die "plan_undo: '$2' must fit on one line without tabs" ;;
  esac
}

# plan_undo TITLE CHECK ACTION [SHOWN]: how to reverse the most recent run or system step.
# CHECK exits 0 when the step is already reversed.
plan_undo() {
  local index=$((PLAN_COUNT - 1)) title="$1" check="$2" action="$3" shown="${4:-$3}"
  [ "$index" -ge 0 ] || die "plan_undo: no step to attach to"
  case "${PLAN_KIND[index]}" in
    run | system | planonly) ;;
    *) die "plan_undo: step '${PLAN_TITLE[index]}' cannot be reversed by a command" ;;
  esac
  [ -n "$action" ] || die "plan_undo: undo for '${PLAN_TITLE[index]}' has no action"
  _plan_one_line "$title" "$title"
  _plan_one_line "$check" "$title"
  _plan_one_line "$action" "$title"
  _plan_one_line "$shown" "$title"
  PLAN_UNDO_TITLE[index]="$title"
  PLAN_UNDO_CHECK[index]="$check"
  PLAN_UNDO_ACTION[index]="$action"
  PLAN_UNDO_SHOWN[index]="$shown"
}

# plan_undo_owner TITLE TEXT: what the owner does by hand to reverse the most recent owner step.
plan_undo_owner() {
  local index=$((PLAN_COUNT - 1))
  [ "$index" -ge 0 ] && [ "${PLAN_KIND[index]}" = owner ] || die "plan_undo_owner: the most recent step is not an owner step"
  _plan_one_line "$1" "$1"
  _plan_one_line "$2" "$1"
  PLAN_UNDO_TITLE[index]="$1"
  PLAN_UNDO_SHOWN[index]="$2"
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
      section | note | adopted) PLAN_STATUS[index]="info" ;;
      owner)
        number=$((number + 1))
        PLAN_STATUS[index]="owner"
        if _plan_check_passes "${PLAN_CHECK[index]}"; then PLAN_STATUS[index]="done"; fi
        ;;
      conflict)
        number=$((number + 1))
        PLAN_STATUS[index]="blocked"
        ;;
      planonly)
        number=$((number + 1))
        PLAN_STATUS[index]="planonly"
        if [ -z "$PLAN_PREFIX" ] && _plan_check_passes "${PLAN_CHECK[index]}"; then
          PLAN_STATUS[index]="done"
        fi
        ;;
      run | system)
        number=$((number + 1))
        PLAN_STATUS[index]="todo"
        if [ "${PLAN_ASSUMED_UNDONE[index]}" = yes ]; then
          :
        elif [ "$kind" = run ]; then
          if _plan_check_passes "${PLAN_CHECK[index]}"; then PLAN_STATUS[index]="done"; fi
        elif [ -n "$PLAN_PREFIX" ]; then
          if _plan_simulated "${PLAN_ACTION[index]}"; then PLAN_STATUS[index]="done"; fi
        elif _plan_check_passes "${PLAN_CHECK[index]}"; then
          PLAN_STATUS[index]="done"
        fi
        ;;
    esac
    case "$kind" in
      section | note | adopted) ;;
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
    blocked) printf 'blocked by a conflict' ;;
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
      adopted) printf '     adopted: %s\n' "${PLAN_TITLE[index]}" ;;
      conflict)
        printf '  %3s. %s (%s)\n' "${PLAN_NUMBER[index]}" "${PLAN_TITLE[index]}" "$(_plan_status_label "$index")"
        printf '       you can: %s\n' "${PLAN_SHOWN[index]}"
        ;;
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
  local steps=0 index=0 blocked blocked_clause=""
  while [ "$index" -lt "$PLAN_COUNT" ]; do
    if [ -n "${PLAN_NUMBER[index]}" ]; then steps=$((steps + 1)); fi
    index=$((index + 1))
  done
  blocked="$(_plan_count_status blocked)"
  if [ "$blocked" -gt 0 ]; then blocked_clause=", $blocked blocked by a conflict"; fi
  printf '\nsummary: %s steps. %s to do, %s already done, %s by the owner, %s plan only%s.\n' \
    "$steps" "$(_plan_count_status todo)" "$(_plan_count_status "done")" \
    "$(_plan_count_status owner)" "$(_plan_count_status planonly)" "$blocked_clause"
}

# why a real macos apply is refused, or nothing when it is allowed. the steps are built and tested
# on a fake root, but no real install has been checked yet (tests/macos/real-install-check.sh), so a
# real apply stays off until the owner turns it on for that check with SIRVEN_MACOS_REAL_APPLY=1.
# sudo drops the variable unless it is passed through: sudo env SIRVEN_MACOS_REAL_APPLY=1 bash install.sh
plan_macos_real_apply_refusal() {
  if [ "${SIRVEN_MACOS_REAL_APPLY:-}" != 1 ]; then
    printf 'applying to a real macos machine is not verified yet and is switched off; use --dry-run, or --prefix for a fake root. the owner switches it on for the real install check only, with: sudo env SIRVEN_MACOS_REAL_APPLY=1 bash install.sh (see docs/research/qa/macos-real-apply-prep.md)'
  elif [ "$(id -u)" != 0 ]; then
    printf 'applying needs root; run it with: sudo env SIRVEN_MACOS_REAL_APPLY=1 bash install.sh (sudo drops the variable without env)'
  fi
}

# why a real (no --prefix) apply is refused, or nothing when it is allowed.
# a real linux machine, container or not, is changed only by root. a real macos machine only with root and
# SIRVEN_MACOS_REAL_APPLY=1 (plan_macos_real_apply_refusal).
plan_real_apply_refusal() {
  if [ -n "$PLAN_PREFIX" ]; then
    return 0
  fi
  if [ "$PLAN_OPERATING_SYSTEM" != linux ]; then
    plan_macos_real_apply_refusal
  elif [ "$(id -u)" != 0 ]; then
    printf 'applying needs root; run it with sudo'
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

# the number of steps blocked by a conflict, 0 when the plan holds none.
plan_conflict_count() {
  _plan_count_status blocked
}

# a field of the install record. empty fields are written as '-', because read with a tab in
# IFS would swallow an empty field.
_plan_field() {
  printf '%s' "${1:--}"
}

# _plan_record INDEX: append the step's undo to the install record, once.
# fields: kind, tag, section, title, undo title, undo check, undo action, undo shown.
_plan_record() {
  local index="$1" line
  [ -n "$PLAN_RECORD_FILE" ] || return 0
  [ -n "${PLAN_UNDO_TITLE[index]}" ] || return 0
  line="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "${PLAN_KIND[index]}" "$(_plan_field "${PLAN_TAG[index]}")" "$(_plan_field "${PLAN_SECTION[index]}")" \
    "$(_plan_field "${PLAN_TITLE[index]}")" "$(_plan_field "${PLAN_UNDO_TITLE[index]}")" \
    "$(_plan_field "${PLAN_UNDO_CHECK[index]}")" "$(_plan_field "${PLAN_UNDO_ACTION[index]}")" \
    "$(_plan_field "${PLAN_UNDO_SHOWN[index]}")")"
  if [ ! -d "$(dirname "$PLAN_RECORD_FILE")" ]; then
    printf 'warning: no folder for the install record %s; step %s is not recorded, so uninstall will leave it.\n' \
      "$PLAN_RECORD_FILE" "${PLAN_NUMBER[index]}" >&2
    return 0
  fi
  if [ -f "$PLAN_RECORD_FILE" ] && grep -qxF -- "$line" "$PLAN_RECORD_FILE"; then
    return 0
  fi
  printf '%s\n' "$line" >> "$PLAN_RECORD_FILE"
  chmod 0600 "$PLAN_RECORD_FILE"
}

# _plan_hook INDEX OUTCOME
_plan_hook() {
  [ -n "$PLAN_STEP_HOOK" ] || return 0
  "$PLAN_STEP_HOOK" "${PLAN_NUMBER[$1]}" "${PLAN_KIND[$1]}" "${PLAN_TAG[$1]}" "${PLAN_TITLE[$1]}" "$2"
}

# _plan_forget INDEX: unset, in this shell, the variables the step marked with plan_forget_secrets. children started later
# do not inherit what is not there.
_plan_forget() {
  local name
  [ -n "${PLAN_FORGET[$1]}" ] || return 0
  for name in ${PLAN_FORGET[$1]}; do
    unset "$name"
  done
}

# _plan_recheck INDEX: with PLAN_RECHECK=yes, read the step's check again now, just before the step runs.
# a step that assumes its end state undone is never rechecked, and a system step on a fake root is judged
# by the simulation log, as in plan_evaluate.
_plan_recheck() {
  local index="$1"
  [ "$PLAN_RECHECK" = yes ] || return 0
  [ "${PLAN_ASSUMED_UNDONE[index]}" != yes ] || return 0
  if [ "${PLAN_KIND[index]}" = system ] && [ -n "$PLAN_PREFIX" ]; then return 0; fi
  if _plan_check_passes "${PLAN_CHECK[index]}"; then PLAN_STATUS[index]="done"; else PLAN_STATUS[index]="todo"; fi
}

# plan_confirm_real_apply: the first change to a real machine is never silent. a real machine is
# any run with no --prefix, on any operating system, and that includes a container: markers such as /.dockerenv or
# container= are written by the machine itself, so they are never taken as consent. --yes (ASSUME_YES, or SIRVEN_YES)
# is the owner's explicit consent; otherwise the plan just printed must be answered with the word yes on a terminal.
# with no terminal and no --yes, nothing is applied (returns 3). PLAN_CONFIRMED=yes means the caller already asked and
# was answered (the kill switch's typed word revoke), so it is not asked twice. plan_apply calls this after the checks
# that cannot be fixed by typing yes, so nobody confirms a plan that is then refused.
plan_confirm_real_apply() {
  local terminal answer=""
  [ -z "$PLAN_PREFIX" ] || return 0
  [ "${ASSUME_YES:-no}" != yes ] || return 0
  [ "${PLAN_CONFIRMED:-no}" != yes ] || return 0
  case "$(lowercase "${SIRVEN_YES:-}")" in 1 | yes | true) return 0 ;; esac
  terminal="$(_setup_terminal)"
  if [ -z "$terminal" ]; then
    printf '\nnot applied: this is a real machine and there is no terminal to confirm the plan on; read the plan above, then run again with --yes\n' >&2
    return 3
  fi
  printf '\nthis changes the real machine %s. type yes to apply the plan above: ' "$(hostname 2>/dev/null || echo this)" >&2
  if [ "$terminal" = tty ]; then read -r answer < /dev/tty || true; else read -r answer || true; fi
  if [ "$(lowercase "$answer")" != yes ]; then
    printf '\nnot applied: the plan was not confirmed; nothing was changed\n' >&2
    return 3
  fi
}

# apply the evaluated plan. refuses up front, before any change, if any step cannot run.
plan_apply() {
  local refusal blockers index=0 kind applied=0 skipped=0 step_status
  refusal="$(plan_real_apply_refusal)"
  if [ -n "$refusal" ]; then
    printf '\nnot applied: %s\n' "$refusal" >&2
    return 3
  fi
  if [ "$(plan_conflict_count)" -gt 0 ]; then
    printf '\nnot applied: this plan has steps blocked by a conflict with what is already on this machine. nothing was changed.\n' >&2
    return 3
  fi
  blockers="$(plan_blockers)"
  if [ -n "$blockers" ]; then
    printf '\nnot yet: this plan has steps the alpha cut does not apply. nothing was changed.\n%s\n' "$blockers" >&2
    printf 'run with --dry-run to read the full plan, or leave out the flags that add plan-only steps.\n' >&2
    return 3
  fi
  plan_confirm_real_apply || return 3
  printf '\napplying\n'
  while [ "$index" -lt "$PLAN_COUNT" ]; do
    kind="${PLAN_KIND[index]}"
    case "$kind" in
      run | system)
        _plan_recheck "$index"
        if [ "${PLAN_STATUS[index]}" = "done" ]; then
          printf '  %3s. skipped, already done\n' "${PLAN_NUMBER[index]}"
          skipped=$((skipped + 1))
          _plan_forget "$index"
          _plan_hook "$index" skipped
        elif [ "$kind" = system ] && [ -n "$PLAN_PREFIX" ]; then
          mkdir -p "$(dirname "$PLAN_SIMULATION_LOG")"
          printf '%s\n' "${PLAN_ACTION[index]}" >> "$PLAN_SIMULATION_LOG"
          printf '  %3s. recorded in %s\n' "${PLAN_NUMBER[index]}" "$PLAN_SIMULATION_LOG"
          applied=$((applied + 1))
          _plan_record "$index"
          _plan_forget "$index"
          _plan_hook "$index" recorded
        else
          step_status=0
          ( eval "${PLAN_ACTION[index]}" ) || step_status=$?
          _plan_forget "$index"
          if [ "$step_status" -ne 0 ]; then
            printf 'error: step %s failed: %s\n' "${PLAN_NUMBER[index]}" "${PLAN_TITLE[index]}" >&2
            _plan_hook "$index" failed
            if [ "${PLAN_CONTINUE[index]}" = yes ]; then
              printf 'the other steps still run: one that cannot finish must not leave a later one undone.\n' >&2
              PLAN_FAILURES=$((PLAN_FAILURES + 1))
              PLAN_FAILED_LIST="${PLAN_FAILED_LIST}  step ${PLAN_NUMBER[index]}: ${PLAN_TITLE[index]}
"
              index=$((index + 1))
              continue
            fi
            printf 'steps before it stay applied; fix the cause and run again, finished steps are skipped.\n' >&2
            return 4
          fi
          printf '  %3s. done\n' "${PLAN_NUMBER[index]}"
          applied=$((applied + 1))
          _plan_record "$index"
          _plan_hook "$index" applied
        fi
        ;;
      owner)
        if [ "${PLAN_STATUS[index]}" = "done" ]; then
          printf '  %3s. skipped, already done\n' "${PLAN_NUMBER[index]}"
          _plan_hook "$index" skipped
        else
          printf '  %3s. yours to do by hand: %s\n' "${PLAN_NUMBER[index]}" "${PLAN_TITLE[index]}"
          _plan_record "$index"
          _plan_hook "$index" owner
        fi
        ;;
      planonly)
        printf '  %3s. skipped, already done\n' "${PLAN_NUMBER[index]}"
        skipped=$((skipped + 1))
        _plan_hook "$index" skipped
        ;;
    esac
    index=$((index + 1))
  done
  printf '\napplied %s steps, skipped %s already done.\n' "$applied" "$skipped"
  if [ "$PLAN_FAILURES" -gt 0 ]; then
    printf '\n%s steps failed, each listed here, and the others ran:\n%s' "$PLAN_FAILURES" "$PLAN_FAILED_LIST" >&2
    return 4
  fi
}
