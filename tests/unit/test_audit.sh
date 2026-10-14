# shellcheck shell=bash
# the audit log writer: escaping, entries, and what install.sh writes when it applies.

# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/layout.sh
. "$REPO_DIR/lib/layout.sh"
# shellcheck source=lib/audit.sh
. "$REPO_DIR/lib/audit.sh"

SERVICE_USER=agent
PREFIX=""
AUDIT_DIR=/var/log/sirven

# json_field LINE KEY: read one field back with a real JSON parser.
json_field() {
  printf '%s' "$1" | python3 -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2"
}

install_sh() {
  SIRVEN_OS_OVERRIDE=linux "$REPO_DIR/install.sh" "$@" --owner example
}

test_strings_are_escaped() {
  local tricky line
  tricky="$(printf 'a "quoted" back\\slash\ttab\nnew line\001bell')"
  line="{\"value\": $(audit_json_string "$tricky")}"
  assert_eq "$(printf 'a "quoted" back\\slash\ttab\nnew line\001bell')" "$(json_field "$line" value)"
}

test_the_escaper_output_parses_as_json() {
  local tricky escaped
  # a backslash, a double quote, a newline, a tab, a control byte, and a unicode character (é)
  tricky="$(printf 'b\\s "q" n\nt\tc\001u\303\251')"
  escaped="$(audit_json_string "$tricky")"
  printf '{"value": %s}' "$escaped" | python3 -c 'import json, sys; json.load(sys.stdin)' || fail "escaped output is not JSON: $escaped"
  assert_eq "$(printf 'b\\s "q" n\nt\tc\001u\303\251')" "$(json_field "{\"value\": $escaped}" value)"
}

test_entries_are_json_and_values_cannot_inject_fields() {
  local line
  line="$(audit_entry step 'title=x", "event": "forged' 'outcome=a json:b=1' 'json:step=3')"
  assert_eq step "$(json_field "$line" event)"
  assert_eq 'x", "event": "forged' "$(json_field "$line" title)"
  assert_eq 3 "$(json_field "$line" step)"
  assert_eq owner "$(json_field "$line" principal)"
  assert_status 1 audit_entry step no-equals-sign
}

test_entries_wait_until_the_log_exists() {
  PREFIX="$TEST_TMP/root"
  AUDIT_PENDING="$TEST_TMP/pending.jsonl"
  audit_write '{"n": 1}'
  assert_no_file "$PREFIX/var/log/sirven/audit.jsonl"
  mkdir -p "$PREFIX/var/log/sirven"
  touch "$PREFIX/var/log/sirven/audit.jsonl"
  audit_write '{"n": 2}'
  assert_eq '{"n": 1}
{"n": 2}' "$(cat "$PREFIX/var/log/sirven/audit.jsonl")"
}

test_flush_warns_when_the_log_never_came() {
  PREFIX="$TEST_TMP/root"
  AUDIT_PENDING="$TEST_TMP/pending.jsonl"
  audit_write '{"n": 1}'
  capture audit_flush
  assert_contains "$CAPTURED_STDERR" "1 audit entries were not written"
}

test_the_time_override_works_only_on_a_fake_root() {
  SIRVEN_TIME_OVERRIDE=2026-01-01T00:00:00Z
  PREFIX=""
  assert_not_contains "$(audit_now)" "2026-01-01T00:00:00Z"
  PREFIX=/tmp/somewhere
  assert_eq 2026-01-01T00:00:00Z "$(audit_now)"
}

test_apply_writes_a_step_entry_for_every_step_and_a_grant() {
  local root="$TEST_TMP/root" log steps
  log="$root/var/log/sirven/audit.jsonl"
  assert_status 0 install_sh --prefix "$root" --level builder --path /srv/app --transport none
  python3 -c 'import json, sys; [json.loads(line) for line in open(sys.argv[1])]' "$log" || fail "every line is JSON"
  steps="$(printf '%s\n' "$CAPTURED_STDOUT" | sed -n '/^applying$/,$p' | grep -cE '^ +[0-9]+\. ')"
  assert_eq "$steps" "$(grep -c '"event": "step"' "$log")" "one entry per numbered step"
  assert_contains "$(cat "$log")" '"event": "grant", "user": "agent", "principal": "owner", "operation": "install", "level": "builder", "paths": ["/srv/app"], "previous_level": null'
  assert_contains "$(tail -n 1 "$log")" '"event": "install"'
}

test_a_grant_entry_only_when_the_grant_changes() {
  local root="$TEST_TMP/root" log
  log="$root/var/log/sirven/audit.jsonl"
  assert_status 0 install_sh --prefix "$root" --level builder --path /srv/app --transport none
  assert_status 0 install_sh --prefix "$root" --level builder --path /srv/app --transport none
  assert_eq 1 "$(grep -c '"event": "grant"' "$log")" "a re-run with the same grant changes nothing"
  assert_status 0 install_sh --prefix "$root" --level observer --path /srv/app --path /srv/docs --transport none
  assert_eq 2 "$(grep -c '"event": "grant"' "$log")"
  assert_contains "$(grep '"event": "grant"' "$log" | tail -n 1)" '"level": "observer", "paths": ["/srv/app", "/srv/docs"], "previous_level": "builder", "previous_paths": ["/srv/app"]'
}

test_dry_run_writes_no_entries() {
  local root="$TEST_TMP/root"
  assert_status 0 install_sh --prefix "$root" --level builder --path /srv/app --transport none
  local before
  before="$(cat "$root/var/log/sirven/audit.jsonl")"
  assert_status 0 install_sh --dry-run --prefix "$root" --level observer --path /srv/app --transport none
  assert_eq "$before" "$(cat "$root/var/log/sirven/audit.jsonl")"
}
