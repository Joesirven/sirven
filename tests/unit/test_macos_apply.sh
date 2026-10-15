# shellcheck shell=bash
# the macos real apply, proved without changing the machine.
#
# two kinds of test. the account steps run against a fake directory service: shell functions named
# dscl, createhomedir, and uuidgen keep their records in TEST_TMP, so nothing on the machine is read
# or written. the access control list steps run for real, but only on macos and only inside TEST_TMP,
# with the account running the test as the principal: the exact commands the compiler writes grant the
# entries, and the exact undo commands it writes take them off again.

# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/plan.sh
. "$REPO_DIR/lib/plan.sh"
# shellcheck source=lib/layout.sh
. "$REPO_DIR/lib/layout.sh"
# shellcheck source=lib/service_user.sh
. "$REPO_DIR/lib/service_user.sh"

MACOS_HELPER="$REPO_DIR/lib/access_control_macos.sh"
MACOS_BUILDER_LEVEL="$REPO_DIR/levels/builder.json"

# --- the account steps, against a fake directory service -------------------------------------------

# a fake dscl. records are files in $FAKE_DS/NAME, one "Field: value" line per field.
# FAKE_DS_FAIL_ON names an attribute whose -create fails, to test the failure path.
fake_directory_service() {
  FAKE_DS="$TEST_TMP/ds"
  mkdir -p "$FAKE_DS"
  PACKAGE=sirven
  dscl() {
    local action="$2" name="${3#/Users/}" field="${4:-}" value="${5:-}"
    case "$action" in
      -create)
        if [ -n "$field" ] && [ "$field" = "${FAKE_DS_FAIL_ON:-}" ]; then return 1; fi
        if [ -z "$field" ]; then : >> "$FAKE_DS/$name"; return 0; fi
        [ -f "$FAKE_DS/$name" ] || return 1
        grep -v "^$field:" "$FAKE_DS/$name" > "$FAKE_DS/$name.new" || true
        printf '%s: %s\n' "$field" "$value" >> "$FAKE_DS/$name.new"
        mv "$FAKE_DS/$name.new" "$FAKE_DS/$name"
        ;;
      -read)
        [ -f "$FAKE_DS/$name" ] || return 1
        if [ "$field" = RecordName ]; then printf 'RecordName: %s\n' "$name"; return 0; fi
        if [ -n "$field" ]; then grep "^$field:" "$FAKE_DS/$name"; else cat "$FAKE_DS/$name"; fi
        ;;
      -delete) rm -f "$FAKE_DS/$name" ;;
      *) return 1 ;;
    esac
  }
  # shellcheck disable=SC2329 # called by service_user_macos_create, which shellcheck cannot see from here
  createhomedir() { mkdir -p "$FAKE_HOME"; }
  # shellcheck disable=SC2329 # same
  uuidgen() { printf '11111111-2222-3333-4444-555555555555\n'; }
  FAKE_HOME="$TEST_TMP/home/agent"
}

test_the_account_is_made_whole_and_a_re_run_skips_it() {
  fake_directory_service
  assert_status 0 service_user_macos_create agent 601 "$FAKE_HOME" "sirven agent"
  service_user_macos_complete agent "$FAKE_HOME" || fail "the account is not complete after create"
  assert_eq 601 "$(service_user_macos_field agent UniqueID)"
  assert_eq 1 "$(service_user_macos_field agent IsHidden)"
  assert_eq '*' "$(service_user_macos_field agent Password)"
  assert_eq 20 "$(service_user_macos_field agent PrimaryGroupID)"
  assert_eq 11111111-2222-3333-4444-555555555555 "$(service_user_macos_field agent GeneratedUID)"
  assert_eq 700 "$(stat -c '%a' "$FAKE_HOME" 2>/dev/null || stat -f '%Lp' "$FAKE_HOME")" "the home folder is private"
}

test_a_failed_create_leaves_no_account_behind() {
  fake_directory_service
  FAKE_DS_FAIL_ON=NFSHomeDirectory
  assert_status 1 service_user_macos_create agent 601 "$FAKE_HOME" "sirven agent"
  assert_contains "$CAPTURED_STDERR" "could not finish creating the account agent"
  assert_no_file "$FAKE_DS/agent"
}

