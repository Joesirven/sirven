# shellcheck shell=bash
# plan engine: numbering, dry run, apply, idempotency, refusals. all on a fake root.

# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/plan.sh
. "$REPO_DIR/lib/plan.sh"

setup_fake_root() {
  ROOT="$TEST_TMP/root"
  PLAN_PREFIX="$ROOT"
  PLAN_SIMULATION_LOG="$ROOT/var/lib/sirven/simulated-system-commands.log"
  PLAN_OPERATING_SYSTEM=linux
  plan_reset
}

add_directory_step() {
  plan_step run "create $1" "[ -d $ROOT$1 ]" "mkdir -p $ROOT$1"
}

test_steps_are_numbered_and_sections_are_not() {
  setup_fake_root
  plan_section "first section"
  plan_note "context"
  add_directory_step /one
  plan_owner "do a thing by hand" "click the button"
  plan_section "second section"
  plan_planonly "a later feature" "later-command" "not built yet"
  plan_evaluate
  capture plan_print
  assert_contains "$CAPTURED_STDOUT" "first section"
  assert_contains "$CAPTURED_STDOUT" "    1. create /one (to do)"
  assert_contains "$CAPTURED_STDOUT" "    2. do a thing by hand (owner, by hand)"
  assert_contains "$CAPTURED_STDOUT" "    3. a later feature (plan only)"
  assert_contains "$CAPTURED_STDOUT" "not yet: not built yet"
  assert_contains "$CAPTURED_STDOUT" "note: context"
}

test_dry_run_print_changes_nothing() {
  setup_fake_root
  add_directory_step /etc/sirven
  plan_step system "make a user" "" "useradd example"
  plan_evaluate
  capture plan_print
  assert_contains "$CAPTURED_STDOUT" "\$ mkdir -p $ROOT/etc/sirven"
  assert_no_file "$ROOT"
}

test_apply_runs_steps_then_rerun_skips_them() {
  setup_fake_root
  add_directory_step /etc/sirven
  add_directory_step /var/log/sirven
  plan_evaluate
  assert_status 0 plan_apply
  assert_file_exists "$ROOT/etc/sirven"
  assert_file_exists "$ROOT/var/log/sirven"
  assert_contains "$CAPTURED_STDOUT" "applied 2 steps, skipped 0 already done."

  plan_reset
  add_directory_step /etc/sirven
  add_directory_step /var/log/sirven
  plan_evaluate
  capture plan_print
  assert_contains "$CAPTURED_STDOUT" "create /etc/sirven (already done)"
  assert_status 0 plan_apply
  assert_contains "$CAPTURED_STDOUT" "applied 0 steps, skipped 2 already done."
}

test_system_steps_are_recorded_not_run_under_prefix() {
  setup_fake_root
  plan_step system "touch outside the fake root" "" "touch $TEST_TMP/outside"
  plan_evaluate
  assert_status 0 plan_apply
  assert_no_file "$TEST_TMP/outside"
  assert_eq "touch $TEST_TMP/outside" "$(cat "$PLAN_SIMULATION_LOG")" "the simulation log holds the command"

  plan_reset
  plan_step system "touch outside the fake root" "" "touch $TEST_TMP/outside"
  plan_evaluate
  assert_eq "done" "${PLAN_STATUS[0]}" "a recorded system step counts as done on the next run"
}

test_plan_only_step_blocks_apply_before_any_change() {
  setup_fake_root
  add_directory_step /etc/sirven
  plan_planonly "join the tailnet" "tailscale up" "tailscale is plan only"
  plan_evaluate
  assert_status 3 plan_apply
  assert_contains "$CAPTURED_STDERR" "not yet"
  assert_contains "$CAPTURED_STDERR" "step 2, join the tailnet: tailscale is plan only"
  assert_no_file "$ROOT/etc/sirven"
}

test_failed_step_stops_the_apply() {
  setup_fake_root
  plan_step run "always fails" "" "false"
  add_directory_step /after
  plan_evaluate
  assert_status 4 plan_apply
  assert_contains "$CAPTURED_STDERR" "step 1 failed: always fails"
  assert_no_file "$ROOT/after"
}

test_checks_ignore_pipefail_from_early_exit() {
  setup_fake_root
  set -o pipefail
  plan_step run "already done through a pipe" "yes | head -n 1 | grep -q y" "false"
  plan_evaluate
  assert_eq "done" "${PLAN_STATUS[0]}"
}

