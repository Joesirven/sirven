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
  printf '#!/bin/sh\necho "$0 $*" >> "%s/%s.ran"\n' "$TEST_TMP" "$1" > "$script"
  chmod 0755 "$script"
  printf '%s' "$script"
}

# value_after_loading LIBRARY NAME VALUE: the value NAME has after the library is loaded into a shell that had NAME exported as VALUE
value_after_loading() {
  env "$2=$3" bash -c '. "$1/lib/common.sh"; . "$1/lib/$2.sh"; printf "%s" "${!3}"' _ "$REPO_DIR" "$1" "$2"
}

assert_ignored_at_load() {  # LIBRARY NAME EXPECTED
  local value
  value="$(value_after_loading "$1" "$2" "planted-by-the-environment")"
  assert_eq "$3" "$value" "$2 must start from its fixed value, not from the environment (lib/$1.sh)"
}

test_every_plan_variable_starts_from_its_fixed_value() {
  assert_ignored_at_load plan PLAN_PREFIX ""
  assert_ignored_at_load plan PLAN_SIMULATION_LOG ""
  assert_ignored_at_load plan PLAN_OPERATING_SYSTEM linux
  assert_ignored_at_load plan PLAN_RECORD_FILE ""
  assert_ignored_at_load plan PLAN_STEP_HOOK ""
  assert_ignored_at_load plan PLAN_RECHECK no
  assert_ignored_at_load plan PLAN_BEFORE_FIRST_CHANGE ""
}

test_the_audit_variables_start_from_their_fixed_values() {
  assert_ignored_at_load audit AUDIT_OPERATION install
  assert_ignored_at_load audit AUDIT_PENDING ""
}

test_the_preflight_commands_start_from_their_fixed_values() {
  assert_ignored_at_load preflight PREFLIGHT_SSH_COMMAND ssh
  assert_ignored_at_load preflight PREFLIGHT_SYSTEM_PYTHON /usr/bin/python3
}

test_the_cloudflare_answers_start_empty_and_come_from_the_arguments() {
  assert_ignored_at_load cloudflare CLOUDFLARE_HOSTNAME ""
  assert_ignored_at_load cloudflare CLOUDFLARE_ACCOUNT ""
  assert_ignored_at_load cloudflare CLOUDFLARE_ZONE ""
}

# R1: the function or script named by PLAN_BEFORE_FIRST_CHANGE runs after the owner has confirmed, as root on a real run. install.sh sets
# it only for a Cloudflare install, so on every other path an exported value must change nothing.
test_an_exported_hook_before_the_first_change_does_not_run_on_a_non_cloudflare_install() {
  local planted
  planted="$(make_planted_script before)"
  PLAN_BEFORE_FIRST_CHANGE="$planted" assert_status 0 install_sh --prefix "$TEST_TMP/root" --transport none --yes --level builder --path /home/example/project
  assert_contains "$CAPTURED_STDOUT" "applied"
  assert_no_file "$TEST_TMP/before.ran"
  # the control: the same script is run when something of sirven's own names it
  # shellcheck disable=SC2016 # the script body is text for bash -c
  bash -c '. "$1/lib/common.sh"; . "$1/lib/plan.sh"; PLAN_PREFIX="$2"; PLAN_SIMULATION_LOG=""; plan_reset; plan_step run "t" "false" "true"; plan_evaluate; PLAN_BEFORE_FIRST_CHANGE="$3"; plan_apply' _ "$REPO_DIR" "$TEST_TMP/control" "$planted" > /dev/null 2>&1
  assert_file_exists "$TEST_TMP/before.ran"
}

test_an_exported_hook_before_the_first_change_does_not_run_on_revoke_or_uninstall() {
  local planted
  assert_status 0 install_sh --prefix "$TEST_TMP/root" --transport none --yes --level builder --path /home/example/project
  planted="$(make_planted_script before)"
  PLAN_BEFORE_FIRST_CHANGE="$planted" assert_status 0 install_sh revoke --all --prefix "$TEST_TMP/root" --yes
  assert_no_file "$TEST_TMP/before.ran"
  PLAN_BEFORE_FIRST_CHANGE="$planted" assert_status 0 uninstall_sh --prefix "$TEST_TMP/root" --yes
  assert_no_file "$TEST_TMP/before.ran"
}