test_a_half_made_account_is_finished_not_deleted_and_keeps_its_number() {
  fake_directory_service
  FAKE_DS_FAIL_ON=IsHidden
  assert_status 1 service_user_macos_create agent 601 "$FAKE_HOME" "sirven agent"
  # an earlier run got as far as the record and the number, then stopped; the failing run deletes only what it started
  : > "$FAKE_DS/agent"
  printf 'UniqueID: 777\n' >> "$FAKE_DS/agent"
  FAKE_DS_FAIL_ON=Password
  assert_status 1 service_user_macos_create agent 601 "$FAKE_HOME" "sirven agent"
  assert_file_exists "$FAKE_DS/agent"
  FAKE_DS_FAIL_ON=""
  assert_status 0 service_user_macos_create agent 601 "$FAKE_HOME" "sirven agent"
  assert_eq 777 "$(service_user_macos_field agent UniqueID)" "the number the account already had is kept"
  service_user_macos_complete agent "$FAKE_HOME" || fail "the account is not complete after the second create"
}

test_an_account_missing_its_home_folder_is_not_complete() {
  fake_directory_service
  assert_status 0 service_user_macos_create agent 601 "$FAKE_HOME" "sirven agent"
  rm -rf "$FAKE_HOME"
  if service_user_macos_complete agent "$FAKE_HOME"; then fail "an account without its home folder counted as done"; fi
}

test_an_account_that_is_not_ours_is_refused() {
  fake_directory_service
  : > "$FAKE_DS/agent"
  printf 'UniqueID: 502\nRealName: Somebody Else\n' >> "$FAKE_DS/agent"
  PREFIX=""
  SERVICE_USER=agent
  SIRVEN_MACOS_REAL_APPLY=1
  assert_status 2 service_user_macos_refuse_foreign
  assert_contains "$CAPTURED_STDERR" "this package did not make it"
  # one this package made is accepted, switch or no switch
  printf 'RealName: sirven agent\n' > "$FAKE_DS/agent.real"
  grep -v '^RealName' "$FAKE_DS/agent" > "$FAKE_DS/agent.new"
  cat "$FAKE_DS/agent.real" >> "$FAKE_DS/agent.new"
  mv "$FAKE_DS/agent.new" "$FAKE_DS/agent"
  assert_status 0 service_user_macos_refuse_foreign
}

test_a_foreign_account_is_only_a_note_while_the_switch_is_off() {
  fake_directory_service
  : > "$FAKE_DS/agent"
  printf 'UniqueID: 502\nRealName: Somebody Else\n' >> "$FAKE_DS/agent"
  PREFIX=""
  SERVICE_USER=agent
  unset SIRVEN_MACOS_REAL_APPLY
  plan_reset
  service_user_macos_refuse_foreign
  plan_evaluate
  capture plan_print
  assert_contains "$CAPTURED_STDOUT" "a real apply would stop here and ask for another --user NAME"
}

test_a_record_with_no_number_is_not_deleted_by_a_failed_create() {
  fake_directory_service
  : > "$FAKE_DS/agent"
  printf 'RealName: Somebody Else\n' >> "$FAKE_DS/agent"
  # the plan refuses it first: a record with no number counts as an account that is there, and not ours
  PREFIX=""
  SERVICE_USER=agent
  SIRVEN_MACOS_REAL_APPLY=1
  assert_status 2 service_user_macos_refuse_foreign
  # and if a create ran on it anyway, a failure does not delete it
  FAKE_DS_FAIL_ON=Password
  assert_status 1 service_user_macos_create agent 601 "$FAKE_HOME" "sirven agent"
  assert_file_exists "$FAKE_DS/agent"
}

