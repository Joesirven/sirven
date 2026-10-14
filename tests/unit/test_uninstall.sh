# shellcheck shell=bash
# uninstall.sh on a fake root: it reverses only what the install record lists, in reverse order.

install_sh() {
  SIRVEN_OS_OVERRIDE=linux "$REPO_DIR/install.sh" "$@" --owner example
}

uninstall_sh() {
  SIRVEN_OS_OVERRIDE=linux "$REPO_DIR/uninstall.sh" "$@"
}

install_on_fake_root() {
  ROOT="$TEST_TMP/root"
  assert_status 0 install_sh --prefix "$ROOT" --level builder --path /home/example/project --transport none
}

test_help_prints_usage() {
  assert_status 0 uninstall_sh --help
  assert_contains "$CAPTURED_STDOUT" "--remove-audit-log"
  assert_status 64 uninstall_sh --sideways
  assert_status 64 uninstall_sh --prefix relative/root
}

test_nothing_recorded_means_nothing_removed() {
  assert_status 0 uninstall_sh --prefix "$TEST_TMP/root"
  assert_contains "$CAPTURED_STDOUT" "there is nothing it may remove"
  assert_no_file "$TEST_TMP/root"
}

test_dry_run_prints_the_reverse_and_changes_nothing() {
  local grant_line user_line directory_line
  install_on_fake_root
  assert_status 0 uninstall_sh --dry-run --prefix "$ROOT"
  assert_contains "$CAPTURED_STDOUT" "dry run: nothing was changed."
  assert_contains "$CAPTURED_STDOUT" "access_control_snapshot.sh restore $ROOT/var/lib/sirven/access-lists/"
  assert_contains "$CAPTURED_STDOUT" "$ROOT/home/example/project yes agent"
  assert_contains "$CAPTURED_STDOUT" "userdel agent"
  grant_line="$(printf '%s\n' "$CAPTURED_STDOUT" | grep -n 'put back the access control lists of /home/example/project' | cut -d: -f1)"
  user_line="$(printf '%s\n' "$CAPTURED_STDOUT" | grep -n 'remove the account' | cut -d: -f1)"
  directory_line="$(printf '%s\n' "$CAPTURED_STDOUT" | grep -n 'remove /etc/sirven if' | cut -d: -f1)"
  [ "$grant_line" -lt "$user_line" ] || fail "access is removed before the account"
  [ "$user_line" -lt "$directory_line" ] || fail "the account is removed before the package directories"
  assert_file_exists "$ROOT/etc/sirven/grants/agent.json"
  assert_file_exists "$ROOT/var/lib/sirven/install-record.tsv"
}

test_apply_removes_what_install_created_and_keeps_the_audit_log() {
  install_on_fake_root
  assert_status 0 uninstall_sh --prefix "$ROOT"
  assert_no_file "$ROOT/etc/sirven"
  assert_no_file "$ROOT/var/lib/sirven"
  assert_file_exists "$ROOT/var/log/sirven/audit.jsonl"
  assert_contains "$(tail -n 1 "$ROOT/var/log/sirven/audit.jsonl")" '"event": "uninstall"'
  assert_contains "$CAPTURED_STDOUT" "kept on purpose: the service user's home folder"
  assert_status 0 uninstall_sh --prefix "$ROOT"
  assert_contains "$CAPTURED_STDOUT" "there is nothing it may remove"
}

test_remove_audit_log_removes_it_too() {
  install_on_fake_root
  assert_status 0 uninstall_sh --prefix "$ROOT" --remove-audit-log
  assert_no_file "$ROOT/var/log/sirven"
  assert_no_file "$ROOT/etc/sirven"
}

test_what_was_there_before_the_install_stays() {
  ROOT="$TEST_TMP/root"
  mkdir -p "$ROOT/etc/sirven"
  printf 'the owner wrote this\n' > "$ROOT/etc/sirven/owner-notes.txt"
  install_on_fake_root
  assert_not_contains "$(cat "$ROOT/var/lib/sirven/install-record.tsv")" "remove /etc/sirven if"
  assert_status 0 uninstall_sh --prefix "$ROOT"
  assert_not_contains "$CAPTURED_STDOUT" "remove /etc/sirven if"
  assert_file_exists "$ROOT/etc/sirven/owner-notes.txt"
  assert_no_file "$ROOT/etc/sirven/levels"
  assert_no_file "$ROOT/etc/sirven/grants"
}

