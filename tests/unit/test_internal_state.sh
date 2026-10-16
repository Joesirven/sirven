# shellcheck shell=bash
# internal state is never read from the environment. a variable that names a command or a function that runs as root, a file root writes,
# or that changes a safety decision (the folder prefix, the question before a real change) is set by sirven's own code and by nothing
# else: root can inherit an environment from anywhere (sudo -E, a root shell, a service). each test exports the variable, then checks
# that the code ignores it. a variable that is a test hook is honoured only in a test run (see sirven_test_run in lib/common.sh).

# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"

install_sh() {
  SIRVEN_OS_OVERRIDE=linux "$REPO_DIR/install.sh" "$@" --owner example
}

uninstall_sh() {
  SIRVEN_OS_OVERRIDE=linux "$REPO_DIR/uninstall.sh" "$@"
}

# a script that records that it ran, for a variable to name. the script is a plain file, as a planted one would be.
make_planted_script() {  # NAME: prints the script's path; it leaves NAME.ran beside it when it runs
  local script="$TEST_TMP/$1.sh"
  # shellcheck disable=SC2016 # the script body is text for the printf, not an expansion
  printf '#!/bin/sh\necho "$0 $*" >> "%s/%s.ran"\n' "$TEST_TMP" "$1" > "$script"
  chmod 0755 "$script"
  printf '%s' "$script"
}

# value_after_loading LIBRARY NAME VALUE: the value NAME has after the library is loaded into a shell that had NAME exported as VALUE
value_after_loading() {
  # shellcheck disable=SC2016 # the script body is text for bash -c
  env "$2=$3" bash -c '. "$1/lib/common.sh"; . "$1/lib/$2.sh"; printf "%s" "${!3}"' _ "$REPO_DIR" "$1" "$2"
}

assert_ignored_at_load() {  # LIBRARY NAME EXPECTED
  local value
  value="$(value_after_loading "$1" "$2" "planted-by-the-environment")"
  assert_eq "$3" "$value" "$2 must start from its fixed value, not from the environment (lib/$1.sh)"
}

# ---- the plan engine (lib/plan.sh)

test_plan_prefix_starts_from_its_fixed_value() {
  assert_ignored_at_load plan PLAN_PREFIX ""
}

test_plan_simulation_log_starts_from_its_fixed_value() {
  assert_ignored_at_load plan PLAN_SIMULATION_LOG ""
}

test_plan_operating_system_starts_from_its_fixed_value() {
  assert_ignored_at_load plan PLAN_OPERATING_SYSTEM linux
}

test_plan_record_file_starts_from_its_fixed_value() {
  assert_ignored_at_load plan PLAN_RECORD_FILE ""
}

test_plan_step_hook_starts_from_its_fixed_value() {
  assert_ignored_at_load plan PLAN_STEP_HOOK ""
}

test_plan_recheck_starts_from_its_fixed_value() {
  assert_ignored_at_load plan PLAN_RECHECK no
}

# the audit step hook is set by uninstall.sh only when the audit log is kept; with --remove-audit-log an exported hook would run after every step
test_an_exported_step_hook_does_not_run_on_an_uninstall_that_removes_the_audit_log() {
  local planted
  assert_status 0 install_sh --prefix "$TEST_TMP/root" --transport none --yes --level builder --path /home/example/project
  planted="$(make_planted_script step)"
  PLAN_STEP_HOOK="$planted" assert_status 0 uninstall_sh --prefix "$TEST_TMP/root" --yes --remove-audit-log
  assert_contains "$CAPTURED_STDOUT" "applied"
  assert_no_file "$TEST_TMP/step.ran"
}

test_an_exported_step_hook_does_not_run_on_install_or_revoke() {
  local planted
  planted="$(make_planted_script step)"
  PLAN_STEP_HOOK="$planted" assert_status 0 install_sh --prefix "$TEST_TMP/root" --transport none --yes --level builder --path /home/example/project
  PLAN_STEP_HOOK="$planted" assert_status 0 install_sh revoke --all --prefix "$TEST_TMP/root" --yes
  assert_no_file "$TEST_TMP/step.ran"
}

# the install record is appended to (and made mode 0600) by root: the file is not the environment's to name
test_an_exported_record_file_is_not_written() {
  local victim="$TEST_TMP/victim"
  # shellcheck disable=SC2016 # the script body is text for bash -c
  PLAN_RECORD_FILE="$victim" assert_status 0 bash -c '. "$1/lib/common.sh"; . "$1/lib/plan.sh"; PLAN_PREFIX="$2"; PLAN_SIMULATION_LOG=""; plan_reset
    plan_step run "make a file" "false" "true"; plan_undo "undo it" "false" "true"; plan_evaluate; plan_apply' _ "$REPO_DIR" "$TEST_TMP/fake"
  assert_no_file "$victim"
}

# the simulation log is appended to by a fake-root run: the file is not the environment's to name
test_an_exported_simulation_log_is_not_written() {
  local victim="$TEST_TMP/victim-log"
  PLAN_SIMULATION_LOG="$victim" assert_status 0 install_sh --prefix "$TEST_TMP/root" --transport none --yes --level builder --path /home/example/project
  assert_no_file "$victim"
}

# the folder prefix decides whether this is a fake root (no refusal, no question, nothing real) or the real machine. an exported prefix must
# not turn a real apply into a fake one: the apply is refused (not root) or waits for a yes it does not get, and nothing is changed
test_an_exported_prefix_does_not_turn_a_real_apply_into_a_fake_one() {
  # shellcheck disable=SC2016 # the script body is text for bash -c
  PLAN_PREFIX="$TEST_TMP/fake" assert_status 3 bash -c '. "$1/lib/common.sh"; . "$1/lib/plan.sh"; PLAN_SIMULATION_LOG=""; plan_reset
    plan_step run "make a file" "[ -e $2 ]" "touch $2"; plan_evaluate; plan_apply' _ "$REPO_DIR" "$TEST_TMP/made"
  assert_no_file "$TEST_TMP/made"
}

test_an_exported_confirmation_and_recheck_are_not_taken() {
  local out
  # shellcheck disable=SC2016 # the script body is text for bash -c
  out="$(PLAN_CONFIRMED=yes PLAN_RECHECK=yes bash -c '. "$1/lib/common.sh"; . "$1/lib/plan.sh"; printf "%s|%s" "$PLAN_CONFIRMED" "$PLAN_RECHECK"' _ "$REPO_DIR")"
  assert_eq "no|no" "$out"
}

# ---- the audit writer (lib/audit.sh)

test_audit_operation_starts_from_its_fixed_value() {
  assert_ignored_at_load audit AUDIT_OPERATION install
}

test_audit_pending_starts_from_its_fixed_value() {
  assert_ignored_at_load audit AUDIT_PENDING ""
}

# the pending audit file is written by root
test_an_exported_pending_audit_file_is_not_written() {
  local victim="$TEST_TMP/victim.jsonl"
  # shellcheck disable=SC2016 # the script body is text for bash -c
  AUDIT_PENDING="$victim" bash -c '. "$1/lib/common.sh"; . "$1/lib/audit.sh"; PREFIX="$2"; AUDIT_DIR="/var/log/nowhere"; audit_write "{\"n\": 1}"' _ "$REPO_DIR" "$TEST_TMP/fake" > /dev/null 2>&1 || true
  assert_no_file "$victim"
}
