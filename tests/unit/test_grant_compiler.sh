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
  assert_contains "$CAPTURED_STDOUT" "grant-access /srv no agent x"
}

test_paths_with_spaces_are_quoted() {
  capture compiler compile --level "$LEVEL_BUILDER" --os linux --path "/srv/my app"
  assert_contains "$CAPTURED_STDOUT" "grant-access '/srv/my app' yes agent rwX"
}

test_prefix_goes_in_commands_not_in_titles() {
  capture compiler compile --level "$LEVEL_BUILDER" --os linux --prefix /tmp/fake --path /srv/app
  assert_contains "$CAPTURED_STDOUT" "grant agent rwX on /srv/app and everything inside"
  assert_contains "$CAPTURED_STDOUT" "grant-access /tmp/fake/srv/app yes agent rwX"
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

# on macos the undo is not the revoke subtraction: it sweeps every entry of the agent (see
# lib/access_control_macos.py), because a subtraction leaves the entries a new file inherited and fails
# on a file with no list. revoke on macos is the same sweep (the next test), so the two agree.
test_with_undo_pairs_every_grant_with_its_removal() {
  local os=macos with_undo undo_commands
  with_undo="$(compiler compile --level "$LEVEL_BUILDER" --os "$os" --with-undo --path /srv/b --path /opt/site/app)"
  assert_eq "" "$(printf '%s\n' "$with_undo" | grep -v '^#' | awk -F '\t' 'NF != 6')" "six fields on $os"
  assert_eq "$(compiler compile --level "$LEVEL_BUILDER" --os "$os" --path /srv/b --path /opt/site/app)" \
    "$(printf '%s\n' "$with_undo" | cut -f1-3)" "the first three fields are the plain compile on $os"
  undo_commands="$(printf '%s\n' "$with_undo" | grep -v '^#' | cut -f6)"
  assert_eq "" "$(printf '%s\n' "$undo_commands" | grep -v '^bash /var/lib/sirven/package/lib/access_control_macos.sh sweep agent ')" "every macos undo is a sweep"
  assert_contains "$undo_commands" "sweep agent yes /srv/b"
  assert_contains "$undo_commands" "sweep agent no /opt"
  assert_eq "" "$(printf '%s\n' "$with_undo" | grep -v '^#' | cut -f5 | grep -v 'access_control_macos.sh status agent ')" "every macos undo check reads the whole tree"
  assert_eq "" "$(printf '%s\n' "$undo_commands" | grep -F 'chmod')" "no macos undo is a subtraction"
}

# revoke on macos is the sweep the undo of a grant is, not a subtraction: the kill switch and uninstall leave
# the same state, and no entry that names the agent is left on an old, an inherited, or a list-less item.
test_macos_revoke_is_the_same_sweep_as_the_undo() {
  local revoke with_undo
  revoke="$(compiler revoke --level "$LEVEL_BUILDER" --os macos --path /srv/b --path /srv/b/sub --path /opt/site/app)"
  with_undo="$(compiler compile --level "$LEVEL_BUILDER" --os macos --with-undo --path /srv/b --path /srv/b/sub --path /opt/site/app)"
  assert_not_contains "$revoke" "chmod"
  assert_not_contains "$revoke" "find "
  assert_eq "" "$(printf '%s\n' "$revoke" | grep -v '^#' | grep -v 'access_control_macos.sh sweep agent ')" "every macos revoke line is a sweep"
  # the title, the check and the command are the undo's, line for line, with the repeats of the two-line grant gone
  assert_eq "$(printf '%s\n' "$with_undo" | grep -v '^#' | cut -f4-6 | sort -u)" \
    "$(printf '%s\n' "$revoke" | grep -v '^#' | sort -u)" "revoke is the undo of the grant, step for step"
  # each granted folder is swept with everything inside it, and each pass-through parent alone
  assert_contains "$revoke" "sweep agent yes /srv/b"
  assert_contains "$revoke" "sweep agent yes /srv/b/sub"
  assert_contains "$revoke" "sweep agent no /srv"
  assert_contains "$revoke" "sweep agent no /opt"
  assert_eq "yes yes yes no no no" "$(printf '%s\n' "$revoke" | grep -v '^#' | cut -f3 | awk '{print $5}' | tr '\n' ' ' | sed 's/ $//')" \
    "the order is as it was: granted folders, then parents"
  # a prefix is put in front of the helper and the path, as the grant does
  assert_contains "$(compiler revoke --level "$LEVEL_BUILDER" --os macos --prefix /tmp/fake --path /srv/b)" \
    "bash /tmp/fake/var/lib/sirven/package/lib/access_control_macos.sh sweep agent yes /tmp/fake/srv/b"
}

test_macos_revoke_from_record_matches_revoke_from_paths() {
  compiler record --level "$LEVEL_BUILDER" --path /srv/app > "$TEST_TMP/grant.json"
  assert_eq \
    "$(compiler revoke --level "$REPO_DIR/levels/observer.json" --os macos --record "$TEST_TMP/grant.json")" \
    "$(compiler revoke --level "$LEVEL_BUILDER" --os macos --path /srv/app)"
}

test_linux_with_undo_records_a_snapshot_before_any_change() {
  local with_undo first_change last_snapshot
  with_undo="$(compiler compile --level "$LEVEL_BUILDER" --os linux --with-undo --prefix /tmp/fake --path /srv/b --path /srv/b/sub)"
  # one snapshot per folder (the parent /srv and the two granted folders), each with its restore as undo
  assert_eq 3 "$(printf '%s\n' "$with_undo" | grep -c '^record the access control lists of ')" "snapshot lines on linux"
  assert_eq 3 "$(printf '%s\n' "$with_undo" | awk -F '\t' 'NF == 6' | grep -c '^record the access control lists of ')" "snapshot lines carry an undo"
  assert_contains "$(printf '%s\n' "$with_undo" | awk -F '\t' 'NF == 6 {print $6}')" \
    "access_control_snapshot.sh restore /tmp/fake/var/lib/sirven/access-lists/"
  # every snapshot line comes before the first line that changes an access control list
  last_snapshot="$(printf '%s\n' "$with_undo" | grep -n '^record the access control lists of ' | tail -n 1 | cut -d: -f1)"
  first_change="$(printf '%s\n' "$with_undo" | grep -n '^let agent pass through\|^grant agent' | head -n 1 | cut -d: -f1)"
  assert_eq 1 "$((last_snapshot < first_change))" "snapshots come before the first change"
}

test_show_reads_a_grant_record() {
  compiler record --level "$LEVEL_BUILDER" --path /srv/b --path /srv/a > "$TEST_TMP/grant.json"
  assert_eq "level=builder
user=agent
principal=owner-agent
write_allowed=true
expires=never
can_grant=false
path=/srv/a
path=/srv/b" "$(compiler show --record "$TEST_TMP/grant.json")"
  printf '{"level": "root"}\n' > "$TEST_TMP/bad.json"
  assert_status 2 compiler show --record "$TEST_TMP/bad.json"
}

test_last_grant_finds_the_newest_entry_for_the_user() {
  cat > "$TEST_TMP/audit.jsonl" <<'END'
{"time": "t1", "event": "grant", "user": "agent", "level": "observer", "paths": ["/srv/a"], "previous_level": null, "previous_paths": [], "reason": "install"}
not json at all
{"time": "t2", "event": "grant", "user": "agent", "level": "builder", "paths": ["/srv/a", "/srv/b"], "previous_level": "observer", "previous_paths": ["/srv/a"], "reason": "install"}
{"time": "t3", "event": "grant", "user": "friend", "level": "observer", "paths": ["/srv/c"], "previous_level": null, "previous_paths": [], "reason": "install"}
{"time": "t4", "event": "step", "user": "agent"}
END
  assert_eq "time=t2
reason=install
level=builder
previous_level=observer
path=/srv/a
path=/srv/b
previous_path=/srv/a
skipped_lines=1" "$(compiler last-grant --audit "$TEST_TMP/audit.jsonl" --user agent)"
  assert_eq "skipped_lines=1" "$(compiler last-grant --audit "$TEST_TMP/audit.jsonl" --user nobody)"
}
