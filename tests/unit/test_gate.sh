# shellcheck shell=bash
# the root gate: one text in three entry scripts, and the checker it carries.

gate_block() {  # FILE: the gate block of an entry script
  sed -n '/^# ---- root gate: begin/,/^# ---- root gate: end/p' "$1"
}

test_the_gate_block_is_the_same_in_every_entry_script() {
  local install uninstall sirven
  install="$(gate_block "$REPO_DIR/install.sh")"
  uninstall="$(gate_block "$REPO_DIR/uninstall.sh")"
  sirven="$(gate_block "$REPO_DIR/bin/sirven")"
  assert_contains "$install" "sirven_gate()"
  assert_eq "$install" "$uninstall" "install.sh and uninstall.sh carry the same gate"
  assert_eq "$install" "$sirven" "install.sh and bin/sirven carry the same gate"
}

test_the_gate_does_not_read_a_file_of_the_folder_it_judges() {
  local block
  block="$(gate_block "$REPO_DIR/install.sh" | grep -v '^[[:space:]]*#')"
  # (comment lines left out: they may name what the gate does not do.) the kept copy is a constant, the checker is this text, and nothing sources a library before the gate runs
  assert_contains "$block" "SIRVEN_KEPT=/var/lib/sirven/package"
  assert_not_contains "$block" "project.json"
  assert_not_contains "$block" "trust.py"
  assert_not_contains "$block" "ROOT_DIR/lib"
  assert_contains "$block" 'PATH=/usr/sbin:/usr/bin:/sbin:/bin'
}

test_every_entry_script_resolves_its_folder_physically_and_gates_before_any_library() {
  local file first_source gate_call
  for file in install.sh uninstall.sh bin/sirven; do
    assert_contains "$(cat "$REPO_DIR/$file")" 'cd -P'
    gate_call="$(grep -n 'sirven_gate ' "$REPO_DIR/$file" | grep -v 'sirven_gate()' | head -1 | cut -d: -f1)"
    # shellcheck disable=SC2016 # the pattern is text to find, not an expansion
    first_source="$(grep -n '^\. "\$ROOT_DIR/lib/' "$REPO_DIR/$file" | head -1 | cut -d: -f1)"
    [ -n "$gate_call" ] && [ -n "$first_source" ] && [ "$gate_call" -lt "$first_source" ] || fail "$file: the gate must run before the first library is read ($gate_call, $first_source)"
  done
}

# run the checker of a script on a folder: the function is the real one
vet() {  # FOLDER OWNER
  bash -c "$(gate_block "$REPO_DIR/install.sh" | sed -n '/^sirven_vet()/,/^}/p'); sirven_vet \"\$1\" \"\$2\"" _ "$1" "$2"
}

vet_python_available() { [ -x /usr/bin/python3 ]; }

test_the_checker_accepts_a_private_folder_and_refuses_a_world_writable_one() {
  vet_python_available || return 0
  local folder="$TEST_TMP/pkg" owner
  owner="$(id -un)"
  mkdir -p "$folder/lib" && echo x > "$folder/lib/a.sh" && chmod -R go-w "$folder"
  assert_status 0 vet "$folder" "$owner"
  chmod o+w "$folder/lib"
  assert_status 3 vet "$folder" "$owner"
  assert_contains "$CAPTURED_STDOUT" "lib: writable by everyone"
}

test_the_checker_refuses_a_link_that_leaves_the_package() {
  vet_python_available || return 0
  local folder="$TEST_TMP/pkg2" owner
  owner="$(id -un)"
  mkdir -p "$folder/lib" "$TEST_TMP/outside" && ln -s "$TEST_TMP/outside" "$folder/lib/out"
  assert_status 3 vet "$folder" "$owner"
  assert_contains "$CAPTURED_STDOUT" "a link to"
}

test_the_checker_does_not_trust_a_read_only_mount_claim() {
  # the shortcut is gone: no mention of a read only file system in the checker
  assert_not_contains "$(gate_block "$REPO_DIR/install.sh")" "ST_RDONLY"
  assert_not_contains "$(gate_block "$REPO_DIR/install.sh")" "statvfs"
}

test_a_prefix_that_is_the_real_root_is_refused() {
  assert_status 64 "$REPO_DIR/install.sh" revoke --all --dry-run --prefix /
  assert_contains "$CAPTURED_STDERR" "/ is the real machine"
  assert_status 64 "$REPO_DIR/install.sh" --dry-run --prefix //
  assert_status 64 "$REPO_DIR/install.sh" --dry-run --prefix /../
  assert_status 64 "$REPO_DIR/uninstall.sh" --dry-run --prefix /
}

