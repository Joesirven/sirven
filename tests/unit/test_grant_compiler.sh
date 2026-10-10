# shellcheck shell=bash
# grant compiler behavior beyond the golden files: determinism, ordering, refusals.

compiler() {
  python3 "$REPO_DIR/lib/grant_compiler.py" "$@"
}

LEVEL_BUILDER="$REPO_DIR/levels/builder.json"

test_output_is_the_same_whatever_the_path_order() {
  local first second
  first="$(compiler compile --level "$LEVEL_BUILDER" --os linux --path /srv/b --path /srv/a --path /opt/c)"
  second="$(compiler compile --level "$LEVEL_BUILDER" --os linux --path /opt/c --path /srv/a/ --path /srv/b --path /srv/a)"
  assert_eq "$first" "$second"
}

test_fragment_lines_have_three_fields() {
  local line fields
  while IFS= read -r line; do
    case "$line" in '#'*) continue ;; esac
    fields="$(printf '%s\n' "$line" | awk -F '\t' '{print NF}')"
    assert_eq 3 "$fields" "title, check, command: $line"
  done <<END
$(compiler compile --level "$LEVEL_BUILDER" --os macos --path /opt/site)
END
}

test_traverse_never_downgrades_a_granted_parent() {
  capture compiler compile --level "$LEVEL_BUILDER" --os linux --path /srv/app --path /srv/app/sub
  assert_not_contains "$CAPTURED_STDOUT" "u:agent:x /srv/app"
  assert_contains "$CAPTURED_STDOUT" "setfacl -m u:agent:x /srv"
}

test_paths_with_spaces_are_quoted() {
  capture compiler compile --level "$LEVEL_BUILDER" --os linux --path "/srv/my app"
  assert_contains "$CAPTURED_STDOUT" "setfacl -R -P -m u:agent:rwX '/srv/my app'"
}

test_prefix_goes_in_commands_not_in_titles() {
  capture compiler compile --level "$LEVEL_BUILDER" --os linux --prefix /tmp/fake --path /srv/app
  assert_contains "$CAPTURED_STDOUT" "grant agent rwX on /srv/app and everything inside"
  assert_contains "$CAPTURED_STDOUT" "setfacl -R -P -m u:agent:rwX /tmp/fake/srv/app"
}

test_compile_needs_a_path() {
  assert_status 2 compiler compile --level "$LEVEL_BUILDER" --os linux
  assert_contains "$CAPTURED_STDERR" "at least one --path is required"
}

test_odd_user_names_are_refused() {
  assert_status 2 compiler compile --level "$LEVEL_BUILDER" --os linux --user 'agent;rm' --path /srv/app
  assert_contains "$CAPTURED_STDERR" "not a plain lowercase account name"
}

test_whole_system_folders_are_refused() {
  local path
  for path in / /etc /usr/local/bin /home /Users /var/lib/sirven /root/project; do
    assert_status 2 compiler compile --level "$LEVEL_BUILDER" --os linux --path "$path"
  done
}

test_record_is_stable_json() {
  capture compiler record --level "$LEVEL_BUILDER" --path /srv/b --path /srv/a
  assert_contains "$CAPTURED_STDOUT" '"level": "builder"'
  assert_contains "$CAPTURED_STDOUT" '"can_grant": false'
  assert_contains "$CAPTURED_STDOUT" '"expires": null'
  assert_eq "$CAPTURED_STDOUT" "$(compiler record --level "$LEVEL_BUILDER" --path /srv/a --path /srv/b)"
}

test_revoke_from_record_matches_revoke_from_paths() {
  compiler record --level "$LEVEL_BUILDER" --path /srv/app > "$TEST_TMP/grant.json"
  assert_eq \
    "$(compiler revoke --level "$REPO_DIR/levels/observer.json" --os linux --record "$TEST_TMP/grant.json")" \
    "$(compiler revoke --level "$LEVEL_BUILDER" --os linux --path /srv/app)"
}
