# shellcheck shell=bash
# optional components: sirven add and sirven remove on a fake root, and proof that core never
# needs one. no test here starts a container: under --prefix, docker commands are recorded.

sirven() {
  SIRVEN_OS_OVERRIDE=linux HOME=/home/example XDG_CONFIG_HOME="" "$REPO_DIR/bin/sirven" "$@"
}

install_core() {
  ROOT="$TEST_TMP/root"
  CRM="$ROOT/home/example/.config/sirven/components/crm"
  assert_status 0 env SIRVEN_OS_OVERRIDE=linux "$REPO_DIR/install.sh" --prefix "$ROOT" --yes --owner example --transport none --path /srv/app
}

secret_values() {
  sed -n -E 's/^(ENCRYPTION_KEY|PG_DATABASE_PASSWORD)=//p' "$1"
}

test_add_usage() {
  assert_status 0 sirven add --help
  assert_contains "$CAPTURED_STDOUT" "sirven add --list"
  assert_status 64 sirven add
  assert_status 64 sirven add nothing-like-it
  assert_contains "$CAPTURED_STDERR" "no component named 'nothing-like-it'"
  assert_status 64 sirven add ../crm
  assert_status 64 sirven remove --list
  assert_status 64 sirven add crm --remove-data --dry-run
  assert_status 64 sirven add crm --dir relative/folder --dry-run
  assert_status 0 sirven --help
  assert_contains "$CAPTURED_STDOUT" "sirven add --list"
}

test_list_shows_crm_and_whether_it_is_added() {
  assert_status 0 sirven add --list
  assert_contains "$CAPTURED_STDOUT" "crm: Twenty, a self-hosted customer relationship manager"
  assert_contains "$CAPTURED_STDOUT" "(not added)"
  mkdir -p "$TEST_TMP/root/home/example/.config/sirven/components/crm"
  assert_status 0 sirven add --list --prefix "$TEST_TMP/root"
  assert_contains "$CAPTURED_STDOUT" "added, in /home/example/.config/sirven/components/crm"
}

test_credentials_and_copies_never_go_in_the_repository() {
  assert_status 64 sirven add crm --dry-run --dir "$REPO_DIR/crm"
  assert_contains "$CAPTURED_STDERR" "outside this repository"
  assert_status 64 sirven add crm --dry-run --env-file "$REPO_DIR/.env"
  assert_status 64 sirven add crm --dry-run --dir "$REPO_DIR"
}

test_add_dry_run_shows_the_plan_and_changes_nothing() {
  assert_status 0 sirven add crm --dry-run --prefix "$TEST_TMP/root"
  assert_contains "$CAPTURED_STDOUT" "sirven add crm plan"
  assert_contains "$CAPTURED_STDOUT" "optional: sirven itself never needs it"
  assert_contains "$CAPTURED_STDOUT" "copy the Docker Compose file for Twenty v2.46.0 (to do)"
  assert_contains "$CAPTURED_STDOUT" "ENCRYPTION_KEY from openssl rand -base64 32"
  assert_contains "$CAPTURED_STDOUT" "--env-file $TEST_TMP/root/home/example/.config/sirven/components/crm/.env up -d"
  assert_contains "$CAPTURED_STDOUT" "open Twenty and create the first workspace (owner, by hand)"
  assert_contains "$CAPTURED_STDOUT" "dry run: nothing was changed"
  assert_no_file "$TEST_TMP/root"
}

test_applying_needs_the_audit_log() {
  assert_status 3 sirven add crm --prefix "$TEST_TMP/root"
  assert_contains "$CAPTURED_STDERR" "no audit log"
  assert_no_file "$TEST_TMP/root/home"
}

test_add_copies_the_component_and_keeps_the_secrets_out_of_every_output() {
  local value
  install_core
  assert_status 0 sirven add crm --prefix "$ROOT"
  assert_contains "$CAPTURED_STDOUT" "applied 6 steps"
  assert_file_exists "$CRM/docker-compose.yml"
  assert_contains "$(cat "$CRM/docker-compose.yml")" "image: twentycrm/twenty:v2.46.0"
  assert_contains "$(cat "$CRM/docker-compose.yml")" '"127.0.0.1:3000:3000"'
  # shellcheck disable=SC2012
  assert_eq "-rw-------" "$(ls -l "$CRM/.env" | cut -c1-10)" "the dotenv must be private"
  assert_eq 2 "$(secret_values "$CRM/.env" | grep -c .)" "the dotenv needs both secrets"
  for value in $(secret_values "$CRM/.env"); do
    assert_not_contains "$CAPTURED_STDOUT$CAPTURED_STDERR" "$value" "a secret was printed"
    assert_not_contains "$(cat "$ROOT/var/log/sirven/audit.jsonl")" "$value" "a secret reached the audit log"
  done
  assert_contains "$(cat "$ROOT/var/lib/sirven/simulated-system-commands.log")" \
    "docker compose --project-directory $CRM --env-file $CRM/.env up -d"
  assert_contains "$(cat "$ROOT/var/log/sirven/audit.jsonl")" '"operation": "add crm", "step": 5, "kind": "system", "title": "start Twenty with Docker Compose", "outcome": "recorded"'
  assert_contains "$(tail -n 1 "$ROOT/var/log/sirven/audit.jsonl")" '"event": "component", "user": "agent", "principal": "owner", "operation": "add crm", "component": "crm"'
  assert_contains "$(tail -n 1 "$ROOT/var/log/sirven/audit.jsonl")" '"outcome": "finished"'
  assert_not_contains "$(cat "$ROOT/var/lib/sirven/install-record.tsv")" "components/crm" "components stay out of the install record"
}