test_a_prefix_with_a_dot_component_is_refused_even_when_it_does_not_exist() {
  assert_status 64 "$REPO_DIR/install.sh" --dry-run --prefix /nonexist/..
  assert_contains "$CAPTURED_STDERR" "may not contain a . or .. component"
  assert_status 64 "$REPO_DIR/install.sh" --dry-run --prefix /tmp/nonexist/../..
  assert_status 64 "$REPO_DIR/install.sh" --dry-run --prefix /tmp/./x
  assert_status 64 "$REPO_DIR/uninstall.sh" --dry-run --prefix /nonexist/..
  assert_status 0 "$REPO_DIR/install.sh" --dry-run --prefix "$TEST_TMP/real-root" --transport none --path /srv/app
  assert_no_file "$TEST_TMP/real-root"
}

test_a_package_name_with_a_slash_or_dots_is_refused() {
  . "$REPO_DIR/lib/common.sh"
  printf '{\n  "name": "../../tmp/evil"\n}\n' > "$TEST_TMP/project.json"
  assert_status 1 package_name "$TEST_TMP/project.json"
  assert_contains "$CAPTURED_STDERR" "not a plain lowercase name"
  printf '{\n  "name": "Sirven"\n}\n' > "$TEST_TMP/project.json"
  assert_eq sirven "$(package_name "$TEST_TMP/project.json")"
  printf '{\n  "name": "-x"\n}\n' > "$TEST_TMP/project.json"
  assert_status 1 package_name "$TEST_TMP/project.json"
}

# ---- the sticky parent folder and the group root rule (SIR-96). the passwd and group databases are made up (tests/lib/gate_fake.py)
# so the cases do not depend on which accounts the machine running them has; the folders are real.

gate_checker() {  # the python text of the checker: the here-document of sirven_vet in install.sh
  gate_block "$REPO_DIR/install.sh" | sed -n "/<<'PY'/,/^PY\$/p" | sed '1d;$d'
}

fake_run() {  # SPEC_JSON VERB ARGUMENT...: run tests/lib/gate_fake.py with the made-up databases
  local spec="$1"
  shift
  printf '%s\n' "$spec" > "$TEST_TMP/spec.json"
  gate_checker > "$TEST_TMP/checker.py"
  # the first argument is the verb (run or outsiders), then the checker and spec files, then the verb's own arguments
  local verb="$1"
  shift
  /usr/bin/python3 -I "$REPO_DIR/tests/lib/gate_fake.py" "$verb" "$TEST_TMP/checker.py" "$TEST_TMP/spec.json" "$@"
}

outsiders_of() {  # SPEC_JSON NUMBER: who the checker names as other members of group NUMBER, as JSON
  fake_run "$1" outsiders root "$2"
}

test_the_system_accounts_in_group_root_that_cannot_log_in_do_not_make_it_untrusted() {
  vet_python_available || return 0
  # Fedora 42's four: sync, shutdown and halt have a program for a shell and a locked password, operator has nologin
  local spec='{"accounts": [["sync",5,0,"/bin/sync"],["shutdown",6,0,"/sbin/shutdown"],["halt",7,0,"/sbin/halt"],["operator",11,0,"/sbin/nologin"]],
    "shadow": "sync:*:19000:0:99999:7:::\nshutdown:*:19000:0:99999:7:::\nhalt:!!:19000:0:99999:7:::\noperator:*:19000::::::\n"}'
  assert_eq '{"0": []}' "$(outsiders_of "$spec" 0)" "Fedora's gid-0 system accounts are not outsiders"
}

test_a_member_of_group_root_with_a_login_shell_and_a_usable_password_is_an_outsider() {
  vet_python_available || return 0
  # shellcheck disable=SC2016 # a password hash is text, not an expansion
  local spec='{"accounts": [["worker",600,0,"/bin/bash"]], "shadow": "worker:$6$salt$hash:19000::::::\n"}'
  assert_eq '{"0": ["worker"]}' "$(outsiders_of "$spec" 0)" "a system account with a password and a shell"
  spec='{"accounts": [["worker",600,0,"/bin/bash"]], "shadow": "worker::19000::::::\n"}'
  assert_eq '{"0": ["worker"]}' "$(outsiders_of "$spec" 0)" "an empty password field is no lock"
  spec='{"accounts": [["worker",600,0,"/bin/bash"]]}'
  assert_eq '{"0": ["worker"]}' "$(outsiders_of "$spec" 0)" "without a readable password file nothing counts as locked"
}