test_an_exported_hook_before_the_first_change_does_not_run_on_a_repeat_install() {
  local planted
  assert_status 0 install_sh --prefix "$TEST_TMP/root" --transport none --yes --level builder --path /home/example/project
  planted="$(make_planted_script before)"
  PLAN_BEFORE_FIRST_CHANGE="$planted" assert_status 0 install_sh --prefix "$TEST_TMP/root" --transport none --yes --level builder --path /home/example/project
  assert_no_file "$TEST_TMP/before.ran"
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

# the folder prefix decides whether this is a fake root (no questions, nothing real) or the real machine; the confirmation and the recheck
# are safety decisions too
test_an_exported_prefix_does_not_turn_a_real_apply_into_a_fake_one() {
  local refusal
  # shellcheck disable=SC2016 # the script body is text for bash -c
  refusal="$(PLAN_PREFIX="$TEST_TMP/fake" PLAN_OPERATING_SYSTEM=macos bash -c '. "$1/lib/common.sh"; . "$1/lib/plan.sh"; plan_real_apply_refusal' _ "$REPO_DIR")"
  if [ "$(id -u)" -ne 0 ]; then
    assert_contains "$refusal" "applying needs root"
  fi
}

test_an_exported_confirmation_and_recheck_are_not_taken() {
  local out
  # shellcheck disable=SC2016 # the script body is text for bash -c
  out="$(PLAN_CONFIRMED=yes PLAN_RECHECK=yes bash -c '. "$1/lib/common.sh"; . "$1/lib/plan.sh"; printf "%s|%s" "$PLAN_CONFIRMED" "$PLAN_RECHECK"' _ "$REPO_DIR")"
  assert_eq "no|no" "$out"
}

# preflight runs the SSH client as root before the owner has said yes
test_an_exported_ssh_command_is_not_run_by_the_preflight() {
  local planted
  planted="$(make_planted_script ssh)"
  # shellcheck disable=SC2016 # the script body is text for bash -c
  PREFLIGHT_SSH_COMMAND="$planted" bash -c '. "$1/lib/common.sh"; . "$1/lib/preflight.sh"; preflight_ssh_server yes' _ "$REPO_DIR" > /dev/null 2>&1 || true
  assert_no_file "$TEST_TMP/ssh.ran"
}

# the pending audit file is written by root
test_an_exported_pending_audit_file_is_not_written() {
  local victim="$TEST_TMP/victim.jsonl"
  # shellcheck disable=SC2016 # the script body is text for bash -c
  AUDIT_PENDING="$victim" bash -c '. "$1/lib/common.sh"; . "$1/lib/audit.sh"; PREFIX="$2"; AUDIT_DIR="/var/log/nowhere"; audit_write "{\"n\": 1}"' _ "$REPO_DIR" "$TEST_TMP/fake" > /dev/null 2>&1 || true
  assert_no_file "$victim"
}

# ---- the shared test-run rule (lib/common.sh): not root, or root with the marker only a test container's setup makes

test_a_test_run_is_any_process_that_is_not_root() {
  # shellcheck disable=SC2329 # called by sirven_test_run in lib/common.sh
  id() { printf '1000'; }
  assert_status 0 sirven_test_run "$TEST_TMP/no-such-marker"
}

test_as_root_a_test_run_needs_the_marker_and_the_marker_must_be_root_owned_and_private() {
  # shellcheck disable=SC2329 # called by sirven_test_run in lib/common.sh
  id() { printf '0'; }
  assert_status 1 sirven_test_run "$TEST_TMP/no-such-marker"
  : > "$TEST_TMP/marker"
  chmod 0600 "$TEST_TMP/marker"
  if [ "$(command id -u)" -eq 0 ]; then
    assert_status 0 sirven_test_run "$TEST_TMP/marker"
    chmod 0620 "$TEST_TMP/marker"
    assert_status 1 sirven_test_run "$TEST_TMP/marker"
    chmod 0602 "$TEST_TMP/marker"
    assert_status 1 sirven_test_run "$TEST_TMP/marker"
    rm -f "$TEST_TMP/marker"
    ln -s /etc/hostname "$TEST_TMP/marker"
    assert_status 1 sirven_test_run "$TEST_TMP/marker"
  else
    # not root: the file is ours, not root's, so a marker we made ourselves is refused
    assert_status 1 sirven_test_run "$TEST_TMP/marker"
    mkdir "$TEST_TMP/folder-marker"
    assert_status 1 sirven_test_run "$TEST_TMP/folder-marker"
  fi
}

# the commands the adopt step probes are seams for tests: root runs only what the vetted search path finds
test_as_root_the_adopt_seams_are_ignored_without_the_marker() {
  local planted
  planted="$(make_planted_script tailscale)"
  # shellcheck disable=SC2329 # called by the library
  id() { printf '0'; }
  # shellcheck source=lib/adopt.sh
  . "$REPO_DIR/lib/adopt.sh"
  PREFIX="$TEST_TMP/fake"
  SIRVEN_TAILSCALE="$planted"
  SIRVEN_BB="$planted"
  assert_eq "" "$(_adopt_tailscale_command)" "root, no marker: the seam names nothing"
  assert_eq "" "$(_adopt_command "$(adopt_seam SIRVEN_BB)" bb)"
}

test_not_as_root_the_adopt_seams_are_honoured() {
  local planted
  planted="$(make_planted_script tailscale)"
  # shellcheck disable=SC2329 # called by the library
  id() { printf '1000'; }
  # shellcheck source=lib/adopt.sh
  . "$REPO_DIR/lib/adopt.sh"
  PREFIX="$TEST_TMP/fake"
  SIRVEN_TAILSCALE="$planted"
  assert_eq "$planted" "$(_adopt_tailscale_command)"
  SIRVEN_TAILSCALE=none
  assert_eq "" "$(_adopt_tailscale_command)"
}

test_the_adopt_seam_check_says_when_a_seam_is_ignored_as_root() {
  # shellcheck disable=SC2329 # called by the library
  id() { printf '0'; }
  # shellcheck source=lib/adopt.sh
  . "$REPO_DIR/lib/adopt.sh"
  DRY_RUN=yes
  PREFIX=""
  SIRVEN_TAILSCALE=none
  SIRVEN_BB=""
  capture adopt_check_seams
  assert_contains "$CAPTURED_STDERR" "SIRVEN_TAILSCALE"
  assert_contains "$CAPTURED_STDERR" "ignored"
}

# the keep-awake program is run by the user who asked for it, never by root from an inherited variable
test_as_root_the_keep_awake_variable_is_ignored() {
  local planted
  planted="$(make_planted_script awake)"
  # shellcheck disable=SC2016 # the script body is text for bash -c
  SIRVEN_KEEP_AWAKE_BIN="$planted" SIRVEN_OS_OVERRIDE=macos bash -c '
    id() { printf "0"; }
    export -f id
    ROOT_DIR="$1"; . "$1/lib/common.sh"
    eval "$(sed -n "/^keep_awake()/,/^}/p" "$1/bin/sirven")"
    keep_awake' _ "$REPO_DIR" > /dev/null 2>&1 || true
  assert_no_file "$TEST_TMP/awake.ran"
}