test_owner_steps_are_shown_but_not_run() {
  setup_fake_root
  plan_owner "paste the policy" "touch $TEST_TMP/never"
  plan_evaluate
  assert_status 0 plan_apply
  assert_contains "$CAPTURED_STDOUT" "yours to do by hand: paste the policy"
  assert_no_file "$TEST_TMP/never"
}

test_real_apply_is_refused_without_root() {
  # as root this would really apply to the machine running the tests
  if [ "$(id -u)" = 0 ]; then
    return 0
  fi
  setup_fake_root
  PLAN_PREFIX=""
  add_directory_step /etc/sirven
  plan_evaluate
  assert_status 3 plan_apply
  assert_contains "$CAPTURED_STDERR" "applying needs root"
  assert_no_file "$ROOT/etc/sirven"
}

# the refusal looks at the user and the operating system only: a container is no longer special.
test_real_apply_on_linux_is_allowed_for_root() {
  PLAN_PREFIX=""
  PLAN_OPERATING_SYSTEM=linux
  id() { printf '0'; }
  assert_eq "" "$(plan_real_apply_refusal)"
  id() { printf '1000'; }
  assert_contains "$(plan_real_apply_refusal)" "applying needs root"
}

# stubs for the confirmation gate: where answers could be read from, and whether this is a container.
# shellcheck disable=SC2329 # called by plan_confirm_real_apply in lib/plan.sh
gate_stubs() {
  in_container() { return "${STUB_CONTAINER:-1}"; }
  _setup_terminal() { printf '%s' "${STUB_TERMINAL:-}"; }
}

test_confirm_gate_needs_yes_flag_or_a_typed_yes_on_a_real_machine() {
  gate_stubs
  PLAN_PREFIX=""
  unset SIRVEN_YES
  ASSUME_YES=no
  STUB_TERMINAL=""
  assert_status 3 plan_confirm_real_apply
  assert_contains "$CAPTURED_STDERR" "no terminal to confirm"
  assert_contains "$CAPTURED_STDERR" "with --yes"
  STUB_TERMINAL=stdin
  capture plan_confirm_real_apply <<< "no"
  assert_eq 3 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "not confirmed"
  capture plan_confirm_real_apply <<< "YES"
  assert_eq 0 "$CAPTURED_STATUS"
}

test_confirm_gate_is_skipped_for_consent_a_prefix_or_a_container() {
  gate_stubs
  STUB_TERMINAL=""
  unset SIRVEN_YES
  PLAN_PREFIX=""
  ASSUME_YES=yes
  assert_status 0 plan_confirm_real_apply
  ASSUME_YES=no
  SIRVEN_YES=1 assert_status 0 plan_confirm_real_apply
  STUB_CONTAINER=0
  assert_status 0 plan_confirm_real_apply
  STUB_CONTAINER=1
  PLAN_PREFIX="$TEST_TMP/fake"
  assert_status 0 plan_confirm_real_apply
}

test_plan_blockers_are_refused_before_asking_for_yes() {
  setup_fake_root
  gate_stubs
  PLAN_PREFIX=""
  ASSUME_YES=no
  unset SIRVEN_YES
  STUB_TERMINAL=stdin
  # shellcheck disable=SC2329 # called by plan_real_apply_refusal in lib/plan.sh
  id() { printf '0'; }
  add_directory_step /one
  plan_planonly "a later feature" "later-command" "not built yet"
  plan_evaluate
  assert_status 3 plan_apply < /dev/null
  assert_contains "$CAPTURED_STDERR" "not yet"
  assert_not_contains "$CAPTURED_STDERR" "type yes"
  assert_no_file "$ROOT/one"
}

test_an_unconfirmed_plan_changes_nothing() {
  setup_fake_root
  gate_stubs
  PLAN_PREFIX=""
  ASSUME_YES=no
  unset SIRVEN_YES
  STUB_TERMINAL=""
  # shellcheck disable=SC2329 # called by plan_real_apply_refusal in lib/plan.sh
  # shellcheck disable=SC2329 # called by plan_real_apply_refusal in lib/plan.sh
  id() { printf '0'; }
  add_directory_step /one
  plan_evaluate
  assert_status 3 plan_apply
  assert_contains "$CAPTURED_STDERR" "no terminal to confirm"
  assert_no_file "$ROOT/one"
}

