# shellcheck shell=bash
# the setup questions: defaults, no terminal, --yes, flags and SIRVEN_* answering ahead of time.
# tests/run.sh gives every test /dev/null on standard input, so asking needs SIRVEN_INTERACTIVE=yes.

# install_in FOLDER ARGUMENT...: install.sh run from FOLDER, a dry run on a fake root.
install_in() {
  local folder="$1"
  shift
  cd "$folder" && SIRVEN_OS_OVERRIDE=linux "$REPO_DIR/install.sh" --dry-run \
    --prefix "$TEST_TMP/root" --transport none --owner example "$@"
}

# answering TEXT FOLDER ARGUMENT...: install_in with TEXT typed at the questions.
answering() {
  local text="$1"
  shift
  printf '%s' "$text" | SIRVEN_INTERACTIVE=yes install_in "$@"
}

project() {
  mkdir -p "$TEST_TMP/project"
  (cd "$TEST_TMP/project" && pwd -P)
}

test_no_terminal_uses_the_defaults() {
  assert_status 0 install_in "$(project)"
  assert_contains "$CAPTURED_STDERR" "using defaults (no terminal to ask on): level observer, paths none"
  assert_not_contains "$CAPTURED_STDERR" "access level ["
  assert_contains "$CAPTURED_STDOUT" "level: observer (write allowed: false)"
  assert_contains "$CAPTURED_STDOUT" "paths: none (the agent can use only its own home)"
  assert_not_contains "$CAPTURED_STDOUT" "setfacl"
}

test_no_terminal_never_grants_the_current_folder() {
  assert_status 0 install_in "$(project)"
  assert_not_contains "$CAPTURED_STDOUT" "$(project)"
}

test_yes_asks_nothing_even_with_a_terminal() {
  assert_status 0 answering "builder
" "$(project)" --yes
  assert_contains "$CAPTURED_STDERR" "using defaults (--yes)"
  assert_not_contains "$CAPTURED_STDERR" "access level ["
  assert_contains "$CAPTURED_STDOUT" "level: observer"
  assert_status 0 answering "" "$(project)" --defaults
  assert_contains "$CAPTURED_STDERR" "using defaults (--yes)"
}

test_sirven_yes_is_the_same_as_the_flag() {
  SIRVEN_YES=1
  export SIRVEN_YES
  assert_status 0 answering "" "$(project)"
  assert_contains "$CAPTURED_STDERR" "using defaults (--yes)"
}

test_enter_twice_accepts_the_shown_defaults() {
  local here
  here="$(project)"
  assert_status 0 answering "

" "$here"
  assert_contains "$CAPTURED_STDERR" "1/2 access level [observer]: "
  assert_contains "$CAPTURED_STDERR" "2/2 path to grant [$here]: "
  assert_contains "$CAPTURED_STDOUT" "level: observer (write allowed: false)"
  assert_contains "$CAPTURED_STDOUT" "paths: $here"
  assert_contains "$CAPTURED_STDOUT" "grant-access $TEST_TMP/root$here yes agent rX"
}

test_answers_shape_the_plan() {
  assert_status 0 answering "Builder
/srv/app
" "$(project)"
  assert_contains "$CAPTURED_STDOUT" "level: builder (write allowed: true)"
  assert_contains "$CAPTURED_STDOUT" "paths: /srv/app"
  assert_contains "$CAPTURED_STDOUT" "grant-access $TEST_TMP/root/srv/app yes agent rwX"
}

test_questions_come_before_the_plan() {
  local combined
  combined="$(printf '\n\n' | SIRVEN_INTERACTIVE=yes install_in "$(project)" 2>&1)"
  assert_eq "1" "$(printf '%s\n' "$combined" | grep -n -e 'path to grant \[' -e '^sirven install plan' | head -n 1 | grep -c 'path to grant')" \
    "the last question must print before the plan"
}

test_the_path_default_is_none_where_nothing_can_be_granted() {
  assert_status 0 answering "

" /
  assert_contains "$CAPTURED_STDERR" "2/2 path to grant [none]: "
  assert_contains "$CAPTURED_STDOUT" "paths: none"
}

test_none_grants_nothing() {
  assert_status 0 answering "builder
none
" "$(project)"
  assert_contains "$CAPTURED_STDOUT" "paths: none"
  assert_not_contains "$CAPTURED_STDOUT" "setfacl"
}

test_a_bad_answer_is_asked_again() {
  assert_status 0 answering "admin
operator
relative/path
/home/example
/srv/app
" "$(project)"
  assert_contains "$CAPTURED_STDERR" "type observer, builder, or operator"
  assert_contains "$CAPTURED_STDERR" "type an absolute path"
  assert_contains "$CAPTURED_STDERR" "/home/example cannot be granted at operator"
  assert_contains "$CAPTURED_STDOUT" "level: operator"
  assert_contains "$CAPTURED_STDOUT" "paths: /srv/app"
}

test_three_bad_levels_stop_the_run() {
  assert_status 64 answering "admin
root
sudo
" "$(project)"
  assert_contains "$CAPTURED_STDERR" "access level must be observer, builder, or operator"
  assert_not_contains "$CAPTURED_STDOUT" "install plan"
}

