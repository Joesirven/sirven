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

# TMPDIR names the folder the stage directory (the pending audit file, the grant snapshot) is made in, and root writes there
test_the_gate_drops_the_variables_that_would_steer_what_root_writes_and_runs() {
  local block name file
  for file in install.sh uninstall.sh bin/sirven; do
    block="$(gate_block "$REPO_DIR/$file" | grep -v '^[[:space:]]*#')"
    for name in BASH_ENV ENV CDPATH LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT PYTHONPATH PYTHONHOME PYTHONSTARTUP TMPDIR; do
      assert_contains "$block" "$name" "$file: the gate must unset $name for root"
    done
  done
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