test_real_apply_on_macos_is_refused() {
  setup_fake_root
  PLAN_PREFIX=""
  PLAN_OPERATING_SYSTEM=macos
  assert_contains "$(plan_real_apply_refusal)" "not verified yet"
  assert_contains "$(plan_real_apply_refusal)" "switched off"
}

test_real_apply_on_macos_needs_the_switch_and_root() {
  setup_fake_root
  PLAN_PREFIX=""
  PLAN_OPERATING_SYSTEM=macos
  # anything but exactly 1 leaves it off
  assert_contains "$(SIRVEN_MACOS_REAL_APPLY=true plan_real_apply_refusal)" "not verified yet"
  assert_contains "$(SIRVEN_MACOS_REAL_APPLY=0 plan_real_apply_refusal)" "not verified yet"
  # switched on but not root
  # shellcheck disable=SC2329 # called by plan_real_apply_refusal, in place of the real id
  id() { printf '501'; }
  assert_contains "$(SIRVEN_MACOS_REAL_APPLY=1 plan_real_apply_refusal)" "needs root"
  assert_contains "$(SIRVEN_MACOS_REAL_APPLY=1 plan_real_apply_refusal)" "sudo env SIRVEN_MACOS_REAL_APPLY=1"
  # switched on and root: allowed
  # shellcheck disable=SC2329 # same
  id() { printf '0'; }
  assert_eq "" "$(SIRVEN_MACOS_REAL_APPLY=1 plan_real_apply_refusal)" "allowed with the switch and root"
  # a fake root is always allowed, switch or not
  PLAN_PREFIX="$ROOT"
  assert_eq "" "$(plan_real_apply_refusal)" "a fake root needs no switch"
}

test_the_macos_switch_does_not_change_the_linux_refusal() {
  setup_fake_root
  PLAN_PREFIX=""
  PLAN_OPERATING_SYSTEM=linux
  # linux has no container rule any more (v0.2-linux-real-apply), so the switch must change nothing:
  # the refusal with it set is the refusal without it, whether that is "needs root" or nothing.
  assert_eq "$(plan_real_apply_refusal)" "$(SIRVEN_MACOS_REAL_APPLY=1 plan_real_apply_refusal)"
}

test_unknown_step_kind_is_an_error() {
  setup_fake_root
  assert_status 1 plan_step sideways "bad" "" "true"
  assert_contains "$CAPTURED_STDERR" "unknown kind"
}

test_summary_counts_every_kind() {
  setup_fake_root
  add_directory_step /a
  plan_owner "by hand" "text"
  plan_planonly "later" "command" "reason"
  plan_evaluate
  capture plan_summary
  assert_contains "$CAPTURED_STDOUT" "summary: 3 steps. 1 to do, 0 already done, 1 by the owner, 1 plan only."
}

test_apply_records_undo_only_for_steps_it_ran() {
  setup_fake_root
  mkdir -p "$ROOT/already"
  PLAN_RECORD_FILE="$ROOT/record.tsv"
  add_directory_step /already
  plan_undo "remove /already" "[ ! -d $ROOT/already ]" "rmdir $ROOT/already"
  add_directory_step /new
  plan_tag example
  plan_undo "remove /new" "[ ! -d $ROOT/new ]" "rmdir $ROOT/new"
  add_directory_step /no-undo
  plan_evaluate
  assert_status 0 plan_apply
  assert_eq "1" "$(grep -c . "$PLAN_RECORD_FILE")" "only the step this run created is recorded"
  assert_contains "$(cat "$PLAN_RECORD_FILE")" "run	example	-	create /new	remove /new"

  plan_reset
  add_directory_step /new
  plan_undo "remove /new" "[ ! -d $ROOT/new ]" "rmdir $ROOT/new"
  rmdir "$ROOT/new"
  plan_evaluate
  assert_status 0 plan_apply
  assert_eq "2" "$(grep -c . "$PLAN_RECORD_FILE")" "a different section makes a new line"
}

test_a_rerun_does_not_record_twice() {
  setup_fake_root
  PLAN_RECORD_FILE="$ROOT/record.tsv"
  mkdir -p "$ROOT"
  plan_step system "make a user" "" "useradd example"
  plan_undo "remove the user" "" "userdel example"
  plan_evaluate
  assert_status 0 plan_apply
  plan_reset
  plan_step system "make a user" "" "useradd example"
  plan_undo "remove the user" "" "userdel example"
  plan_evaluate
  : > "$PLAN_SIMULATION_LOG"
  plan_evaluate
  assert_status 0 plan_apply
  assert_eq "1" "$(grep -c . "$PLAN_RECORD_FILE")"
}