test_the_account_undo_only_deletes_the_account_this_package_made() {
  fake_directory_service
  # shellcheck disable=SC2329 # called by service_user_macos_remove
  pkill() { return 0; }
  : > "$FAKE_DS/agent"
  printf 'UniqueID: 601\nRealName: sirven agent\n' >> "$FAKE_DS/agent"
  assert_status 0 service_user_macos_remove agent "sirven agent"
  assert_no_file "$FAKE_DS/agent"
  # renamed or replaced since: kept, with a plain note
  : > "$FAKE_DS/agent"
  printf 'UniqueID: 601\nRealName: Somebody Else\n' >> "$FAKE_DS/agent"
  assert_status 0 service_user_macos_remove agent "sirven agent"
  assert_file_exists "$FAKE_DS/agent"
  assert_contains "$CAPTURED_STDERR" "kept the account agent on purpose, and this is not a failure"
  assert_contains "$CAPTURED_STDERR" "no longer the account this package made"
  # the undo check calls that done, and an account that is ours is not
  assert_status 0 service_user_macos_gone agent "sirven agent"
  printf 'RealName: sirven agent\n' > "$FAKE_DS/agent.new"
  grep -v '^RealName' "$FAKE_DS/agent" >> "$FAKE_DS/agent.new"; mv "$FAKE_DS/agent.new" "$FAKE_DS/agent"
  assert_status 1 service_user_macos_gone agent "sirven agent"
  printf 'UniqueID: 601\nRealName: Somebody Else\n' > "$FAKE_DS/agent"
  # nothing there: nothing to do
  rm -f "$FAKE_DS/agent"
  assert_status 0 service_user_macos_remove agent "sirven agent"
}

test_the_account_undo_in_the_record_is_the_guarded_helper() {
  assert_status 0 env SIRVEN_OS_OVERRIDE=macos "$REPO_DIR/install.sh" --prefix "$TEST_TMP/root" --transport none --yes --owner example
  assert_contains "$(cat "$TEST_TMP/root/var/lib/sirven/install-record.tsv")" "service_user_macos.sh remove agent "
}

# --- the access control list steps, for real, inside TEST_TMP (macos only) -------------------------------

macos_only() {
  [ "$(uname -s)" = Darwin ] || return 1
  # the test folder is removed after the test, and a list entry that denies delete would stop that
  trap '/usr/bin/find -P "$TEST_TMP" -exec /bin/chmod -h -N {} + 2>/dev/null' EXIT
  # TMPDIR ends with a slash, so the folder name has a double slash the grant compiler would normalize away
  TEST_TMP="${TEST_TMP//\/\///}"
}

# the listing of every item in a list of paths: its mode letters, owner, group, and list entries. no
# times, because creating a file changes its folder's time and that is not what is being compared.
acl_listing() {
  local item
  while IFS= read -r item; do
    printf '%s\n' "$item"
    /bin/ls -lde "$item" | awk 'NR == 1 { print "  " $1, $3, $4; next } { print }'
  done
}

# the grant and undo lines of the compiler for a path, for the paths inside TEST_TMP only. the
# pass-through parents above TEST_TMP are left out: they are real folders outside it.
compiled_lines() {
  python3 "$REPO_DIR/lib/grant_compiler.py" compile --level "$MACOS_BUILDER_LEVEL" --os macos \
    --user "$(id -un)" --prefix "" --with-undo --path "$1" | grep -v '^#' | grep -F "$TEST_TMP" |
    sed "s|/var/lib/sirven/package/lib/|$REPO_DIR/lib/|g"
}

# run_each LINES: run every command in LINES, failing the test on the first that fails.
run_each() {
  local command
  while IFS= read -r command; do
    bash -c "$command" || fail "a command failed: $command"
  done <<END
$1
END
}

# the lines the kill switch's revoke prints for a path, for the paths inside TEST_TMP only (the title, the check,
# and the command), with the helper taken from this checkout instead of the pinned copy.
revoked_lines() {
  python3 "$REPO_DIR/lib/grant_compiler.py" revoke --level "$MACOS_BUILDER_LEVEL" --os macos \
    --user "$(id -un)" --prefix "" --path "$1" | grep -v '^#' | grep -F "$TEST_TMP" |
    sed "s|/var/lib/sirven/package/lib/|$REPO_DIR/lib/|g"
}

