# shellcheck shell=bash
# install.sh end to end on a fake root: flags, dry run, apply, re-run, refusals.

install_sh() {
  SIRVEN_OS_OVERRIDE="${TEST_OS:-linux}" "$REPO_DIR/install.sh" "$@" --owner example
}

# the plan part of the output: everything before the summary, without the mode line.
plan_part() {
  printf '%s\n' "$1" | sed -n '/^summary:/q;p' | grep -v '^  mode:'
}

test_help_prints_usage() {
  assert_status 0 install_sh --help
  assert_contains "$CAPTURED_STDOUT" "usage:"
  assert_contains "$CAPTURED_STDOUT" "--transport NAME"
  assert_contains "$CAPTURED_STDOUT" "revoke --all"
}

test_unknown_flag_is_a_usage_error() {
  assert_status 64 install_sh --dry-run --sideways
  assert_contains "$CAPTURED_STDERR" "unknown option '--sideways'"
}

test_bad_level_and_transport_are_usage_errors() {
  assert_status 64 install_sh --dry-run --level admin
  assert_contains "$CAPTURED_STDERR" "--level must be observer, builder, or operator"
  assert_status 64 install_sh --dry-run --transport carrier-pigeon
  assert_contains "$CAPTURED_STDERR" "--transport must be tailscale, cloudflare, or none"
  assert_status 64 install_sh --dry-run --level
  assert_contains "$CAPTURED_STDERR" "--level needs a value"
}

test_relative_prefix_is_refused() {
  assert_status 64 install_sh --dry-run --prefix relative/root
  assert_contains "$CAPTURED_STDERR" "--prefix must be an absolute path"
}

test_dry_run_changes_nothing() {
  assert_status 0 install_sh --dry-run --prefix "$TEST_TMP/root" --level builder --path /home/example/project
  assert_no_file "$TEST_TMP/root"
  assert_contains "$CAPTURED_STDOUT" "dry run: nothing was changed."
  assert_contains "$CAPTURED_STDOUT" "setfacl -R -P -m u:agent:rwX $TEST_TMP/root/home/example/project"
}

test_default_level_is_observer() {
  assert_status 0 install_sh --dry-run --prefix "$TEST_TMP/root" --path /srv/app --transport none
  assert_contains "$CAPTURED_STDOUT" "level: observer (write allowed: false)"
  assert_contains "$CAPTURED_STDOUT" "u:agent:rX"
  assert_not_contains "$CAPTURED_STDOUT" "rwX"
}

test_dry_run_and_apply_print_the_same_plan() {
  local dry
  assert_status 0 install_sh --dry-run --prefix "$TEST_TMP/root" --level builder --path /srv/app --transport none
  dry="$(plan_part "$CAPTURED_STDOUT")"
  assert_status 0 install_sh --prefix "$TEST_TMP/root" --level builder --path /srv/app --transport none
  assert_eq "$dry" "$(plan_part "$CAPTURED_STDOUT")" "apply must print the identical plan"
  assert_contains "$CAPTURED_STDOUT" "applying"
}

test_apply_on_fake_root_then_rerun_is_idempotent() {
  local root="$TEST_TMP/root"
  assert_status 0 install_sh --prefix "$root" --level builder --path /home/example/project --transport none
  assert_file_exists "$root/etc/sirven/levels/builder.json"
  assert_file_exists "$root/etc/sirven/grants/agent.json"
  assert_file_exists "$root/etc/sirven/audit-format.json"
  assert_file_exists "$root/var/log/sirven/audit.jsonl"
  assert_contains "$(cat "$root/var/lib/sirven/simulated-system-commands.log")" "useradd --create-home --home-dir $root/home/agent"
  assert_contains "$(cat "$root/var/lib/sirven/simulated-system-commands.log")" "setfacl -R -P -m u:agent:rwX $root/home/example/project"
  assert_contains "$(cat "$root/etc/sirven/grants/agent.json")" '"can_grant": false'
  # ls shows modes the same way on linux and macos, unlike stat
  # shellcheck disable=SC2012
  assert_eq "-rw-r-----" "$(ls -l "$root/var/log/sirven/audit.jsonl" | cut -c1-10)" "audit log mode"
  # shellcheck disable=SC2012
  assert_eq "drwxr-x---" "$(ls -ld "$root/var/log/sirven" | cut -c1-10)" "audit directory mode"
  # shellcheck disable=SC2012
  assert_eq "drwx------" "$(ls -ld "$root/var/lib/sirven" | cut -c1-10)" "state directory mode"

  assert_status 0 install_sh --prefix "$root" --level builder --path /home/example/project --transport none
  assert_contains "$CAPTURED_STDOUT" "applied 0 steps"
  assert_not_contains "$CAPTURED_STDOUT" "(to do"
}

test_tailscale_apply_says_not_yet_and_changes_nothing() {
  assert_status 3 install_sh --prefix "$TEST_TMP/root" --level builder --path /srv/app --transport tailscale
  assert_contains "$CAPTURED_STDERR" "not yet"
  assert_contains "$CAPTURED_STDERR" "join the tailnet"
  assert_no_file "$TEST_TMP/root"
}

