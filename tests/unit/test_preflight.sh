# shellcheck shell=bash
# preflight: version math, tool versions, missing commands, a missing python3.

# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/preflight.sh
. "$REPO_DIR/lib/preflight.sh"

# make_tool NAME OUTPUT: a fake command in $TEST_TMP/bin that prints OUTPUT.
make_tool() {
  mkdir -p "$TEST_TMP/bin"
  printf '#!/bin/sh\necho "%s"\n' "$2" > "$TEST_TMP/bin/$1"
  chmod +x "$TEST_TMP/bin/$1"
}

test_version_at_least() {
  version_at_least 3.2 3.2 || fail "3.2 >= 3.2"
  version_at_least 5.1 3.2 || fail "5.1 >= 3.2"
  version_at_least 3.10 3.6 || fail "3.10 >= 3.6, compared as numbers"
  version_at_least 1.62.0 1.60.0 || fail "1.62.0 >= 1.60.0"
  version_at_least 2024.8.2 2024.1.0 || fail "2024.8.2 >= 2024.1.0"
  version_at_least 1.60 1.60.0 || fail "missing parts count as zero"
  if version_at_least 3.1 3.2; then fail "3.1 < 3.2"; fi
  if version_at_least 1.58.2 1.60.0; then fail "1.58.2 < 1.60.0"; fi
  if version_at_least 2023.12.9 2024.1.0; then fail "2023.12.9 < 2024.1.0"; fi
}

test_first_version_reads_tool_output() {
  assert_eq 1.62.0 "$(first_version '1.62.0-t1234abcd go1.22')"
  assert_eq 2024.8.2 "$(first_version 'cloudflared version 2024.8.2 (built 2024-08-20-1200)')"
  assert_eq 3.10.12 "$(first_version 'Python 3.10.12')"
  assert_eq "" "$(first_version 'no numbers here')"
}

test_tool_too_old_is_a_problem_when_strict() {
  make_tool tailscale "1.40.0"
  PATH="$TEST_TMP/bin:$PATH"
  PREFLIGHT_PROBLEMS=0
  capture preflight_tool yes tailscale 1.60.0 version
  assert_eq 0 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "tailscale 1.40.0 is older than the pinned minimum 1.60.0"
  preflight_tool yes tailscale 1.60.0 version 2>/dev/null
  assert_eq 1 "$PREFLIGHT_PROBLEMS"
}

test_tool_too_old_only_warns_when_not_strict() {
  make_tool tailscale "1.40.0"
  PATH="$TEST_TMP/bin:$PATH"
  PREFLIGHT_PROBLEMS=0
  preflight_tool no tailscale 1.60.0 version 2>/dev/null
  assert_eq 0 "$PREFLIGHT_PROBLEMS"
}

test_tool_new_enough_passes() {
  make_tool cloudflared "cloudflared version 2024.8.2 (built 2024-08-20)"
  PATH="$TEST_TMP/bin:$PATH"
  capture preflight_tool yes cloudflared 2024.1.0 --version
  assert_contains "$CAPTURED_STDERR" "preflight: ok cloudflared 2024.8.2"
}

test_missing_command_counts_when_strict() {
  PREFLIGHT_PROBLEMS=0
  preflight_commands yes sh no-such-command-sirven 2>/dev/null
  assert_eq 1 "$PREFLIGHT_PROBLEMS"
  PREFLIGHT_PROBLEMS=0
  preflight_commands no no-such-command-sirven 2>/dev/null
  assert_eq 0 "$PREFLIGHT_PROBLEMS"
}

test_preflight_bash_accepts_this_shell() {
  capture preflight_bash
  assert_eq 0 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "preflight: ok bash"
}

test_missing_python3_fails_loudly() {
  local tool
  mkdir -p "$TEST_TMP/bin"
  # everything install.sh needs before the python check, and no python3
  for tool in dirname uname sed tr head id mkdir chmod cp cmp touch grep cat; do
    ln -s "$(command -v "$tool")" "$TEST_TMP/bin/$tool"
  done
  assert_status 1 env PATH="$TEST_TMP/bin" "$BASH" "$REPO_DIR/install.sh" --dry-run --prefix "$TEST_TMP/root" --transport none
  assert_contains "$CAPTURED_STDERR" "python3 was not found on PATH"
  assert_contains "$CAPTURED_STDERR" "grant compiler needs python"
  assert_eq "" "$CAPTURED_STDOUT" "no plan is printed without python3"
}

test_detect_os_override() {
  assert_eq macos "$(SIRVEN_OS_OVERRIDE=macos detect_os)"
  assert_eq linux "$(SIRVEN_OS_OVERRIDE=linux detect_os)"
  SIRVEN_OS_OVERRIDE=windows
  assert_status 1 detect_os
  assert_contains "$CAPTURED_STDERR" "must be linux or macos"
}

test_detect_os_on_this_machine() {
  case "$(uname -s)" in
    Linux) assert_eq linux "$(detect_os)" ;;
    Darwin) assert_eq macos "$(detect_os)" ;;
  esac
}

test_package_name_comes_from_project_json() {
  assert_eq sirven "$(package_name "$REPO_DIR/project.json")"
  printf '{\n  "name": "Other Name"\n}\n' > "$TEST_TMP/project.json"
  assert_eq "other name" "$(package_name "$TEST_TMP/project.json")"
}