test_undo_must_fit_on_one_line() {
  setup_fake_root
  add_directory_step /one
  assert_status 1 plan_undo "remove" "" "rm -f a
rm -f b"
  assert_contains "$CAPTURED_STDERR" "must fit on one line"
  plan_section "a heading"
  assert_status 1 plan_undo "remove" "" "rm -f a"
}

record_outcome() {
  printf '%s %s %s %s\n' "$1" "$2" "${3:--}" "$5" >> "$TEST_TMP/hook.log"
}

test_step_hook_sees_every_outcome() {
  setup_fake_root
  mkdir -p "$ROOT/done"
  PLAN_STEP_HOOK=record_outcome
  add_directory_step /done
  add_directory_step /new
  plan_tag example
  plan_step system "make a user" "" "useradd example"
  plan_owner "click the button" "in the browser"
  plan_step run "break" "" "false"
  plan_evaluate
  assert_status 4 plan_apply
  assert_eq "1 run - skipped
2 run example applied
3 system - recorded
4 owner - owner
5 run - failed" "$(cat "$TEST_TMP/hook.log")"
}

test_an_owner_step_with_a_passing_check_is_done() {
  setup_fake_root
  mkdir -p "$ROOT"
  plan_owner "add a key" "paste it" "[ -d $ROOT ]"
  plan_owner "log in" "in the browser"
  plan_evaluate
  capture plan_print
  assert_contains "$CAPTURED_STDOUT" "add a key (already done)"
  assert_contains "$CAPTURED_STDOUT" "log in (owner, by hand)"
}

test_steps_assumed_undone_always_run() {
  setup_fake_root
  mkdir -p "$ROOT/there"
  add_directory_step /there
  plan_assume_undone
  add_directory_step /there
  plan_step system "make a user" "" "useradd example"
  mkdir -p "$(dirname "$PLAN_SIMULATION_LOG")"
  printf 'useradd example\n' > "$PLAN_SIMULATION_LOG"
  plan_evaluate
  assert_eq "done todo todo" "${PLAN_STATUS[0]} ${PLAN_STATUS[1]} ${PLAN_STATUS[2]}"
}

test_a_failed_continue_step_does_not_stop_the_steps_after_it() {
  setup_fake_root
  mkdir -p "$ROOT"
  plan_step run "a step that fails" "false" "false"
  plan_continue
  add_directory_step /after
  plan_step run "a second step that fails" "false" "false"
  plan_continue
  plan_evaluate
  assert_status 4 plan_apply
  assert_contains "$CAPTURED_STDERR" "the other steps still run"
  assert_contains "$CAPTURED_STDERR" "2 steps failed, each listed here, and the others ran:"
  assert_contains "$CAPTURED_STDERR" "step 1: a step that fails"
  assert_contains "$CAPTURED_STDERR" "step 3: a second step that fails"
  assert_file_exists "$ROOT/after"
}

test_a_step_that_is_not_continue_still_stops_the_run() {
  setup_fake_root
  mkdir -p "$ROOT"
  plan_step run "a step that fails" "false" "false"
  add_directory_step /after
  plan_evaluate
  assert_status 4 plan_apply
  assert_no_file "$ROOT/after"
}

test_recheck_reads_the_check_again_just_before_the_step() {
  setup_fake_root
  mkdir -p "$ROOT"
  # step 2 looks done when the plan is read (nothing is there) and is not done once step 1 has run
  plan_step run "make a file" "false" "touch $ROOT/made"
  plan_step run "remove it again" "[ ! -e $ROOT/made ]" "rm -f $ROOT/made && touch $ROOT/removed"
  plan_evaluate
  PLAN_RECHECK=yes
  assert_status 0 plan_apply
  PLAN_RECHECK=no
  assert_file_exists "$ROOT/removed"
  assert_no_file "$ROOT/made"
}

test_without_recheck_the_first_reading_stands() {
  setup_fake_root
  mkdir -p "$ROOT"
  plan_step run "make a file" "false" "touch $ROOT/made"
  plan_step run "remove it again" "[ ! -e $ROOT/made ]" "rm -f $ROOT/made && touch $ROOT/removed"
  plan_evaluate
  assert_status 0 plan_apply
  assert_no_file "$ROOT/removed"
  assert_file_exists "$ROOT/made"
}