test_cloudflare_apply_says_not_yet() {
  assert_status 3 install_sh --prefix "$TEST_TMP/root" --path /srv/app --transport cloudflare
  assert_contains "$CAPTURED_STDERR" "cloudflare tunnel path is documented"
  assert_no_file "$TEST_TMP/root"
}

test_with_bb_is_a_plan_only_note() {
  assert_status 0 install_sh --dry-run --prefix "$TEST_TMP/root" --path /srv/app --transport none --with-bb
  assert_contains "$CAPTURED_STDOUT" "install bb for agent (plan only)"
  assert_contains "$CAPTURED_STDOUT" "orca install is not specified yet"
  assert_status 3 install_sh --prefix "$TEST_TMP/root" --path /srv/app --transport none --with-bb
  assert_no_file "$TEST_TMP/root"
}

test_macos_plan_is_plan_only() {
  TEST_OS=macos
  assert_status 0 install_sh --dry-run --prefix "$TEST_TMP/root" --level builder --path /Users/example/code/app --transport none
  assert_contains "$CAPTURED_STDOUT" "operating system: macos"
  assert_contains "$CAPTURED_STDOUT" "dscl . -create /Users/agent"
  assert_contains "$CAPTURED_STDOUT" "/bin/chmod +a"
  assert_not_contains "$CAPTURED_STDOUT" "setfacl"
  assert_status 3 install_sh --prefix "$TEST_TMP/root" --level builder --path /Users/example/code/app --transport none
  assert_contains "$CAPTURED_STDERR" "macos virtual machine"
}

test_paths_the_policy_refuses() {
  assert_status 2 install_sh --dry-run --prefix "$TEST_TMP/root" --path relative/path
  assert_contains "$CAPTURED_STDERR" "must be absolute"
  assert_status 2 install_sh --dry-run --prefix "$TEST_TMP/root" --path /home/example
  assert_contains "$CAPTURED_STDERR" "whole home directory"
  assert_status 2 install_sh --dry-run --prefix "$TEST_TMP/root" --path /home/example/.ssh
  assert_contains "$CAPTURED_STDERR" "keys or credentials"
  assert_status 2 install_sh --dry-run --prefix "$TEST_TMP/root" --path /etc/sirven
  assert_contains "$CAPTURED_STDERR" "belongs to the package itself"
  assert_status 2 install_sh --dry-run --prefix "$TEST_TMP/root" --path /var/log/sirven/audit.jsonl
  assert_contains "$CAPTURED_STDERR" "belongs to the package itself"
  assert_status 2 install_sh --dry-run --prefix "$TEST_TMP/root" --path /home/example/../../etc
  assert_contains "$CAPTURED_STDERR" "must not contain"
  TEST_OS=macos
  assert_status 2 install_sh --dry-run --prefix "$TEST_TMP/root" --path /Users/example/Documents/app
  assert_contains "$CAPTURED_STDERR" "privacy folder"
}

test_no_path_grants_nothing() {
  assert_status 0 install_sh --dry-run --prefix "$TEST_TMP/root" --transport none
  assert_contains "$CAPTURED_STDOUT" "no --path given"
  assert_not_contains "$CAPTURED_STDOUT" "setfacl"
}

test_revoke_needs_all() {
  assert_status 64 install_sh revoke --dry-run
  assert_contains "$CAPTURED_STDERR" "revoke needs --all"
  assert_status 64 install_sh --all --dry-run
}

test_revoke_reads_the_grant_record() {
  local root="$TEST_TMP/root"
  assert_status 0 install_sh --prefix "$root" --level builder --path /home/example/project --transport none
  assert_status 0 install_sh revoke --all --dry-run --prefix "$root"
  assert_contains "$CAPTURED_STDOUT" "setfacl -R -P -x u:agent $root/home/example/project"
  assert_contains "$CAPTURED_STDOUT" "usermod --lock --expiredate 1"
  assert_contains "$CAPTURED_STDOUT" "pkill -KILL -u agent"
  assert_contains "$CAPTURED_STDOUT" "revoke_started"
  assert_contains "$CAPTURED_STDOUT" "revoke_finished"
}

test_revoke_apply_says_not_yet() {
  local root="$TEST_TMP/root"
  assert_status 3 install_sh revoke --all --prefix "$root" --path /srv/app
  assert_contains "$CAPTURED_STDERR" "kill switch is plan output in the alpha cut"
  assert_no_file "$root"
}

test_real_apply_is_refused_outside_a_container() {
  if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
    return 0
  fi
  assert_status 3 "$REPO_DIR/install.sh" --path /srv/app --transport none
  assert_contains "$CAPTURED_STDERR" "not applied"
}

test_os_override_needs_dry_run_or_prefix() {
  assert_status 64 env SIRVEN_OS_OVERRIDE=macos "$REPO_DIR/install.sh" --transport none
  assert_contains "$CAPTURED_STDERR" "SIRVEN_OS_OVERRIDE only works with --dry-run or --prefix"
}

test_plan_never_mentions_passwords_being_set() {
  assert_status 0 install_sh --dry-run --prefix "$TEST_TMP/root" --level builder --path /srv/app
  assert_not_contains "$CAPTURED_STDOUT" "passwd "
  assert_not_contains "$CAPTURED_STDOUT" "sysadminctl -addUser"
  assert_contains "$CAPTURED_STDOUT" "usermod --password '*' agent"
}