test_a_locked_password_makes_a_system_account_harmless_even_with_a_shell() {
  vet_python_available || return 0
  # shellcheck disable=SC2016 # a password hash is text, not an expansion
  local spec='{"accounts": [["svc",600,0,"/bin/bash"]], "shadow": "svc:!$6$salt$hash:19000::::::\n"}'
  assert_eq '{"0": []}' "$(outsiders_of "$spec" 0)" "a password locked with a leading !"
}

test_only_a_system_account_is_harmless_never_an_ordinary_one() {
  vet_python_available || return 0
  local spec='{"accounts": [["ordinary",1500,0,"/usr/sbin/nologin"]]}'
  assert_eq '{"0": ["ordinary"]}' "$(outsiders_of "$spec" 0)" "user number 1500 with nologin, no login definitions: ordinary"
  spec='{"accounts": [["edge",999,0,"/usr/sbin/nologin"],["first",1000,0,"/usr/sbin/nologin"]]}'
  assert_eq '{"0": ["first"]}' "$(outsiders_of "$spec" 0)" "999 is a system account and 1000 is not, when the login definitions are missing"
  spec='{"accounts": [["low",400,0,"/bin/false"],["mid",700,0,"/bin/false"]], "login_defs": "# comment\nUID_MIN\t\t500\nUID_MAX 60000\n"}'
  assert_eq '{"0": ["mid"]}' "$(outsiders_of "$spec" 0)" "UID_MIN 500 from the login definitions"
  spec='{"accounts": [["edge",999,0,"/bin/false"],["first",1000,0,"/bin/false"]], "login_defs": "#UID_MIN 500\nUID_MIN notanumber\n"}'
  assert_eq '{"0": ["first"]}' "$(outsiders_of "$spec" 0)" "a commented or damaged line leaves the default of 1000"
}

test_the_system_account_allowance_is_for_group_root_only() {
  vet_python_available || return 0
  local spec='{"accounts": [["daemon",1,20,"/usr/sbin/nologin"]], "members": {"20": ["listed", "daemon"]}}'
  assert_eq '{"20": ["daemon", "listed"]}' "$(outsiders_of "$spec" 20)" "in any other group a nologin system account still counts, and so does a name with no account"
  spec='{"accounts": [["daemon",1,0,"/usr/sbin/nologin"]], "members": {"0": ["ghost"]}}'
  assert_eq '{"0": ["ghost"]}' "$(outsiders_of "$spec" 0)" "a name in the group file with no account is an outsider in group root too"
}

# a sticky, world-writable folder on the way, a package folder in it
sticky_world() {  # sets STK and PKG under TEST_TMP
  STK="$TEST_TMP/stk"
  PKG="$STK/pkg"
  mkdir -p "$PKG/lib" && echo x > "$PKG/lib/a.sh" && chmod -R go-w "$PKG" && chmod 1777 "$STK"
}

test_a_package_in_a_sticky_world_writable_folder_passes_even_when_the_folders_group_has_other_members() {
  vet_python_available || return 0
  sticky_world
  local owner spec
  owner="$(id -un)"
  spec='{"accounts": [["worker",600,"folder","/bin/bash"]]}'
  assert_status 0 fake_run "$spec" run "$PKG" "$owner"
}

test_a_sticky_folder_does_not_excuse_the_folder_below_it() {
  vet_python_available || return 0
  sticky_world
  local owner spec
  owner="$(id -un)"
  spec='{}'
  chmod o+w "$PKG"
  assert_status 3 fake_run "$spec" run "$PKG" "$owner"
  assert_contains "$CAPTURED_STDOUT" "$PKG: writable by everyone"
  chmod o-w "$PKG"
  # a second sticky folder as the next component: only the first one is let through
  mkdir -p "$STK/inner/pkg" && chmod 1777 "$STK/inner"
  assert_status 3 fake_run "$spec" run "$STK/inner/pkg" "$owner"
  assert_contains "$CAPTURED_STDOUT" "$STK/inner: writable by everyone"
}

test_the_package_folder_itself_is_never_let_through_for_being_sticky() {
  vet_python_available || return 0
  sticky_world
  assert_status 3 fake_run '{}' run "$STK" "$(id -un)"
  assert_contains "$CAPTURED_STDOUT" "$STK: writable by everyone (mode 1777)"
}

test_a_world_writable_parent_without_the_sticky_bit_is_refused() {
  vet_python_available || return 0
  sticky_world
  chmod 0777 "$STK"
  assert_status 3 fake_run '{}' run "$PKG" "$(id -un)"
  assert_contains "$CAPTURED_STDOUT" "$STK: writable by everyone (mode 777)"
}