test_add_again_never_overwrites_your_edits_or_your_secrets() {
  local before
  install_core
  assert_status 0 sirven add crm --prefix "$ROOT"
  printf '# my own change\n' >> "$CRM/docker-compose.yml"
  before="$(cat "$CRM/docker-compose.yml" "$CRM/.env")"
  assert_status 0 sirven add crm --prefix "$ROOT"
  assert_contains "$CAPTURED_STDOUT" "summary: 8 steps. 0 to do, 6 already done, 2 by the owner"
  assert_eq "$before" "$(cat "$CRM/docker-compose.yml" "$CRM/.env")" "add changed a file that was already there"
}

test_a_dotenv_you_control_keeps_its_values() {
  local own="$TEST_TMP/root/home/example/secrets/twenty.env"
  install_core
  mkdir -p "$(dirname "$own")"
  printf 'ENCRYPTION_KEY=the-one-i-already-have\n' > "$own"
  assert_status 0 sirven add crm --prefix "$ROOT" --env-file /home/example/secrets/twenty.env
  assert_contains "$CAPTURED_STDOUT" "credentials: /home/example/secrets/twenty.env, a dotenv you control"
  assert_eq "the-one-i-already-have" "$(sed -n 's/^ENCRYPTION_KEY=//p' "$own")"
  assert_eq 1 "$(grep -c '^PG_DATABASE_PASSWORD=.' "$own")"
  assert_no_file "$CRM/.env"
  assert_status 0 sirven remove crm --prefix "$ROOT" --env-file /home/example/secrets/twenty.env --remove-data
  assert_contains "$CAPTURED_STDOUT" "you named it with --env-file, so it is not this component's to remove"
  assert_file_exists "$own"
}

test_remove_keeps_your_changes_and_your_data_by_default() {
  install_core
  assert_status 0 sirven add crm --prefix "$ROOT"
  printf '# my own change\n' >> "$CRM/docker-compose.yml"
  assert_status 0 sirven remove crm --prefix "$ROOT"
  assert_contains "$CAPTURED_STDOUT" "kept: the Docker volumes"
  assert_contains "$CAPTURED_STDOUT" "you changed it, so it is yours"
  assert_file_exists "$CRM/docker-compose.yml"
  assert_file_exists "$CRM/.env"
  assert_contains "$(cat "$ROOT/var/lib/sirven/simulated-system-commands.log")" "--env-file $CRM/.env down"
  assert_contains "$(tail -n 1 "$ROOT/var/log/sirven/audit.jsonl")" '"operation": "remove crm"'
}

test_remove_with_remove_data_leaves_nothing() {
  install_core
  assert_status 0 sirven add crm --prefix "$ROOT"
  assert_status 0 sirven remove crm --prefix "$ROOT" --remove-data
  assert_contains "$(cat "$ROOT/var/lib/sirven/simulated-system-commands.log")" "--env-file $CRM/.env down --volumes"
  assert_no_file "$CRM"
  assert_status 0 sirven add --list --prefix "$ROOT"
  assert_contains "$CAPTURED_STDOUT" "(not added)"
  # core is untouched: the grant is still in force.
  assert_file_exists "$ROOT/etc/sirven/grants/agent.json"
}

# Jose's ruling: the customer relationship component is optional, never core. so core must not
# name it, and must work in a copy of sirven that has no components folder at all.
test_core_never_names_a_component() {
  local hits
  hits="$(cd "$REPO_DIR" && grep -rliE 'twenty|crm' install.sh uninstall.sh bin lib levels project.json)"
  assert_eq "" "$hits" "core files name a component"
}

test_core_works_with_no_components_folder() {
  local copy="$TEST_TMP/core" root="$TEST_TMP/core-root" name
  mkdir -p "$copy"
  (cd "$REPO_DIR" && tar -cf - install.sh uninstall.sh bin lib levels project.json Makefile tests) | (cd "$copy" && tar -xf -)
  rm -f "$copy/tests/unit/test_components.sh"
  assert_no_file "$copy/components"

  assert_status 0 env SIRVEN_OS_OVERRIDE=linux "$copy/install.sh" --prefix "$root" --yes --owner example --transport none --level builder --path /srv/app
  assert_status 0 env SIRVEN_OS_OVERRIDE=linux "$copy/bin/sirven" grant inspect --prefix "$root"
  assert_contains "$CAPTURED_STDOUT" "level in force: builder"
  assert_status 0 env SIRVEN_OS_OVERRIDE=linux "$copy/bin/sirven" add --list
  assert_contains "$CAPTURED_STDOUT" "none: this copy of sirven has no components folder, and needs none."
  assert_status 64 env SIRVEN_OS_OVERRIDE=linux "$copy/bin/sirven" add crm --dry-run
  assert_status 0 env SIRVEN_OS_OVERRIDE=linux "$copy/install.sh" revoke --all --dry-run --prefix "$root" --owner example --transport none
  assert_status 0 env SIRVEN_OS_OVERRIDE=linux "$copy/uninstall.sh" --prefix "$root"

  # the core suites themselves, run from the copy: plans, golden files, the command, uninstall.
  for name in plan_engine idempotency cli uninstall audit golden; do
    assert_status 0 bash "$copy/tests/run.sh" "$name"
    assert_contains "$CAPTURED_STDOUT" " 0 failed"
  done
}