test_the_undo_puts_every_list_back_exactly() {
  macos_only || return 0
  local user project lines before after
  user="$(id -un)"
  project="$TEST_TMP/project"
  mkdir -p "$project/sub/deep" "$TEST_TMP/outside" "$TEST_TMP/staging"
  printf 'one\n' > "$project/a.txt"
  printf 'two\n' > "$project/sub/b.txt"
  printf 'secret\n' > "$TEST_TMP/outside/secret.txt"
  printf 'moved in\n' > "$TEST_TMP/staging/moved.txt"
  ln -s ../outside/secret.txt "$project/file-link"
  ln -s ../outside "$project/folder-link"
  # a list that was there before, for someone else: it must come out of the undo untouched
  /bin/chmod +a "everyone deny delete" "$project/a.txt"
  /usr/bin/find -P "$project" "$TEST_TMP/outside" | sort > "$TEST_TMP/paths-before.txt"
  printf '%s\n' "$TEST_TMP" >> "$TEST_TMP/paths-before.txt"
  before="$(acl_listing < "$TEST_TMP/paths-before.txt")"

  lines="$(compiled_lines "$project")"
  [ -n "$lines" ] || fail "the compiler gave no lines for $project"
  run_each "$(printf '%s\n' "$lines" | cut -f3)"
  # the grant is in force: the folder and its files have entries for the account
  assert_contains "$(/bin/ls -lde "$project")" "user:$user allow list"
  assert_contains "$(/bin/ls -lde "$project/a.txt")" "user:$user allow read"

  # life during the grant: a new file and folder inherit entries, a file moved in has none
  printf 'new\n' > "$project/new.txt"
  mkdir "$project/newdir"
  printf 'newer\n' > "$project/newdir/inner.txt"
  mv "$TEST_TMP/staging/moved.txt" "$project/moved.txt"
  assert_contains "$(/bin/ls -lde "$project/new.txt")" "inherited"
  # nothing was reached through a link: the folder and the file behind the links hold no entry
  assert_not_contains "$(/bin/ls -lde "$TEST_TMP/outside" "$TEST_TMP/outside/secret.txt")" "user:$user"

  # every undo check says there is work to do while the entries are there
  if bash -c "$(printf '%s\n' "$lines" | cut -f5 | sed -n '$p')"; then
    fail "the undo check passed while entries were still there"
  fi
  run_each "$(printf '%s\n' "$lines" | cut -f6)"
  run_each "$(printf '%s\n' "$lines" | cut -f5)"

  after="$(acl_listing < "$TEST_TMP/paths-before.txt")"
  assert_eq "$before" "$after" "every list that existed before the grant is as it was"
  assert_not_contains "$(/usr/bin/find -P "$project" -exec /bin/ls -lde {} +)" "user:$user" "no entry of the account is left, on old or new items"
  assert_contains "$(/bin/ls -lde "$project/a.txt")" "group:everyone deny delete"
  assert_eq "$(printf 'secret\n')" "$(cat "$TEST_TMP/outside/secret.txt")" "the file behind the link is untouched"
}