test_a_sticky_folder_above_a_folder_owned_by_somebody_else_is_refused() {
  vet_python_available || return 0
  [ "$(id -u)" -ne 0 ] || return 0
  sticky_world
  # root alone is trusted here, so the folder this account owns under the sticky /tmp is somebody else's
  assert_status 3 fake_run '{}' run "$PKG" root
  assert_contains "$CAPTURED_STDOUT" "owned by $(id -un), who can change its mode"
}

test_a_sticky_folder_with_an_access_list_entry_for_somebody_else_is_still_refused() {
  vet_python_available || return 0
  sticky_world
  # the entry is on the sticky folder (one level above the package: ".."): user number 4242 may write, mask rw
  local spec='{"accounts": [["intruder",4242,4242,"/bin/bash"]], "acl": {"..": [[2,6,4242],[16,6,4294967295]]}}'
  assert_status 3 fake_run "$spec" run "$PKG" "$(id -un)"
  assert_contains "$CAPTURED_STDOUT" "$STK: an access list entry gives intruder write"
}

test_the_group_message_names_the_members_that_make_it_untrusted() {
  vet_python_available || return 0
  sticky_world
  chmod 0775 "$PKG/lib"
  local spec='{"accounts": [["worker",600,"folder","/bin/bash"]]}'
  assert_status 3 fake_run "$spec" run "$PKG" "$(id -un)"
  assert_contains "$CAPTURED_STDOUT" "lib: writable by the group"
  assert_contains "$CAPTURED_STDOUT" "which has other members: worker"
}

# ---- the reason for a refusal when an access list is on the file (SIR-97). with an access list the group bits of the mode are
# the mask, so a file whose owning group cannot write shows group write; the refusal must name the entry that gives the write.

acl_package() {  # sets PKG, with lib/a.sh mode 664 (the mask is rw)
  PKG="$TEST_TMP/pkg"
  mkdir -p "$PKG/lib" && echo x > "$PKG/lib/a.sh" && chmod -R go-w "$PKG" && chmod 664 "$PKG/lib/a.sh"
}

test_an_access_list_entry_is_named_as_the_cause_not_the_group() {
  vet_python_available || return 0
  acl_package
  # the owning group may only read (entry 4, permission 4), user number 4242 may write, mask rw; the file's group has an outsider
  local spec='{"accounts": [["worker",600,"folder","/bin/bash"],["intruder",4242,4242,"/bin/bash"]],
    "acl": {"lib/a.sh": [[2,6,4242],[4,4,4294967295],[16,6,4294967295]]}}'
  assert_status 3 fake_run "$spec" run "$PKG" "$(id -un)"
  assert_contains "$CAPTURED_STDOUT" "lib/a.sh: an access list entry gives intruder write"
  assert_not_contains "$CAPTURED_STDOUT" "writable by the group"
}

test_a_mask_that_only_serves_a_trusted_entry_is_not_blamed_on_the_group() {
  vet_python_available || return 0
  acl_package
  # the same file with the only named entry for the owner: nobody else can write, though the mode shows group write
  local spec acl_owner
  acl_owner="$(id -u)"
  spec='{"accounts": [["worker",600,"folder","/bin/bash"]], "acl": {"lib/a.sh": [[2,6,'"$acl_owner"'],[4,4,4294967295],[16,6,4294967295]]}}'
  assert_status 0 fake_run "$spec" run "$PKG" "$(id -un)"
}

test_an_owning_group_entry_that_can_write_is_still_the_groups_doing() {
  vet_python_available || return 0
  acl_package
  local spec='{"accounts": [["worker",600,"folder","/bin/bash"]], "acl": {"lib/a.sh": [[2,6,0],[4,6,4294967295],[16,6,4294967295]]}}'
  assert_status 3 fake_run "$spec" run "$PKG" "$(id -un)"
  assert_contains "$CAPTURED_STDOUT" "lib/a.sh: writable by the group"
  assert_contains "$CAPTURED_STDOUT" "which has other members: worker"
  # and a mask that takes the write away from that entry makes it harmless
  spec='{"accounts": [["worker",600,"folder","/bin/bash"]], "acl": {"lib/a.sh": [[2,6,0],[4,6,4294967295],[16,4,4294967295]]}}'
  assert_status 0 fake_run "$spec" run "$PKG" "$(id -un)"
}

test_an_access_list_entry_for_an_untrusted_group_is_named_as_such() {
  vet_python_available || return 0
  acl_package
  local spec='{"accounts": [["worker",600,5000,"/bin/bash"]], "acl": {"lib/a.sh": [[8,6,5000],[4,4,4294967295],[16,6,4294967295]]}}'
  assert_status 3 fake_run "$spec" run "$PKG" "$(id -un)"
  assert_contains "$CAPTURED_STDOUT" "lib/a.sh: an access list entry gives the group g5000 write"
}