# ---- the API program clears OPENSSL_CONF (and the proxy and certificate variables) before the ssl module is loaded: OpenSSL reads the
# configuration file once, when the module loads, so clearing it afterwards does nothing

# ssl_environment_at_load: what the environment holds, for each of the names, at the moment the ssl module is first loaded by the program
ssl_environment_at_load() {
  env OPENSSL_CONF=/nonexistent/openssl.cnf SSL_CERT_FILE=/nonexistent/ca.pem https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 SSLKEYLOGFILE=/nonexistent/keys \
    python3 -I -c '
import builtins, os, runpy, sys
seen = []
real_import = builtins.__import__
def spy(name, *arguments, **keywords):
    if name == "ssl" and "ssl" not in sys.modules:
        seen.append(",".join(sorted(key for key in ("OPENSSL_CONF", "SSL_CERT_FILE", "https_proxy", "HTTPS_PROXY", "SSLKEYLOGFILE") if key in os.environ)))
    return real_import(name, *arguments, **keywords)
builtins.__import__ = spy
runpy.run_path(sys.argv[1], run_name="not_the_program")
print("loaded" if seen else "ssl-not-loaded")
print(seen[0] if seen else "")' "$REPO_DIR/lib/cloudflare_api.py"
}

test_the_openssl_configuration_is_cleared_before_the_ssl_module_is_loaded() {
  local result
  result="$(ssl_environment_at_load)"
  assert_contains "$result" "loaded" "the program loads ssl, so the order matters"
  assert_eq "" "$(printf '%s\n' "$result" | sed -n 2p)" "no proxy, certificate or OpenSSL variable is left when ssl is loaded"
}

test_the_openssl_configuration_is_still_cleared_when_the_client_is_made() {
  local left
  left="$(env OPENSSL_CONF=/nonexistent/openssl.cnf python3 -I -c '
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("cloudflare_api", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
os.environ["OPENSSL_CONF"] = "/nonexistent/again"
module.clear_environment()
print(os.environ.get("OPENSSL_CONF", "cleared"))' "$REPO_DIR/lib/cloudflare_api.py")"
  assert_eq cleared "$left"
}