# revoke does what uninstall does: the commands the kill switch prints for a macos revoke are run for real here
# on a granted tree, after life in it that a subtraction cannot undo (a new file inherits an entry built from
# the folder rights, a file moved in with mv has no list at all). no entry of the account is left, every list
# that was there before is as it was, and nothing behind a link is touched. this proves the commands on this
# Mac inside TEST_TMP; a whole revoke run (as root, with the service user, the lock and the keys) is not run.
test_revoke_sweeps_inherited_entries_and_items_with_no_list() {
  macos_only || return 0
  local user project grant revoke before after
  user="$(id -un)"
  project="$TEST_TMP/project"
  mkdir -p "$project/sub" "$TEST_TMP/outside" "$TEST_TMP/staging"
  printf 'one\n' > "$project/a.txt"
  printf 'secret\n' > "$TEST_TMP/outside/secret.txt"
  printf 'moved in\n' > "$TEST_TMP/staging/moved.txt"
  ln -s ../outside "$project/folder-link"
  ln -s ../outside/secret.txt "$project/file-link"
  /bin/chmod +a "everyone deny delete" "$project/a.txt"
  /usr/bin/find -P "$project" "$TEST_TMP/outside" | sort > "$TEST_TMP/paths-before.txt"
  printf '%s\n' "$TEST_TMP" >> "$TEST_TMP/paths-before.txt"
  before="$(acl_listing < "$TEST_TMP/paths-before.txt")"

  grant="$(compiled_lines "$project")"
  revoke="$(revoked_lines "$project")"
  [ -n "$revoke" ] || fail "the compiler gave no revoke lines for $project"
  assert_not_contains "$revoke" "chmod" "revoke is not a subtraction"
  run_each "$(printf '%s\n' "$grant" | cut -f3)"

  printf 'new\n' > "$project/new.txt"
  mkdir "$project/newdir"
  printf 'newer\n' > "$project/newdir/inner.txt"
  mv "$TEST_TMP/staging/moved.txt" "$project/moved.txt"
  assert_contains "$(/bin/ls -lde "$project/new.txt")" "inherited" "a new file holds an inherited entry"
  assert_not_contains "$(/bin/ls -lde "$project/moved.txt")" "user:$user" "a file moved in holds no entry and no list"

  if bash -c "$(printf '%s\n' "$revoke" | head -n 1 | cut -f2)"; then
    fail "the revoke check passed while entries were still there"
  fi
  run_each "$(printf '%s\n' "$revoke" | cut -f3)"
  run_each "$(printf '%s\n' "$revoke" | cut -f2)"

  after="$(acl_listing < "$TEST_TMP/paths-before.txt")"
  assert_eq "$before" "$after" "every list that existed before the grant is as it was"
  assert_not_contains "$(/usr/bin/find -P "$project" -exec /bin/ls -lde {} +)" "user:$user" "no entry of the account is left, inherited ones included"
  assert_not_contains "$(/bin/ls -lde "$project/new.txt" "$project/newdir/inner.txt")" "inherited"
  assert_contains "$(/bin/ls -lde "$project/a.txt")" "group:everyone deny delete"
  assert_eq "$(printf 'secret\n')" "$(cat "$TEST_TMP/outside/secret.txt")" "the file behind the link is untouched"
  # a second revoke has nothing left to do and does not fail on the items that have no list
  run_each "$(printf '%s\n' "$revoke" | cut -f3)"
}

test_check_refuses_a_link_and_an_existing_entry() {
  macos_only || return 0
  local user project
  user="$(id -un)"
  project="$TEST_TMP/project"
  mkdir -p "$project" "$TEST_TMP/real"
  ln -s real "$TEST_TMP/link"
  assert_status 0 bash "$MACOS_HELPER" check "$user" --tree "$project" --alone "$TEST_TMP"
  assert_status 3 bash "$MACOS_HELPER" check "$user" --tree "$TEST_TMP/link"
  assert_contains "$CAPTURED_STDOUT" "is a symbolic link"
  assert_status 3 bash "$MACOS_HELPER" check "$user" --tree "$TEST_TMP/missing"
  assert_contains "$CAPTURED_STDOUT" "is not a folder that exists"
  printf 'x\n' > "$project/a.txt"
  /bin/chmod +a "$user allow read" "$project/a.txt"
  assert_status 3 bash "$MACOS_HELPER" check "$user" --tree "$project"
  assert_contains "$CAPTURED_STDOUT" "a.txt already has an access list entry for $user"
  # a second run of an install this package made finds its own entries, and says nothing about them
  assert_status 0 bash "$MACOS_HELPER" check "$user" --allow-own-entries --tree "$project"
  # but a link is refused either way
  assert_status 3 bash "$MACOS_HELPER" check "$user" --allow-own-entries --tree "$TEST_TMP/link"
}

test_a_file_name_cannot_forge_a_list_entry() {
  macos_only || return 0
  local user name
  user="$(id -un)"
  mkdir -p "$TEST_TMP/tree"
  name="$(printf 'x\n 0: user:%s allow read ' "$user")"
  : > "$TEST_TMP/tree/$name"
  /bin/chmod +a "everyone deny delete" "$TEST_TMP/tree/$name"
  printf 'y\n' > "$TEST_TMP/tree/plain"
  /bin/chmod +a "$user allow read" "$TEST_TMP/tree/plain"
  assert_status 0 bash "$MACOS_HELPER" sweep "$user" yes "$TEST_TMP/tree"
  assert_contains "$(/bin/ls -le "$TEST_TMP/tree/plain" "$TEST_TMP/tree/"x*)" "group:everyone deny delete" "the entry of somebody else on the odd name is still there"
  assert_not_contains "$(/bin/ls -le "$TEST_TMP/tree/plain")" "user:$user"
  assert_status 0 bash "$MACOS_HELPER" status "$user" yes "$TEST_TMP/tree"
  # and a check does not see the forged line as an entry
  rm -f "$TEST_TMP/tree/plain"
  assert_status 0 bash "$MACOS_HELPER" check "$user" --tree "$TEST_TMP/tree"
}