test_input_that_ends_takes_the_defaults() {
  local here
  here="$(project)"
  assert_status 0 answering "" "$here"
  assert_contains "$CAPTURED_STDOUT" "level: observer"
  assert_contains "$CAPTURED_STDOUT" "paths: $here"
}

test_a_level_flag_leaves_one_question() {
  assert_status 0 answering "/srv/app
" "$(project)" --level builder
  assert_contains "$CAPTURED_STDERR" "1/1 path to grant ["
  assert_not_contains "$CAPTURED_STDERR" "access level ["
  assert_contains "$CAPTURED_STDOUT" "level: builder"
  assert_contains "$CAPTURED_STDOUT" "paths: /srv/app"
}

test_a_path_flag_leaves_one_question() {
  assert_status 0 answering "operator
" "$(project)" --path /srv/app
  assert_contains "$CAPTURED_STDERR" "1/1 access level [observer]: "
  assert_not_contains "$CAPTURED_STDERR" "path to grant"
  assert_contains "$CAPTURED_STDOUT" "level: operator"
}

test_flags_for_both_ask_nothing() {
  assert_status 0 answering "operator
" "$(project)" --level builder --path /srv/app
  assert_eq "" "$(printf '%s\n' "$CAPTURED_STDERR" | grep -e 'setup:' -e 'using defaults')" "nothing asked, no defaults note"
  assert_contains "$CAPTURED_STDOUT" "level: builder"
}

test_environment_answers_ahead_of_time() {
  SIRVEN_LEVEL=builder
  SIRVEN_PATH=/srv/app:/home/example/notes
  export SIRVEN_LEVEL SIRVEN_PATH
  assert_status 0 answering "operator
" "$(project)"
  assert_not_contains "$CAPTURED_STDERR" "["
  assert_contains "$CAPTURED_STDOUT" "level: builder"
  assert_contains "$CAPTURED_STDOUT" "paths: /srv/app, /home/example/notes"
}

test_sirven_path_none_grants_nothing() {
  SIRVEN_PATH=none
  export SIRVEN_PATH
  assert_status 0 answering "
" "$(project)"
  assert_contains "$CAPTURED_STDERR" "1/1 access level"
  assert_contains "$CAPTURED_STDOUT" "paths: none"
}

test_flags_beat_the_environment() {
  SIRVEN_LEVEL=operator
  SIRVEN_PATH=/srv/other
  export SIRVEN_LEVEL SIRVEN_PATH
  assert_status 0 install_in "$(project)" --level builder --path /srv/app
  assert_contains "$CAPTURED_STDOUT" "level: builder"
  assert_contains "$CAPTURED_STDOUT" "paths: /srv/app"
  assert_not_contains "$CAPTURED_STDOUT" "/srv/other"
}

test_bad_environment_values_stop_before_preflight() {
  SIRVEN_LEVEL=root
  export SIRVEN_LEVEL
  assert_status 64 install_in "$(project)"
  assert_contains "$CAPTURED_STDERR" "SIRVEN_LEVEL must be observer, builder, or operator, got 'root'"
  assert_not_contains "$CAPTURED_STDERR" "preflight:"
  unset SIRVEN_LEVEL
  SIRVEN_INTERACTIVE=maybe
  export SIRVEN_INTERACTIVE
  assert_status 64 install_in "$(project)"
  assert_contains "$CAPTURED_STDERR" "SIRVEN_INTERACTIVE must be yes or no"
}

test_interactive_no_never_asks() {
  # input waiting on standard input is still not read
  SIRVEN_INTERACTIVE=no
  export SIRVEN_INTERACTIVE
  capture install_in "$(project)" <<END
builder
END
  assert_eq 0 "$CAPTURED_STATUS" "exit status"
  assert_contains "$CAPTURED_STDERR" "using defaults (no terminal to ask on)"
  assert_contains "$CAPTURED_STDOUT" "level: observer"
}

revoke_in() {
  cd "$1" && printf 'builder\n' | SIRVEN_INTERACTIVE=yes SIRVEN_OS_OVERRIDE=linux "$REPO_DIR/install.sh" \
    revoke --all --dry-run --prefix "$TEST_TMP/root" --transport none --owner example
}

test_revoke_asks_nothing() {
  assert_status 0 revoke_in "$(project)"
  assert_not_contains "$CAPTURED_STDERR" "["
  assert_not_contains "$CAPTURED_STDERR" "using defaults"
}

test_defaults_apply_on_a_fake_root() {
  local root="$TEST_TMP/root"
  capture sh -c 'cd "$1" && SIRVEN_OS_OVERRIDE=linux "$2/install.sh" --yes --prefix "$3" --transport none --owner example' _ "$(project)" "$REPO_DIR" "$root"
  assert_eq 0 "$CAPTURED_STATUS" "exit status: $CAPTURED_STDERR"
  assert_contains "$CAPTURED_STDOUT" "paths: none"
  assert_file_exists "$root/etc/sirven/levels/observer.json"
  assert_no_file "$root/etc/sirven/grants/agent.json"
}
