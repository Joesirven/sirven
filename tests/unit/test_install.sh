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
  assert_contains "$CAPTURED_STDOUT" "grant-access $TEST_TMP/root/home/example/project yes agent rwX"
}

test_default_level_is_observer() {
  assert_status 0 install_sh --dry-run --prefix "$TEST_TMP/root" --path /srv/app --transport none
  assert_contains "$CAPTURED_STDOUT" "level: observer (write allowed: false)"
  assert_contains "$CAPTURED_STDOUT" "yes agent rX"
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
  assert_contains "$(cat "$root/var/lib/sirven/simulated-system-commands.log")" "grant-access $root/home/example/project yes agent rwX"
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
  assert_contains "$CAPTURED_STDOUT" "/bin/chmod -h +a"
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
  assert_contains "$CAPTURED_STDOUT" "access_control_snapshot.sh restore"
  assert_contains "$CAPTURED_STDOUT" "$root/home/example/project yes agent"
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

test_real_apply_is_refused_without_root() {
  # as root this would really apply to the machine running the tests, so only a non-root run is checked here.
  if [ "$(id -u)" = 0 ]; then
    return 0
  fi
  assert_status 3 "$REPO_DIR/install.sh" --path /srv/app --transport none
  assert_contains "$CAPTURED_STDERR" "applying needs root"
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

test_apply_keeps_a_pinned_copy_that_revoke_runs_from() {
  local root="$TEST_TMP/root" copy
  copy="$root/var/lib/sirven/package"
  export SIRVEN_PACKAGE_TAG=v0.2.0 SIRVEN_PACKAGE_SHA256=abc123
  assert_status 0 install_sh --prefix "$root" --transport none
  unset SIRVEN_PACKAGE_TAG SIRVEN_PACKAGE_SHA256
  assert_file_exists "$copy/install.sh"
  assert_file_exists "$copy/uninstall.sh"
  assert_file_exists "$copy/lib/layout.sh"
  assert_file_exists "$copy/levels/observer.json"
  assert_no_file "$copy/tests"
  assert_contains "$(cat "$copy/PINNED-COPY")" "tag=v0.2.0"
  assert_contains "$(cat "$copy/PINNED-COPY")" "sha256=abc123"
  assert_status 0 env SIRVEN_OS_OVERRIDE=linux SIRVEN_TAILSCALE=none SIRVEN_BB=none \
    "$BASH" "$copy/install.sh" revoke --all --dry-run --prefix "$root"
  assert_contains "$CAPTURED_STDOUT" "dry run: nothing was changed."
}

test_a_checkout_install_records_the_copy_as_unpinned() {
  local root="$TEST_TMP/root"
  assert_status 0 install_sh --prefix "$root" --transport none
  assert_contains "$(cat "$root/var/lib/sirven/package/PINNED-COPY")" "tag=unpinned"
}

test_rerun_from_the_same_release_leaves_the_copy_alone() {
  local root="$TEST_TMP/root" copy
  copy="$root/var/lib/sirven/package"
  export SIRVEN_PACKAGE_TAG=v0.2.0 SIRVEN_PACKAGE_SHA256=abc123
  assert_status 0 install_sh --prefix "$root" --transport none
  printf 'marker\n' > "$copy/keep-me"
  assert_status 0 install_sh --prefix "$root" --transport none
  assert_contains "$CAPTURED_STDOUT" "applied 0 steps"
  assert_file_exists "$copy/keep-me"
}

test_rerun_from_a_new_release_replaces_the_copy() {
  local root="$TEST_TMP/root" copy
  copy="$root/var/lib/sirven/package"
  export SIRVEN_PACKAGE_TAG=v0.2.0 SIRVEN_PACKAGE_SHA256=old
  assert_status 0 install_sh --prefix "$root" --transport none
  printf 'marker\n' > "$copy/keep-me"
  export SIRVEN_PACKAGE_TAG=v0.3.0 SIRVEN_PACKAGE_SHA256=new
  assert_status 0 install_sh --prefix "$root" --transport none
  assert_contains "$CAPTURED_STDOUT" "applied 1 steps"
  assert_contains "$(cat "$copy/PINNED-COPY")" "tag=v0.3.0"
  assert_contains "$(cat "$copy/PINNED-COPY")" "sha256=new"
  assert_no_file "$copy/keep-me"
  assert_file_exists "$copy/lib/layout.sh"
}

test_a_checkout_rerun_replaces_a_pinned_copy_with_its_own_files() {
  local root="$TEST_TMP/root" copy
  copy="$root/var/lib/sirven/package"
  export SIRVEN_PACKAGE_TAG=v0.2.0 SIRVEN_PACKAGE_SHA256=old
  assert_status 0 install_sh --prefix "$root" --transport none
  unset SIRVEN_PACKAGE_TAG SIRVEN_PACKAGE_SHA256
  assert_status 0 install_sh --prefix "$root" --transport none
  assert_contains "$(cat "$copy/PINNED-COPY")" "tag=unpinned"
}

test_a_failed_copy_leaves_no_package_folder_and_no_marker() {
  local root="$TEST_TMP/root" source
  source="$TEST_TMP/source"
  . "$REPO_DIR/lib/common.sh"
  . "$REPO_DIR/lib/layout.sh"
  mkdir -p "$source"
  for item in install.sh uninstall.sh bin levels project.json components; do
    cp -R "$REPO_DIR/$item" "$source/"
  done
  mkdir -p "$root/var/lib/sirven"
  capture layout_keep_package "$source" "$root/var/lib/sirven/package"
  assert_eq 1 "$CAPTURED_STATUS" "a source without lib/ is an error"
  assert_contains "$CAPTURED_STDERR" "the package has no lib to keep"
  assert_no_file "$root/var/lib/sirven/package"
  assert_no_file "$root/var/lib/sirven/package.new"
}

test_a_failed_copy_keeps_the_old_copy_it_was_replacing() {
  local root="$TEST_TMP/root" source copy
  copy="$root/var/lib/sirven/package"
  . "$REPO_DIR/lib/common.sh"
  . "$REPO_DIR/lib/layout.sh"
  export SIRVEN_PACKAGE_TAG=v0.2.0 SIRVEN_PACKAGE_SHA256=old
  assert_status 0 install_sh --prefix "$root" --transport none
  source="$TEST_TMP/source"
  mkdir -p "$source"
  for item in install.sh uninstall.sh bin levels project.json; do
    cp -R "$REPO_DIR/$item" "$source/"
  done
  capture layout_keep_package "$source" "$copy"
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$(cat "$copy/PINNED-COPY")" "tag=v0.2.0"
  assert_file_exists "$copy/lib/layout.sh"
}

test_the_installer_run_from_its_copy_never_deletes_it() {
  local root="$TEST_TMP/root" copy
  copy="$root/var/lib/sirven/package"
  export SIRVEN_PACKAGE_TAG=v0.2.0 SIRVEN_PACKAGE_SHA256=abc123
  assert_status 0 install_sh --prefix "$root" --transport none
  rm -f "$copy/PINNED-COPY"
  assert_status 0 env SIRVEN_OS_OVERRIDE=linux SIRVEN_TAILSCALE=none SIRVEN_BB=none \
    "$BASH" "$copy/install.sh" --prefix "$root" --transport none --owner example --yes
  assert_contains "$CAPTURED_STDOUT" "runs from its pinned copy"
  assert_file_exists "$copy/lib/layout.sh"
  assert_file_exists "$copy/levels/observer.json"
  assert_file_exists "$copy/install.sh"
}

test_the_kept_copy_has_no_group_or_other_write_bits() {
  local root="$TEST_TMP/root" source copy mode
  copy="$root/var/lib/sirven/package"
  . "$REPO_DIR/lib/common.sh"
  . "$REPO_DIR/lib/layout.sh"
  mkdir -p "$root/var/lib/sirven" "$TEST_TMP/source"
  source="$TEST_TMP/source"
  for item in install.sh uninstall.sh bin lib levels project.json; do
    cp -R "$REPO_DIR/$item" "$source/"
  done
  # the source is writable by others, as a checkout in a shared folder can be: the copy must not be
  chmod 666 "$source/lib/layout.sh"
  chmod 777 "$source/bin"
  # a permissive umask would keep the group and other write bits, so only the explicit chmod removes them
  umask 000
  assert_status 0 layout_keep_package "$source" "$copy"
  # shellcheck disable=SC2012
  mode="$(ls -l "$copy/lib/layout.sh" | cut -c1-10)"
  assert_eq "-" "$(printf '%s' "$mode" | cut -c6)" "group write on the kept file"
  assert_eq "-" "$(printf '%s' "$mode" | cut -c9)" "other write on the kept file"
  # shellcheck disable=SC2012
  mode="$(ls -ld "$copy/bin" | cut -c1-10)"
  assert_eq "-" "$(printf '%s' "$mode" | cut -c6)" "group write on the kept folder"
  assert_eq "-" "$(printf '%s' "$mode" | cut -c9)" "other write on the kept folder"
}

test_a_copy_path_outside_the_state_directory_is_refused() {
  local source="$TEST_TMP/source"
  . "$REPO_DIR/lib/common.sh"
  . "$REPO_DIR/lib/layout.sh"
  mkdir -p "$source"
  for item in install.sh uninstall.sh bin lib levels components project.json; do
    cp -R "$REPO_DIR/$item" "$source/"
  done
  capture layout_keep_package "$source" "$TEST_TMP/not-a-package-copy"
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "refusing to keep a copy"
}

test_a_checkout_rerun_is_idempotent_and_refreshes_after_an_edit() {
  local root="$TEST_TMP/root" copy
  copy="$root/var/lib/sirven/package"
  unset SIRVEN_PACKAGE_TAG SIRVEN_PACKAGE_SHA256
  assert_status 0 install_sh --prefix "$root" --transport none
  assert_status 0 install_sh --prefix "$root" --transport none
  assert_contains "$CAPTURED_STDOUT" "applied 0 steps"
  # the copy is a snapshot: an edit to the source must reach it on the next run, not stay behind
  cp -R "$REPO_DIR/lib" "$TEST_TMP/lib-copy"
  printf '# edited\n' >> "$TEST_TMP/lib-copy/layout.sh"
  mkdir -p "$TEST_TMP/checkout"
  for item in install.sh uninstall.sh bin levels components project.json; do cp -R "$REPO_DIR/$item" "$TEST_TMP/checkout/"; done
  cp -R "$TEST_TMP/lib-copy" "$TEST_TMP/checkout/lib"
  assert_status 0 env SIRVEN_OS_OVERRIDE=linux SIRVEN_TAILSCALE=none SIRVEN_BB=none \
    "$BASH" "$TEST_TMP/checkout/install.sh" --prefix "$root" --transport none --owner example --yes
  assert_contains "$CAPTURED_STDOUT" "applied 1 steps"
  assert_contains "$(cat "$copy/lib/layout.sh")" "# edited"
}

test_a_required_file_that_cannot_be_copied_fails_the_step_and_leaves_nothing() {
  local root="$TEST_TMP/root" source
  source="$TEST_TMP/source"
  . "$REPO_DIR/lib/common.sh"
  . "$REPO_DIR/lib/layout.sh"
  # a root account reads unreadable files, so the failure cannot be made under root
  [ "$(id -u)" -ne 0 ] || return 0
  mkdir -p "$source"
  for item in install.sh uninstall.sh bin lib levels project.json; do
    cp -R "$REPO_DIR/$item" "$source/"
  done
  chmod 000 "$source/lib/layout.sh"
  mkdir -p "$root/var/lib/sirven"
  capture layout_keep_package "$source" "$root/var/lib/sirven/package"
  assert_eq 1 "$CAPTURED_STATUS" "a file that cannot be read is a failed copy, not a finished one"
  assert_contains "$CAPTURED_STDERR" "could not copy lib"
  assert_no_file "$root/var/lib/sirven/package"
  assert_no_file "$root/var/lib/sirven/package.new"
}