test_sweep_and_status_refuse_a_granted_path_that_became_a_link() {
  macos_only || return 0
  local user
  user="$(id -un)"
  mkdir -p "$TEST_TMP/elsewhere"
  printf 'x\n' > "$TEST_TMP/elsewhere/file"
  /bin/chmod +a "$user allow read" "$TEST_TMP/elsewhere/file"
  ln -s elsewhere "$TEST_TMP/was-a-folder"
  assert_status 1 bash "$MACOS_HELPER" sweep "$user" yes "$TEST_TMP/was-a-folder"
  assert_contains "$CAPTURED_STDERR" "is a symbolic link now"
  assert_status 1 bash "$MACOS_HELPER" status "$user" yes "$TEST_TMP/was-a-folder"
  assert_contains "$(/bin/ls -le "$TEST_TMP/elsewhere/file")" "user:$user allow read" "nothing behind the link was touched"
}

test_sweep_never_follows_a_link_and_tolerates_an_item_with_no_list() {
  macos_only || return 0
  local user
  user="$(id -un)"
  mkdir -p "$TEST_TMP/tree" "$TEST_TMP/elsewhere"
  printf 'x\n' > "$TEST_TMP/elsewhere/file"
  printf 'y\n' > "$TEST_TMP/tree/plain"
  /bin/chmod +a "$user allow read" "$TEST_TMP/elsewhere/file"
  ln -s ../elsewhere "$TEST_TMP/tree/link"
  assert_status 0 bash "$MACOS_HELPER" sweep "$user" yes "$TEST_TMP/tree"
  assert_contains "$(/bin/ls -lde "$TEST_TMP/elsewhere/file")" "user:$user allow read" "an entry behind a link is not ours to remove"
  assert_status 0 bash "$MACOS_HELPER" status "$user" yes "$TEST_TMP/tree"
  assert_status 1 bash "$MACOS_HELPER" status "$user" yes "$TEST_TMP/elsewhere"
  assert_contains "$CAPTURED_STDERR" "still has an entry"
  # a path that is gone is already swept
  assert_status 0 bash "$MACOS_HELPER" sweep "$user" yes "$TEST_TMP/gone"
}

# --- the real install check script: only its refusal and its rehearsal run here, never a real run ----------

test_the_real_install_check_refuses_to_run_without_approval() {
  assert_status 64 bash "$REPO_DIR/tests/macos/real-install-check.sh"
  assert_contains "$CAPTURED_STDERR" "needs the owner's approval"
  assert_status 64 bash "$REPO_DIR/tests/macos/real-install-check.sh" --sideways
  assert_status 64 bash "$REPO_DIR/tests/macos/real-install-check.sh" --rehearse "$TEST_TMP/not-a-folder"
}

test_the_real_install_check_rehearses_on_a_fake_root() {
  # the script reads state with the macos forms of stat and ls
  [ "$(uname -s)" = Darwin ] || return 0
  mkdir "$TEST_TMP/rehearsal"
  assert_status 0 bash "$REPO_DIR/tests/macos/real-install-check.sh" --rehearse "$TEST_TMP/rehearsal"
  assert_contains "$CAPTURED_STDOUT" "PASS: observer level"
  assert_contains "$CAPTURED_STDOUT" "PASS: builder level"
  assert_contains "$CAPTURED_STDOUT" "failed: 0"
  assert_contains "$CAPTURED_STDOUT" "the machine is as it was"
  # a rehearsal leaves the fake root without a state directory, as an uninstall does
  assert_no_file "$TEST_TMP/rehearsal/root/var/lib/sirven"
}
