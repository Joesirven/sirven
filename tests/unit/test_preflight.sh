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

test_bash_floor_is_the_macos_bash() {
  assert_eq 3.2 "$PREFLIGHT_MINIMUM_BASH"
  capture preflight_bash 3.2
  assert_eq 0 "$CAPTURED_STATUS"
  assert_status 1 preflight_bash 3.1
  assert_contains "$CAPTURED_STDERR" "bash 3.1 is too old"
  assert_contains "$CAPTURED_STDERR" "the version macos ships as /bin/bash"
}

test_install_started_by_sh_says_to_use_bash() {
  assert_status 1 sh "$REPO_DIR/install.sh" --help
  assert_contains "$CAPTURED_STDERR" "run this with bash"
  assert_status 1 sh "$REPO_DIR/uninstall.sh" --help
  assert_contains "$CAPTURED_STDERR" "run this with bash"
}

# fake_ssh STATUS MESSAGE: an ssh that records its arguments, prints MESSAGE, and exits STATUS.
fake_ssh() {
  mkdir -p "$TEST_TMP/bin"
  printf '#!/bin/sh\necho "$@" > "%s/ssh-arguments"\necho "%s" >&2\nexit %s\n' "$TEST_TMP" "$2" "$1" > "$TEST_TMP/bin/ssh"
  chmod +x "$TEST_TMP/bin/ssh"
  PREFLIGHT_SSH_COMMAND="$TEST_TMP/bin/ssh"
}

test_ssh_probe_reads_what_the_server_said() {
  fake_ssh 255 "Host key verification failed."
  assert_eq reachable "$(preflight_ssh_probe example.com)"
  fake_ssh 255 "probe@example.com: Permission denied (publickey)."
  assert_eq reachable "$(preflight_ssh_probe example.com)"
  fake_ssh 255 "ssh: connect to host example.com port 22: Connection refused"
  assert_eq refused "$(preflight_ssh_probe example.com)"
  fake_ssh 255 "ssh: connect to host 10.9.9.9 port 22: Connection timed out"
  assert_eq timeout "$(preflight_ssh_probe 10.9.9.9)"
  fake_ssh 255 "ssh: Could not resolve hostname nowhere.invalid: Name or service not known"
  assert_eq unresolved "$(preflight_ssh_probe nowhere.invalid)"
  if preflight_ssh_probe nowhere.invalid >/dev/null; then fail "only reachable returns 0"; fi
}

test_ssh_probe_never_authenticates_or_saves_a_host_key() {
  fake_ssh 255 "Host key verification failed."
  preflight_ssh_probe example.com 2222 4 >/dev/null
  assert_contains "$(cat "$TEST_TMP/ssh-arguments")" "-o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -p 2222 probe@example.com"
}

test_ssh_probe_refuses_hosts_that_look_like_options() {
  fake_ssh 0 ""
  assert_status 2 preflight_ssh_probe -oProxyCommand=touch
  assert_status 2 preflight_ssh_probe 'host;reboot'
  assert_status 2 preflight_ssh_probe example.com 22x
  assert_no_file "$TEST_TMP/ssh-arguments"
}

test_ssh_server_probe_is_skipped_in_a_dry_run_and_only_warns() {
  fake_ssh 255 "Connection refused"
  capture preflight_ssh_server no
  assert_contains "$CAPTURED_STDERR" "skipped the SSH server probe"
  assert_no_file "$TEST_TMP/ssh-arguments"
  PREFLIGHT_PROBLEMS=0
  capture preflight_ssh_server yes
  assert_eq 0 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "no SSH server answered on this machine (refused)"
  preflight_ssh_server yes 2>/dev/null
  assert_eq 0 "$PREFLIGHT_PROBLEMS" "a missing SSH server is never a blocking problem"
}

# make_placeholder_python: a fake python3 that is the system python3 here, and that leaves a
# marker if it is ever run. the real placeholder opens a dialog when run, so running it is the bug.
make_placeholder_python() {
  mkdir -p "$TEST_TMP/bin"
  printf '#!/bin/sh\ntouch "%s/python3-was-run"\necho "Python 3.9.6"\n' "$TEST_TMP" > "$TEST_TMP/bin/python3"
  chmod +x "$TEST_TMP/bin/python3"
  PREFLIGHT_SYSTEM_PYTHON="$TEST_TMP/bin/python3"
}

# make_xcode_select EXIT_STATUS: a fake xcode-select; 2 is what it says with no developer tools.
make_xcode_select() {
  mkdir -p "$TEST_TMP/bin"
  # shellcheck disable=SC2016 # the $1 is written into the fake xcode-select script, to expand when it runs
  printf '#!/bin/sh\n[ "$1" = -p ] || exit 1\nexit %s\n' "$1" > "$TEST_TMP/bin/xcode-select"
  chmod +x "$TEST_TMP/bin/xcode-select"
}

test_mac_without_developer_tools_gets_the_install_command_and_never_runs_the_placeholder() {
  make_placeholder_python
  make_xcode_select 2
  PATH="$TEST_TMP/bin:$PATH"
  assert_status 1 preflight_python macos
  assert_contains "$CAPTURED_STDERR" "xcode-select --install"
  assert_contains "$CAPTURED_STDERR" "nothing was changed"
  assert_no_file "$TEST_TMP/python3-was-run"
}

test_mac_with_developer_tools_checks_python_as_usual() {
  make_placeholder_python
  make_xcode_select 0
  PATH="$TEST_TMP/bin:$PATH"
  capture preflight_python macos
  assert_eq 0 "$CAPTURED_STATUS" "python3 with the developer tools installed passes: $CAPTURED_STDERR"
  assert_contains "$CAPTURED_STDERR" "preflight: ok python3 3.9.6"
  assert_file_exists "$TEST_TMP/python3-was-run"
}

test_a_python_other_than_the_system_one_works_without_the_developer_tools() {
  make_xcode_select 2
  mkdir -p "$TEST_TMP/homebrew"
  printf '#!/bin/sh\necho "Python 3.12.1"\n' > "$TEST_TMP/homebrew/python3"
  chmod +x "$TEST_TMP/homebrew/python3"
  PREFLIGHT_SYSTEM_PYTHON="$TEST_TMP/bin/python3"
  PATH="$TEST_TMP/homebrew:$TEST_TMP/bin:$PATH"
  capture preflight_python macos
  assert_eq 0 "$CAPTURED_STATUS" "a Homebrew python3 is not the placeholder: $CAPTURED_STDERR"
  assert_contains "$CAPTURED_STDERR" "preflight: ok python3 3.12.1"
}

test_linux_never_asks_about_the_developer_tools() {
  make_placeholder_python
  make_xcode_select 2
  PATH="$TEST_TMP/bin:$PATH"
  capture preflight_python linux
  assert_eq 0 "$CAPTURED_STATUS"
  assert_not_contains "$CAPTURED_STDERR" "xcode-select"
}
