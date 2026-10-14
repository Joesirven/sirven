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

test_real_apply_is_refused_outside_a_container() {
  if in_container; then
    return 0
  fi
  setup_fake_root
  PLAN_PREFIX=""
  add_directory_step /etc/sirven
  plan_evaluate
  assert_status 3 plan_apply
  assert_contains "$CAPTURED_STDERR" "throwaway container"
  assert_no_file "$ROOT/etc/sirven"
}

test_real_apply_on_macos_is_refused() {
  setup_fake_root
  PLAN_PREFIX=""
  PLAN_OPERATING_SYSTEM=macos
  assert_contains "$(plan_real_apply_refusal)" "not verified yet"
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