test_a_created_directory_with_foreign_files_is_kept() {
  install_on_fake_root
  printf 'not from the package\n' > "$ROOT/etc/sirven/grants/someone-else.json"
  assert_status 0 uninstall_sh --prefix "$ROOT"
  assert_contains "$CAPTURED_STDOUT" "kept $ROOT/etc/sirven/grants: it holds files this package did not create"
  assert_file_exists "$ROOT/etc/sirven/grants/someone-else.json"
  assert_no_file "$ROOT/etc/sirven/grants/agent.json"
}

test_a_damaged_record_is_refused_before_any_change() {
  install_on_fake_root
  printf 'sideways\tx\n' >> "$ROOT/var/lib/sirven/install-record.tsv"
  assert_status 2 uninstall_sh --prefix "$ROOT"
  assert_contains "$CAPTURED_STDERR" "unknown kind 'sideways'"
  assert_file_exists "$ROOT/etc/sirven/grants/agent.json"
}

test_a_record_not_owned_by_root_is_refused_on_a_real_root() {
  if [ "$(id -u)" = 0 ]; then
    return 0
  fi
  printf 'run\t-\t-\t-\tx\t-\ttrue\ttrue\n' > "$TEST_TMP/record.tsv"
  # shellcheck disable=SC1091
  . "$REPO_DIR/uninstall.sh"
  PREFIX=""
  RECORD_FILE="$TEST_TMP/record.tsv"
  assert_status 2 check_record_ownership
  assert_contains "$CAPTURED_STDERR" "does not belong to root"
}

test_real_apply_is_refused_without_root() {
  # as root this would really apply to the machine running the tests, so only a non-root run is checked here.
  if [ "$(id -u)" = 0 ]; then
    return 0
  fi
  assert_status 3 "$REPO_DIR/uninstall.sh"
  assert_contains "$CAPTURED_STDERR" "applying needs root"
}

test_install_after_uninstall_records_again() {
  install_on_fake_root
  assert_status 0 uninstall_sh --prefix "$ROOT"
  install_on_fake_root
  # the kept audit log was already there, so this install did not create it and does not record it
  assert_contains "$CAPTURED_STDOUT" "applied 23 steps, skipped 2 already done."
  assert_contains "$(cat "$ROOT/var/lib/sirven/install-record.tsv")" "remove /etc/sirven if"
  assert_not_contains "$(cat "$ROOT/var/lib/sirven/install-record.tsv")" "remove the audit log"
}

test_uninstall_removes_the_pinned_copy_only_when_this_package_made_it() {
  local copy
  install_on_fake_root
  copy="$ROOT/var/lib/sirven/package"
  assert_file_exists "$copy/install.sh"
  assert_status 0 uninstall_sh --dry-run --prefix "$ROOT"
  assert_contains "$CAPTURED_STDOUT" "remove the pinned copy of this package in /var/lib/sirven/package"
  assert_status 0 uninstall_sh --prefix "$ROOT"
  assert_no_file "$ROOT/var/lib/sirven"
}

test_a_folder_without_the_marker_is_kept_by_the_undo() {
  local folder="$TEST_TMP/not-ours"
  . "$REPO_DIR/lib/common.sh"
  . "$REPO_DIR/lib/layout.sh"
  mkdir -p "$folder"
  printf 'theirs\n' > "$folder/file"
  capture layout_remove_package_copy "$folder"
  assert_contains "$CAPTURED_STDOUT$CAPTURED_STDERR" "kept $folder: it is not a copy this package made"
  assert_file_exists "$folder/file"
}

test_the_copy_from_a_newer_release_undoes_an_older_install() {
  local root="$TEST_TMP/root" copy
  copy="$root/var/lib/sirven/package"
  export SIRVEN_PACKAGE_TAG=v0.2.0 SIRVEN_PACKAGE_SHA256=old
  install_sh --prefix "$root" --level builder --path /home/example/project --transport none >/dev/null
  export SIRVEN_PACKAGE_TAG=v0.3.0 SIRVEN_PACKAGE_SHA256=new
  assert_status 0 install_sh --prefix "$root" --level builder --path /home/example/project --transport none
  assert_contains "$(cat "$copy/PINNED-COPY")" "tag=v0.3.0"
  assert_status 0 env SIRVEN_OS_OVERRIDE=linux "$BASH" "$copy/uninstall.sh" --dry-run --prefix "$root"
  assert_contains "$CAPTURED_STDOUT" "remove the pinned copy of this package"
  assert_no_file "$root/var/lib/sirven/install-record.tsv.missing"
  assert_status 0 env SIRVEN_OS_OVERRIDE=linux "$BASH" "$copy/uninstall.sh" --prefix "$root"
  assert_no_file "$root/var/lib/sirven"
  assert_no_file "$root/etc/sirven"
}
